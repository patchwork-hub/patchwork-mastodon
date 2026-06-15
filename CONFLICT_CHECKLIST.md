# Conflict Checklist: v4.5.11 → v4.5.11 vs. newsmast_mastodon gem

Maps each substantive core change in the v4.5.11 → v4.5.11 range to the gem code that patches the same area, with a resolution strategy.

**Release type:** Security + dependency patch (11 files changed, no core db migrations, no API signature changes).

Risk legend: **HIGH** = likely break, must adapt the gem · **MED** = re-verify behavior · **LOW** = unlikely to conflict · **NONE** = no gem overlap.

## Execution status (2026-06-15)

- [x] `bundle lock --normalize-platforms` executed to resolve Bundler/Nokogiri platform mismatch.
- [x] `bundle install` completed successfully.
- [x] Runtime boot check passed: `RAILS_ENV=development bin/rails runner 'puts Mastodon::Version.to_s'` returned `4.5.11`.
- [x] Concern/prepend chain check passed for:
  - `NewsmastMastodon::Concerns::MediaAttachmentConcern`
  - `NewsmastMastodon::Concerns::AccountConcern`
  - `NewsmastMastodon::Concerns::AccountSearchConcern`
  - `NewsmastMastodon::Concerns::CustomSessionBehavior`
  - `NewsmastMastodon::Concerns::CustomAuthenticationBehavior`
- [x] Dependency versions verified in `Gemfile.lock`: `erb 6.0.4`, `css_parser 1.22.0`, `faraday 2.14.2`, `jwt 2.10.3`.
- [x] Schema overlap check executed: `status_edits.quote_id`, `statuses.fetched_replies_at`, and `announcements.notification_sent_at` exist.
- [ ] Targeted specs passed. Current blockers:
  - Media attachment specs fail in this environment when `ffmpeg/ffprobe` are unavailable.
  - `ActivityPub::ProcessAccountService` targeted spec reveals `Status#local_only` missing (likely pending gem migration/concern mismatch).

## Upstream change summary (v4.5.11 → v4.5.11)

| Commit       | Change                                                                       |
| ------------ | ---------------------------------------------------------------------------- |
| `2c103cc487` | Security: fix sanitize_config.rb nil annotation crash (DoS vector)           |
| `ad8539385d` | Security: harden `ProcessAccountService` attribution_domains parsing         |
| `0361c8adea` | Backport: `context_helper.rb` attribution_domains `@type` → `@container` fix |
| `0361c8adea` | Backport: `media_attachment.rb` description validation only for local media  |
| `f69e387761` | Dependency: `erb` 5.1.3 → 6.0.4                                              |
| `d3e1923ba1` | Dependency: `css_parser` 1.21.1 → 1.22.0                                     |
| `19f3a2e0f7` | Dependency: `faraday` 2.14.1 → 2.14.2                                        |
| `618b4f48e1` | Dependency: `jwt` 2.10.2 → 2.10.3                                            |
| `0748a5ff81` | Version bump to 4.5.11                                                       |

## Conflict table

