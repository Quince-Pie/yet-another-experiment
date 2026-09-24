# Release contract

This document is the specification the release system implements and the
recipient verification checks. `RELEASING.md` is the maintainer procedure,
`README.md` the recipient procedure, `docs/release-qualification.md` the
evidence behind the design.

## 1. What is released

The project is a Nix flake. Nothing is compiled for recipients: they fetch
the flake source and Nix realises the dev shells from the locked `nixpkgs`
and cache.nixos.org. A release therefore fixes one thing, the source tree,
and vouches for what that tree evaluates and builds to.

| Item | Identity | Where recipients get it |
|---|---|---|
| Source tree | git tag `vX.Y.Z[-pre]` -> annotated, signed tag object -> commit -> tree -> `narHash` | `github:Quince-Pie/yet-another-experiment/vX.Y.Z` (GitHub tarball, unpacked and hashed by Nix), `git`, or the release asset `yet-another-experiment-X.Y.Z.nar` |
| Declared inputs | `flake.lock` inside the tree (`nixpkgs` rev + `narHash`) | inside the source tree |
| Evaluation identities | derivation and output store paths of `devShells.<system>.*` and `formatter.<system>` for `x86_64-linux` and `aarch64-linux` | `release.json`, recomputed locally by `nix eval` |
| Release notes | the `CHANGELOG.md` section for the version (pre-releases: `[Unreleased]`) | the GitHub Release body |
| Evidence | `release.json`, `SHA256SUMS`, `provenance.intoto.jsonl`, the tag signature | GitHub Release assets, the git tag |

Version = tag name without the leading `v`. The tag is the only place the
version exists; `CHANGELOG.md` must contain a matching section, which is how
the tree itself agrees with its version. Pre-release tags (`-rc.1`, ...) are
published as GitHub pre-releases and are never marked latest.

## 2. Reproducibility

Payloads claimed byte-for-byte reproducible from the tagged source alone,
in an independently prepared clean environment:

- **`yet-another-experiment-X.Y.Z.nar`** is the Nix archive of the tagged
  tree. NAR is canonical (sorted entries, no timestamps, no ownership, only
  the executable bit), so every `nix nar pack` of that tree is the same bytes
  and its SHA-256 is exactly the `narHash` Nix records for the flake. The
  same hash is what `nix flake metadata github:.../vX.Y.Z` reports for
  GitHub's tarball, because Nix hashes the unpacked tree, not the tarball.
- **`release.json` fields `source.*`, `inputs.*` and
  `systems.<system>.outputs.*.{drvPath,outPath}`** are pure functions of the
  tree, its lock file and the Nix evaluator. Anyone can recompute them.

Explicitly outside the byte-reproducibility claim:

