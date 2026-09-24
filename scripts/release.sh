#!/usr/bin/env bash
# Release tooling for yet-another-experiment. The maintainer runs it locally
# and .github/workflows/release.yml runs the same subcommands on GitHub, so
# there is one implementation of every release check. See RELEASING.md.
#
#   verify-tag TAG   TAG is an annotated, signed, semver tag at HEAD whose
#                    signature verifies against .github/allowed_signers (SSH)
#                    or .github/trusted-keys.asc (OpenPGP)
#   notes VERSION    print the CHANGELOG.md section for VERSION
#   smoke SYSTEM     compile and run tests/smoke.c inside every dev shell
#   fragment SYSTEM  record evaluation identities, closures and smoke results
#   archive          dump the committed tree as a NAR: the release payload
#   assemble TAG     write release.json, release-notes.md and SHA256SUMS
#   crosscheck TAG   GitHub's tarball for TAG unpacks to the archive's narHash
#   publish TAG      create the GitHub Release: draft, assets, then publish
#   check            run the checks for this host without a tag
#
# Every artefact goes to $RELEASE_DIST (default: ./dist). Exit status is 0
# only when the subcommand fully succeeded.
set -euo pipefail

readonly PROJECT=yet-another-experiment
readonly REPO=Quince-Pie/yet-another-experiment
readonly PROVENANCE=provenance.sigstore.json
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo 'release: run this inside the repository' >&2
  exit 1
}
readonly ROOT
readonly DIST=${RELEASE_DIST:-$ROOT/dist}
readonly ALLOWED_SIGNERS=$ROOT/.github/allowed_signers
readonly TRUSTED_KEYS=$ROOT/.github/trusted-keys.asc
# SemVer 2.0.0 core + pre-release, no build metadata, leading "v".
readonly SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'
# The lock file is part of the release contract: never let nix rewrite it.
NIX_FLAGS=(--no-update-lock-file)
readonly NIX_FLAGS

die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}
log() { printf 'release: %s\n' "$*" >&2; }
need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required tool not found: $c"
  done
}
usage() {
  sed -n '2,20p' "$0" >&2
  exit 2
}
host_system() { nix eval --impure --raw --expr builtins.currentSystem; }

