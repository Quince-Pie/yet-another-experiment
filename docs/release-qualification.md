# Release system qualification record

Date of qualification: 2026-09-24. Scope: the release system for this
repository as delivered at the revision that carries this file, hosted on
GitHub only. The contract it must satisfy is `docs/release-contract.md`;
that contract was fixed before the design below was selected and was not
changed to fit it. Verbatim source-audit records with repository revisions
and file:line evidence are under `docs/audit/`.

## 1. Baseline and selection rule

**Baseline.** Before this work the repository had one file, no commits, no
tags, no lock file, no CI and no release process. Nothing recorded which
`nixpkgs` narHash the flake was built against, nothing checked that the
shells built or that C23 was actually the default, and nothing bound a
version to a tree.

**Feasibility constraints** (not traded against anything): every check in
contract section 3; byte-for-byte reproducibility of the payloads in
contract section 2; recipient verification without maintainer credentials;
native verification on both declared systems; no third-party hosting
outside GitHub; no secrets in the workflow beyond `GITHUB_TOKEN`.

**Objectives, in the order used to break ties among feasible designs:**
strength of what a recipient can independently re-derive; size of the
trusted third-party code surface; wall-clock and runner minutes per release;
maintainer effort per release; number of moving parts to keep patched.

## 2. Contenders and decisions

Each row names the mechanism that would make the contender win, the cost
that decided against it, and the evidence (record section). "Rejected" means
a contract violation or decisive evidence; "deferred" means out of scope
with the reason.

### 2.1 Version, changelog and release orchestration

| Contender | Would win by | Decision | Evidence |
|---|---|---|---|
| Keep a Changelog section extracted by CI (**selected**) | no runtime, no tokens, human-written notes, tag stays maintainer-signed | selected | frontier §1.2 |
| release-please v5 | automatic version bumps from Conventional Commits via a bot PR | rejected: the bot creates the tag with a token, so the release anchor cannot be a maintainer-held key; requires a PR flow and `version.txt` this repository does not have | frontier §1.1 |
| semantic-release v25 | fully automatic versioning in CI | rejected: same anchor problem (tag created by CI credential); Node runtime; Conventional Commits mandatory | frontier §1.1 |
| git-cliff v2.14 | notes rendered from git history at tag time, single Rust binary | rejected for notes: quality equals commit-message quality and Keep a Changelog's own rationale ("commit log diffs as changelogs ... are full of noise"); it stays a valid later add-on for drafting the section | frontier §1.1 |
| changie / towncrier | per-change fragments | rejected: a fragment directory and a tool run per release for a repository with a handful of changes per release | frontier §1.2 |
| GitHub auto-generated notes | zero files | rejected as the sole source: it lists merged pull requests; a single maintainer pushing directly yields an empty body | frontier §1.1 |

Ecosystem check: of NixOS/nix, home-manager, devenv, treefmt-nix, sops-nix
and nix-installer, none uses any of the rejected tools; the only one whose
release anchor is a maintainer-signed tag (NixOS/nix, OpenPGP keys vendored
in-repo) uses the same shape as this design (frontier §1.3).

### 2.2 Publishing the GitHub Release

| Contender | Would win by | Decision | Evidence |
|---|---|---|---|
| `gh` CLI preinstalled on the runner, driven by `scripts/release.sh` (**selected**) | GitHub-maintained binary already on the image; draft-first with explicit `--draft`; asset digests via the API let the script verify uploads before publishing | selected | gh-cli §1 |
| softprops/action-gh-release v3.0.3 | one step, popular | rejected: pre-releases are created already published unless `draft: true` (not immutable-release safe by default); its bundled `@octokit/plugin-retry`/`throttling` are never imported so the retry options are inert; 793 KB minified bundle of 33 packages; floating `v3` tag | gh-cli §2, §5 |
| ncipollo/release-action v1.21.0 | one step | rejected: draft-first only with `immutableCreate: true`; upload failures are warnings by default so a release can publish without its asset; update path publishes before uploading | gh-cli §3 |

`gh release create` itself uploads to a draft and publishes afterwards, and
deletes the draft on failure (gh-cli §1a). The script keeps `--draft` so a
failed upload leaves a draft for diagnosis, and it detects stale drafts by
listing releases, which `gh`'s own published-only check does not (gh-cli
§1a). Post-upload verification compares name, size and SHA-256 digest of
every asset with the local file before the single publish call.

### 2.3 Installing Nix on the runner

