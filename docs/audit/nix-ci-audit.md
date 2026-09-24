# Nix-in-CI installer audit (source trace)

Date: 2026-09-24. Local Nix used for CLI probes: `nix (Nix) 2.34.8`.
Clones: `<audit-clones>/<repo>` (fetched Nix 2.35.2 sources under `audit/nixsrc/`, upstream install script saved as `audit/upstream-install-2.35.2.sh`).
Line numbers below refer to the checked-out release tag. Nothing under `/tmp/yet-another-experiment` was read or modified; no Quince-Pie repository was accessed.

## Checkout record

| Repo | Latest release (GitHub "latest") | Tag object | Commit SHA at tag | Default branch HEAD | Release date | License |
|---|---|---|---|---|---|---|
| cachix/install-nix-action | v31.11.1 | lightweight | 13d8dd58da0234aa297dedd986986ccb8e7f3e24 | master 13d8dd58… (same) | 2026-08-13 | Apache-2.0 |
| DeterminateSystems/nix-installer-action | v23 | lightweight | 3138316df39ed29be04236d7ffc686fa525866aa | main 3138316d… (same) | 2026-09-09 | LGPL-2.1 (package.json says "ISC") |
| DeterminateSystems/nix-installer | v3.22.5 | lightweight | 76f61b5202e21eab17728915775da4ae5153a993 | main 76f61b52… (same) | 2026-09-17 | LGPL-2.1 |
| nixbuild/nix-quick-install-action | v35 | lightweight | 9f63be77f412a248c9d9a65a4c82cf066cdf8f0c | master ef2850366b5ded57dc77cad10392197c5ce70343 | 2026-06-17 | Apache-2.0 |
| actions/checkout | v7.0.1 | lightweight | 3d3c42e5aac5ba805825da76410c181273ba90b1 | main f548e57e544e1ff5a4c46bf1e1b8685f8e4a348a | 2026-07-20 | MIT |

Moving major tags: install-nix-action `v31` is an annotated tag (b85815f) pointing at 13d8dd5 (RELEASE.md:18-35 documents force-moving it); nix-installer-action publishes only `vNN` tags; nix-quick-install-action publishes only `vNN` tags.

## 1. cachix/install-nix-action v31.11.1 (13d8dd58)

Mechanism (`install-nix.sh`):
- :105 `nix_version=2.35.2`; :106 `curl -sS -o "$workdir/install" -v --fail -L "${INPUT_INSTALL_URL:-https://releases.nixos.org/nix/nix-${nix_version}/install}"`; :115 `sh "$workdir/install" "${installer_options[@]}"`.
- The version is hard-coded in the action. There is no `nix_version` input; `action.yml:5-22` lists only `extra_nix_config`, `github_access_token`, `install_url`, `install_options`, `nix_path`, `enable_kvm`, `set_as_trusted_user`. To pin, use `install_url` (README:61: "Useful for … pinning a specific Nix version (e.g., https://releases.nixos.org/nix/nix-2.3.7/install)").
- Version bumps are automated: `.github/workflows/update-nix.yml:16-31` runs daily, takes the newest `NixOS/nix` tag via `gh api repos/NixOS/nix/tags`, `sed`s `nix_version=`, opens a PR. Git log: `6624a11 nix: 2.35.1 -> 2.35.2`, `0247906 nix: 2.34.8 -> 2.35.1`.

Integrity:
- The action does not verify the install script (plain `curl … | sh` split into two steps, no hash, no signature).
- The upstream script embeds per-system tarball hashes and enforces them: `upstream-install-2.35.2.sh:39-41` (`hash=4d0302a2…`, `path=…/nix-2.35.2-aarch64-linux.tar.xz`, `system=aarch64-linux`), :105-116 (`oops "SHA-256 hash mismatch in '$url'; expected $hash, got $hash2"`).
- releases.nixos.org publishes `install.sha256` (= `9adda97297d9e8ab360df95c729eabff4f4f93d6db091953c3a68f29e3fb130c`, matches the downloaded script) and `<tarball>.sha256` sidecars; no `SHA256SUMS`, no signatures. Trust chain = TLS to releases.nixos.org + script-embedded hashes. A workflow can pin the script hash itself by using `install_url` plus a separate checksum step; the action does not offer that.

Install mode: :76-86 uses `--daemon --daemon-user-count $((cpu*2))` when `/run/systemd/system` exists (true on `ubuntu-24.04` and `ubuntu-24.04-arm`) unless `install_options` contains `--no-daemon`; otherwise single-user with `build-users-group =`. Always `--no-channel-add --nix-extra-conf-file`.

