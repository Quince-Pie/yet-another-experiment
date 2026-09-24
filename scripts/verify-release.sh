#!/usr/bin/env bash
# Verify a published release of yet-another-experiment as a recipient.
#
#   verify-release.sh TAG [--dir DIR] [--allowed-signers FILE] [--gpg-keys FILE]
#                         [--base-url URL]
#
# Downloads the release assets into DIR (default ./verify-TAG) and checks:
#   1. SHA256SUMS matches every payload asset (the NAR and release.json);
#   2. the provenance attestation was produced by this repository's release
#      workflow for TAG (Sigstore bundle, verified offline by cosign, or by
#      `gh attestation verify`), and its provenance names the same commit;
#   3. TAG on github.com is an annotated tag signed by a trusted maintainer
#      key, pointing at the commit release.json names;
#   4. the NAR reproduces: its hash is release.json's narHash, equals the
#      narHash nix computes for github:REPO/TAG (what `nix develop` fetches),
#      and equals the hash of the tag's tree checked out from git;
#   5. github:REPO/TAG evaluates to exactly the derivation and output paths
#      release.json records for every supported system.
#
# Trust roots for step 3: --allowed-signers / --gpg-keys files you obtained
# out of band; by default the maintainer's keys registered on the GitHub
# account, which means trusting GitHub's account key registry.
#
# Exit status: 0 when every check passed, 1 when any failed. Nothing is
# skipped silently; a missing tool is a failure.
set -euo pipefail

readonly REPO=Quince-Pie/yet-another-experiment
readonly OWNER=${REPO%%/*}
readonly WORKFLOW=.github/workflows/release.yml
readonly PROVENANCE=provenance.intoto.jsonl
readonly OIDC_ISSUER=https://token.actions.githubusercontent.com

die() {
  printf 'verify-release: FAIL: %s\n' "$*" >&2
  exit 1
}
ok() { printf 'verify-release: ok: %s\n' "$*" >&2; }
need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required tool not found: $c"
  done
}

tag=${1-}
[[ -n $tag && $tag != -* ]] || {
  sed -n '2,26p' "$0" >&2
  exit 2
}
shift
dir=./verify-$tag allowed_signers='' gpg_keys='' base_url=''
while (($#)); do
  case $1 in
    --dir) dir=$2; shift 2 ;;
    --allowed-signers) allowed_signers=$2; shift 2 ;;
    --gpg-keys) gpg_keys=$2; shift 2 ;;
    --base-url) base_url=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "'$tag' is not a release tag"
base_url=${base_url:-https://github.com/$REPO/releases/download/$tag}
need curl jq sha256sum nix git ssh-keygen
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)

fetch() {
  curl -fsSL --retry 3 --proto '=https,file' -o "$dir/$1" "$base_url/$1" || die "cannot download $1 from $base_url"
}

# ---- 1. payload integrity ----------------------------------------------
fetch release.json
fetch SHA256SUMS
fetch "$PROVENANCE"
jq -e --arg tag "$tag" --arg repo "$REPO" \
  '.manifestVersion == 1 and .tag == $tag and .repository == $repo' "$dir/release.json" >/dev/null ||
  die "release.json is not a version-1 manifest for $tag of $REPO"
narfile=$(jq -r .source.archive "$dir/release.json")
[[ $narfile == *.nar && $narfile != */* ]] || die "release.json names an unexpected archive: $narfile"
fetch "$narfile"
(cd "$dir" && sha256sum --quiet --strict -c SHA256SUMS) || die "SHA256SUMS does not match the downloaded assets"
if ! grep -q " $narfile\$" "$dir/SHA256SUMS" || ! grep -q ' release.json$' "$dir/SHA256SUMS"; then
  die "SHA256SUMS does not cover both $narfile and release.json"
fi
ok "SHA256SUMS covers $narfile and release.json"

