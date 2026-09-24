# GitHub platform facts for a tag-driven release pipeline (public repo, single maintainer)

Retrieval date for everything below: 2026-09-24 (UTC), unless a line says otherwise.
Method: docs.github.com / github.blog / cli.github.com pages, raw README/action.yml from github.com, unauthenticated
public REST API (api.github.com), and an empirical test run with the official gh 2.100.0 Linux tarball
(sha256 e4d4bb44…64be matched cli/cli's published gh_2.100.0_checksums.txt) in an isolated, logged-out GH_CONFIG_DIR.
"UNVERIFIED" marks anything I could not confirm from a primary source.

--------------------------------------------------------------------------------------------------
## 1. Immutable releases

Status: GA since 2025-10-28 (public preview 2025-08-26).
- https://github.blog/changelog/2025-08-26-releases-now-support-immutability-in-public-preview/ (dated August 26, 2025)
  "Once you publish a release as immutable, its assets can't be added, modified, or deleted."
- https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/ (dated October 28, 2025)
  "You can enable immutable releases at the repository or organization level in your settings. Once enabled: All new
  releases are immutable (i.e., assets are locked and tags are protected)." "Existing releases remain mutable unless
  you republish them. Disabling immutability doesn't affect releases created while it was enabled. They remain immutable."
  "Attestations use the Sigstore bundle format, so you can easily verify releases and assets using the GitHub CLI or
  integrate with any Sigstore-compatible tooling".

What it guarantees — https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
  "Git tags cannot be moved : Once an immutable release is published, its associated Git tag is locked to a specific
  commit, cannot be changed, and cannot be deleted while the release exists. If you delete the immutable release, you
  can delete the tag, but you cannot reuse the same tag name."
  "Release assets cannot be modified or deleted : All files attached to the release (such as binaries and archives) are
  protected from modification or deletion. Only the assets and tag are locked. You can still edit the title and release
  notes of a published immutable release, and change whether it is marked as a pre-release or as the latest release."
  "creating an immutable release automatically generates a release attestation , which is a cryptographically verifiable
  record of a release containing the release tag, commit SHA, and release assets."
  "Immutable releases include protection against repository resurrection attacks. Even if you delete a repository and
  create a new one with the same name, you cannot reuse tags that were associated with immutable releases in the
  original repository."
  Drafts: "We recommend you use the following workflow for publishing an immutable release. Create the release as a
  draft. Attach all associated assets to the draft release. Publish the draft release. This ensures that all assets are
  in place before the release becomes immutable".
  => A published immutable release CAN be deleted (then its tag can be deleted; tag name is burned forever).

Draft handling — https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository
  "If you have enabled immutable releases for your repository, you cannot add, replace, or delete assets after a
  release is published, and you cannot move or delete its tag while the release exists." "If you have enabled immutable
  releases for the repository, creating a draft first allows you to attach all assets before the release becomes immutable."

Enabling — https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/preventing-changes-to-your-releases
  Repository: Settings -> "Releases" section -> "Enable release immutability". Organization: Settings -> Repository ->
  General -> "Releases" -> policy dropdown "No policy" -> "All repositories" / "Selected repositories".
  "Be aware that immutability will only apply to future releases."
  Default for NEW repositories: no doc states it is on by default; docs describe manual enablement. UNVERIFIED (assume off).

REST API (repos, docs examples use X-GitHub-Api-Version: 2026-03-10) — https://docs.github.com/en/rest/repos/repos
  GET  /repos/{owner}/{repo}/immutable-releases  -> 200 {"enabled": true, "enforced_by_owner": false}
       "Shows whether immutable releases are enabled or disabled. Also identifies whether immutability is being enforced
       by the repository owner. The authenticated user must have admin read access to the repository."
  PUT  /repos/{owner}/{repo}/immutable-releases  -> 204   "The authenticated user must have admin access"
  DELETE /repos/{owner}/{repo}/immutable-releases -> 204
  Fine-grained permission: "Administration" repository permissions (write).
  Release object (https://docs.github.com/en/rest/releases/releases) has a read-only boolean field "immutable".
  Create-release body: tag_name, target_commitish, draft, prerelease, generate_release_notes, make_latest (no
  immutability field; immutability comes from the repo setting). "Users with push access to the repository can delete a release."

Release attestation (empirical, from public bundles pypdfium2-team/pypdfium2 attestation 29421912 and cli/cli 45033981):
  in-toto Statement v1, predicateType "https://in-toto.io/attestation/release/v0.2"; predicate keys: databaseId,
  ownerId, packageId, purl, repository, repositoryId, tag; subjects = every uploaded asset (26 for pypdfium2 5.9.0).
  Signing cert SAN = "https://dotcom.releases.github.com", issuer org "GitHub, Inc."; bundle has certificate +
  rfc3161 timestamps and NO tlogEntries (i.e., GitHub's own Sigstore instance, not the public-good Rekor log).
  gh source (https://raw.githubusercontent.com/cli/cli/trunk/pkg/cmd/release/shared/attestation.go):
  `// If no trust domain is specified, default to "dotcom"` ... `^https://%s\.releases\.github\.com$` ... "No issuer
  extension (match anything)"; fetch uses PredicateType: "release", Initiator: "github".
  The "Release attestation (json)" link on a release page is https://github.com/<owner>/<repo>/attestations/<id>/download
  and returned HTTP 200 without authentication.
Verification — https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verifying-the-integrity-of-a-release
  `gh release verify RELEASE-TAG` and `gh release verify-asset RELEASE-TAG ARTIFACT-PATH`.
  "This command cannot be used to verify the source code zip file or tarball for a release, since these assets are only
  created when a download is requested."
  https://cli.github.com/manual/gh_release_verify : options only --format json, --jq, --template, -R/--repo (no --bundle).
  https://cli.github.com/manual/gh_release_verify-asset : "Verify that a given asset file originated from a specific
  GitHub Release using cryptographically signed attestations."
  EMPIRICAL: both commands, run logged-out, print "To get started with GitHub CLI, please run: gh auth login /
  Alternatively, populate the GH_TOKEN environment variable" => they REQUIRE authentication.
  `gh attestation verify --bundle <release-attestation> --repo|--owner ... --predicate-type
  https://in-toto.io/attestation/release/v0.2 --cert-identity-regex '^https://[a-z0-9-]+\.releases\.github\.com$'`
  FAILS with "expected SourceRepositoryOwnerURI to be https://github.com/<owner>, got " (the release cert has no
  GitHub Actions extensions), so gh attestation verify cannot be used for release attestations; cosign with
  --certificate-identity https://dotcom.releases.github.com would be the anonymous path: UNVERIFIED (not run).

--------------------------------------------------------------------------------------------------
## 2. Artifact attestations

Actions (tags -> commit SHAs resolved via api.github.com/repos/.../git/ref/tags on 2026-09-24; all lightweight tags
unless noted):
  actions/attest-build-provenance  latest major v4; latest release v4.2.2 (published 2026-08-06T19:59:04Z)
      v4.2.2 -> 4d101475d8b20a2381f78447822ac1eab6504dd8 ; v4 (annotated tag 8beda2b7…) -> same commit 4d101475…
      action.yml: runs.using "composite"; it does `uses: actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d # v4.2.1`
      README (https://github.com/actions/attest-build-provenance): "As of version 4, `actions/attest-build-provenance`
      is simply a wrapper on top of `actions/attest`." "new implementations should use `actions/attest` instead."
  actions/attest  latest major v4; latest release v4.2.2 (published 2026-08-04T20:36:29Z)
      v4.2.2 -> 1e69f48acb82d1966a394da916b4c1698aa569d6 ; v4 -> 1e69f48a… ; v4.2.1 -> 508db95d… ; runs.using node24
      v4.0.0 (2026-02-25): "All of the capabilities of actions/attest-build-provenance, and actions/attest-sbom have
      now been folded into actions/attest."
actions/attest README (https://github.com/actions/attest, raw main):
  permissions block: "id-token: write / attestations: write / artifact-metadata: write" — "The `id-token` permission
  gives the action the ability to mint the OIDC token necessary to request a Sigstore signing certificate. The
  `attestations` permission is necessary to persist the attestation. The `artifact-metadata` permission is necessary
  to create the artifact storage record." (input create-storage-record "Defaults to true"; input show-summary
  "Defaults to true"). The docs how-to example uses only id-token: write, contents: read, attestations: write.
  Inputs: subject-path, subject-digest ("sha256:hex_digest"), subject-name, subject-checksums ("Path to checksums file
  containing digest and name of subjects"), sbom-path, predicate-type, predicate, predicate-path, push-to-registry,
  create-storage-record, show-summary, github-token. "At most one of subject-path, subject-digest, or subject-checksums
  may be provided." Outputs: bundle-path, attestation-id, attestation-url, storage-record-ids.
  Limits: "No more than 1024 subjects can be attested at the same time." predicate "cannot exceed 16MB"; SBOM "File
  size cannot exceed 16MB."
  Sigstore: "If the repository initiating the GitHub Actions workflow is public, the public-good instance of Sigstore
  will be used to generate the attestation signature. If the repository is private/internal, it will use the GitHub
  private Sigstore instance."
Docs: https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations
  example step `uses: actions/attest@v4` with `subject-path: 'PATH/TO/ARTIFACT'`; verify:
  `gh attestation verify PATH/TO/YOUR/BUILD/ARTIFACT-BINARY -R ORGANIZATION_NAME/REPOSITORY_NAME`.
  https://docs.github.com/en/actions/concepts/security/artifact-attestations : public repos "use the Sigstore Public
  Good Instance"; private repos use "GitHub's Sigstore instance...does not have a transparency log and only federates
  with GitHub Actions"; "A copy of the generated Sigstore bundle is stored with GitHub and is also written to an
  immutable transparency log that is publicly readable on the internet." Retention period: none documented (UNVERIFIED);
  deletion is manual/API (https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/manage-attestations).
gh attestation verify — https://cli.github.com/manual/gh_attestation_verify
  Required: one of -R/--repo <owner>/<repo> or -o/--owner. "By default, this command will attempt to fetch relevant
  attestations via the GitHub API using the values provided to --owner or --repo." "For offline verification using
  attestations stored on disk (c.f. the download command) provide a path to the --bundle flag."
  Flags: -b/--bundle, --bundle-from-oci, --cert-identity, -i/--cert-identity-regex, --cert-oidc-issuer (default
  https://token.actions.githubusercontent.com), --custom-trusted-root ("Path to a trusted_root.jsonl file; likely for
  offline verification"), --deny-self-hosted-runners, -d/--digest-alg {sha256|sha512}, --format json, --hostname,
  -q/--jq, -L/--limit (30), --no-public-good, --predicate-type (default https://slsa.dev/provenance/v1),
  --signer-digest, --signer-repo, --signer-workflow ([host/]<owner>/<repo>/<path>/<to>/<workflow>), --source-digest,
  --source-ref, -t/--template.
  gh source https://raw.githubusercontent.com/cli/cli/trunk/pkg/cmd/attestation/verify/verify.go line 236:
  `cmdutil.DisableAuthCheckFlag(verifyCmd.Flags().Lookup("bundle"))` (auth check skipped when --bundle is given).
  cli/cli#11803 "`gh attestation verify` should be able to work without token / authentication" (opened 2025-09-24,
  still OPEN, labels enhancement, gh-attestation). GitHub staff (steiza, 2025-09-25): "`gh attestation verify` actually
  **does not** require GitHub authentication **when** you supply the bundle. ... All GitHub REST APIs, even for public
  repositories, are heavily rate-limited for unauthenticated users". Also: "it is compatible with other Sigstore tooling.
  See ... https://blog.sigstore.dev/cosign-verify-bundles/ ... It would also be possible to verify this content with
  https://github.com/sigstore/sigstore-python". Official docs mention no cosign/sigstore-python recipe.
  EMPIRICAL (logged-out gh 2.100.0, artifact gh_2.100.0_linux_amd64.tar.gz, repo cli/cli):
    - `gh attestation verify <file> --repo cli/cli` (no --bundle): refused, asks for gh auth login / GH_TOKEN.
    - `gh attestation download ... --repo cli/cli`: refused (needs auth). cli/cli#12030 tracks this.
    - `gh attestation trusted-root > trusted_root.jsonl`: exit 0, 34634 bytes, no auth needed (TUF from Sigstore).
    - `gh attestation verify <file> --repo cli/cli --bundle sha256:<digest>.jsonl`: exit 0 (online TUF root, no auth).
    - same + `--custom-trusted-root trusted_root.jsonl --signer-repo cli/cli --deny-self-hosted-runners --format json`:
      exit 0; cert SAN https://github.com/cli/cli/.github/workflows/deployment.yml@refs/heads/trunk, issuer
      https://token.actions.githubusercontent.com, runnerEnvironment github-hosted, predicateType slsa.dev/provenance/v1.
    - same with HTTPS_PROXY/HTTP_PROXY pointed at a dead port (simulated offline): exit 0 with --custom-trusted-root;
      without it: "error creating Sigstore verifier: no valid Sigstore verifiers could be initialized".
    - `--owner cli` instead of --repo: exit 0. `--source-ref refs/tags/v2.100.0` on a trunk build: correct failure
      "expected SourceRepositoryRef to be refs/tags/v2.100.0, got refs/heads/trunk".
  Getting bundles WITHOUT a token: GET https://api.github.com/repos/cli/cli/attestations/sha256:<digest> returned 200
  anonymously, but with "bundle": null and a "bundle_url" (Azure blob SAS URL, ~1h expiry) whose body is raw
  snappy-compressed JSON (gh decodes it with klauspost/compress/snappy). The blob filename number is the attestation id;
  https://github.com/<owner>/<repo>/attestations/<id>/download returned plain JSON bundles (200, no auth); one bundle
  per line makes a valid --bundle JSONL. Docs for the endpoint say "The authenticated user making the request must have
  read access to the repository. In addition, when using a fine-grained access token the attestations:read permission
  is required." and predicate_type filter "accepts provenance, sbom, release, or freeform text"
  (https://docs.github.com/en/rest/repos/attestations). The /orgs/{org}/attestations/... variant returned 401 anonymously.
gh attestation download — https://cli.github.com/manual/gh_attestation_download : writes "a file in the current directory
  named after the artifact's digest" (sha256:<hex>.jsonl); needs --repo or --owner; -L/--limit 30; --predicate-type.
Offline how-to — https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline
  `gh attestation trusted-root > trusted_root.jsonl`; `gh attestation verify <artifact> -R <owner>/<repo> --bundle
  sha256:<digest>.jsonl --custom-trusted-root trusted_root.jsonl`; "It's best practice to generate a new
  trusted_root.jsonl file any time you are importing new signed material into your offline environment."
Sigstore blog (2024-08-27, https://blog.sigstore.dev/cosign-verify-bundles/): `cosign verify-blob-attestation --bundle
  sha256:<digest>.jsonl --new-bundle-format --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
  --certificate-identity-regexp="^https://github.com/cli/cli/.github/workflows/deployment.yml.?" <artifact>`.

--------------------------------------------------------------------------------------------------
## 3. Hosted runners

https://github.com/actions/runner-images/blob/main/README.md (table, 2026-09-24): ubuntu-latest = ubuntu-24.04 today;
labels ubuntu-26.04, ubuntu-26.04-arm, ubuntu-24.04, ubuntu-24.04-arm, ubuntu-22.04, ubuntu-22.04-arm, ubuntu-slim.
ubuntu-latest migration: https://github.blog/changelog/2026-09-17-ubuntu-26-generally-available-and-latest-migration/
  (Sept 17, 2026): ubuntu-latest moves 24.04 -> 26.04 "gradually between October 19 and November 19, 2026"; "If you are
  not ready to move, pin your workflows to ubuntu-24.04". Tracking issue actions/runner-images#14748:
  "This change will be rolled out over a period of several weeks beginning October 19, 2026. We plan to complete the
  migration by November 19, 2026." (x64 label; arm64 checkbox not ticked in that issue.)
Ubuntu 22.04 retirement: actions/runner-images#14254 (opened 2026-06-16): "Deprecation will begin on September 17th,
  2026 and the images will be fully unsupported by April 17th,, 2027"; brownouts listed as March 23, March 30, April 6,
  April 13 (14:00 UTC windows; year unstated in the issue, implicitly 2027); affects ubuntu-22.04 and ubuntu-22.04-arm;
  "GitHub Actions maintains the latest two stable versions of any given OS version."
arm64 free for public repos: https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/
  (Aug 7, 2025): labels ubuntu-24.04-arm, ubuntu-22.04-arm (and windows-11-arm), 4 vCPU, free for public repositories;
  "These runners are only available in public repositories and will not work in private repositories" (private repos got
  arm64 standard runners on 2026-01-29, separate changelog). ubuntu-26.04-arm is listed in the README table.
Preinstalled tools (raw READMEs, main branch, 2026-09-24):
  Ubuntu2404-Readme.md        Image Version 20260907.300.1  OS 24.04.5 LTS  GitHub CLI 2.100.0  Git 2.55.0  jq 1.7    curl 8.5.0-2ubuntu10.13  Node.js 22.23.2  Docker 28.0.4
  Ubuntu2404-Arm64-Readme.md  Image Version 20260907.118.1  OS 24.04.5 LTS  GitHub CLI 2.100.0  Git 2.55.0  jq 1.7    curl 8.5.0-2ubuntu10.13  Node.js 22.23.2  Docker 28.0.4
  Ubuntu2604-Readme.md        Image Version 20260907.131.1  OS 26.04.1 LTS  GitHub CLI 2.100.0  Git 2.55.0  jq 1.8.1  curl 8.18.0-1ubuntu2.4   Node.js 24.20.0  Docker 29.4.2
  Ubuntu2604-Arm64-Readme.md  Image Version 20260907.118.1  OS 26.04.1 LTS  same versions as 26.04 x64
  (image versions roll weekly; a 20260920 image release exists, README lags). Nix: not present in any of the four lists.
  URLs: https://github.com/actions/runner-images/blob/main/images/ubuntu/{Ubuntu2404-Readme.md,Ubuntu2404-Arm64-Readme.md,Ubuntu2604-Readme.md,Ubuntu2604-Arm64-Readme.md}

--------------------------------------------------------------------------------------------------
## 4. Actions runtime and pinned versions

Node 20 -> 24: https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/ (Sept 19, 2025):
  runner v2.328.0+ supports both; "June 16, 2026: Runners switch to Node 24 by default"; "September 23, 2026: Node 20
  completely removed"; FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true to test early; ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION=true
  as the interim opt-out.
  https://github.blog/changelog/2026-09-23-node-20-is-no-longer-available-in-github-actions/ (Sept 23, 2026): "This is
  the final notification that Node 20 is no longer available on GitHub Actions runners." "Runners now use Node 24 for
  JavaScript actions" (actions still declaring node20 are run on Node 24); "The temporary ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION
  opt-out is no longer available." Node 24 "is incompatible with macOS 13.4 and earlier, and it doesn't officially support ARM32".
Latest majors / tags / commit SHAs (api.github.com, 2026-09-24; all lightweight tags unless noted):
  actions/checkout           v7   v7.0.1 (2026-07-20)  3d3c42e5aac5ba805825da76410c181273ba90b1  (v7 tag -> same SHA) runs.using node24
                              v7.0.0 (2026-06-18): "block checking out fork pr for pull_request_target and workflow_run", ESM upgrade
  actions/upload-artifact    v7   v7.0.1 (2026-04-10)  043fb46d1a93c77aae656e7c1c64a875d1fc6a0a  (v7 -> same) node24
                              v7.0.0 (2026-02-26): "Direct Uploads ... set the new `archive` parameter to `false`"; ESM
  actions/download-artifact  v8   v8.0.1 (2026-03-11)  3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c  (v8 -> same) node24
                              v8.0.0 (2026-02-26): "Hash mismatches will now error by default"; `skip-decompress` input; ESM
  actions/attest-build-provenance v4  v4.2.2 (2026-08-06)  4d101475d8b20a2381f78447822ac1eab6504dd8  (v4 annotated -> same) composite
  actions/attest             v4   v4.2.2 (2026-08-04)  1e69f48acb82d1966a394da916b4c1698aa569d6  (v4 -> same) node24
Other deprecations relevant in 2026:
  - artifact actions v3 shut off "Starting January 30th, 2025" (https://github.blog/changelog/2024-04-16-deprecation-notice-v3-of-the-artifact-actions/, Apr 16 2024).
  - set-output/save-state: still functional; removal postponed (https://github.blog/changelog/2023-07-24-github-actions-update-on-save-state-and-set-output-commands/:
    "Workflows using save-state or set-output ... will continue to work as expected, however, a warning will appear"). No 2026 removal found (UNVERIFIED that none is scheduled).
  - Actions retention (https://github.blog/changelog/2026-08-27-actions-retention-will-cover-checks-workflow-runs-and-statuses/, Aug 27 2026):
    "Starting October 1, 2026, checks, workflow runs, and statuses will be governed by the same Actions retention setting ... with a default of 90 days."
  - Workflow execution protections GA (https://github.blog/changelog/2026-09-17-workflow-execution-protections-in-github-actions-generally-available/, Sept 17 2026):
    default rule for public repos disables pull_request_target (enforced Nov 2, 2026); nothing about push/tag events.
  - "GitHub Actions holds potentially malicious workflows for approval" (2026-07-28): automatic for public repos; a write
    collaborator must approve held runs; criteria not published (impact on maintainer tag pushes UNVERIFIED).
  - REST API version 2026-03-10 (https://github.blog/changelog/2026-03-12-rest-api-version-2026-03-10-is-now-available/):
    "Version 2022-11-28 will continue to be fully supported for at least 24 months from today, and requests that don't
    include the X-GitHub-Api-Version header will continue to default to 2022-11-28."
  - OIDC immutable sub claims (https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/):
    repos created after July 15, 2026 get `repo:octocat@123456/my-repo@456789:ref:...` sub claims (affects cloud trust
    policies, not attestation SAN identities — attestation cert SAN observed unchanged format; effect on attestations UNVERIFIED).
  - Early Sept 2026 updates (https://github.blog/changelog/2026-09-03-github-actions-early-september-2026-updates/):
    new `vulnerability-alerts` GITHUB_TOKEN permission; job.workflow_ref/sha/repository/file_path context; runner deprecation API.
  - The URL github.blog/changelog/2026-02-05-notice-of-upcoming-deprecations-and-breaking-changes-for-github-actions/
    serves the February 12, 2025 post (same slug); no separate 2026 notice content exists there.

--------------------------------------------------------------------------------------------------
## 5. Source archive byte stability

- https://github.blog/open-source/git/update-on-the-future-stability-of-source-code-archives-and-hashes/ (February 21, 2023):
  "GitHub will hold the source downloads byte-for-byte stable for no less than a year from today (February 21, 2023)."
  "In the future, if we intend to change either archive format, we'll provide six months' notice in documentation, and
  on the blog and changelog." "If we discover a critical vulnerability in the compression path, we reserve the right to
  shorten or omit the notice period." "We presently have no intent to change either format".
- https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives (current):
  "An archive of a commit ID will always have the same file contents whenever it's requested, assuming the commit ID is
  still in the repository and the repository's name has not changed." "Because branches and tags can move to different
  commit IDs, future downloads of an archive may have different contents than previously downloaded archives of the same
  branch or tag." "GitHub will give at least six months' notice before changing compression settings." URL forms:
  /archive/refs/tags/<tag>.tar.gz|.zip, /archive/refs/heads/<branch>.tar.gz, /archive/<sha>.zip.
  => Contents are stable per commit; byte-level (compression) stability is only promised with 6 months' notice, not forever.

--------------------------------------------------------------------------------------------------
## 6. Rulesets for tags

- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
  "You can create branch or tag rulesets". Restrict creations: "only users with bypass permissions can create branches or
  tags whose name matches the pattern you specify." Restrict updates: "only users with bypass permissions can push to
  branches or tags whose name matches the pattern". Restrict deletions: "only users with bypass permissions can delete
  branches or tags whose name matches the pattern you specify. This rule is selected by default."
  Require signed commits: "When you enable required commit signing on a branch, contributors and bots can only push
  commits that have been signed and verified to the branch." ... "we use the verified_signature? to confirm if a commit
  has a valid signature. If not, the update is not accepted."
- UI: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository
  "to create a ruleset targeting tags, click New tag ruleset" ... 'In the "Branch protections" or "Tag protections"
  section, select the rules you want to include in the ruleset.'
- REST: POST /repos/{owner}/{repo}/rulesets (https://docs.github.com/en/rest/repos/rules) — fine-grained
  "Administration" repository permissions (write); body: name (required), enforcement (disabled|active|evaluate,
  required), target (branch|tag|push, default branch), bypass_actors[], conditions.ref_name.include/exclude (patterns;
  ~ALL), rules[] with types incl. creation, update, deletion, required_linear_history, required_signatures ("Commits
  pushed to matching refs must have verified signatures."), tag_name_pattern, non_fast_forward, etc.
  => Yes: a tag ruleset can restrict create/update/delete of refs/tags/v* to bypass actors and require verified commit
  signatures ("matching refs"). No rule type exists for requiring signed TAG OBJECTS (annotated-tag signatures); the
  signature rule checks commits. (Tag-ruleset UI exposing "Require signed commits" inferred from the REST wording and the
  shared rule page; not exercised — UNVERIFIED.)

--------------------------------------------------------------------------------------------------
## 7. Public key endpoints and "Verified" tags

- https://docs.github.com/en/rest/users/ssh-signing-keys : GET /users/{username}/ssh_signing_keys "Lists the SSH signing
  keys for a user. This operation is accessible by anyone." Fields: id, key, title, created_at.
- https://docs.github.com/en/rest/users/gpg-keys : GET /users/{username}/gpg_keys "Lists the GPG keys for a user. This
  information is accessible by anyone." Fields: id, key_id, raw_key, emails[{email,verified}], subkeys, can_sign, expires_at.
- EMPIRICAL 2026-09-24 (no token): https://github.com/web-flow.gpg -> 200 text/plain (armored PGP block);
  https://github.com/octocat.keys -> 200 text/plain (authentication keys only); api /users/web-flow/gpg_keys -> 200
  JSON; /users/octocat/ssh_signing_keys -> 200 "[]"; /users/octocat/keys -> 200. Docs page describing the .keys/.gpg
  URLs: not located (UNVERIFIED as a documented contract).
- Verified status: https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification
  "If a commit or tag has a GPG, SSH, or S/MIME signature that is cryptographically verifiable, GitHub marks the commit
  or tag "Verified" or "Partially verified."" GPG: "GitHub uses OpenPGP libraries to confirm that your locally signed
  commits and tags are cryptographically verifiable against a public key you have added to your account". SSH: "GitHub
  uses ssh_data ... to confirm that your locally signed commits and tags are cryptographically verifiable against a
  public key you have added to your account" (SSH signing requires Git 2.34+; an authentication key can be re-uploaded
  as a signing key). Statuses: Verified "The commit is signed and the signature was successfully verified."; Unverified
  "The commit is signed but the signature could not be verified."; vigilant mode adds "Partially verified".
  Email rule (GPG): https://docs.github.com/en/authentication/managing-commit-signature-verification/associating-an-email-with-your-gpg-key
  "Your GPG key must be associated with a verified email that matches your committer identity."
  Web commits: "GitHub will automatically use GPG to sign commits you make using the web interface." (web-flow key 4AEE18F83AFDEB23).

--------------------------------------------------------------------------------------------------
## 8. GITHUB_TOKEN, gh CLI on runners

- Workflow-syntax permissions list (https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax):
  actions, artifact-metadata, attestations, checks, code-quality, contents, deployments, discussions, id-token
  (write|none only), issues, packages, pages, pull-requests, security-events, statuses, vulnerability-alerts.
  "If you specify the access for any of these permissions, all of those that are not specified are set to none."
  "id-token Fetch an OpenID Connect (OIDC) token. This requires id-token: write." GITHUB_TOKEN "expires ... 24 hours".
- Defaults: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository
  "when you create a new repository in your personal account, GITHUB_TOKEN only has read access for the contents and
  packages scopes." Under "Workflow permissions": "read and write access for all permissions (the permissive setting),
  or just read access for the contents and packages permissions (the restricted setting)."
- Release creation: REST "Create a release" requires "Contents" repository permissions (write) => `contents: write`.
  Attestations: `id-token: write` + `attestations: write` (+ `artifact-metadata: write` for storage records per actions/attest README).
- gh on runners: https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-what-your-workflow-does/using-github-cli-in-workflows
  "GitHub CLI is preinstalled on all GitHub-hosted runners." Auth: "set an environment variable called GH_TOKEN to a
  token with the required scopes" (example `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`). Not auto-authenticated without it.
- gh release create (https://cli.github.com/manual/gh_release_create): "If a matching git tag does not yet exist, one
  will automatically get created from the latest state of the default branch. Use --target to point to a different
  branch or commit for the automatic tag creation. Use --verify-tag to abort the release if the tag doesn't already
  exist." Flag text: "--verify-tag Abort in case the git tag doesn't already exist in the remote repository". Also
  --draft, --notes-from-tag, --generate-notes, --notes-start-tag, --latest[=false], --prerelease, --fail-on-no-commits,
  --notes-file, --title, --discussion-category; assets as '/path/to/asset.zip#My display label'.
- Token-triggered events: https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
  "With the exception of workflow_dispatch and repository_dispatch, other GITHUB_TOKEN-triggered events do not create
  workflow runs at all." (also https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow:
  "events triggered by the GITHUB_TOKEN will not create a new workflow run, with the following exceptions:
  workflow_dispatch and repository_dispatch events always create workflow runs.")

--------------------------------------------------------------------------------------------------
## 9. Workflow semantics

- push event: "Runs your workflow when you push a commit or tag, or when you create a repository from a template."
  Table: GITHUB_SHA = "Tip commit pushed to the ref. When you delete a branch, the SHA in the workflow run (and its
  associated refs) reverts to the default branch of the repository."; GITHUB_REF = "Updated ref".
  "Events will not be created if more than 5,000 branches are pushed at once. Events will not be created for tags when
  more than three tags are pushed at once." Tag push by a human/PAT with a commit not on any branch: docs impose no
  branch-membership condition, but no explicit statement found — UNVERIFIED. (Events like create/delete/release say
  "This event will only trigger a workflow run if the workflow file exists on the default branch"; push does not carry
  that note.)
- Filters (workflow-syntax): "Use the tags filter when you want to include tag name patterns or when you want to both
  include and exclude tag names patterns." "If you define only tags/tags-ignore or only branches/branches-ignore, the
  workflow won't run for events affecting the undefined Git ref."
- Contexts (https://docs.github.com/en/actions/reference/workflows-and-actions/contexts): github.ref "The fully-formed
  ref of the branch or tag that triggered the workflow run. For workflows triggered by push, this is the branch or tag
  ref that was pushed."; github.ref_name "The short ref name of the branch or tag that triggered the workflow run. This
  value matches the branch or tag name shown on GitHub."; github.ref_type "Valid values are branch or tag."
- Concurrency (https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/control-the-concurrency-of-workflows-and-jobs):
  "When a concurrent job or workflow is queued, if another job or workflow using the same concurrency group in the
  repository is in progress, the queued job or workflow will be pending. By default, any existing pending job or
  workflow in the same concurrency group will be canceled and the new queued job or workflow will take its place."
  "To also cancel any currently running job or workflow in the same concurrency group, specify cancel-in-progress: true."
  "The concurrency group name is case insensitive." "Since the actual start time of a job or run may vary, ordering is not guaranteed."

--------------------------------------------------------------------------------------------------
## 10. Limits

- https://docs.github.com/en/actions/reference/limits : "Each job in a workflow can run for up to 6 hours of execution
  time. If a job reaches this limit, the job is terminated and fails." Workflow run limit 35 days ("includes execution
  duration, and time spent on waiting and approval"). Concurrency table (standard hosted runners): Free 20 total
  (5 macOS), Pro 40, Team 60, Enterprise 500. Job matrix max 256 jobs. GITHUB_TOKEN API rate limit "1,000 requests per
  hour per repository". timeout-minutes default = 360 (6 h).
- Artifact retention (https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization):
  "By default, checks, workflow runs, commit statuses, and the artifacts and log files generated by workflows are
  retained for 90 days"; public repos "between 1 day or 90 days"; private repos "between 1 day or 400 days".
- Releases (https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases): "Up to 1000 release
  assets may be associated with a single release"; "Each file included in a release must be under 2 GiB"; "There is no
  limit on the total size of a release, nor bandwidth usage".
- Anonymous REST rate limit observed: 60/h (x-ratelimit headers); GITHUB_TOKEN 1,000/h/repo (docs).

--------------------------------------------------------------------------------------------------
## UNVERIFIED list (consolidated)
1. Immutable releases being ON by default for newly created repositories (no doc statement; assume off).
2. Attestation retention period (no doc found).
3. Anonymous verification of a *release* attestation with cosign/sigstore-python using identity
   https://dotcom.releases.github.com (derived from gh source + cert bytes; not executed).
4. Tag-ruleset UI exposing "Require signed commits" (REST wording "matching refs" implies yes; not exercised).
5. A docs page documenting https://github.com/<user>.keys / .gpg (endpoints work empirically).
6. Docs statement that a tag whose commit is on no branch triggers on:push (only the general "push a commit or tag" text).
7. Whether "holds potentially malicious workflows for approval" (2026-07-28) can affect a maintainer's tag-push run.
8. Effect of the July 15, 2026 OIDC immutable-sub-claim change on attestation certificates (observed cert SAN format unchanged for cli/cli).
9. No scheduled removal of set-output/save-state in 2026 (none found).
