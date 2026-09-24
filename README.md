# yet-another-experiment

A Nix flake providing C23 development shells: GCC 15 or LLVM 22, with the
GNU, mold or LLD linker, on `x86_64-linux` and `aarch64-linux`. Every shell
defaults to `-std=gnu23`, ships cmake/meson/ninja, bear, ccache, gdb,
valgrind, hyperfine, poop, samply, Tracy and clangd, and has nixpkgs'
hardening flags switched off so measurements mean what they say.

```sh
nix develop github:Quince-Pie/yet-another-experiment            # gcc + GNU ld
nix develop github:Quince-Pie/yet-another-experiment#clang-mold # clang + mold
```

| Shell | Compiler | Linker |
|---|---|---|
| `default`, `gcc` | GCC 15.2.0 | GNU ld (bfd) |
| `gcc-mold` | GCC 15.2.0 | mold 2.41.0 |
| `gcc-lld` | GCC 15.2.0 | LLD 22.1.5 |
| `clang` | clang 22.1.5 | GNU ld (bfd) |
| `clang-mold` | clang 22.1.5 | mold 2.41.0 |
| `clang-lld` | clang 22.1.5 | LLD 22.1.5 |

Pin a release in your own flake:

```nix
inputs.c23.url = "github:Quince-Pie/yet-another-experiment/v0.1.0";
# then: devShells.default = c23.devShells.${system}.gcc-mold;
```

`nix fmt` formats the tree (nixfmt); `nix flake check` runs everything the
release workflow checks.

## Releases

Every release is a signed annotated tag `vX.Y.Z` (pre-releases
`vX.Y.Z-rc.N`) with a GitHub Release carrying:

| Asset | What it is |
|---|---|
| `yet-another-experiment-X.Y.Z.nar` | the tagged source tree as a Nix archive; its SHA-256 is the `narHash` Nix records for the flake |
| `release.json` | tag, commit, signer, `narHash`, the locked `nixpkgs`, and for each system the derivation and output paths every shell evaluates to, their closure sizes, and the smoke-test results |
| `SHA256SUMS` | digests of the two files above |
| `provenance.intoto.jsonl` | SLSA v1 provenance, signed through Sigstore by this repository's release workflow |

Versions follow SemVer: major = a shell removed, renamed or changed in what
it guarantees; minor = a toolchain upgrade or a new shell; patch = a fix.
`CHANGELOG.md` has the details. The full contract, including what is and
is not reproducible, is in `docs/release-contract.md`.

## Verifying a release

The one-command path fetches the assets, then checks checksums, the
provenance attestation, the tag signature, the reproducibility of the NAR
against both GitHub's tarball and the git tree, and that the flake
evaluates to exactly the derivations the release records:

```sh
nix run github:Quince-Pie/yet-another-experiment/v0.1.0#verify-release -- v0.1.0
```

The script is `scripts/verify-release.sh`; it needs `nix` plus `curl`,
`jq`, `git`, `ssh-keygen` and `cosign` or `gh`, all of which `nix run`
supplies except `nix` itself. It exits 0 only when every check passed and
never skips a check silently. By default the tag signature is checked
against the maintainer's signing keys registered on GitHub (SSH signing
keys via `https://api.github.com/users/Quince-Pie/ssh_signing_keys`, GPG via
`https://github.com/Quince-Pie.gpg`); pass `--allowed-signers FILE` or
`--gpg-keys FILE` to use keys you obtained another way. The repository's
own `.github/allowed_signers` and `.github/trusted-keys.asc` list the keys
the release workflow accepts.

Doing it by hand, with `TAG=v0.1.0` and the assets downloaded from the
release page:

```sh
sha256sum -c SHA256SUMS

# Provenance: signed by *this repository's* release.yml running at this
# tag on a GitHub-hosted runner. Either tool works without any account.
cosign verify-blob-attestation release.json --bundle provenance.intoto.jsonl \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/Quince-Pie/yet-another-experiment/.github/workflows/release.yml@refs/tags/$TAG" \
  --type https://slsa.dev/provenance/v1
gh attestation verify release.json --repo Quince-Pie/yet-another-experiment --bundle provenance.intoto.jsonl \
  --cert-identity "https://github.com/Quince-Pie/yet-another-experiment/.github/workflows/release.yml@refs/tags/$TAG" \
  --source-ref "refs/tags/$TAG" --deny-self-hosted-runners
# (repeat for the .nar and SHA256SUMS; all three are subjects of the one attestation.
#  Offline: add --trusted-root / --custom-trusted-root with a file from `gh attestation trusted-root`.)

# Maintainer authorisation: the tag is signed by a listed key.
git clone --branch "$TAG" https://github.com/Quince-Pie/yet-another-experiment src
git -C src -c gpg.ssh.allowedSignersFile="$PWD/src/.github/allowed_signers" verify-tag "$TAG"

# Reproducibility: the NAR is the tree, and the tree is what `github:` fetches.
nix hash file --sri --type sha256 yet-another-experiment-*.nar          # = release.json .source.narHash
nix flake metadata --json "github:Quince-Pie/yet-another-experiment/$TAG" | jq -r .locked.narHash
nix flake metadata --json ./src | jq -r .locked.narHash

# Evaluation: the released flake evaluates to what was verified.
nix eval --json "github:Quince-Pie/yet-another-experiment/$TAG#devShells.x86_64-linux.gcc.outPath"
jq -r '.systems["x86_64-linux"].outputs["devShells.gcc"].outPath' release.json
```

What each proves is spelled out in `docs/release-contract.md` (section 5).
In short: the provenance proves GitHub ran this repository's workflow for
this tag and it produced these bytes; the tag signature proves a maintainer
key named this commit as this version; the hash and evaluation checks prove
that what you fetch is what was verified.

## Releasing

See `RELEASING.md`.
