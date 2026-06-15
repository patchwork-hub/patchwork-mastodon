# Mastodon Upgrade Runbook (Reusable Template)

Use this document for every Mastodon upgrade cycle by filling the template values below.

## Release intake (fill before starting)

- `FROM_VERSION`: `4.5.6`
- `TO_VERSION`: `4.5.11`
- `TARGET_TAG`: `https://github.com/mastodon/mastodon/releases/tag/v4.5.11`
- `TARGET_COMMIT`: `https://github.com/patchwork-hub/patchwork-mastodon/commit/0748a5ff81b24e666ab10b8ee7fbc6f0362c8cb0`
- `BASE_BRANCH`: `mo-me-4.5.6`
- `UPGRADE_BRANCH`: `mo-me-4.5.11`
- `CORE_REMOTE`: `https://github.com/mastodon/mastodon.git`
- `GEM_REPO`: `https://github.com/patchwork-hub/newsmast_mastodon`
- `GEM_BRANCH`: `mastodon-4.5.11`

## What to collect for each release

- [x] Release notes delta for `{FROM_VERSION} -> {TO_VERSION}`.
- [x] Number and names of upstream core migrations introduced in the range.
- [x] Major dependency jumps (especially auth/session stack).
- [x] Any API/signature changes that may affect patched concerns.
- [x] Estimated risk summary for this cycle.

## Pre-flight

- [ ] Confirm clean working tree: `git status`.
- [ ] Confirm `upstream` remote URL matches `CORE_REMOTE`.
- [ ] Backup staging database before migrations.
- [ ] Confirm `GEM_BRANCH` exists in `newsmast_mastodon`.
- [ ] Confirm environment variables and credentials are available for boot, migration, and test runs.

## Phase A - Branch and fetch

1. Create an upgrade branch from the selected base branch:
   ```bash
   git checkout {BASE_BRANCH}
   git checkout -b {UPGRADE_BRANCH}
   ```
2. Fetch tags and latest upstream refs:
   ```bash
   git fetch upstream --tags
   ```

## Phase B - Merge target tag

1. Merge without auto-commit so conflicts can be reviewed:
   ```bash
   git merge {TARGET_TAG} --no-commit --no-ff
   ```
2. Resolve conflicts and prioritize these files:
   - `Gemfile`
   - `Gemfile.lock`
   - `config/initializers/devise.rb`
   - `lib/mastodon/version.rb`
3. Confirm `lib/mastodon/version.rb` reports `{TO_VERSION}`.
4. Commit merge result.

## Phase C - Consolidated gem wiring

1. Ensure `Gemfile` uses the consolidated engine:
   ```ruby
   gem 'newsmast_mastodon',
       git: 'https://github.com/patchwork-hub/newsmast_mastodon',
       branch: '{GEM_BRANCH}'
   ```
2. Remove superseded patchwork gems if still present.
3. Install dependencies and resolve lock conflicts:
   ```bash
   bundle install
   ```

## Phase D - Database and boot

1. Apply migrations against staging clone/copy first:
   ```bash
   bin/rails db:migrate
   ```
2. Check migration overlap for pre-existing columns before editing migrations:
   - `status_edits.quote_id`
   - `statuses.fetched_replies_at`
   - `announcements.notification_sent_at`
3. If overlap exists, guard migrations with existence checks (`if_not_exists` / `column_exists?`).
4. Verify app boots and reports the expected version:
   ```bash
   bin/rails runner 'puts Mastodon::Version.to_s'
   ```

## Phase E - Verification gates

1. Core test suite:
   ```bash
   bundle exec rspec
   ```
2. Gem suite against upgraded core:
   ```bash
   cd ../newsmast_mastodon
   MASTODON_ROOT=/absolute/path/to/patchwork-mastodon bundle exec rspec
   ```
