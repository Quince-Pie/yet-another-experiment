#!/usr/bin/env bash
# Contract tests for scripts/release.sh: tag authorisation, changelog notes,
# the reproducible source NAR, manifest assembly, and the publish state
# machine against a fake `gh`. Runs against a throwaway copy of the working
# tree with its own throwaway signing key, so it never touches the real trust
# roots, the real remote, or the real dist/. Requires nix; the smoke section
# builds this host's dev shells (a one-off ~700 MiB download on a cold store).
#
#   tests/test-release.sh            run everything
#   SKIP_SMOKE=1 tests/test-release.sh  skip the shells / smoke / fragment part
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
# expect_fail NAME PATTERN CMD...: CMD must fail and mention PATTERN on stderr.
expect_fail() {
  local name=$1 pattern=$2 out
  shift 2
  if out=$("$@" 2>&1); then
    bad "$name (unexpectedly succeeded)"
  elif grep -q -- "$pattern" <<<"$out"; then
    ok "$name"
  else
    bad "$name (failed for the wrong reason: $(tail -n1 <<<"$out"))"
  fi
}
expect_ok() {
  local name=$1 out
  shift
  if out=$("$@" 2>&1); then ok "$name"; else
    bad "$name: $(tail -n2 <<<"$out" | tr '\n' ' ')"
  fi
}
# Fixture commits and tags must not pick up the maintainer's signing config.
git_() { git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
sign_tag() { # sign_tag KEY TAG [MESSAGE]
  git_ -c gpg.format=ssh -c user.signingkey="$1" tag -s -m "${3:-release $2}" "$2"
}

# ---- fixture: a copy of the working tree with a test signing key ---------
REPO=$TMP/repo
mkdir -p "$REPO"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | grep -zv '^dist/' | xargs -0 -I{} cp --parents {} "$REPO/")
ssh-keygen -q -t ed25519 -N '' -C release-test -f "$TMP/trusted" </dev/null
ssh-keygen -q -t ed25519 -N '' -C release-intruder -f "$TMP/intruder" </dev/null
printf 'release-test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$TMP/trusted.pub")" >"$REPO/.github/allowed_signers"
git_ init -q -b main
git_ add -A
git_ commit -q -m 'fixture'
export RELEASE_DIST=$TMP/dist
R=$REPO/scripts/release.sh
cd "$REPO"

echo '# verify-tag'
git_ tag v0.0.1
expect_fail 'lightweight tag is rejected' 'not an annotated tag' "$R" verify-tag v0.0.1
git_ tag -a -m unsigned v0.0.2
expect_fail 'unsigned annotated tag is rejected' 'does not verify' "$R" verify-tag v0.0.2
sign_tag "$TMP/intruder" v0.0.3
expect_fail 'tag signed by an untrusted key is rejected' 'does not verify' "$R" verify-tag v0.0.3
expect_fail 'malformed tag name is rejected' 'not of the form' "$R" verify-tag v1.0
sign_tag "$TMP/trusted" v0.1.0-rc.1
expect_ok 'tag signed by a trusted key verifies' "$R" verify-tag v0.1.0-rc.1
if jq -e '.tag == "v0.1.0-rc.1" and .version == "0.1.0-rc.1" and .prerelease == true and .signature.format == "ssh"
          and .signature.principal == "release-test" and (.signature.key | startswith("SHA256:"))
          and .commit == "'"$(git_ rev-parse HEAD)"'"' "$RELEASE_DIST/tag.json" >/dev/null; then
  ok 'tag.json records tag, version, prerelease, commit and signer'
else bad 'tag.json content'; fi
git_ commit -q --allow-empty -m 'later commit'
expect_fail 'tag behind HEAD is rejected' 'but HEAD is' "$R" verify-tag v0.1.0-rc.1
git_ reset -q --hard v0.1.0-rc.1
# Same name re-tagged without a signature must not inherit the earlier verdict.
git_ tag -f -a -m 'retagged' v0.1.0-rc.1 >/dev/null
expect_fail 're-created unsigned tag is rejected' 'does not verify' "$R" verify-tag v0.1.0-rc.1
git_ tag -d v0.1.0-rc.1 >/dev/null
sign_tag "$TMP/trusted" v0.1.0-rc.1
# tag.json must describe the tag object that exists now, not the earlier one.
"$R" verify-tag v0.1.0-rc.1 >/dev/null 2>&1