# ---------------------------------------------------------------- verify-tag
cmd_verify_tag() {
  local tag=${1-}
  [[ -n $tag ]] || usage
  need git ssh-keygen jq
  [[ $tag =~ $SEMVER_RE ]] || die "tag '$tag' is not of the form vMAJOR.MINOR.PATCH[-PRERELEASE]"
  local version=${tag#v} prerelease=false
  [[ $version == *-* ]] && prerelease=true

  local tagobj commit head tree
  tagobj=$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag^{tag}" 2>/dev/null) ||
    die "'$tag' is not an annotated tag; a lightweight tag cannot carry a signature"
  commit=$(git -C "$ROOT" rev-parse "refs/tags/$tag^{commit}")
  head=$(git -C "$ROOT" rev-parse HEAD)
  [[ $commit == "$head" ]] || die "tag $tag points at $commit but HEAD is $head"
  tree=$(git -C "$ROOT" rev-parse "$commit^{tree}")
  [[ -s $ALLOWED_SIGNERS ]] || die "$ALLOWED_SIGNERS is missing or empty"

  # git picks the verifier from the signature format; it only ever sees the
  # repository's trust roots: allowed_signers for SSH, a throwaway keyring
  # holding trusted-keys.asc for OpenPGP.
  local gnupghome out
  gnupghome=$(mktemp -d)
  if [[ -s $TRUSTED_KEYS ]]; then
    need gpg
    gpg --homedir "$gnupghome" --batch --quiet --import "$TRUSTED_KEYS" 2>/dev/null ||
      die "cannot import $TRUSTED_KEYS"
  fi
  if ! out=$(GNUPGHOME=$gnupghome git -C "$ROOT" -c gpg.ssh.allowedSignersFile="$ALLOWED_SIGNERS" \
    verify-tag --raw "$tag" 2>&1); then
    rm -rf "$gnupghome"
    printf '%s\n' "$out" >&2
    die "the signature on $tag does not verify against .github/allowed_signers or .github/trusted-keys.asc"
  fi
  rm -rf "$gnupghome"

  local format key principal
  if [[ $out =~ Good\ \"git\"\ signature\ for\ ([^[:space:]]+)\ with\ ([A-Z0-9-]+)\ key\ (SHA256:[A-Za-z0-9+/=]+) ]]; then
    format=ssh principal=${BASH_REMATCH[1]} key=${BASH_REMATCH[3]}
  elif [[ $out =~ \[GNUPG:\]\ GOODSIG\ ([0-9A-F]+)\ ([^$'\n']+) ]]; then
    format=openpgp key=${BASH_REMATCH[1]} principal=${BASH_REMATCH[2]}
    [[ $out =~ \[GNUPG:\]\ VALIDSIG\ ([0-9A-F]{40}) ]] && key=${BASH_REMATCH[1]}
  else
    printf '%s\n' "$out" >&2
    die "unrecognised verification output for $tag"
  fi

  mkdir -p "$DIST"
  jq -n --arg tag "$tag" --arg version "$version" --argjson prerelease "$prerelease" \
    --arg tagObject "$tagobj" --arg commit "$commit" --arg tree "$tree" \
    --arg tagger "$(git -C "$ROOT" tag -l --format='%(taggername) %(taggeremail)' "$tag")" \
    --arg taggerDate "$(git -C "$ROOT" tag -l --format='%(taggerdate:iso-strict)' "$tag")" \
    --arg format "$format" --arg key "$key" --arg principal "$principal" \
    '{tag: $tag, version: $version, prerelease: $prerelease, tagObject: $tagObject,
      commit: $commit, tree: $tree, tagger: $tagger, taggerDate: $taggerDate,
      signature: {format: $format, key: $key, principal: $principal}}' >"$DIST/tag.json"
  log "tag $tag -> commit $commit, $format signature by $principal ($key)"
}

# --------------------------------------------------------------------- notes
# Print the body of "## [KEY]" from CHANGELOG.md, without surrounding blank
# lines. Empty output means "no such section" or "section is empty".
changelog_section() {
  awk -v key="[$1]" '
    /^## / { if (found) exit; found = (index($0, key) == 4); next }
    found  { lines[++n] = $0 }
    END {
      first = 1; last = n
      while (first <= last && lines[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }' "$ROOT/CHANGELOG.md"
}

cmd_notes() {
  local version=${1-}
  [[ -n $version ]] || usage
  [[ -r $ROOT/CHANGELOG.md ]] || die "CHANGELOG.md not found"
  local section
  section=$(changelog_section "$version")
  # A pre-release may be cut from the Unreleased section; a release may not.
  if [[ -z $section && $version == *-* ]]; then
    section=$(changelog_section Unreleased)
    [[ -n $section ]] || die "CHANGELOG.md has neither a '## [$version]' nor a non-empty '## [Unreleased]' section"
  fi
  [[ -n $section ]] || die "CHANGELOG.md has no non-empty '## [$version]' section"
  printf '%s\n' "$section"
}

# --------------------------------------------------------------------- smoke
# Runs inside `nix develop`, so it only relies on what the shell provides.
# shellcheck disable=SC2016
readonly SMOKE_PROBE='set -euo pipefail
src=$1 bin=$2
cc "$src" -o "$bin"
printf "result=%s\n" "$("$bin")"
printf "cc=%s\n" "$(cc --version | head -n1)"
printf "ld=%s\n" "$(cc -Wl,--version "$src" -o /dev/null 2>/dev/null | head -n1)"
printf "cflags=%s\n" "${CFLAGS-}"'

cmd_smoke() {
  local system=${1-}
  [[ -n $system ]] || usage
  need nix jq
  local host
  host=$(host_system)
  [[ $host == "$system" ]] || die "smoke tests for $system must run on a $system host (this is $host)"
  local shells shell tmp probe results='{}'
  mapfile -t shells < <(nix eval "${NIX_FLAGS[@]}" --json "$ROOT#devShells.$system" --apply builtins.attrNames | jq -r '.[]')
  ((${#shells[@]})) || die "no dev shells for $system"
  tmp=$(mktemp -d)
  for shell in "${shells[@]}"; do
    log "smoke: $system.$shell"
    probe=$(nix develop "${NIX_FLAGS[@]}" "$ROOT#devShells.$system.$shell" \
      --command bash -c "$SMOKE_PROBE" probe "$ROOT/tests/smoke.c" "$tmp/$shell") ||
      die "smoke test failed in shell $shell"
    [[ $(sed -n 's/^result=//p' <<<"$probe") == '202311 ok' ]] ||
      die "shell $shell did not compile tests/smoke.c as C23: $(sed -n 's/^result=//p' <<<"$probe")"
    results=$(jq --arg s "$shell" \
      --arg cc "$(sed -n 's/^cc=//p' <<<"$probe")" \
      --arg ld "$(sed -n 's/^ld=//p' <<<"$probe")" \
      --arg cflags "$(sed -n 's/^cflags=//p' <<<"$probe")" \
      '.[$s] = {cc: $cc, ld: $ld, cflags: $cflags, stdcVersion: "202311"}' <<<"$results")
  done
  rm -rf "$tmp"
  mkdir -p "$DIST"
  jq -n --arg system "$system" --argjson shells "$results" '{system: $system, shells: $shells}' >"$DIST/smoke-$system.json"
  log "smoke: ${#shells[@]} shells passed on $system"
}

# ------------------------------------------------------------------ fragment
cmd_fragment() {
  local system=${1-}
  [[ -n $system ]] || usage
  need nix jq
  [[ -s $DIST/smoke-$system.json ]] || die "run 'release.sh smoke $system' first"
  local outputs paths info
  # `nix eval --json` renders any attrset that has an outPath as a bare
  # string, so the identities are collected under other names and renamed.
  # shellcheck disable=SC2016
  outputs=$(nix eval "${NIX_FLAGS[@]}" --json "$ROOT#devShells.$system" --apply \
    'ds: builtins.listToAttrs (map (n: { name = "devShells.${n}"; value = { drv = ds.${n}.drvPath; out = ds.${n}.outPath; }; }) (builtins.attrNames ds))')
  outputs=$(jq --argjson f "$(nix eval "${NIX_FLAGS[@]}" --json "$ROOT#formatter.$system" --apply 'd: { drv = d.drvPath; out = d.outPath; }')" \
    '(. + {formatter: $f}) | map_values({drvPath: .drv, outPath: .out})' <<<"$outputs")
  mapfile -t paths < <(jq -r '.[].outPath' <<<"$outputs")
  info=$(nix path-info --json --json-format 2 --closure-size "${paths[@]}" 2>/dev/null) ||
    die "not every output of $system is built; run 'nix flake check' first"
  mkdir -p "$DIST"
  jq -n --arg system "$system" --argjson outputs "$outputs" --argjson info "$info" \
    --slurpfile smoke "$DIST/smoke-$system.json" \
    --arg nixVersion "$(nix --version)" \
    --arg image "${ImageOS-}" --arg imageVersion "${ImageVersion-}" \
    --arg kernel "$(uname -sr)" --arg machine "$(uname -m)" \
    '{system: $system,
      nixVersion: $nixVersion,
      host: {image: $image, imageVersion: $imageVersion, kernel: $kernel, machine: $machine},
      outputs: ($outputs | with_entries(.value += {
        closureSize: ($info.info[.value.outPath | sub("^.*/"; "")].closureSize // error("output not built: " + .value.outPath))})),
      smoke: $smoke[0].shells}' >"$DIST/fragment-$system.json"
  log "fragment: $DIST/fragment-$system.json"
}

# ------------------------------------------------------------------- archive
cmd_archive() {
  need nix jq git
  [[ -s $DIST/tag.json ]] || die "run 'release.sh verify-tag TAG' first"
  [[ -z $(git -C "$ROOT" status --porcelain) ]] ||
    die "the working tree has uncommitted or untracked changes; the archive must be the committed tree"
  local meta path narhash rev version file filehash
  meta=$(nix flake metadata "${NIX_FLAGS[@]}" --json "$ROOT")
  path=$(jq -r .path <<<"$meta")
  narhash=$(jq -r .locked.narHash <<<"$meta")
  rev=$(jq -r .revision <<<"$meta")
  [[ $rev == "$(jq -r .commit "$DIST/tag.json")" ]] || die "flake revision $rev is not the tagged commit"
  version=$(jq -r .version "$DIST/tag.json")
  file=$PROJECT-$version.nar
  nix nar pack "$path" >"$DIST/$file"
  # The NAR is the exact serialisation nix hashes: its file hash must be the
  # narHash consumers see in flake.lock.
  filehash=$(nix hash file --sri --type sha256 "$DIST/$file")
  [[ $filehash == "$narhash" ]] || die "NAR hash $filehash differs from narHash $narhash"
  jq -n --arg file "$file" --arg narHash "$narhash" --arg commit "$rev" \
    --argjson size "$(stat -c %s "$DIST/$file")" \
    '{file: $file, narHash: $narHash, size: $size, commit: $commit}' >"$DIST/archive.json"
  log "archive: $file ($narhash)"
}

# ------------------------------------------------------------------ assemble
cmd_assemble() {
  local tag=${1-}
  [[ -n $tag ]] || usage
  need nix jq sha256sum
  [[ -s $DIST/tag.json && $(jq -r .tag "$DIST/tag.json") == "$tag" ]] || die "run 'release.sh verify-tag $tag' first"
  [[ -s $DIST/archive.json ]] || die "run 'release.sh archive' first"
  local systems s fragments=() version narfile
  mapfile -t systems < <(nix eval "${NIX_FLAGS[@]}" --json "$ROOT#devShells" --apply builtins.attrNames | jq -r '.[]')
  for s in "${systems[@]}"; do
    [[ -s $DIST/fragment-$s.json ]] || die "missing $DIST/fragment-$s.json: every supported system must have been verified"
    fragments+=("$DIST/fragment-$s.json")
  done
  version=$(jq -r .version "$DIST/tag.json")
  narfile=$(jq -r .file "$DIST/archive.json")

  jq -n --arg project "$PROJECT" --arg repo "$REPO" --arg workflow ".github/workflows/release.yml" \
    --slurpfile tag "$DIST/tag.json" --slurpfile archive "$DIST/archive.json" \
    --argjson inputs "$(jq '.nodes | del(.root) | map_values(.locked)' "$ROOT/flake.lock")" \
    --slurpfile fragments <(cat "${fragments[@]}") \
    '{manifestVersion: 1, project: $project, repository: $repo, releaseWorkflow: $workflow,
      tag: $tag[0].tag, version: $tag[0].version, prerelease: $tag[0].prerelease,
      source: ($tag[0] | {commit, tree, tagObject, tagger, taggerDate, signature}
               + {narHash: $archive[0].narHash, archive: $archive[0].file, archiveSize: $archive[0].size}),
      inputs: $inputs,
      systems: ($fragments | map({(.system): del(.system)}) | add)}' >"$DIST/release.json"

  # shellcheck disable=SC2016
  {
    cmd_notes "$version"
    printf '\n---\n\n'
    printf 'Tag `%s` = commit `%s` (%s signature by %s, %s).  \n' "$tag" \
      "$(jq -r .commit "$DIST/tag.json")" "$(jq -r .signature.format "$DIST/tag.json")" \
      "$(jq -r .signature.principal "$DIST/tag.json")" "$(jq -r .signature.key "$DIST/tag.json")"
    printf 'Source narHash `%s`; nixpkgs `%s`.  \n' "$(jq -r .narHash "$DIST/archive.json")" \
      "$(jq -r '.nodes.nixpkgs.locked.rev' "$ROOT/flake.lock")"
    printf 'Verify: `nix run github:%s/%s#verify-release -- %s` (see README).\n' "$REPO" "$tag" "$tag"
  } >"$DIST/release-notes.md"

  (cd "$DIST" && sha256sum "$narfile" release.json >SHA256SUMS)
  log "assembled: release.json, release-notes.md, SHA256SUMS"
}

# ---------------------------------------------------------------- crosscheck
# `github:` consumers fetch GitHub's tarball, not this checkout: its unpacked
# tree must hash to the narHash the archive was made from. Needs the tag on
# github.com, so it runs in the workflow, not in the local test suite.
cmd_crosscheck() {
  local tag=${1-}
  [[ -n $tag ]] || usage
  need nix jq
  [[ -s $DIST/archive.json ]] || die "run 'release.sh archive' first"
  local want got rev meta
  want=$(jq -r .narHash "$DIST/archive.json")
  meta=$(nix flake metadata --json "github:$REPO/$tag") || die "cannot fetch github:$REPO/$tag"
  got=$(jq -r .locked.narHash <<<"$meta")
  rev=$(jq -r .locked.rev <<<"$meta")
  [[ $rev == "$(jq -r .commit "$DIST/archive.json")" ]] || die "github:$REPO/$tag resolves to $rev, not the archived commit"
  [[ $got == "$want" ]] || die "github:$REPO/$tag unpacks to narHash $got but the archive is $want"
  log "crosscheck: github:$REPO/$tag unpacks to $want"
}

# ------------------------------------------------------------------- publish
# Idempotent by construction: a published release for TAG is never modified
# (that is a hard error), a stale draft is replaced, and every asset is
# uploaded to the draft before anything becomes visible.
cmd_publish() {
  local tag=${1-}
  [[ -n $tag ]] || usage
  need gh jq git sha256sum
  [[ -s $DIST/tag.json && $(jq -r .tag "$DIST/tag.json") == "$tag" ]] || die "run 'release.sh verify-tag $tag' first"
  local prerelease tagobj narfile a
  prerelease=$(jq -r .prerelease "$DIST/tag.json")
  tagobj=$(jq -r .tagObject "$DIST/tag.json")
  narfile=$(jq -r .file "$DIST/archive.json")
  local assets=("$DIST/$narfile" "$DIST/release.json" "$DIST/SHA256SUMS" "$DIST/$PROVENANCE")
  for a in "${assets[@]}"; do [[ -s $a ]] || die "missing asset: $a"; done
  (cd "$DIST" && sha256sum --quiet -c SHA256SUMS) || die "SHA256SUMS does not match the assets on disk"
  jq -e --arg tag "$tag" '.tag == $tag' "$DIST/release.json" >/dev/null || die "release.json is not for $tag"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (set GH_TOKEN)"

  # The remote tag must be the very object that was verified locally.
  local remote
  remote=$(gh api "repos/$REPO/git/ref/tags/$tag" --jq '.object.type + " " + .object.sha' 2>/dev/null) ||
    die "tag $tag does not exist on github.com/$REPO"
  [[ $remote == "tag $tagobj" ]] || die "remote tag $tag is '$remote', expected annotated tag object $tagobj"

  # Existing releases: published => refuse; draft => discard and start over.
  local line id draft url
  while read -r id draft url; do
    [[ -n $id ]] || continue
    if [[ $draft == false ]]; then
      die "release $tag is already published at $url; existing releases are never modified"
    fi
    log "discarding stale draft release $id"
    gh api -X DELETE "repos/$REPO/releases/$id" >/dev/null || die "cannot delete draft release $id"
  done < <(gh api --paginate "repos/$REPO/releases" --jq ".[] | select(.tag_name == \"$tag\") | \"\(.id) \(.draft) \(.html_url)\"")

  local args=(release create "$tag" --repo "$REPO" --draft --verify-tag --title "$tag" --notes-file "$DIST/release-notes.md")
  [[ $prerelease == true ]] && args+=(--prerelease)
  log "creating draft release $tag with ${#assets[@]} assets"
  gh "${args[@]}" "${assets[@]}" >/dev/null ||
    die "creating the draft release failed; any partial draft is discarded on the next run"

  id=$(gh api --paginate "repos/$REPO/releases" --jq ".[] | select(.tag_name == \"$tag\" and .draft) | .id" | head -n1)
  [[ -n $id ]] || die "the draft release for $tag cannot be found after creation"

  # Name, size and SHA-256 of every uploaded asset must match the local file.
  local expected got
  expected=$(for a in "${assets[@]}"; do
    printf '%s %s sha256:%s uploaded\n' "$(basename "$a")" "$(stat -c %s "$a")" "$(sha256sum "$a" | cut -d' ' -f1)"
  done | sort)
  got=$(gh api "repos/$REPO/releases/$id" --jq '.assets[] | "\(.name) \(.size) \(.digest) \(.state)"' | sort)
  [[ $got == "$expected" ]] || {
    printf 'expected:\n%s\ngot:\n%s\n' "$expected" "$got" >&2
    die "the draft's assets differ from the local assets; not publishing"
  }

  local make_latest=true
  [[ $prerelease == true ]] && make_latest=false
  url=$(gh api -X PATCH "repos/$REPO/releases/$id" -F draft=false -f make_latest="$make_latest" --jq .html_url) ||
    die "publishing draft $id failed; the draft is left in place"
  line=$(gh api "repos/$REPO/releases/$id" --jq '"\(.draft) \(.prerelease) \(.tag_name) \(.assets | length)"')
  [[ $line == "false $prerelease $tag ${#assets[@]}" ]] || die "post-publish state mismatch: $line"
  log "published $url"
  printf '%s\n' "$url"
}

# --------------------------------------------------------------------- check
cmd_check() {
  need nix
  local host
  host=$(host_system)
  log "nix flake check (builds the $host checks, evaluates every system)"
  nix flake check "${NIX_FLAGS[@]}" --all-systems "$ROOT"
  cmd_smoke "$host"
  cmd_fragment "$host"
}

case ${1-} in
  verify-tag) shift; cmd_verify_tag "$@" ;;
  notes) shift; cmd_notes "$@" ;;
  smoke) shift; cmd_smoke "$@" ;;
  fragment) shift; cmd_fragment "$@" ;;
  archive) shift; cmd_archive "$@" ;;
  assemble) shift; cmd_assemble "$@" ;;
  crosscheck) shift; cmd_crosscheck "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) usage ;;
esac