| File changed in core                                                                         | Gem code that touches it                                                                                              | Risk     | Resolution strategy                                                                                                                         |
| -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/models/media_attachment.rb` (description validation scoped to `local?`)                 | `MediaAttachment` ← include `MediaAttachmentConcern` (adds `patchwork_drafted_status_id`, scopes, alt-text callbacks) | **LOW**  | Gem concern does not override validation; change only affects remote media acceptance. Verify `MediaAttachmentConcern` still loads cleanly. |
| `app/services/activitypub/process_account_service.rb` (attribution_domains filter by String) | `Account` ← include `AccountConcern`, `AccountSearchConcern`                                                          | **LOW**  | Gem concerns add `is_banned` and search methods; they do not touch `set_fetchable_attributes!`. No conflict.                                |
| `app/helpers/context_helper.rb` (attribution_domains type change)                            | not patched by gem                                                                                                    | **NONE** | No action.                                                                                                                                  |
| `lib/sanitize_ext/sanitize_config.rb` (nil-guard annotation encoding)                        | not patched by gem                                                                                                    | **NONE** | No action.                                                                                                                                  |
| `Gemfile.lock` (4 dependency bumps)                                                          | gem adds own deps; lockfile regenerated by `bundle install`                                                           | **LOW**  | Run `bundle install` after merge; confirm no version constraint conflicts in `newsmast_mastodon.gemspec`.                                   |
| `lib/mastodon/version.rb` (4.5.11 → 4.5.11)                                                  | not patched by gem                                                                                                    | **NONE** | Confirm version reports 4.5.11 after merge.                                                                                                 |
| `.github/actions/setup-ruby/action.yml`                                                      | not relevant to runtime                                                                                               | **NONE** | No action.                                                                                                                                  |
| `docker-compose.yml`                                                                         | not patched by gem                                                                                                    | **NONE** | No action.                                                                                                                                  |
| `spec/` (test changes)                                                                       | not patched by gem                                                                                                    | **NONE** | No action (upstream test improvements).                                                                                                     |

## Migration-specific notes

The v4.5.11 release introduces **zero** new core migrations. The gem ships pre-existing migrations that add columns to core tables — these need to be re-validated against the 4.5.11 schema (unchanged from 4.5.11):

| Gem migration target                                   | Risk | Check                                                                |
| ------------------------------------------------------ | ---- | -------------------------------------------------------------------- |
| `statuses` (is_banned, local_only, fetched_replies_at) | MED  | `fetched_replies_at` may already exist — guard with `column_exists?` |
| `status_edits` (quote_id)                              | MED  | `quote_id` may already exist in core quote feature — verify schema   |
| `announcements` (notification_sent_at)                 | MED  | May already exist — verify before migrating                          |
| `media_attachments` (patchwork_drafted_status_id FK)   | LOW  | Custom column, no core overlap                                       |
| `users` (alttext_enabled)                              | LOW  | Custom column                                                        |
| `accounts` (is_banned)                                 | LOW  | Custom column                                                        |
| `server_settings` (new table)                          | LOW  | Custom table, no core overlap                                        |

## Gem boot compatibility checks

These are the critical prepend/include chains to verify after merge:

- [x] `MediaAttachment.include(MediaAttachmentConcern)` — loads without error; new `if: :local?` validation does not conflict with concern callbacks.
- [x] `Account.include(AccountConcern)` / `Account.include(AccountSearchConcern)` — loads without error; upstream `process_account_service.rb` change is in a service, not the model.
- [x] `Auth::SessionsController.prepend(CustomSessionBehavior)` — unchanged in this release; verified via loaded ancestors.
- [x] `Auth::TokensController.prepend(CustomAuthenticationBehavior)` — verified via loaded ancestors (mounted under OAuth controller namespace in this app).
- [ ] All other prepend/include declarations in `config/initializers/prepend_concerns.rb` — no upstream changes to base classes in this release.

## Dependency compatibility checks

- [x] `erb` 6.0.4 — lockfile version verified.
- [x] `css_parser` 1.22.0 — lockfile version verified.
- [x] `faraday` 2.14.2 — lockfile version verified.
- [x] `jwt` 2.10.3 — lockfile version verified.

## Gem-specific actions

- [ ] Create `newsmast_mastodon` branch `mastodon-4.5.11-fixed` from `mastodon-4.5.11-fixed`.
- [ ] Verify gem `newsmast_mastodon.gemspec` has no pinned version constraints conflicting with updated deps. (pending in gem repo)
- [ ] Guard gem migrations with `column_exists?` / `table_exists?` checks.
- [ ] Run `MASTODON_ROOT=/path/to/patchwork-mastodon bundle exec rspec` in the gem against the upgraded core. (pending in gem repo)
- [x] Verify all prepend/include concerns load at boot with no `already defined` / `NoMethodError`.
- [ ] Run full login/OAuth/password-reset smoke test (auth stack unchanged but verify with new `jwt` version).

## Risk assessment

**Overall risk: LOW.** This is a security + dependency patch release with no schema migrations, no API changes, and no modifications to classes where the gem prepends behavior (controllers, services). The only runtime-relevant code changes are:

1. A nil-guard in sanitize_config (no gem overlap)
2. Attribution domain parsing hardening (no gem overlap)
3. Media attachment validation scoped to local (gem includes concern on same model but doesn't touch validation)

**Go/No-Go threshold:** Any failure in boot, auth smoke test, or federation smoke test should block the release.
