# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a major
bump removes or renames a shell or changes what a shell guarantees, a minor
bump upgrades a toolchain or adds a shell, a patch bump fixes a shell without
changing its toolchain. The release workflow publishes the section for the
tagged version as the release notes; pre-releases use the Unreleased section.

## [Unreleased]

### Added

- Dev shells `gcc`, `gcc-mold`, `gcc-lld`, `clang`, `clang-mold` and `clang-lld`
  (GCC 15.2.0, LLVM 22.1.5, mold 2.41.0) for `x86_64-linux` and
  `aarch64-linux`, all defaulting to `-std=gnu23`; `default` is `gcc`.
- `formatter` (nixfmt-tree) and `checks` (`dev-shells`, `format`, `lint`) so
  that `nix flake check` verifies what the release workflow verifies.
- Signed-tag release process: `scripts/release.sh`, the `release` and
  `verify-release` apps, and the GitHub Actions workflows that publish a
  reproducible source NAR, `release.json`, `SHA256SUMS` and a provenance
  attestation for every `v*` tag.