# ---- 2. provenance -----------------------------------------------------
commit=$(jq -r .source.commit "$dir/release.json")
identity="https://github.com/$REPO/$WORKFLOW@refs/tags/$tag"
# The signing certificate's identity (SAN) is set by GitHub's OIDC token,
# not by the workflow, so it is the trustworthy statement of who signed:
# this repository's release.yml running at this tag on a GitHub-hosted
# runner, for this commit. Either verifier checks the Sigstore bundle,
# the certificate chain, the transparency-log inclusion, and that the
# file's digest is a subject of the signed statement.
verify_blob() {
  if command -v cosign >/dev/null 2>&1; then
    cosign verify-blob-attestation "$dir/$1" --bundle "$dir/$PROVENANCE" \
      --certificate-oidc-issuer "$OIDC_ISSUER" --certificate-identity "$identity" \
      --certificate-github-workflow-repository "$REPO" --certificate-github-workflow-ref "refs/tags/$tag" \
      --certificate-github-workflow-sha "$commit" --type https://slsa.dev/provenance/v1 >/dev/null 2>&1
  elif command -v gh >/dev/null 2>&1; then
    gh attestation verify "$dir/$1" --repo "$REPO" --bundle "$dir/$PROVENANCE" \
      --cert-identity "$identity" --cert-oidc-issuer "$OIDC_ISSUER" --predicate-type https://slsa.dev/provenance/v1 \
      --source-ref "refs/tags/$tag" --source-digest "$commit" --deny-self-hosted-runners >/dev/null 2>&1
  else
    die "neither cosign nor gh is available to verify the provenance attestation"
  fi
}
for f in "$narfile" release.json SHA256SUMS; do
  verify_blob "$f" || die "the provenance attestation does not cover $f, or was not produced by $identity"
done
# The verifier proved signature and identity; the statement's own claims
# (written by the workflow job) must agree with release.json, so a bundle
# from another run of the same workflow cannot be substituted.
statement=$(jq -r '.dsseEnvelope.payload' "$dir/$PROVENANCE" | base64 -d)
jq -e --arg commit "$commit" --arg ref "refs/tags/$tag" --arg repo "https://github.com/$REPO" --arg workflow "$WORKFLOW" \
  '.predicateType == "https://slsa.dev/provenance/v1"
   and (.predicate.buildDefinition.resolvedDependencies | any(.uri == ("git+" + $repo + "@" + $ref) and .digest.gitCommit == $commit))
   and (.predicate.buildDefinition.externalParameters.workflow | .ref == $ref and .repository == $repo and .path == $workflow)
   and (.predicate.buildDefinition.internalParameters.github | .event_name == "push" and .runner_environment == "github-hosted")' \
  <<<"$statement" >/dev/null || die "the provenance is not for $REPO@refs/tags/$tag at commit $commit"
ok "provenance: built by $identity from commit $commit"

# ---- 3. maintainer authorisation ---------------------------------------
src=$dir/src
rm -rf "$src"
git init -q "$src"
git -C "$src" fetch -q --depth 1 --no-tags "https://github.com/$REPO" "refs/tags/$tag:refs/tags/$tag" ||
  die "cannot fetch tag $tag from github.com/$REPO"
[[ $(git -C "$src" cat-file -t "refs/tags/$tag") == tag ]] || die "$tag is not an annotated tag on github.com"
[[ $(git -C "$src" rev-parse "refs/tags/$tag^{commit}") == "$commit" ]] || die "tag $tag on github.com does not point at $commit"
[[ $(git -C "$src" rev-parse "refs/tags/$tag") == "$(jq -r .source.tagObject "$dir/release.json")" ]] ||
  die "tag object on github.com differs from release.json"
if [[ -z $allowed_signers ]]; then
  allowed_signers=$dir/allowed_signers
  curl -fsSL --retry 3 "https://api.github.com/users/$OWNER/ssh_signing_keys" |
    jq -r --arg p "$OWNER" '.[] | "\($p) namespaces=\"git\" \(.key)"' >"$allowed_signers" ||
    die "cannot fetch $OWNER's SSH signing keys from api.github.com"
