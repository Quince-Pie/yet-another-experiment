# Releasing

The release system is specified in `docs/release-contract.md`. This is the
maintainer's procedure. Everything the workflow checks can be run locally
first with `nix run .#release -- check`, which runs the same script the
workflow runs.

## One-time setup

1. **Signing key.** Releases are authorised by a signed annotated tag. Sign
   with SSH (recommended; any key in `~/.ssh` works, including FIDO keys):

   ```sh
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/id_ed25519.pub
   git config --global tag.gpgsign true
   ```

   The public key must be listed in `.github/allowed_signers`
   (`PRINCIPAL namespaces="git" KEYTYPE BASE64`). The file currently lists
   this machine's `~/.ssh/id_ed25519.pub`; replace it if you sign with
   another key. Alternatively sign with OpenPGP: the key must be in
   `.github/trusted-keys.asc` (currently the key published at
   <https://github.com/Quince-Pie.gpg>).

2. **Register the same key on GitHub** (Settings -> SSH and GPG keys -> "New
   SSH key" with type "Signing Key", or the GPG key). This makes the tag show
   as *Verified* and is what `verify-release` uses as the default trust root
   for recipients. Nothing in the workflow depends on it.

3. **Protect tags (recommended).** A repository ruleset that lets only the
   repository owner create, update or delete `refs/tags/v*` closes the gap
   described in the contract's threat model (a collaborator or stolen token
   adding its own key to the trust roots). Repository admins can create it
   with:

   ```sh
   gh api -X POST repos/Quince-Pie/yet-another-experiment/rulesets --input - <<'EOF'
   {
     "name": "release tags",
     "target": "tag",
     "enforcement": "active",
     "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
     "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ],
     "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ]
   }
   EOF
   ```

   (`actor_id` 5 is the built-in *admin* repository role.) The release
   workflow itself never creates tags, so it needs no bypass.

4. **Immutable releases (recommended).** Enable *Settings -> General ->
   Releases -> Immutable releases* so that GitHub itself refuses any change
   to a published release's assets or tag. The workflow is written for this
   mode: assets are uploaded to a draft and the release is published once,
   with everything in place.

## Cutting a release

1. Make sure `main` is green (the `CI` workflow runs the same verification
   on every push and pull request).
2. Update `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   and add a fresh empty `## [Unreleased]` above it. A pre-release
   (`vX.Y.Z-rc.1`) may be cut from `[Unreleased]` directly.
3. Optionally run the checks locally (builds this machine's shells):

   ```sh
   nix run .#release -- check
   ```

4. Commit, then create and push the signed tag:

   ```sh
   git tag -s vX.Y.Z -m "yet-another-experiment vX.Y.Z"
   nix run .#release -- verify-tag vX.Y.Z   # optional: same check the workflow runs first
   git push origin main vX.Y.Z
   ```

5. Watch the *Release* workflow (`gh run watch`). It verifies the tag,
   runs the checks and smoke tests natively on `x86_64-linux` and
   `aarch64-linux`, packages the source NAR, attests the assets, uploads them
   to a draft and publishes it. The run's summary links the release.
6. Verify what recipients will verify:

   ```sh
   nix run github:Quince-Pie/yet-another-experiment/vX.Y.Z#verify-release -- vX.Y.Z
   ```

## When something goes wrong

- **The workflow failed before publishing.** Nothing is visible. Fix the
  cause with a new commit, and tag it as the *next* version; never move or
  re-sign an existing tag name. (Between the failed tag and the fixed one,
  simply delete the failed tag locally and remotely: `git push --delete
  origin vX.Y.Z`. Nothing references it.)
- **The workflow failed while publishing.** At most a draft release exists;
  it is invisible to recipients. Re-run the failed job or push nothing and
  re-run the workflow (`gh run rerun ID`): the publish step deletes the
  stale draft and starts over. If the draft was published by hand in the
  meantime, the re-run refuses to touch it.
- **A published release is wrong.** It cannot be replaced (by policy, and
  by GitHub if immutable releases are enabled). Publish a corrected version
  and, if the release is harmful, mark it as such in the next release notes
  and delete only its *tag* if you must (this breaks `github:...` refs for
  its consumers; prefer leaving it and documenting).
- **A signing key is compromised.** Remove it from `.github/allowed_signers`
  or `.github/trusted-keys.asc`, remove it from the GitHub account, add the
  new key, and release the change as a new version whose notes say which
  releases were signed with the old key.
- **The `verify-tag` step rejects a tag** ("does not verify"): the tag was
  not signed (`git tag -s`), the key is not listed in the trust roots, or the
  tag is lightweight. Delete the tag, fix, re-tag.
- **`nix flake check` fails on `format`**: run `nix fmt`. On `lint`: run
  `nix build .#checks.x86_64-linux.lint` locally and read the actionlint,
  zizmor or shellcheck report.
- **cache.nixos.org or GitHub are unavailable.** Runs fail cleanly; re-run
  later. The release script never partially publishes.

## Updating the toolchain

`flake.nix` pins `nixpkgs` by revision and `flake.lock` records its
`narHash`. To move: change the revision, run `nix flake lock`, commit both
files together, and describe the compiler/linker versions that changed in
`CHANGELOG.md` (that is a minor version bump; removing or renaming a shell
is a major one). The `CI` workflow will refuse a lock file that does not
match `flake.nix`.

## Updating the release system itself

- Actions are pinned by full commit SHA with the version in a comment; bump
  them deliberately and re-run the `CI` workflow.
- The Nix version installed on runners is pinned in
  `.github/workflows/verify.yml`; bump it together with a local test
  (`tests/test-release.sh`), which exercises every subcommand of
  `scripts/release.sh` against a throwaway repository and a fake `gh`.
- `scripts/release.sh`, `scripts/verify-release.sh` and the workflows are
  linted by `nix flake check` (`checks.<system>.lint`).
