# Live acceptance record

Repository: `github.com/Quince-Pie/yet-another-experiment`. Date: 2026-09-24
(all times UTC). Runners: GitHub-hosted `ubuntu-24.04` (image
20260907.300.1) and `ubuntu-24.04-arm` (image 20260907.118.1), runner
2.337.0, upstream Nix 2.35.2 installed by `.github/actions/install-nix`.

The release path was exercised on this repository's real flake with a
throwaway SSH key: a side branch added the key to `.github/allowed_signers`
(commit `9a79b314ef14f558af2c60d735179c9e59edb9c9`, itself SSH-signed with
that key) on top of `main` at `73ad0f6`, and the tag was signed with it.
`main` differs from the tested tree only by that one `allowed_signers`
line. The key never left the session's scratch directory.

## Runs

| Run | Revision | Result | What it established |
|---|---|---|---|
| CI [36054337694](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36054337694) | `2416b40` | failure | first live run: flake check, smoke and fragment passed on both systems; `tests/test-release.sh` failed because `nix flake metadata` on Nix 2.35 does not copy a local tree into the store; fixed in `d45d289` (`nix flake prefetch`) |
| CI [36054862807](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36054862807) | `50a5254` | success | both systems green, including the 41-case tooling test |
| Release [36054816874](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36054816874) | tag `v0.1.0-rc.1` | failure at publish | tag verified, both systems verified, NAR packed, manifest assembled, GitHub tarball cross-check passed; `actions/attest` refused a `predicate-type` input (custom-predicate mode); fixed in `3b82a7d`; the tag was retired per RELEASING.md (nothing referenced it) |
| CI [36055167991](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36055167991) | `73ad0f6` | success | delivered `main` is green |
| Release [36055173527](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36055173527) | tag `v0.1.0-rc.2` (`9a79b31`) | success, then failure on deliberate re-run | published <https://github.com/Quince-Pie/yet-another-experiment/releases/tag/v0.1.0-rc.2>; the Publish job was then re-run by hand and failed with "release v0.1.0-rc.2 is already published ...; existing releases are never modified", leaving the release untouched (4 assets, same `publishedAt`) |
| Release [36055669304](https://github.com/Quince-Pie/yet-another-experiment/actions/runs/36055669304) | tag `v0.1.0-rc.3`, annotated but unsigned | failure at Verify tag | "error: no signature found ... does not verify against .github/allowed_signers or .github/trusted-keys.asc"; verify and publish skipped; tag retired afterwards |

## Timings (release run 36055173527)

| Job / step | Duration |
|---|---|
| Verify tag (checkout + signature + changelog) | 6 s |
| verify / x86_64-linux: Install Nix / flake check (incl. ~710 MiB of substitutes, lint and format builds) / smoke (7 shells) / fragment / tooling tests | 4 s / 24 s / 19 s / 4 s / 22 s; job 77 s |
| verify / aarch64-linux: same steps | 4 s / 22 s / 15 s / 3 s / 17 s; job 66 s |
| Publish: Install Nix / verify-tag + archive + assemble + crosscheck / attest / publish | 4 s / 11 s / 2 s / 5 s; job 27 s |
| Tag push to published release (run created 20:29:07, `publishedAt` 20:31:05) | 118 s |

Cold-store substitution volume per system, measured locally with a fresh
store (`nix build --dry-run`): 156 paths, 702 to 710 MiB download, 2.8 GiB
unpacked, of which 682 MiB is needed by the `gcc` shell alone. No cache is
used between runs (see qualification section 2.7).

## The published release

| Asset | Size | SHA-256 |
|---|---|---|
| `yet-another-experiment-0.1.0-rc.2.nar` | 297944 | `9003c5fef8668596ce1188daefd24e691b2a1b79d6c0ecfe2976b83f593f3ce4` |
| `release.json` | 8243 | `d3a0d666927f3f10b95fa534d9b61271d0b7ba69258147bd7ebfa31b35d3a58c` |
| `SHA256SUMS` | 183 | `c37af1d5da26ce668ed9fbef710d9b35054349d07b96a27b9871b75b0e0bf660` |
| `provenance.intoto.jsonl` | 11469 | `85decd3e29df021c52d5369db96f50de652cb8232e1311c6d43f9d192d53d03d` |

Source narHash `sha256-kAPF/vhmhZbOEYja79JOaRsqG3nWwOz+KXa4P1k/POQ=`
(= SHA-256 of the NAR in SRI form). Attestation: Sigstore bundle v0.3,
signed via the Public Good instance, one Rekor entry (log index
2944215291), no RFC 3161 timestamp, three subjects. Certificate: SAN
`https://github.com/Quince-Pie/yet-another-experiment/.github/workflows/release.yml@refs/tags/v0.1.0-rc.2`,
source ref `refs/tags/v0.1.0-rc.2`, source digest `9a79b314...`, runner
`github-hosted`, trigger `push`, visibility `public`, issuer
`https://token.actions.githubusercontent.com`. The immutable OIDC subject
claims that apply to this repository (created after 2026-07-15) did not
change the SAN format. `isImmutable: false` because the repository setting
is not enabled (maintainer decision, RELEASING.md).

## Recipient verification (no credentials)

`scripts/verify-release.sh v0.1.0-rc.2 --allowed-signers <file with the
test key>` from a clean directory with `GH_TOKEN` unset, cosign 3.0.6 or
gh 2.96.0 from the flake's nixpkgs, Nix 2.34.8: all five checks pass in
6.6 s wall clock (the cosign path; the gh path also passes):

```
ok: SHA256SUMS covers yet-another-experiment-0.1.0-rc.2.nar and release.json
ok: provenance: built by https://github.com/Quince-Pie/yet-another-experiment/.github/workflows/release.yml@refs/tags/v0.1.0-rc.2 from commit 9a79b314ef14f558af2c60d735179c9e59edb9c9
ok: tag v0.1.0-rc.2 is signed by a trusted maintainer key (SHA256:bAQwmKHjDFttn5zeAvyINHDkq4QT+RYQe7wF7YvB2mM)
ok: payload reproduces: NAR = github:Quince-Pie/yet-another-experiment/v0.1.0-rc.2 = git tree of v0.1.0-rc.2 = sha256-kAPF/vhmhZbOEYja79JOaRsqG3nWwOz+KXa4P1k/POQ=
ok: evaluation: aarch64-linux, x86_64-linux evaluate to the recorded derivations
v0.1.0-rc.2 VERIFIED
```

Adversarial cases, each served from a copy of the real assets with one
change (`--base-url file://...`), all rejected with the expected reason:

| Case | Rejected by |
|---|---|
| one byte appended to the NAR | `sha256sum -c SHA256SUMS` |
| `release.json` edited (an outPath replaced) with `SHA256SUMS` updated to match | attestation: digest not a subject |
| provenance statement edited (`gitCommit` zeroed) | attestation: signature no longer matches |
| trust root listing a different SSH key | tag signature ("does not verify against the trusted maintainer keys") |
| default trust root (no signing keys registered on the GitHub account yet) | tag signature (same) |
| same assets presented as tag `v0.1.0-rc.9` | `release.json` is not the manifest for that tag |
| nonexistent tag `v9.9.9` | download fails |

Nix's own commit verification also works against the same key:
`nix --extra-experimental-features verified-fetches flake prefetch
"git+https://github.com/Quince-Pie/yet-another-experiment?ref=refs/tags/v0.1.0-rc.2&verifyCommit=1&keytype=ssh-ed25519&publicKey=..."`
returns the same narHash with the test key and fails ("Commit signature
verification ... failed") with another key. This requires the release
*commit* to be signed as well as the tag; RELEASING.md leaves that to the
maintainer's `commit.gpgsign` setting.

## What was not exercised live

- A tag signed by the maintainer's own key (the maintainer had no signing
  key configured; `.github/allowed_signers` ships their local
  `~/.ssh/id_ed25519.pub` provisionally).
- Immutable releases and the GitHub-generated release attestation (a
  repository setting the maintainer must enable).
- A stale-draft recovery on GitHub (covered by the fake-`gh` tests only;
  no run failed between draft creation and publish).
- A tag ruleset (recommended, not applied: repository settings are the
  maintainer's to change).