echo '# notes'
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- pending change

## [0.1.0] - 2026-09-24

### Added

- first shell

## [0.0.9] - 2026-09-01

- older
EOF
if [[ $("$R" notes 0.1.0) == $'### Added\n\n- first shell' ]]; then ok 'notes extracts exactly the version section'; else bad 'notes extraction'; fi
if [[ $("$R" notes 0.1.0-rc.1) == '- pending change' ]]; then ok 'pre-release notes fall back to Unreleased'; else bad 'pre-release fallback'; fi
expect_fail 'missing section for a release is rejected' "no non-empty '## \[0.2.0\]'" "$R" notes 0.2.0
printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-09-24\n' >"$REPO/CHANGELOG.md"
expect_fail 'empty section is rejected' 'no non-empty' "$R" notes 0.2.0
git_ checkout -q -- CHANGELOG.md

echo '# archive'
touch "$REPO/stray"
expect_fail 'archive refuses an unclean tree' 'uncommitted or untracked' "$R" archive
rm "$REPO/stray"
expect_ok 'archive dumps the committed tree' "$R" archive
narhash=$(jq -r .narHash "$RELEASE_DIST/archive.json")
nar=$RELEASE_DIST/$(jq -r .file "$RELEASE_DIST/archive.json")
if [[ $(nix hash file --sri --type sha256 "$nar") == "$narhash" ]]; then ok 'NAR file hash is the narHash'; else bad 'NAR hash'; fi
# Independent reproduction: a fresh clone of the tag, dumped by a separate
# nix invocation, must be byte-identical.
git clone -q --branch v0.1.0-rc.1 "$REPO" "$TMP/clone" 2>/dev/null
nix nar pack "$(nix flake prefetch --json "git+file://$TMP/clone" | jq -r .storePath)" >"$TMP/clone.nar"
if cmp -s "$nar" "$TMP/clone.nar"; then ok 'NAR reproduces byte-for-byte from a fresh clone'; else bad 'NAR reproduction'; fi
if [[ $(nix flake metadata --json "git+file://$TMP/clone" | jq -r .locked.narHash) == "$narhash" ]]; then
  ok 'fresh clone narHash equals the archive narHash'
else bad 'clone narHash'; fi

host=$(nix eval --impure --raw --expr builtins.currentSystem)
if [[ -z ${SKIP_SMOKE-} ]]; then
  echo "# smoke + fragment ($host)"
  nix build --no-link --no-update-lock-file "$REPO#checks.$host.dev-shells" >/dev/null 2>&1 || bad 'building dev-shells check'
  expect_fail 'fragment requires smoke results' 'smoke' "$R" fragment "$host"
  expect_ok 'smoke passes in every shell' "$R" smoke "$host"
  n=$(jq '.shells | length' "$RELEASE_DIST/smoke-$host.json")
  if [[ $n -ge 7 ]] && jq -e '.shells | all(.stdcVersion == "202311" and (.cc | test("gcc|clang")))' "$RELEASE_DIST/smoke-$host.json" >/dev/null; then
    ok "smoke recorded $n shells with C23 compilers"
  else bad 'smoke record'; fi
  expect_ok 'fragment records identities' "$R" fragment "$host"
  if jq -e --arg s "$host" '.system == $s and (.outputs | has("formatter") and has("devShells.gcc"))
      and (.outputs["devShells.gcc"] | (.drvPath | endswith(".drv")) and (.outPath | startswith("/nix/store/")) and .closureSize > 0)' \
    "$RELEASE_DIST/fragment-$host.json" >/dev/null; then
    ok 'fragment has drvPath, outPath, closure sizes'
  else bad 'fragment content'; fi
else
  echo "# smoke + fragment skipped (SKIP_SMOKE); using a synthetic fragment for $host"
  jq -n --arg s "$host" '{system: $s, nixVersion: "test", host: {}, outputs: {}, smoke: {}}' >"$RELEASE_DIST/fragment-$host.json"
fi

echo '# assemble'
# The manifest's notes come from CHANGELOG.md; use a fixture so the test does
# not depend on the real changelog (whose Unreleased section is legitimately
# empty right after a release).
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- pending change

## [0.0.9] - 2026-09-01