3. Manual smoke checklist:
   - [ ] Login/session
   - [ ] OAuth token issuance
   - [ ] Password change/reset flow
   - [ ] Post create/edit/draft flow
   - [ ] Local-only post behavior
   - [ ] Custom feeds/timelines
   - [ ] Banned-keyword filtering
   - [ ] Admin authentication/dashboard
4. Optional assets verification:
   ```bash
   bin/vite build
   ```
5. Classify failures as one of:
   - [ ] Environment/infrastructure (missing services, credentials, tooling)
   - [ ] Upgrade regression in core merge
   - [ ] Regression in patched gem behavior

### Execution notes (2026-06-15)

- Executed `bundle lock --normalize-platforms` to fix lockfile platform mismatch (`x86_64-linux` vs modern Nokogiri platform naming), then ran `bundle install` successfully.
- Executed `RAILS_ENV=development bin/rails runner 'puts Mastodon::Version.to_s'` and confirmed runtime version `4.5.11`.
- Executed boot compatibility probe for concern/prepend chains; all expected `newsmast_mastodon` concerns were present in loaded ancestors.
- Executed targeted specs:
  - `RAILS_ENV=test bundle exec rspec spec/models/media_attachment_spec.rb spec/services/activitypub/process_account_service_spec.rb`
  - Re-ran with `S3_ENABLED=false` to isolate infra impact.
- Current failure classification:
  - [x] Environment/infrastructure (missing `ffmpeg`/`ffprobe` causes multiple media attachment failures)
  - [ ] Upgrade regression in core merge
  - [x] Regression in patched gem behavior (`undefined method local_only for Status` in `process_account_service` path; likely pending gem migration/concern alignment)

## High-risk watchlist (every release)

- [ ] Auth stack updates: Devise/Doorkeeper/session strategy/token flow changes.
- [ ] Controller/service signature changes where gem concerns prepend or override methods.
- [ ] Model API changes affecting patched `Status`, `Quote`, `MediaAttachment`, `User`, `Account` concerns.
- [ ] Serializer and autoload constant changes that can break gem namespace loading.
- [ ] Migration collisions where gem columns may already exist in core schema.
- [ ] Any upstream security hardening that changes request validation, federation behavior, or URL checks.

## Gem-specific actions (newsmast_mastodon)

- [ ] Ensure branch `{GEM_BRANCH}` is created from the correct baseline.
- [ ] Update auth-related concerns for current Devise/Doorkeeper APIs.
- [ ] Update patched call sites for upstream signature changes.
- [ ] Guard migrations for column/index/table existence.
- [ ] Re-run gem specs with `MASTODON_ROOT` pointed at upgraded core.
- [ ] Confirm no `already defined` / `NoMethodError` at boot from prepend/include ordering.

## Phase F - Ship

1. Deploy to staging.
2. Re-run smoke checklist in staging.
3. Record final go/no-go decision for production rollout.

## Post-upgrade report (fill after completion)

- `Upgrade branch`: `mo-me-4.5.11`
- `Merge commit SHA`: `{MERGE_SHA}`
- `Target tag`: `https://github.com/mastodon/mastodon/releases/tag/v4.5.11`
- `Gem branch`: `mastodon-4.5.11`
- `Migrations applied`: `Core release introduces no new migrations; schema overlap columns present. Additional gem migration alignment still required for Status#local_only path.`
- `Core test result`: `Targeted suite executed, failing due to mixed infra + gem behavior blockers (see execution notes)`
- `Gem test result`: `{GEM_TEST_RESULT}`
- `Smoke test result`: `{SMOKE_TEST_RESULT}`
- `Known follow-ups`: `Install ffmpeg/ffprobe in test env; reconcile/execute gem migrations providing statuses.local_only semantics; run gem repo specs with MASTODON_ROOT`

## Rollback

- [ ] Abandon upgrade branch `{UPGRADE_BRANCH}` if release is blocked.
- [ ] Restore database from pre-migration backup snapshot.
- [ ] Re-point deploy configuration to last known good branch/tag.
- [ ] Record rollback reason and remediation tasks.