nix.conf side effects (written by the upstream installer into `/etc/nix/nix.conf` from the extra-conf file):
- :31 `show-trace = true`; :33 `max-jobs = auto`; :41 `trusted-users = root ${USER}` (default `set_as_trusted_user: true`).
- :45-55 `access-tokens = github.com=<token>`: uses `github_access_token` if given, else the workflow's default `GITHUB_TOKEN` (`action.yml:39 GITHUB_TOKEN: ${{ github.token }}`) when `GITHUB_SERVER_URL == https://github.com`. So the job token lands in `/etc/nix/nix.conf` by default.
- :57-62 `extra_nix_config` appended verbatim; `experimental-features = nix-command flakes` added unless the extra config mentions `experimental-features`; :65-67 `always-allow-substitutes = true` unless overridden.
- Env: `NIX_PROFILES`, `NIX_SSL_CERT_FILE` (probe list :157-174), `TMPDIR=$RUNNER_TEMP` if unset, PATH additions (:179-182). KVM udev rule via sudo by default (:9-18).

aarch64-linux: CI matrix runs `ubuntu-24.04-arm` and `ubuntu-22.04-arm` with `system: aarch64-linux` (`.github/workflows/test.yml:27-31`); upstream script supports it.
Runtime: composite, bash (`action.yml:27-30`). No Node.
Maintenance: release 2026-08-13; last push 2026-08-14; SemVer since v31 (RELEASE.md:3). 699 stars. License Apache-2.0.

## 2. DeterminateSystems/nix-installer-action v23 (3138316d) + nix-installer v3.22.5 (76f61b52)

Mechanism (action, bundled detsys-ts in `dist/index.js`):
- Download host: `dist/index.js:170582 const DEFAULT_IDS_HOST = "https://install.determinate.systems"`, with DNS SRV discovery `_detsys_ids._tcp.install.determinate.systems.` (:170580) restricted to `.install.determinate.systems`/`.install.detsys.dev` (:170581).
- URL: :171693-171703 `<root>/nix-installer/{tag/<t>|pr/<n>|branch/<b>|rev/<r>|stable}/<nix-system>`; default is **`/stable`** (moving). The fetch adds `?ci=github&correlation=<identity json>` (:171567-171569). README:66: "This GitHub Action uses the most recent version of Determinate Nix Installer, even when the Action itself is pinned." Pin with `source-tag: v3.22.5` (action.yml:102-104).
- Integrity: none by default. Opt-in `source-checksums-url` + `source-checksums-sha256` (action.yml:108-118; verification at dist:171613-171631 and :171637-171641); requires a pinned `source-tag`/`source-revision`/`source-url` (dist:170980-170982). No signature verification. Cached in the tool cache keyed by ETag (:171570-171583).
- The installer binary contains the Determinate Nix tarball: `nix-installer/src/distribution.rs:47-51` (`include_bytes!(env!("DETERMINATE_NIX_TARBALL_PATH"))`) and `determinate-nixd` (:56). Upstream Nix, when selected, is downloaded at run time from `NIX_TARBALL_URL` = `https://releases.nixos.org/nix/nix-2.35.2/nix-2.35.2-<system>.tar.xz` (`flake.nix:37,91`), by `src/action/base/fetch_and_unpack_nix.rs:116-196` (reqwest GET, xz+tar unpack). No SHA-256 check exists in that file; none found elsewhere (UNVERIFIED negative).