- older
EOF
expect_fail 'assemble requires a fragment per supported system' 'missing' "$R" assemble v0.1.0-rc.1
# Test fixture only: the other system's fragment is a relabelled copy.
for s in $(nix eval --json "$REPO#devShells" --apply builtins.attrNames | jq -r '.[]'); do
  [[ -s $RELEASE_DIST/fragment-$s.json ]] || jq --arg s "$s" '.system = $s' "$RELEASE_DIST/fragment-$host.json" >"$RELEASE_DIST/fragment-$s.json"
done
expect_ok 'assemble writes the manifest' "$R" assemble v0.1.0-rc.1
if jq -e --arg nh "$narhash" '.manifestVersion == 1 and .tag == "v0.1.0-rc.1" and .prerelease == true
    and .source.narHash == $nh and (.inputs.nixpkgs.narHash | startswith("sha256-"))
    and (.systems | has("x86_64-linux") and has("aarch64-linux"))' "$RELEASE_DIST/release.json" >/dev/null; then
  ok 'release.json links tag, narHash, inputs and systems'
else bad 'release.json content'; fi
if (cd "$RELEASE_DIST" && sha256sum --quiet --strict -c SHA256SUMS); then ok 'SHA256SUMS verifies'; else bad 'SHA256SUMS'; fi
if [[ $(head -n1 "$RELEASE_DIST/release-notes.md") == '- pending change' ]] && grep -q "$narhash" "$RELEASE_DIST/release-notes.md"; then
  ok 'release notes carry the changelog section and the narHash'
else bad 'release notes'; fi
git_ checkout -q -- CHANGELOG.md

echo '# publish (fake gh)'
FAKE=$TMP/fake
mkdir -p "$FAKE/bin"
export FAKE_GH_DIR=$FAKE
cat >"$FAKE/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal GitHub API stand-in: state lives in $FAKE_GH_DIR, every call is logged.
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_DIR/calls"
method=GET jqf= args=()
while (($#)); do
  case $1 in
    -X) method=$2; shift 2 ;;
    --jq) jqf=$2; shift 2 ;;
    -F | -f | --repo | --title | --notes-file) shift 2 ;;
    --paginate | --draft | --prerelease | --verify-tag) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
emit() { if [[ -n $jqf ]]; then jq -r "$jqf"; else cat; fi; }
case "${args[0]} ${args[1]-}" in
  'auth status') exit "${FAKE_GH_AUTH_RC:-0}" ;;
  'api '*)
    path=${args[1]}
    case "$method $path" in
      'GET repos/'*'/git/ref/tags/'*) [[ -s $FAKE_GH_DIR/ref.json ]] || exit 1; emit <"$FAKE_GH_DIR/ref.json" ;;
      'GET repos/'*'/releases') emit <"$FAKE_GH_DIR/releases.json" ;;
      'GET repos/'*'/releases/'*) id=${path##*/}; jq --argjson id "$id" '.[] | select(.id == $id)' "$FAKE_GH_DIR/releases.json" | emit ;;
      'DELETE repos/'*'/releases/'*) id=${path##*/}; jq --argjson id "$id" 'map(select(.id != $id))' "$FAKE_GH_DIR/releases.json" >"$FAKE_GH_DIR/r.tmp"; mv "$FAKE_GH_DIR/r.tmp" "$FAKE_GH_DIR/releases.json" ;;
      'PATCH repos/'*'/releases/'*) id=${path##*/}; jq --argjson id "$id" 'map(if .id == $id then .draft = false else . end)' "$FAKE_GH_DIR/releases.json" >"$FAKE_GH_DIR/r.tmp"; mv "$FAKE_GH_DIR/r.tmp" "$FAKE_GH_DIR/releases.json"; jq --argjson id "$id" '.[] | select(.id == $id)' "$FAKE_GH_DIR/releases.json" | emit ;;
      *) echo "fake gh: unhandled $method $path" >&2; exit 1 ;;
    esac ;;
  'release create')
    [[ ${FAKE_GH_CREATE_RC:-0} == 0 ]] || exit "$FAKE_GH_CREATE_RC"
    tag=${args[2]}; files=("${args[@]:3}")
    [[ -n ${FAKE_GH_DROP_ASSET-} ]] && files=("${files[@]:1}")
    assets=$(for f in "${files[@]}"; do jq -n --arg n "$(basename "$f")" --argjson s "$(stat -c %s "$f")" --arg d "sha256:$(sha256sum "$f" | cut -d' ' -f1)" '{name: $n, size: $s, digest: $d, state: "uploaded"}'; done | jq -s .)
    jq --arg tag "$tag" --argjson assets "$assets" '. + [{id: 900, tag_name: $tag, draft: true, prerelease: true, html_url: "https://example.invalid/draft", assets: $assets}]' \
      "$FAKE_GH_DIR/releases.json" >"$FAKE_GH_DIR/r.tmp"; mv "$FAKE_GH_DIR/r.tmp" "$FAKE_GH_DIR/releases.json"
    echo https://example.invalid/draft ;;
  *) echo "fake gh: unhandled ${args[*]}" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE/bin/gh"