| Contender | Would win by | Decision | Evidence |
|---|---|---|---|
| cachix/install-nix-action v31.11.1 with the installer script fetched and hash-checked first (**selected**) | upstream Nix, official installer whose embedded tarball hashes are pinned by the script hash; composite bash, ~180 lines, auditable; daemon mode gives sandboxed builds | selected; the action alone does not verify the script it downloads, so the workflow pins its SHA-256 (verified against `install.sha256`) | nix-ci §1 |
| DeterminateSystems/nix-installer-action v23 | fast Rust installer | rejected: installs Determinate Nix (a fork) by default and calls upstream "not a supported configuration"; the installer floats on `/stable` unless pinned; telemetry to install.determinate.systems by default; adds FlakeHub substituters | nix-ci §2 |
| nixbuild/nix-quick-install-action v35 | ~1 s install from prebuilt archives | rejected: `curl \| tar` with no checksum; newest offered Nix is 2.34.7; sets `accept-flake-config = true`, which lets any evaluated flake change Nix settings; writes the token to `~/.netrc` | nix-ci §3 |
| `nixos/nix` container pinned by digest | exact image pin, no installer | deferred: steps run as root with the sandbox off, and Node-based actions inside the image are untested | nix-ci §6 |

Installed Nix: upstream 2.35.2 (latest stable at qualification; nix-ci §5).

### 2.4 Provenance

| Contender | Would win by | Decision | Evidence |
|---|---|---|---|
| actions/attest v4.2.2 (**selected**) | GitHub OIDC identity in the Sigstore certificate (workflow path and ref set by GitHub, not by the job), public-good Fulcio and Rekor for public repositories, bundle written to a file the workflow can ship as an asset; verifiable by `gh` (no token with `--bundle`), cosign and sigstore-python | selected; `dist/index.js` was rebuilt from source and matched byte-for-byte except a stale unreferenced chunk | attest §A |
| actions/attest-build-provenance v4.2.2 | familiar name | rejected: it is now a composite wrapper that pins actions/attest v4.2.1; using actions/attest directly removes a layer | attest §A.0 |
| slsa-github-generator | SLSA Build L3 via an isolated reusable builder | rejected: README states it is no longer actively maintained; builders must be referenced by mutable tag | frontier §3.1 |
| cosign keyless signing inside the job | no GitHub attestation store | rejected: identical identity and guarantees to actions/attest but without the API copy and with an extra binary to fetch | attest §C |
| no provenance | simplest | rejected by contract section 3 item 7 | |

SLSA level: GitHub documents artifact attestations as Build L2; L3 would
need the attestation to be produced outside the job that produced the
assets. It is not pursued because every payload field a recipient relies on
is recomputed by the recipient (narHash, evaluation identities), so a
forged predicate gains an attacker nothing the other checks would not
catch (contract section 5).

### 2.5 The maintainer's authorization anchor

| Contender | Would win by | Decision | Evidence |
|---|---|---|---|
| SSH-signed annotated tag, `allowed_signers` in-tree, OpenPGP also accepted (**selected**) | offline key never in CI; `git verify-tag` and `ssh-keygen -Y verify` are ubiquitous; GitHub shows "Verified" once the key is registered; Nix's `verifyCommit` can consume SSH signatures | selected | frontier §4.1 |
| gitsign (Sigstore keyless for tags) | no long-lived key | rejected: GitHub does not show such tags as verified, signing needs a browser OIDC flow and network, and recipients need gitsign plus the Sigstore root | frontier §4.3 |
| CI-only signature (attestation as the anchor) | zero maintainer setup | rejected: anyone able to push a matching tag obtains the same identity; it is provenance of observation, not authorization | frontier §4.4 |

### 2.6 Payload form

The NAR of the tagged tree is selected because its SHA-256 *is* the
`narHash` every consumer's `flake.lock` pins, and that hash is identical
across the `github:` tarball, `git+https`, a local `git archive` and a
fresh clone (frontier §2.1, §5; measured again in `tests/test-release.sh`).
A `git archive` tar is also byte-stable but its digest is not what Nix
checks; GitHub's `.tar.gz` bytes are explicitly not promised stable beyond a
notice period (gh-platform §5, frontier §2.2), so they are never hashed.

### 2.7 Destinations and caches

GitHub Release plus the `github:` fetcher is the whole distribution path;
immutable releases (GA 2025-10-28) are recommended to the maintainer because
they make the tag-to-commit binding platform-enforced and add a
GitHub-signed release attestation (gh-platform §1). FlakeHub is the only
contender offering SemVer-range consumption but is a third-party hosted
service and out of scope by the GitHub-only constraint (frontier §2.3).
Binary caches add nothing: every store path the shells need is served by
cache.nixos.org, and the shell derivations themselves are trivial. Store
caching between runs is rejected on evidence: GitHub evicts cache entries
unused for 7 days, releases are less frequent than that, and the cold
download is the smaller part of a job that completes in about a minute
(section 4).