Determinate Nix vs upstream (source of truth):
- `action.yml:10-13`: `determinate: … default: true`. `src/index.ts:125-126`: `this.determinate = inputs.getBool("determinate") || inputs.getBool("flakehub")`.
- `src/index.ts:425-441`: if determinate → arg `--determinate`; else → `--prefer-upstream-nix`.
- Installer `src/settings.rs:324-333`: `distribution()` returns `DeterminateNix` for `--determinate`, `Nix` for `--prefer-upstream-nix`, and **`DeterminateNix` when neither is set** (the installer's own default is Determinate Nix too).
- README:36-37 "This Action installs Determinate Nix by default. You can still use it to install upstream Nix … although that isn't a supported configuration."; README:151-152 "Installing upstream Nix isn't a supported configuration. The option remains available for now, but we may remove it in a future release."

Default Nix version at v3.22.5: Determinate Nix 3.22.5, whose release notes state "Based on upstream Nix 2.35.2" (DeterminateSystems/nix-src release v3.22.5, 2026-09-17; the installer's `nix` input is `flakehub.com/f/DeterminateSystems/nix-src`, locked rev 6468ca43). With `determinate: false`, upstream Nix 2.35.2 (flake.nix:37). Because the action fetches `/stable`, both float with each installer release unless `source-tag` is set.

nix.conf side effects:
- Action-assembled `NIX_INSTALLER_EXTRA_CONF` (`src/index.ts:348-368`): `access-tokens = github.com=<github-token>` (default `${{ github.token }}`, action.yml:28-30); `trusted-users = root <runner user>` (`trust-runner-user` default true); `build-provenance-tags = {…json…}`; then `extra-conf` lines.
- Installer standard config (`src/action/common/place_nix_configuration.rs:124-177`): `extra-experimental-features = nix-command flakes`; `auto-optimise-store = true` (non-macOS); `always-allow-substitutes = true`; `extra-trusted-substituters = https://cache.flakehub.com`; `extra-trusted-public-keys = cache.flakehub.com-3 … -10`; `bash-prompt-prefix`; `max-jobs = auto`; `extra-nix-path = nixpkgs=flake:nixpkgs`; `upgrade-nix-store-path-url = https://install.determinate.systems/nix-upgrade/stable/universal`. `--extra-conf` goes to `nix.custom.conf` (comment :180-186). No netrc written by the action for upstream mode.
- FlakeHub login (`src/index.ts:748-800`): only when determinate=true and OIDC env present; runs `determinate-nixd login github-action`; failure is a warning. Daemon is `determinate-nixd` when determinate (:535-538).

Telemetry:
- `action.yml:133-136` `diagnostic-endpoint` default `"-"`. `dist/index.js:170664-170678`: `""` → disabled; `"-"`/unset → `<root>/events/batch`; the URL is passed as `NIX_INSTALLER_DIAGNOSTIC_ENDPOINT` (`src/index.ts:286-287`). Installer CLI: `src/cli/mod.rs:68-79` (`--diagnostic-endpoint`, `NIX_INSTALLER_DIAGNOSTIC_ENDPOINT`, disable with `""`); installer README:455-471 lists what is sent.
- The action itself also POSTs a check-in to `<root>/check-in` with `distinct_id`/`anon_distinct_id`/person properties (dist:171519-171545) and emits OpenTelemetry spans; whether that can be switched off was not traced (UNVERIFIED).

aarch64: README:9 "Linux (x86_64 and aarch64)"; installer `flake.nix:38` `supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]` (x86_64-darwin dropped; `src/index.ts:95-106` pins v3.12.2 for Intel Macs).
Runtime: `node24`, main+post (`action.yml:164-166`).
Maintenance: action v23 2026-09-09; installer v3.22.5 2026-09-17, pushed 2026-09-24; 250 / 3699 stars. License LGPL-2.1 (both LICENSE files; action `package.json:23` says "ISC").

## 3. nixbuild/nix-quick-install-action v35 (9f63be77)

Mechanism (`nix-quick-install.sh`):
- :80-81 `rel="$(head -n1 "$RELEASE_FILE")"` (RELEASE:1 = `v35`); `url="…/releases/download/$rel/nix-$NIX_VERSION-$sys.tar.zstd"`.
- :89-90 `curl -sL --retry 3 --retry-connrefused "$url" | tar --skip-old-files --strip-components 1 -x -I unzstd -C /nix`. Streamed straight into tar; **no checksum or signature**. GitHub exposes per-asset `sha256:` digests via the Releases API (all 31 assets listed during the audit), but the script does not use them.
- Archives are prebuilt by the project's own CI from `github:nixos/nix/<ver>` flake inputs (`flake.nix:7-13`, e.g. `nix_2_34.url = "github:nixos/nix/2.34.7"`), built on `ubuntu-22.04`, `ubuntu-24.04-arm`, `macos-15`, `macos-15-intel` (`cicd.yml:17-21`) and uploaded by `packages.release` (`flake.nix:109-140`).
- Versions offered at v35 (release assets): 2.3.18 (no aarch64-linux), 2.28.7, 2.29.4, 2.30.5, 2.31.5, 2.32.8, 2.33.6, 2.34.7. No 2.35.x. Default `nix_version: "2.34.7"` (`action.yml:7-9`). Old versions are dropped (RELEASE:9 "Remove Nix version 2.26.4").

Install mode: single-user, no daemon (`action.yml:2`; script :67 `sudo install -d -o "$USER" /nix`; README:14, :30-32). Speed claim README:16: "Installs ≈ 1 second on Linux, ≈ 5 seconds on MacOS".

nix.conf side effects (user-level `${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf`, :95):
- :98-99 `nix_conf` input replaces the file; :103-105 `access-tokens = github.com=<token>` (default `${{ github.token }}`, action.yml:28-29); :109-111 also writes `~/.netrc` (`machine github.com / login github-token / password <token>`).
- :115-119 for Nix > 2.13: `extra-experimental-features = nix-command flakes` and **`accept-flake-config = true`** (flake-provided `nixConfig` is accepted without prompting).
- KVM udev rule by default (:37-43); `nix_on_tmpfs` optional.

aarch64-linux: script :15-17 maps `aarch64`; assets exist for every version except 2.3.18; CI runs `ubuntu-24.04-arm`.
Runtime: composite, bash (`action.yml:55`).
Maintenance: v35 2026-06-17, previous v34 2025-09-24 (nine-month gap); last push 2026-08-04; 169 stars; single maintainer. License Apache-2.0.

## 4. actions/checkout v7.0.1 (3d3c42e5)

Annotated tag push, default inputs (`ref` = `github.ref` = `refs/tags/vX`, `commit` = `github.sha`, `fetch-depth: 1` (action.yml:74-76), `fetch-tags: false` (:77-79)):
- `src/git-source-provider.ts:213-219`: `getRefSpec(settings.ref, settings.commit, settings.fetchTags)`.
- `src/ref-helper.ts:109-113`: for `refs/tags/` with a commit and `!fetchTags` → refspec `+refs/tags/vX:refs/tags/vX`.
- `src/git-command-manager.ts:285-312`: `git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules [--progress] [--filter=…] --depth=1 origin +refs/tags/vX:refs/tags/vX` (comment :286-287: "Always use --no-tags for explicit control over tag fetching. Tags are fetched explicitly via refspec when needed").
- `src/ref-helper.ts:191-197` then requires `commit === revParse("refs/tags/vX^{commit}")` ("Use ^{commit} to dereference annotated tags to their underlying commit"); mismatch throws "The ref … does not point to the expected commit" (git-source-provider.ts:224-229).
- `getCheckoutInfo` (:45-47) returns `ref = refs/tags/vX`; `git checkout --force refs/tags/vX` (git-source-provider.ts:271).
- Empirical check (local git, same fetch command against a repo with an annotated tag): `git cat-file -t refs/tags/v1` → `tag`; `refs/tags/v1^{commit}` equals the tagged commit; `git verify-tag v1` → `error: no signature found` (the tag object is present; a signed tag would be verifiable given the key). Conclusion: yes, the annotated tag object itself is fetched with default inputs because the refspec names the tag ref; `--no-tags` only disables auto-following. That `github.sha` is the peeled commit for annotated tags is GitHub's documented behaviour and was not re-verified here (UNVERIFIED).

persist-credentials: default `true` (action.yml:52-54). Stores `http.https://github.com/.extraheader = AUTHORIZATION: basic <base64 x-access-token:TOKEN>` (`src/git-auth-helper.ts:57-64`) in a separate file `$RUNNER_TEMP/git-credentials-<uuid>.config` (:416-428) referenced from the repo's `.git/config` via `include.path`/`includeIf.gitdir:` (:345-400), plus `url.https://github.com/.insteadOf git@github.com:` (:67-68). Removed in the post step only if `persist-credentials: false` (git-source-provider.ts:319-323).
set-safe-directory: default `true` (action.yml:95-97) → `git config --global --add safe.directory <path>` in a temporary global config (git-source-provider.ts:46-62).
Runtime: `node24` (action.yml:116-118); `package.json:31-32 "engines": {"node": ">=24"}`. License MIT.

## 5. Upstream Nix facts

- Latest stable: **2.35.2**. nixos.org/download shows "Current version 2.35.2". Tag `2.35.2` = commit 2c73b59da29606068c0c98db015dd3a66955525d, committed 2026-08-12; `releases.nixos.org/nix/nix-2.35.2/install` Last-Modified 2026-08-12. Series: 2.34.8 (2026-07-01), 2.35.0 (tag 2026-07-13; `rl-2.35.md:1` header says "Release 2.35.0 (2026-06-22)"), 2.35.1 (2026-07-13). NixOS/nix has no GitHub Release objects (API `releases/latest` returns null); tags only. Docker Hub `nixos/nix:2.35.2` pushed 2026-08-12.
- `nix flake check --all-systems`: `src/nix/flake.cc:329-333` "Check the outputs for all systems." `--no-update-lock-file` / `--no-write-lock-file`: `src/libcmd/installables.cc:65-77` ("Do not allow any updates to the flake's lock file." / "Do not write the flake's newly generated lock file."). Online manual (2.35.2) shows all three with identical wording.
- `nix flake metadata --json` (2.34.8 probe on a git flake and on `github:NixOS/flake-compat`): top-level keys `fingerprint, lastModified, locked, locks, original, originalUrl, path, resolved, resolvedUrl, revCount, revision, url`. **`narHash` is not a top-level key** (null); it is `locked.narHash` (with `locked.rev`, `locked.lastModified`, `locked.type`, `locked.__final`). `revision` and `lastModified` are top-level. `src/nix/flake-metadata.md:25-50` shows the same shape.
- `nix hash path`: present ("print cryptographic hash of the NAR serialisation of a path"). NAR dump: current name is **`nix nar pack`**; `nix nar dump-path` is a deprecated alias (`src/nix/dump-path.cc:73` `warn("'nix nar dump-path' is a deprecated alias for 'nix nar pack'")`, :78-79). `nix store dump-path` is a separate command for store paths (dump-path.cc:38). The 2.35.2 online manual still has a `nix nar dump-path` page whose example uses `nix nar pack`.
- `nix flake archive`: present ("copy a flake and all its inputs to a store").
- `nix build --rebuild`: `src/nix/build.cc:115-119` "Rebuild an already built package and compare the result to the existing store paths." (`bmCheck`).
- `nix path-info --json` on 2.34.8: default output is an object keyed by full store path; fields `ca, deriver, narHash (SRI string), narSize, references (full paths), registrationTime, signatures, storeDir, ultimate, version`. 2.34.8 warns "'--json' without '--json-format' is deprecated; please specify '--json-format 1' or '--json-format 2'. This will become an error in a future release." `--json-format 2` yields `{"version":2,"storeDir":"/nix/store","info":{"<basename>":{…references as base names…}}}`. 2.35.2 adds format 3 (`src/nix/path-info.cc:143-150`: "Version 1 uses string hashes and full store paths. Version 2 uses structured hashes and store path base names. Version 3 uses structured signatures. This flag will be required in a future release."); 2.34.8 rejects `--json-format 3`. Scripts should pass `--json-format 1` explicitly for the keyed-by-path shape.
- `nix derivation show`: present ("show the contents of a store derivation").
- `github:` narHash is computed over the unpacked tree: `src/libfetchers/github.cc:262-331` unpacks the API tarball into the git tarball cache and records a git `treeHash` (:311-317), comparing it with GitHub's reported tree hash (:323-328); `getAccessor` (:335-347) exposes that tree; `src/libfetchers/fetchers.cc:196-216` `Input::fetchToStore` copies the accessor into the store and sets `narHash = store.queryPathInfo(storePath)->narHash`. Manual `src/nix/flake.md:141-144`: "narHash: The hash of the Nix Archive (NAR) serialisation … of the contents of the flake"; :709-711 "as computed by nix hash-path". Compression or tarball re-packing does not affect it.

## 6. Docker alternative: `nixos/nix`

- Publisher: the NixOS project (Docker Hub namespace `nixos/nix`, not the Docker "Official Images" library). Built from `docker.nix` in NixOS/nix by `maintainers/upload-release.pl:205-263` (loads Hydra-built `dockerImage.{x86_64,aarch64}-linux`, pushes `<ver>-amd64`, `<ver>-arm64`, then `docker manifest create/push <ver>` and `latest`), driven by the manual `Upload Release` workflow (`upload-release.yml`, `workflow_dispatch` with a Hydra eval id); also pushed to `ghcr.io/nixos/nix` (:70-79).
- Current: `latest` = `2.35.2`, pushed 2026-08-12. Manifest list digest `sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c` → `linux/amd64 sha256:617d914dba5384bf75adf17081583b69371031ec7defce36c34c5fa14fc819b0`, `linux/arm64 sha256:a326ac1ed46069ead5cdcba3a3a1e7255ebf72300c8319bf2c12cacfe9ab2787`. Pin: `container: image: docker.io/nixos/nix@sha256:7a007c76…` (multi-arch index; resolves per runner arch). Version tags back to 2.28.7 have arm64 variants.
- Image config (`docker.nix` at 2.35.2): runs as root (uid 0, :18-21); `/etc/nix/nix.conf` = `sandbox = false`, `build-users-group = nixbld`, `trusted-public-keys = cache.nixos.org-1:…` (:186-191); no experimental features enabled (set `NIX_CONFIG` or `--extra-experimental-features`).
- Downsides on GitHub-hosted runners: `container:` jobs run every step as root inside the image (store and workspace owned by root; checkout mitigates git ownership via `safe.directory`); the build sandbox is off and enabling it needs user namespaces/privileges in the container (not tested, UNVERIFIED); `container:` jobs are Linux-only and add image pull time; JavaScript actions must run with GitHub's injected Node inside a glibc-less Nix-built rootfs (compatibility not tested, UNVERIFIED). Advantage: exact pin by digest, no installer download, arm64 available.

## Comparison

| | cachix/install-nix-action v31.11.1 | DeterminateSystems/nix-installer-action v23 | nixbuild/nix-quick-install-action v35 | `nixos/nix` container 2.35.2 |
|---|---|---|---|---|
| Mechanism | curl upstream `install` script → `sh` (multi-user daemon on systemd) | fetch `nix-installer` binary from install.determinate.systems, run planner `linux` | curl prebuilt `.tar.zstd` from its own GitHub release → tar into `/nix` (single-user) | prebuilt image built from `docker.nix` |
| Download source | releases.nixos.org (script + tarball) | install.determinate.systems (`/nix-installer/stable/<system>`); upstream tarball from releases.nixos.org only if `determinate: false` | github.com/nixbuild/…/releases/download/v35/ | Docker Hub / ghcr.io |
| Integrity | script unverified; tarball SHA-256 embedded in script (upstream-install:39,105-116); `install.sha256` published | none by default; opt-in `source-checksums-*` (requires pinned `source-tag`); embedded Determinate tarball; upstream tarball fetch has no hash check found | none (curl → tar); asset digests exist in the GitHub API but unused | content-addressed digest |
| Pinnability | Nix version hard-coded per release (2.35.2); override via `install_url` | installer floats on `stable` unless `source-tag`; Nix version = installer's embedded/`NIX_TARBALL_URL` | `nix_version` input, but only versions shipped with that action release (max 2.34.7) | exact digest |
| Upstream vs fork | upstream NixOS Nix | **Determinate Nix by default** (`determinate: true`; installer defaults to Determinate too); upstream via `determinate: false` ("not a supported configuration") | upstream NixOS Nix built by nixbuild CI | upstream NixOS Nix |
| aarch64-linux | yes (CI on ubuntu-24.04-arm) | yes | yes (except 2.3.18) | yes (arm64 manifest) |
| nix.conf side effects | `/etc/nix/nix.conf`: trusted-users, `access-tokens = github.com=$GITHUB_TOKEN` (default), experimental-features, always-allow-substitutes, max-jobs, show-trace, + `extra_nix_config` | `/etc/nix/nix.conf` + `nix.custom.conf`: access-tokens (github.token), trusted-users, build-provenance-tags, FlakeHub trusted substituter/keys, extra-nix-path, upgrade-nix-store-path-url, auto-optimise-store, …; diagnostics to install.determinate.systems by default; FlakeHub login if OIDC | user `~/.config/nix/nix.conf`: access-tokens, experimental-features, **`accept-flake-config = true`**; `~/.netrc` with token | image nix.conf: `sandbox = false`, cache.nixos.org key; no flakes enabled |
| Runtime | composite/bash | node24 (main+post) | composite/bash | n/a (`container:` job) |
| Last release | 2026-08-13 | action 2026-09-09; installer 2026-09-17 | 2026-06-17 (prev. 2025-09-24) | 2026-08-12 |
| License | Apache-2.0 | LGPL-2.1 | Apache-2.0 | LGPL-2.1 (Nix) |

## Unresolved / UNVERIFIED

- nix-installer: no SHA-256 check of the upstream tarball found in `fetch_and_unpack_nix.rs`; a check elsewhere was not found but not exhaustively excluded.
- nix-installer-action: whether the action's own OpenTelemetry/check-in traffic can be disabled (only `diagnostic-endpoint: ""` was traced).
- `github.sha` peeling for annotated tags relies on GitHub's documented behaviour; not re-tested.
- Running Node-based actions inside the `nixos/nix` container and enabling `sandbox = true` there were not tested.
- Docker Hub image size and pull time not measured.