- **Built dev-shell outputs.** `pkgs.mkShell` writes its build environment,
  including the builder's `NIX_BUILD_CORES`, into `$out`; rebuilding the same
  derivation with a different `cores` setting yields different bytes
  (measured: `nix build --rebuild --cores 2` reports "may not be
  deterministic"). The output path is nevertheless fixed by the derivation,
  and the shell's toolchain closure (which store paths it references) is
  fixed by nixpkgs; `release.json` records the closure size per output.
- **`release.json` fields `systems.<system>.{nixVersion,host,smoke}`** and
  the provenance attestation: they describe the verification run (runner
  image, compiler version strings, workflow identity) and legitimately depend
  on where and when the release was verified.
- **GitHub's own tarball bytes**, which GitHub does not promise to keep
  stable. Only their unpacked content, hence the `narHash`, is relied on.

## 3. Checks that authorise publication

A release is published only when, for the tagged commit:

1. the tag is annotated, named `vMAJOR.MINOR.PATCH[-PRERELEASE]`, and its
   signature verifies against `.github/allowed_signers` (SSH) or
   `.github/trusted-keys.asc` (OpenPGP) as they exist in that commit;
2. `CHANGELOG.md` has the section required by section 1;
3. `flake.lock` is consistent with `flake.nix` (every `nix` invocation runs
   with `--no-update-lock-file`);
4. `nix flake check --all-systems` passes on both supported systems: the
   tree is formatted, workflows and scripts lint clean, and every dev shell
   builds from the lock file;
5. `tests/smoke.c` compiles as C23 and runs inside every dev shell via
   `nix develop`, on native runners for both systems;
6. the NAR produced from the checkout hashes to the `narHash` Nix computes
   for the same tree, and (in the publish job) GitHub's tarball for the tag
   yields the same `narHash`, so recipients using `github:` get the bytes
   that were verified;
7. the assets are attested (SLSA v1 provenance, Sigstore) before upload,
   uploaded to a draft, compared with the local files by name, size and
   SHA-256 digest, and only then published.

The recorded evaluation identities come from the same runs that built and
smoke-tested the shells, so the manifest describes exactly what was checked.

## 4. Failure, duplicates and recovery

- **Overlapping releases.** Runs are grouped by tag (`concurrency` group
  `release-<ref>`, no cancellation): a second push of the same tag waits
  for the first; different tags run in parallel and each publishes its own
  release. When two stable tags are published within minutes of each other,
  whichever publishes last is marked *latest*.
- **A tag that already has a published release** is never modified: the
  publish step fails with "already published". Re-running the workflow for a
  published tag is therefore safe and a no-op. Deleting and re-pushing a
  tag name that already has a published release is refused for the same
  reason; a new version number is required.
- **Interrupted or failed publication** leaves at most a *draft* release,
  invisible to recipients. The next run discards the draft and starts over.
  A draft whose assets do not match the local files is never published.
- **Remote tag changed after verification.** The publish step re-reads the
  remote tag and requires it to be the exact tag object that was verified;
  otherwise it fails.
- **Verification failure** (checks, smoke, signature, changelog) stops the
  workflow before anything visible happens. The fix is a new commit and a
  new tag; tags are never force-updated.
- **What observers see during a run:** nothing until the final publish call;
  afterwards a complete release. There is no window in which a release
  exists with missing assets.
- **Determining the outcome:** the release page (assets present, not draft),
  the workflow run log, or `verify-release`.
- **Publication is not atomic across services** in one respect: the
  provenance is stored both as an asset and in GitHub's attestation store; if
  the run fails between attestation and publication, an attestation exists
  for assets that were never published. This is harmless (it names bytes,
  not a release) and is superseded by the next run's attestation.

## 5. Threat model and trust policy

Actors: the maintainer (holds the tag-signing key), GitHub (hosts the
source, executes the workflow, issues OIDC identities, stores releases and
attestations), Sigstore's public instance (Fulcio, Rekor), nixpkgs and
cache.nixos.org (signed by the cache key), third-party GitHub Actions used by
the workflow, contributors and anyone who can open a pull request, and an
attacker who obtains a repository token or push access.

Assets: the association tag -> commit -> bytes; the assurance that the
published tree was verified; the maintainer's signing key; the workflow
token.

| Evidence | Proves | Trusted party | Does not prove |
|---|---|---|---|
| Tag signature (SSH or OpenPGP) | the holder of a listed maintainer key named this commit as this version | the maintainer's key custody; the trust root the verifier used | that the commit is safe, or that CI verified it |
| Provenance attestation | GitHub's OIDC identity for *this repository's* `release.yml` at `refs/tags/vX.Y.Z` signed a statement naming the asset digests and the source commit | GitHub Actions and Sigstore | that a maintainer authorised the tag |
| `narHash` equality | the NAR, the GitHub tarball and the git tree are the same content | Nix's hashing | anything about who produced it |
| `release.json` (attested) | which derivations and closures the verified tree evaluates to, and which checks ran where | the workflow | that your machine will evaluate identically unless you recompute it (`verify-release` does) |

Policy decisions:

- **Untrusted contributions have no publication authority.** Pull-request
  workflows run with read-only permissions and no secrets; only a `v*` tag
  push starts `release.yml`, and only its final job holds `contents: write`
  and `id-token: write`.
- **A stolen repository token or push access alone cannot produce a
  release**: the verify-tag step requires a signature from a key listed in
  the tree. It *can* push a commit that lists a new key and a tag signed by
  it, so the in-tree trust roots protect against accidents and API-created
  tags, not against a fully compromised repository. Restricting tag
  creation to the maintainer with a repository ruleset (see `RELEASING.md`)
  closes that gap on GitHub's side; the recipient-side check against keys
  obtained out of band closes it for recipients.
- **A compromised workflow dependency** (installer action, checkout,
  attest) could tamper with verification. Mitigations: every action is
  pinned to a full commit SHA, the set of actions is minimal, the Nix
  installer is pinned to a specific Nix version, and the recipient re-derives
  the payload and evaluation identities independently rather than trusting
  the manifest's word for them.
- **A compromised maintainer key** can authorise malicious commits; rotate
  by removing it from the trust roots (a new commit and tag) and from the
  GitHub account. Releases signed before rotation remain verifiable against
  the key set that was valid then; whether to trust them is a policy call
  documented in the release notes of the rotating release.
- **Cryptographic validity is not authorisation.** `verify-release` checks
  the signer identity string of the attestation (repository + workflow path
  + tag ref), the provenance's source commit, the tag object identity, and
  that the signing key is in the recipient's trust root, not merely that
  signatures verify.
- **Unavailable verification dependencies fail the verification**; nothing
  is skipped silently. Without network access only `SHA256SUMS`, the NAR
  hash and the bundle signature can be checked (cosign verifies the bundle
  offline; the tag and evaluation checks need the repository and nixpkgs).

## 6. Supported scope

- Hosts: GitHub (`github.com/Quince-Pie/yet-another-experiment`). No other
  hosting platform is supported by this revision of the release system.
- Systems: `x86_64-linux` and `aarch64-linux`, the systems the flake
  declares; both are verified natively.
- Nix: the version pinned in the workflows verifies releases; recipients need
  a Nix with flakes (`nix flake metadata`, `nix hash file`, `nix eval`), which
  is any Nix 2.4 or later with `experimental-features = nix-command flakes`.
- Verification tools for recipients: `curl`, `jq`, `git`, `ssh-keygen`
  (OpenSSH 8.2+ for SSH signatures), `nix`, and one of `cosign` or `gh`;
  `nix run github:Quince-Pie/yet-another-experiment/vX.Y.Z#verify-release`
  supplies all of them except `nix` itself.