export PATH=$FAKE/bin:$PATH
reset_state() { # reset_state [existing-releases-json]
  : >"$FAKE/calls"
  printf '%s' "${1:-[]}" >"$FAKE/releases.json"
  jq -n --arg sha "$(git_ rev-parse v0.1.0-rc.1)" '{object: {type: "tag", sha: $sha}}' >"$FAKE/ref.json"
}
reset_state
expect_fail 'publish requires the provenance bundle' 'missing asset' "$R" publish v0.1.0-rc.1
echo '{"fake":"bundle"}' >"$RELEASE_DIST/provenance.intoto.jsonl"
rm "$FAKE/ref.json"
expect_fail 'publish refuses when the tag is not on the remote' 'does not exist on github.com' "$R" publish v0.1.0-rc.1
reset_state
jq '.object.type = "commit"' "$FAKE/ref.json" >"$FAKE/ref.tmp" && mv "$FAKE/ref.tmp" "$FAKE/ref.json"
expect_fail 'publish refuses a remote lightweight/different tag' 'expected annotated tag object' "$R" publish v0.1.0-rc.1
reset_state '[{"id": 1, "tag_name": "v0.1.0-rc.1", "draft": false, "html_url": "https://example.invalid/published", "assets": []}]'
expect_fail 'publish never modifies a published release' 'already published' "$R" publish v0.1.0-rc.1
if ! grep -q 'release create' "$FAKE/calls"; then ok 'no draft was created for the published release'; else bad 'draft created despite published release'; fi
reset_state '[{"id": 7, "tag_name": "v0.1.0-rc.1", "draft": true, "html_url": "https://example.invalid/stale", "assets": []}]'
FAKE_GH_AUTH_RC=1 expect_fail 'publish requires gh authentication' 'not authenticated' "$R" publish v0.1.0-rc.1
expect_ok 'publish replaces a stale draft and publishes' "$R" publish v0.1.0-rc.1
if grep -q '^api -X DELETE repos/.*/releases/7$' "$FAKE/calls" && grep -q '^release create v0.1.0-rc.1 .*--draft.*--verify-tag.*--prerelease' "$FAKE/calls" &&
  grep -q '^api -X PATCH repos/.*/releases/900 -F draft=false -f make_latest=false' "$FAKE/calls" &&
  [[ $(grep -c 'release create' "$FAKE/calls") == 1 ]]; then
  ok 'publish sequence: delete stale draft, create draft with assets, publish with make_latest=false'
else bad "publish sequence: $(tr '\n' '|' <"$FAKE/calls")"; fi
if jq -e '.[0].draft == false and (.[0].assets | length) == 4' "$FAKE/releases.json" >/dev/null; then ok 'release ends published with 4 assets'; else bad 'final state'; fi
reset_state
FAKE_GH_DROP_ASSET=1 expect_fail 'publish refuses to publish a draft whose assets differ' 'assets differ' "$R" publish v0.1.0-rc.1
if ! grep -q 'PATCH' "$FAKE/calls" && jq -e '.[0].draft == true' "$FAKE/releases.json" >/dev/null; then ok 'incomplete draft is left unpublished'; else bad 'incomplete draft handling'; fi
reset_state
FAKE_GH_CREATE_RC=1 expect_fail 'publish fails when creating the draft fails' 'creating the draft release failed' "$R" publish v0.1.0-rc.1
if ! grep -q 'PATCH' "$FAKE/calls"; then ok 'nothing is published after a failed upload'; else bad 'published after failed upload'; fi
# A second run after success must refuse (duplicate request / retry safety).
reset_state
"$R" publish v0.1.0-rc.1 >/dev/null 2>&1
expect_fail 'a repeated publish of the same tag is refused' 'already published' "$R" publish v0.1.0-rc.1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
