# Audit: GitHub Release publishing mechanisms (gh CLI vs action-gh-release vs release-action)

Audit date: 2026-09-24. Clones under `scratchpad/audit/`. Line numbers refer to the checked-out tag.
Evidence standard: repo@tag (SHA), file:line, verbatim quotes. Items not confirmed from source or docs are marked UNVERIFIED.

## 0. Provenance

| Repo | Tag audited | Commit SHA | Tag kind | Release date | Notes |
|---|---|---|---|---|---|
| cli/cli | v2.101.0 | `0cf1092493af067646fc5f3db9421c6a6ec9c938` | lightweight | 2026-09-15 | GitHub release for this tag has `"immutable": true` (API). go.mod: `go 1.27.0`, 61 direct / 179 total module requirements. |
| softprops/action-gh-release | v3.0.3 | `efb35369e0ad2afab669f228072c1b0d510eae64` | annotated (tag obj `e598afbe…`) | 2026-08-30 | Floating `v3` (annotated tag obj `5113cdc9…`) peels to the same commit. `npm run updatetag` force-moves `v3` (package.json:14). Own releases are NOT immutable (`"immutable": false`). |
| ncipollo/release-action | v1.21.0 | `339a81892b84b4eeb0f6e744e4574d79d0d9b8dd` | lightweight | 2026-03-14 | `v1` currently points at the same SHA. Own releases NOT immutable. |
| cli/go-gh (gh's HTTP layer, for retry check) | v2.16.1 | `37aa5bbaf1a591aa134913efeb3775f0235dc5ab` | | | |

Runner context: actions/runner-images Ubuntu 24.04 image `20260907.300.1` ships "GitHub CLI 2.100.0". `pkg/cmd/release/create/create.go` and `pkg/cmd/release/shared/upload.go` at v2.100.0 differ from v2.101.0 only by `errors.As` → `errors.AsType` refactors (diffed raw files); behaviour below applies to the preinstalled gh.

---

## 1. gh CLI (cli/cli v2.101.0), `pkg/cmd/release`

### 1a. `gh release create TAG [files...]`

**Draft-first ordering (verified).** `create.go:497-512`:
```go
hasAssets := len(opts.Assets) > 0
draftWhileUploading := false
if hasAssets && !opts.Draft {
    // Check for an existing release
    if opts.TagName != "" {
        if ok, err := publishedReleaseExists(httpClient, baseRepo, opts.TagName); err != nil {
            return fmt.Errorf("error checking for existing release: %w", err)
        } else if ok {
            return fmt.Errorf("a release with the same tag name already exists: %s", opts.TagName)
        }
    }
    // Save the release initially as draft and publish it after all assets have finished uploading
    draftWhileUploading = true
    params["draft"] = true
}
```
Sequence of API calls when assets are given and `--draft` is absent:
1. `HEAD /repos/{o}/{r}/releases/tags/{tag}` (`create/http.go:110-138`, `publishedReleaseExists`; 404 → false).
2. `POST /repos/{o}/{r}/releases` with `"draft": true` (`create/http.go:140-180`, `createRelease`; called at `create.go:514`).
3. Concurrent asset uploads, 5 workers (`create.go:190` `opts.Concurrency = 5`; `create.go:550` → `shared.ConcurrentUpload`).
4. `PATCH {release.url}` with `{"draft": false}` (+ `discussion_category_name`, `make_latest` if set) (`create/http.go:182-206`, `publishRelease`; called at `create.go:556-562`).

The help text documents this (`create.go:111-122`): "When using the `create` command to attach assets to a release, separate API calls are made to create the release as a draft, upload the assets, and then publish the release. Immutability protections will be enforced ONLY after the release is published."

Test evidence `create/create_test.go:802-858` ("publish after uploading files"): stubs `HEAD …/releases/tags/v1.2.3` → 404, `POST repos/OWNER/REPO/releases` asserting params `{"tag_name":"v1.2.3","draft":true,"prerelease":false}`, `POST assets/upload`, then `PATCH releases/123` asserting `{"draft": false}`.

History: `params["draft"] = true` + `publishRelease` already present in v1.0.0 (`create.go:274,296` of that tag, fetched raw). The draft-cleanup below is present in v2.60.0 and absent in v2.20.0 (exact introducing version UNVERIFIED).

**Failure midway (verified): the draft is deleted.** `create.go:533-541`:
```go
cleanupDraftRelease := func(err error) error {
    if !draftWhileUploading {
        return err
    }
    if cleanupErr := deleteRelease(httpClient, baseRepo.RepoHost(), safeurl.NewImmutableSafeURL(newRelease.APIURL)); cleanupErr != nil {
        return fmt.Errorf("%w\ncleaning up draft failed: %v", err, cleanupErr)
    }
    return err
}
```
Invoked on upload error (`create.go:552-554`) and on publish (PATCH) error (`create.go:557-560`). `deleteRelease` = `DELETE {release.url}` (`create/http.go:208-213`). Tests: `create_test.go:949-982` (upload 422 → `DELETE releases/123`, command exits with `HTTP 422 (…assets/upload?label=&name=ball.tgz)`), `create_test.go:984-1018` (PATCH 500 → `DELETE releases/123`, exits `HTTP 500`). Upload concurrency uses `errgroup.WithContext`, so the first failure cancels in-flight sibling uploads (`shared/upload.go:116-127`; requests are built with `gctx`, `upload.go:176`).
Caveat: with explicit `--draft`, `draftWhileUploading` stays false, so a failed upload leaves the draft (with partial assets) in place and no cleanup happens (`create.go:534-536`).

**Existing-release check only sees PUBLISHED releases.** `publishedReleaseExists` uses `HEAD …/releases/tags/{tag}`; REST docs: "Get a published release with the specified tag." Consequence: an orphaned/pre-existing DRAFT for the same tag is not detected, and a re-run of `gh release create TAG files…` creates a second draft (then publishes it; the API then rejects the publish if the tag is already bound to a published release — status UNVERIFIED). The check is skipped entirely when there are no assets or `--draft` is set (`create.go:500`).

**Flags (all `create.go`):**
- `--draft` (`:209`): `params["draft"] = opts.Draft` (`:450`); with assets → draft created, assets uploaded, never published, no cleanup on failure. Rejected together with `--discussion-category` (`:160-162`).
- `--prerelease` (`:210`): `params["prerelease"]` on the initial POST (`:451`); the publish PATCH sends only `draft`/`discussion_category_name`/`make_latest`, so prerelease is preserved.
- `--latest` (`:218`, `cmdutil.NilBoolFlag` → `*bool`, `pkg/cmdutil/flags.go:21-25`): `params["make_latest"] = fmt.Sprintf("%v", *opts.IsLatest)` i.e. `"true"`/`"false"` on POST (`:462-465`) AND repeated on the publish PATCH (`:557`; `create/http.go:188-190`). `legacy` is not reachable via the flag.
- `--verify-tag` (`:219`): `create.go:283-292` → `remoteTagExists` (`create/http.go:41-58`), a GraphQL query `RepositoryFindRef`: `repository(owner:$owner,name:$name){ ref(qualifiedName: "refs/tags/<tag>") { id } }`; non-empty id ⇒ exists. Error: `tag %s doesn't exist in the repo %s, aborting due to --verify-tag flag`. It checks existence only, not which commit the tag points to.
- Tag missing remotely, no `--verify-tag`: gh just sends `tag_name` (+ `target_commitish` if `--target`); GitHub creates the tag. Help (`:90-92`): "If a matching git tag does not yet exist, one will automatically get created from the latest state of the default branch. Use `--target` to point to a different branch or commit". REST docs for `target_commitish`: "Unused if the Git tag already exists. Default: the repository's default branch." For a draft the tag materialises at publish time (indirect evidence: action-gh-release handles the "tag creation blocked by rules" error at finalize, `github.ts:785-808`; drafts use "untagged-…" asset URLs, `run.ts:82-83`) — docs statement UNVERIFIED.
- Local-tag guard (`:294-321`, only without `--repo`): if a local tag exists, no `--target`, no `--verify-tag`, and the remote tag is missing → error `tag %s exists locally but has not been pushed to %s, please push it before continuing or specify the --target flag to create a new tag` (`:311-320`).
- `--notes-file/-F` (`:214`, `:193-200`): `cmdutil.ReadFile`; `-` reads stdin; sets `BodyProvided`.
- `--notes-from-tag` (`:220`): requires the tag locally (`:298-301`, error `cannot generate release notes from tag %s as it does not exist locally`); body = `git tag --list <tag> --format=%(contents)` with the PGP/SSH signature block stripped (`:570-603`); `--notes` text is prepended (`:489-495`); incompatible with `--generate-notes`/`--notes-start-tag` (`:182-184`) and `--repo` (`:186-188`).
- `--generate-notes` (`:216`): without `--notes-start-tag` → `params["generate_release_notes"] = true` on the POST (`:485-487`); with `--notes-start-tag` → client-side `POST …/releases/generate-notes` (`create/http.go:75-108`) and body/name merged (`:469-484`).
- `--target` (`:211`): `params["target_commitish"]` (`:459-461`).
- `--fail-on-no-commits` (`:221`, `:239-247`) → `isNewRelease` (`create/http.go:237-267`): `GET …/releases/latest`; if none → proceed; else `GET …/compare/{latestTag}...HEAD?per_page=1` and require `status == "ahead"`, else error `no new commits since the last release`.
- `--discussion-category`: sent on POST (`:466-468`) and again on the publish PATCH (`create/http.go:184-186`).
- 404 on POST without `workflow` scope (OAuth tokens only) is turned into a hint (`create/http.go:151-178`, `create.go:516-527`); irrelevant for `GITHUB_TOKEN` (no `X-Oauth-Scopes` header ⇒ assumed OK, `create/http.go:217-235`).

### 1b. `gh release upload TAG files… [--clobber]`

- Lookup: `shared.FetchRelease` (`upload/upload.go:89`) races two lookups — REST `GET …/releases/tags/{tag}` (published) and GraphQL `repository.release(tagName:)` filtered to `isDraft` then REST `GET …/releases/{id}` (`shared/fetch.go:182-225`, `236-270`). So `upload`, `edit`, `view`, `delete` all resolve DRAFTS by their pending tag name.
- Existing-asset detection (`upload/upload.go:94-104`): compares `sanitizeFileName(localName)` (`:135-157`, mimics GitHub's server-side name normalisation) against `release.Assets[].Name`.
- **Without `--clobber`**: `upload/upload.go:106-108` → `asset under the same name already exists: [names]`; the command aborts before any upload (no partial upload of non-colliding files).
- **With `--clobber`** (`:73`): delete-then-upload per asset — `AssetForUpload.ExistingURL` set (`:99`), then `uploadWithDelete` issues `DELETE {asset.url}` before the POST (`shared/upload.go:141-146`, `210-222`). Help text (`upload/upload.go:48-49`): "When using `--clobber`, existing assets are deleted before new assets are uploaded. If the upload fails, the original assets will be lost." On a published immutable release the DELETE fails and the command errors (no special handling).
- **Retry (verified)**: `shared/upload.go:130-155`:
  ```go
  func shouldRetry(err error) bool {
      if _, ok := errors.AsType[errNetwork](err); ok { return true }
      var httpError api.HTTPError
      return errors.As(err, &httpError) && httpError.StatusCode >= 500
  }
  var retryInterval = time.Millisecond * 200
  … backoff.Retry(func() error { … }, backoff.WithContext(backoff.WithMaxRetries(bo, 3), ctx))
  ```
  Constant 200 ms backoff, max 3 retries (≤4 attempts) on transport errors or HTTP ≥500 (`github.com/cenkalti/backoff/v4 v4.3.0`, go.mod:17). 4xx (incl. 422 duplicate) is `backoff.Permanent`. Test `shared/upload_test.go:80-117`: network error, then 500, then 200 ⇒ 3 tries. The DELETE step is not retried. gh does not re-list assets between retries, so a 502 that leaves a `starter` asset (docs, §4) makes the retry hit 422 duplicate → permanent failure (analysis, not tested in repo).
- **Transport**: single `POST {upload_url}?name=&label=` with the whole file as body, `req.ContentLength = asset.Size`, `req.GetBody = asset.Open`, `Content-Type` from extension (`shared/upload.go:157-208`, `75-101`). No chunking, no multipart, no client-side size check. Server limit: "Each file included in a release must be under 2 GiB." (docs, §4).

### 1c. `gh release edit TAG --draft=false`

- `edit/edit.go:103` → `FetchRelease` (draft or published); `getParams` (`:136-173`) includes `draft` only if the flag was given (`:147-149`); `tag_name` is always sent because "If we don't provide any tag name, the API will remove the current tag from the release" (`:110-113`); `PATCH /repos/{o}/{r}/releases/{id}` (`edit/http.go:17-37`). Help example (`edit.go:46-47`): "Publish a release that was previously a draft: `gh release edit v1.0 --draft=false`". `--verify-tag` in edit only checks when `--tag` is also passed (`edit.go:115-124`).
- **Immutable handling in gh**: grep `immutab` over non-vendor source. Release-command hits are read-only: `isImmutable` JSON field (`shared/fetch.go:33`, struct `IsImmutable bool \`json:"immutable"\`` `:52`; `list/http.go:21,30`), `immutable:` line in `release view` plain output (`view/view.go:184`), and feature detection (`internal/featuredetection/feature_detection.go:164`, `492-506`: introspects GraphQL `Release` type for a field named `immutable`, used by `release list` to pick a query variant, `list/http.go:58-61`). No code path in `create`/`upload`/`edit`/`delete`/`delete-asset` inspects immutability or adapts behaviour; API errors are surfaced as-is. (`pkg/cmd/skills/publish/publish.go:558-571,729-748` can enable immutable releases for a repo via API — unrelated command.)
- **Events on publishing a draft** (docs, Actions "events that trigger workflows", `release`): activity types `published, unpublished, created, edited, deleted, prereleased, released`. "Workflows are not triggered for the `created`, `edited`, or `deleted` activity types for draft releases." "The `prereleased` type will not trigger for pre-releases published from draft releases, but the `published` type will trigger." "If you want a workflow to run when stable *and* pre-releases publish, subscribe to `published` instead of `released` and `prereleased`." ⇒ PATCH `draft:false` fires `release: published`. Notifications: docs only say "You can receive notifications when new releases are published in a repository"; whether publish-from-draft notifies identically to direct publish is UNVERIFIED (no docs statement found).

### 1d. `--json` fields for idempotency checks

- `gh release view [TAG] --json` (`view/view.go:70`, fields `shared/fetch.go:23-42`): `apiUrl, author, assets, body, createdAt, databaseId, id, isDraft, isPrerelease, isImmutable, name, publishedAt, tagName, tarballUrl, targetCommitish, uploadUrl, url, zipballUrl`. `assets[]` sub-fields (`fetch.go:103-120`): `url` (browser_download_url), `apiUrl, id, name, label, size, digest, state, createdAt, updatedAt, downloadCount, contentType`. `digest` maps to the API asset digest (`fetch.go:76`), `state` distinguishes `uploaded` vs `starter`. `view TAG` resolves drafts (`view.go:95` → `FetchRelease`); `view` without a tag = latest published (`view.go:90`).
- `gh release list --json` (`list/http.go:15-24`, GraphQL): `name, tagName, isDraft, isLatest, isPrerelease, isImmutable, createdAt, publishedAt` only (no assets/url/targetCommitish).
- `gh release create` itself prints only the HTML URL (`create.go:565`); no `--json`.

### 1e. Rate limits / HTTP retry in gh's client

- `api/http_client.go:35-89`: transport = go-gh `ghAPI.NewHTTPClient` (headers, optional cache, logging) wrapped by `AddAuthTokenHeader` and a telemetry disabler. No retry/backoff transport.
- grep `retry|backoff|429|rate.?limit|Retry-After` in `api/`, `internal/` (non-test) and go-gh v2.16.1 `pkg/api/`: no hits in the GitHub API client (hits only in `internal/codespaces` (own client), `internal/attachments` (issue attachments error text), and go-gh's Windows cache-rename helper). Non-2xx responses become `api.HTTPError` (`api/client.go:262-276`), so 403/429 primary/secondary rate limits fail immediately; `Retry-After` is not honoured. The only retry in the release path is the asset-upload retry of §1b.

---

## 2. softprops/action-gh-release v3.0.3 (`efb35369…`)

- **Runtime**: `runs.using: "node24"`, `main: "dist/index.js"` (`action.yml:77-79`); `engines.node >=24` (`package.json:24-26`). v3.0.0 (2026-04-12) moved Node 20 → 24; `v2` frozen at 2.6.2 (CHANGELOG.md:52-57, 67-70).
- **Build/dist**: `esbuild src/main.ts --bundle --platform=node --format=cjs --target=node24 --outfile=dist/index.js --minify` (`package.json:8`). `dist/index.js` (793,482 bytes, minified, no sourcemap) is committed; CI rebuilds and fails on drift ("Check dist freshness", `.github/workflows/main.yml:29-35, 68-72`).
- **Bundled dependency surface**: `package-lock.json` has 180 packages, 40 non-dev entries (33 unique names: @actions/core, exec, github, http-client, io; @octokit/auth-token, core, endpoint, graphql, openapi-types, plugin-paginate-rest, plugin-rest-endpoint-methods, plugin-retry, plugin-throttling, request, request-error, types; balanced-match, before-after-hook, bottleneck, brace-expansion, fast-content-type-parse, glob, json-with-bigint, lru-cache, mime-db, mime-types, minimatch, minipass, path-scurry, tunnel, undici, universal-user-agent). **`@octokit/plugin-retry` and `@octokit/plugin-throttling` (`package.json:30-31`) are never imported**: `src/` imports only `getOctokit` (`run.ts:2`) and `GitHub` from `@actions/github/lib/utils` (`github.ts:1`); `dist/index.js` contains 0 occurrences of `plugin-retry`, `plugin-throttling`, `doNotRetry`, `Bottleneck`; `@actions/github@9.1.1`'s lockfile deps list neither plugin and toolkit `utils.ts` registers only `restEndpointMethods` + `paginateRest`. Hence the `throttle: { onRateLimit, onAbuseLimit }` options passed at `run.ts:24-37` are inert. No automatic 5xx/network retry on any request.
- **Release create/update ordering** (`src/run.ts`, `src/github.ts`):
  1. `release()` (`github.ts:614-745`): `findTagFromReleases` (`:866-899`) = `getReleaseByTag` (published only) → on 404 scan ≤2 pages×100 of `listReleases` for `tag_name` match incl. drafts (`:909-927`), preferring non-draft then lowest id (`:930-948`).
  2. Existing release found → `updateRelease` PATCH with `draft: existingRelease.draft` (`:703-717`, draft state preserved), body replace/append (`:689-696`), `make_latest`, `target_commitish`, `prerelease`.
  3. Not found → `createRelease` (`:1044-1129`): **`const draft = prerelease === true ? config.input_draft === true : true;` (`:1058`)** — normal releases are ALWAYS created as drafts (draft-first since v2.5.0, PR #692 "feat: mark release as draft until all artifacts are uploaded", 2025-11); **prereleases are created already published unless `draft: true`**, i.e. NOT immutable-safe by default (documented: `action.yml:19`, README:249-253 "On an immutable-release repository, use `draft: true` for prereleases that upload assets, then publish that draft later"; reason: issue #708, `prereleased` event doesn't fire for drafts). After creation, `canonicalizeCreatedRelease` (`:979-1041`) re-finds by tag to collapse concurrent duplicates and deletes its own empty duplicate draft (`:951-977`). 422 `already_exists` on POST → retry the lookup, ≤3 tries total (`:1112-1123`, `:616-621`).
  4. Uploads (`run.ts:43-77`): `Promise.all` (unbounded concurrency) unless `preserve_order` (sequential, `:67-74`).
  5. `finalizeRelease` (`run.ts:79-80`; `github.ts:756-813`): returns early if `input_draft === true` or release already published (`:763-765`); else PATCH `{draft:false, make_latest, discussion_category_name}` (`:274-289`); on error retries immediately, ≤3 attempts (`:767-770`, `:811-812`), except a 422 `pre_receive … creations being restricted` (tag creation blocked by rulesets, `:1131-1143`) where it deletes the created draft and throws (`:786-808`).
  6. Assets re-listed after publish because draft asset URLs are temporary "untagged-…" (`run.ts:82-95`).
- **Upload semantics** (`github.ts:420-611`): match existing by name / space→dot aligned name / label (`:385-388`). `overwrite_files` default `'true'` (`action.yml:33-36`, `util.ts:126-128`): existing → DELETE asset then POST (`:439-447`); `false` → skip with log, returns null (`:435-438`). Single streamed POST with `content-length` (`:353-370`, `:478-491`), no chunking. Error handling: 422 with message matching `/immutable release/i` → explicit error "Cannot upload asset … to an immutable release. GitHub only allows asset uploads before a release is published…" (`:405-418`, `:558-561`); 404 on asset metadata → re-list ≤3× with 1 s sleep (`:452-477`, `:563-579`); 422 `already_exists` race → delete + one retry (`:581-608`); everything else (incl. 5xx/network) thrown once (`:610`). An upload failure leaves the draft in place (`run.ts:101-103` only `setFailed`), so a re-run resumes via the draft scan.
- **Idempotency**: re-run after partial failure → finds draft, PATCHes it, re-uploads (deleting same-name assets), publishes. Re-run after a successful publish on an immutable repo → PATCH succeeds (title/notes editable) but with `overwrite_files: true` the asset DELETE fails → action fails; with `overwrite_files: false` existing assets are skipped and finalize is a no-op → idempotent success.
- **Other inputs**: `fail_on_unmatched_files` (`action.yml:37-39`; `run.ts:13-22` per pattern, `:45-51` when nothing matched); `make_latest` `true|false|legacy` (`action.yml:63-65`, `util.ts:142-147`; sent at create `:1078` and finalize `:285`); `preserve_order` (`action.yml:24-26`); `target_commitish` note about 403 with `github.token` (`action.yml:47-49`); outputs `url, id, upload_url, assets` (`action.yml:68-76`).
- **Permissions**: README:291-302 `permissions: contents: write` (+ `discussions: write` with `discussion_category_name`).
- **Maintenance**: releases 3.0.0 (2026-04-12), 3.0.1 (06-19), 3.0.2 (07-13), 3.0.3 (08-30); repo `pushed_at` 2026-09-21; 116 open issues; 5,766 stars. Immutable-release issues: #653 "Incompatible with immutable releases" (closed 2025-12-01, fixed by draft-first default), #708 prerelease-event regression (closed 2026-03-15 → prerelease exception), #641 pitch (open), #769 "Enable immutable releases on this project" (open; its own releases are mutable), #771 (closed same day). Maintainer process in RELEASE.md/AGENTS.md; `v3` is force-moved by script → pin by SHA.

## 3. ncipollo/release-action v1.21.0 (`339a8189…`)

- **Runtime**: `runs.using: 'node24'`, `main: 'dist/index.js'` (`action.yml:139-141`); `engines.node >=20` (`package.json:29-31`); CI builds with Node 20 (`.github/workflows/build.yml:20-23`) and fails on uncommitted diff after `pnpm build` (`:31-37`). `tsc` + `@vercel/ncc build --source-map --license licenses.txt` (`package.json:9,14`); committed `dist/index.js` 1,642,527 bytes + `index.js.map` + `sourcemap-register.js` + `licenses.txt`.
- **Bundled deps**: 19 packages listed in `dist/licenses.txt` (@actions/core, exec, github, http-client, io; @octokit/auth-token, core, endpoint, graphql, plugin-paginate-rest, plugin-rest-endpoint-methods, request, request-error; before-after-hook, fast-content-type-parse, glob, tunnel, undici, universal-user-agent). Runtime deps in package.json: `@actions/core`, `@actions/github`, `@types/node`, `glob` (`:32-37`). No octokit retry/throttling plugins.
- **Draft-first only when opted in**: `Action.ts:128-129` `// If immutableCreate is enabled we need to start with a draft release` / `const draft = this.inputs.createdDraft || this.inputs.immutableCreate`; input `immutableCreate` default `'false'` (`action.yml:54-57`: "When enabled, the action will first create a draft, upload artifacts, then publish the release."; `Inputs.ts:147-150`). Publish step `publishImmutableRelease` (`Action.ts:171-188`) = `update()` with `draft:false` (+ tag, discussion, makeLatest, name, prerelease) but it runs **only when the release was just created** (`Action.ts:160-166` `if (wasCreated)`). Default (no `immutableCreate`) = create published → upload ⇒ fails on immutable repos.
- **Update path is NOT immutable-safe**: with `allowUpdates: true` (`Action.ts:53-70`) a missing published release falls back to a draft found in the FIRST page of `listReleases` (`:94-105`; `Releases.ts:143-148`, unpaginated) and `updateRelease` PATCHes `draft = updatedDraft` (= `createdDraft`, i.e. `false` unless `draft: true`; `Inputs.ts:210-213`) BEFORE uploading (`Action.ts:107-123` → `:145-159`), and no post-upload publish occurs (`wasCreated=false`). So a re-run that finds an orphan draft publishes it first and then uploads fail. `omitDraftDuringUpdate: true` keeps the draft state but then nothing publishes it.
- **Uploads** (`ArtifactUploader.ts`): sequential (`:21-26`); `replacesArtifacts` default `'true'` (`action.yml:102-105`) → list assets and DELETE same-name first (`:57-70`); retry ≤3 with no delay on `error.status >= 500` (`:30-45`); **`artifactErrorsFailBuild` default false** (`action.yml:9-12` default `''`, `Inputs.ts:65-68`) ⇒ upload failures are `core.warning` and the action SUCCEEDS (`:47-52`), and with `immutableCreate` the release is then published without the asset. `removeArtifacts` deletes all existing assets (`ArtifactDestroyer.ts:11-18`). Unmatched globs warn unless `artifactErrorsFailBuild` (`ArtifactGlobber.ts:32-42`).
- **Other**: `skipIfReleaseExists` uses `getReleaseByTag` (published only; `ActionSkipper.ts:14-27`); `updateOnlyUnreleased` refuses to update a published non-prerelease (`ReleaseValidator.ts:4-14`); `makeLatest` default `'legacy'` (`action.yml:58-61`); `generateReleaseNotes` via generate-notes endpoint merged client-side (`Action.ts:190-208`). Permissions: README:73-74 `contents: write`.
- **Maintenance**: v1.19.0 (2025-09-01) added `immutableCreate` (PR #544 for #540); v1.19.1 defaulted it to false after regression #545; v1.20.0 (2025-09-02) previous-tag option; v1.21.0 (2026-03-14) dependency bumps only. Repo `pushed_at` 2026-09-10; 10 open issues; 1,681 stars. Own `release.yml` uses `draft: true` + `allowUpdates: true` and the maintainer publishes manually. Issue #627 (2026-08, closed not_planned) complained `v1` was stale; today `v1` == v1.21.0 SHA.

## 4. GitHub REST/docs semantics (docs.github.com, fetched 2026-09-24)

- **POST /repos/{o}/{r}/releases**: `draft` "true to create a draft (unpublished) release, false to create a published one. Default: false"; `prerelease` default false; `make_latest` "Can be one of: true, false, legacy" default `true`, "Drafts and prereleases cannot be set as latest."; `generate_release_notes` default false; `target_commitish` "Unused if the Git tag already exists. Default: the repository's default branch."; responses 201 / 404 / 422 (validation failed or spammed). "OAuth app tokens and personal access tokens (classic) need the workflow scope when the resolved target commit modifies workflow files."
- **Upload asset** (`POST {upload_url}`, host uploads.github.com): `Content-Type` required, `Content-Length` required; `name` query param. "If you upload an asset with the same filename as another uploaded asset, you'll receive an error and must delete the old file before you can re-upload the new asset." 201 created / 422 duplicate. "When an upstream failure occurs, you will receive a 502 Bad Gateway status. This may leave an empty asset with a state of starter. It can be safely deleted."
- **PATCH /repos/{o}/{r}/releases/{id}**: same body fields; `draft: false` publishes. Release schema contains `immutable` (boolean). Docs do not enumerate immutable-specific error responses (UNVERIFIED which status; observed in the wild: 422 with message "Cannot upload assets to an immutable release." — issue softprops#653 log; action-gh-release classifies `status === 422 && /immutable release/i`).
- **DELETE release**: 204 / 404; no immutable restriction in the API doc. Concept doc: "If you delete the immutable release, you can delete the tag, but you cannot reuse the same tag name."
- **GET /releases/tags/{tag}**: "Get a published release with the specified tag." (drafts not returned).
- **Immutable releases** (concept doc + changelog 2025-08-26 preview, 2025-10-28 GA): "Once you publish a release as immutable, its assets can't be added, modified, or deleted." "Tags for new immutable releases are protected and can't be deleted or moved." "You can still edit the title and release notes." Tag "is locked to a specific commit, cannot be changed, and cannot be deleted while the release exists." "You can enable immutable releases at the repository or organization level in your settings." "Existing releases remain mutable unless you republish them." "Creating an immutable release automatically generates a release attestation" (Sigstore bundle; `gh release verify`, `gh release verify-asset`). Managing-releases doc: "If you have enabled immutable releases for your repository, it's recommended to create releases as drafts first, attach all assets, and then publish."
- **Limits** (about-releases): "Each file included in a release must be under 2 GiB." "There is no limit on the total size of a release, nor bandwidth usage." "Up to 1000 release assets may be associated with a single release."
- **Events**: see §1c quotes.

## 5. Comparison

| Property | gh CLI (preinstalled, 2.100.0 on ubuntu-24.04 image; audited 2.101.0) | softprops/action-gh-release v3.0.3 | ncipollo/release-action v1.21.0 |
|---|---|---|---|
| Draft-first ordering | Yes, automatic whenever assets are given and `--draft` absent (`create.go:497-512`); since v1.0.0 | Yes for normal releases (`github.ts:1058`); **NO for prereleases** unless `draft: true` | **Only with `immutableCreate: true`** (default false); update path publishes before upload |
| Publish step | PATCH `draft:false` (+make_latest, discussion) after all uploads succeed | `finalizeRelease` PATCH after uploads, ≤3 immediate retries | PATCH via `update()` after uploads, only on freshly created releases |
| On upload failure | Draft DELETED, non-zero exit (`create.go:533-554`) | Draft LEFT (resumable on re-run); non-zero exit | Warning only by default (`artifactErrorsFailBuild=false`) ⇒ may publish WITHOUT the asset |
| Immutable-release safety (new release) | Safe: assets on draft, then publish | Safe for releases; prerelease needs `draft: true` + separate publish | Safe only with `immutableCreate: true` and `artifactErrorsFailBuild: true` |
| Re-run after success on immutable repo | `create` → "a release with the same tag name already exists" (HEAD check) → non-zero; `upload --clobber` fails on DELETE; `upload` w/o clobber fails on name check | PATCH ok; asset DELETE fails unless `overwrite_files: false` (then idempotent) | `skipIfReleaseExists: true` skips; otherwise `allowUpdates` PATCH + DELETE asset fails |
| Duplicate-draft detection | No (`HEAD …/releases/tags` sees published only) — use `gh release view TAG --json isDraft` first | Yes (scans 2×100 recent releases incl. drafts, dedupes concurrent creates) | First page of `listReleases` only, `allowUpdates` path |
| Retry on upload | 3 retries, 200 ms constant, on transport error or ≥500 | None for 5xx/network (retry plugin not bundled); 1 retry for 422 race; 3 re-lists for 404 | 3 immediate retries on ≥500 |
| Rate-limit handling | None (no Retry-After) | None (throttle options inert) | None |
| Clobber semantics | `--clobber` = DELETE then POST per asset; without it, abort before any upload | `overwrite_files` (default true) = DELETE then POST; false = skip | `replacesArtifacts` (default true) = DELETE then POST; `removeArtifacts` = delete all |
| Chunked upload / size guard | Single POST, no guard (API: <2 GiB/file) | Single streamed POST, no guard | Single POST, no guard |
| Third-party trust surface | Go binary maintained by GitHub; 61 direct / 179 module deps; preinstalled by runner image | 793 KB minified bundle, 33 non-dev packages; `v3` tag force-movable | 1.6 MB ncc bundle + sourcemap, 19 packages |
| Runtime | native binary | node24 | node24 (built on node 20 in CI) |
| Maintenance | v2.101.0 2026-09-15; releases immutable themselves | v3.0.3 2026-08-30; active (pushed 2026-09-21); 116 open issues; own releases mutable | v1.21.0 2026-03-14 (deps only); pushed 2026-09-10; 10 open issues; own releases mutable |
| JSON for idempotency | `view --json isDraft,isPrerelease,isImmutable,tagName,targetCommitish,url,assets(name,size,digest,state)` | outputs `id,url,upload_url,assets` | outputs `id,html_url,upload_url,assets` |

## 6. Gaps / UNVERIFIED

1. Exact HTTP status/message GitHub returns for asset upload/delete/PATCH-with-tag-change on a published immutable release: not in REST docs; 422 "Cannot upload assets to an immutable release." inferred from issue logs and action-gh-release's classifier.
2. Status returned when publishing a second draft for a tag that already has a published release (POST/PATCH 422 assumed).
3. Whether publish-from-draft sends the same "new release" notifications as direct publish (only the `release: published` event is documented).
4. Whether the tag is created at draft creation or at publish time (indirect evidence points to publish time).
5. The gh version that introduced draft cleanup-on-failure (between v2.20.0 and v2.60.0).
6. The `GITHUB_TOKEN`-does-not-trigger-workflows rule was not re-quoted in the fetched events page extract.