fi
if [[ -z $gpg_keys ]]; then
  gpg_keys=$dir/gpg-keys.asc
  curl -fsSL --retry 3 "https://github.com/$OWNER.gpg" -o "$gpg_keys" || die "cannot fetch $OWNER's GPG keys"
fi
gnupghome=$(mktemp -d)
if [[ -s $gpg_keys ]] && command -v gpg >/dev/null 2>&1; then
  gpg --homedir "$gnupghome" --batch --quiet --import "$gpg_keys" 2>/dev/null || true
fi
[[ -s $allowed_signers ]] || : >"$allowed_signers"
sigout=$(GNUPGHOME=$gnupghome git -C "$src" -c gpg.ssh.allowedSignersFile="$allowed_signers" verify-tag --raw "$tag" 2>&1) || {
  rm -rf "$gnupghome"
  printf '%s\n' "$sigout" >&2
  die "the signature on $tag does not verify against the trusted maintainer keys"
}
rm -rf "$gnupghome"
ok "tag $tag is signed by a trusted maintainer key ($(grep -oE 'SHA256:[A-Za-z0-9+/=]+|GOODSIG [0-9A-F]+' <<<"$sigout" | head -n1))"

# ---- 4. reproducible payload -------------------------------------------
narhash=$(jq -r .source.narHash "$dir/release.json")
[[ $(nix hash file --sri --type sha256 "$dir/$narfile") == "$narhash" ]] || die "$narfile does not hash to $narhash"
fetched=$(nix flake metadata --json "github:$REPO/$tag")
[[ $(jq -r .locked.rev <<<"$fetched") == "$commit" ]] || die "github:$REPO/$tag resolves to $(jq -r .locked.rev <<<"$fetched"), not $commit"
[[ $(jq -r .locked.narHash <<<"$fetched") == "$narhash" ]] || die "github:$REPO/$tag has narHash $(jq -r .locked.narHash <<<"$fetched"), not $narhash"
git -C "$src" -c advice.detachedHead=false checkout -q "refs/tags/$tag"
[[ $(nix flake metadata --json "git+file://$src" | jq -r .locked.narHash) == "$narhash" ]] ||
  die "the tag's tree checked out from git does not reproduce narHash $narhash"
ok "payload reproduces: NAR = github:$REPO/$tag = git tree of $tag = $narhash"

# ---- 5. evaluation identities ------------------------------------------
recorded=$(jq '.systems | map_values(.outputs | map_values({drvPath, outPath}))' "$dir/release.json")
# shellcheck disable=SC2016
evaluated=$(nix eval --json "github:$REPO/$commit#devShells" --apply \
  'ds: builtins.mapAttrs (s: shells: builtins.listToAttrs (map (n: { name = "devShells.${n}"; value = { drv = shells.${n}.drvPath; out = shells.${n}.outPath; }; }) (builtins.attrNames shells))) ds')
formatters=$(nix eval --json "github:$REPO/$commit#formatter" --apply 'f: builtins.mapAttrs (s: d: { drv = d.drvPath; out = d.outPath; }) f')
evaluated=$(jq --argjson f "$formatters" 'with_entries(.value += {formatter: $f[.key]}) | map_values(map_values({drvPath: .drv, outPath: .out}))' <<<"$evaluated")
[[ $(jq -S . <<<"$recorded") == $(jq -S . <<<"$evaluated") ]] || {
  diff <(jq -S . <<<"$recorded") <(jq -S . <<<"$evaluated") >&2 || true
  die "github:$REPO/$tag does not evaluate to the derivations recorded in release.json"
}
ok "evaluation: $(jq -r '.systems | keys | join(", ")' "$dir/release.json") evaluate to the recorded derivations"

printf 'verify-release: %s VERIFIED (assets in %s)\n' "$tag" "$dir"