## 3. Correctness and security evidence

- `tests/test-release.sh`: 41 contract cases covering tag authorisation
  (lightweight, unsigned, untrusted key, malformed name, tag behind HEAD,
  re-created tag), changelog extraction, NAR reproduction from an
  independent clone (byte-identical), smoke tests in all seven shells,
  manifest assembly, and the publish state machine against a fake `gh`
  (missing remote tag, lightweight remote tag, already published, stale
  draft replaced, asset mismatch refused, failed upload not published,
  repeated publish refused). Run locally on Nix 2.34.8 and on both runner
  types on Nix 2.35.2.
- `nix flake check --all-systems`: format, lint (actionlint, zizmor
  pedantic persona with every audit enabled offline, shellcheck), and all
  dev shells built from the lock file; passes locally and on both runners.
- mkShell determinism: `nix build --rebuild --cores 2` of the gcc shell
  reports non-deterministic output (the env dump records
  `NIX_BUILD_CORES`), which is why built shells are excluded from the
  reproducibility claim (contract section 2).
- Workflow hardening: `permissions: {}` at every top level, write
  permissions only in the publish job, every action pinned by full commit
  SHA, `persist-credentials: false`, no `${{ }}` interpolation inside `run:`
  scripts, no caches in the release path, tag names reach scripts only
  through environment variables.
- Live acceptance on GitHub: see section 4.

## 4. Live acceptance and measurements

`docs/audit/live-acceptance.md` records the runs, revisions, timings, the
published release, the recipient transcript and the adversarial cases. In
summary, on this repository's real flake with a throwaway signing key:

| Check | Result |
|---|---|
| Tag push to published pre-release `v0.1.0-rc.2`, both systems verified natively | 118 s end to end; verify jobs 66 s (aarch64) and 77 s (x86_64), publish job 27 s |
| Cold substitution per system (fresh store) | 156 paths, 702 to 710 MiB download, 2.8 GiB unpacked |
| Recipient verification without credentials (cosign and gh paths) | all five checks pass in 6.6 s |
| Tampered NAR, tampered manifest with matching checksums, tampered provenance, wrong trust root, wrong tag, missing release | all rejected with the expected reason |
| Unsigned annotated tag pushed | rejected in 5 s at the tag job; nothing published |
| Publish job re-run for the published tag | refused ("already published"); release unchanged |
| GitHub tarball for the tag vs. packed NAR vs. git tree | identical narHash (cross-check in the publish job and in the recipient script) |
| Nix `verifyCommit` with the signing key over `git+https` | accepts the tag's commit; rejects another key |

Efficiency reading: the dominant cost of a release is the two verify jobs,
and within them the toolchain substitution plus the tooling tests; the
publish job is under half a minute. At the project's release cadence
(toolchain bumps, well under one a week) no cache could be reused across
runs, so none is configured; a release costs about three runner-minutes
in total.

## 5. Residual risks and unresolved evidence

- The in-tree trust roots protect against unsigned or accidentally pushed
  tags, not against an actor with push access who also edits the trust
  roots; the recommended tag ruleset (RELEASING.md) and recipient-side
  verification against out-of-band keys close that gap.
- `actions/attest` selects the public Sigstore instance from the event
  payload's `repository.visibility`; if a future event lacked that field the
  bundle would be TSA-only and the recipient's cosign check would fail
  closed (attest §A.3, §G.5).
- Repositories created after 2026-07-15 use immutable OIDC subject claims;
  the certificate SAN format observed on the live run is recorded in
  `docs/audit/live-acceptance.md` and the recipient script matches it
  exactly.
- `ubuntu-latest` moves to 26.04 between 2026-10-19 and 2026-11-19; the
  workflows pin `ubuntu-24.04` and `ubuntu-24.04-arm`, which are supported
  until at least 2027 (gh-platform §3).
- No independent throughput measurement of cache.nixos.org from GitHub
  runners exists in the sources; the measured job times in section 4 are
  the evidence used.
- The repository has no LICENSE file; nothing in the release system can
  supply one, and an "open-source" release without a licence is a gap only
  the maintainer can close.

## 6. What the evidence does and does not establish

Established: the contract's checks, reproducibility boundary, failure
semantics and recipient verification are implemented and were exercised
end to end on GitHub for this repository's actual outputs on both declared
systems. Every contender that could have reversed a selection was
examined at source and rejected for a stated reason.

Not established: any literal optimality claim. A scoped selection under
the rule in section 1 is not a proof that no other design is better on
every objective; in particular a reusable-workflow (SLSA L3) variant was
deferred with reasons rather than measured.
