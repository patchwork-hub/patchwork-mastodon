# Conflict Checklist: v4.5.6 → v4.5.10 vs. newsmast_mastodon gem

Maps each substantive core change in the v4.5.6 → v4.5.10 range to the gem code that patches the same area, with a resolution strategy.

Risk legend: **HIGH** = likely break, must adapt the gem · **MED** = re-verify behavior · **LOW** = unlikely to conflict.

## Conflict table

| File changed in core | Gem code that touches it | Risk | Resolution strategy |
|---|---|---|---|
| `Gemfile` + `config/initializers/devise.rb` (Devise 4 → 5.0) | `CustomSessionBehavior`, `CustomAuthenticationBehavior`, `OverrideChangedPassword` (prepended on Auth/OAuth controllers + User) | **HIGH** | Adapt gem concerns to Devise 5 strategy/session API; test login, OAuth token, password reset end-to-end |
| `app/controllers/auth/sessions_controller.rb` | `Auth::SessionsController` ← prepend `CustomSessionBehavior` | **MED/HIGH** | Re-verify prepended actions still match Devise 5 controller; adjust `super` calls / before_actions |
| `app/controllers/auth/tokens_controller.rb` (via Devise) | `Auth::TokensController` / `OAuth::TokensController` ← prepend `CustomAuthenticationBehavior` | **MED/HIGH** | Confirm strategy hooks still fire under Devise 5 |
| `app/models/user.rb` (accepts_nested_attributes change) | `User` ← include `UserConcern`, `OverrideChangedPassword`; prepend `UserSettingExtend` | **MED** | Re-run User specs; confirm password override signature still matches |
| `app/models/quote.rb` (`accept!` now takes `approval_uri:`) | `Status` concern / `PostStatusService` / `UpdateStatusService` / `ProcessHashtagsService` | **MED** | Re-test quote/status flows; update concern call sites if they invoke `accept!` |
| `app/lib/activitypub/activity/create.rb` (quote_approval_uri) | `Status`, `ProcessHashtagsService` patches | **MED** | Verify federation create path; gem hooks unaffected unless they override create |
| `app/services/activitypub/process_status_update_service.rb` | `UpdateStatusService` patch | **MED** | Re-run update-status specs |
| `app/models/media_attachment.rb` (+`MAX_DESCRIPTION_HARD_LENGTH_LIMIT`) | `MediaAttachment` ← include `MediaAttachmentConcern` | **LOW** | New constant only; no override needed |
| `app/controllers/accounts_controller.rb`, `statuses_controller.rb` (short-url redirects) | not patched by gem | **LOW** | No action |
| `app/helpers/json_ld_helper.rb`, `context_helper.rb` | not patched | **LOW** | No action |
| `app/lib/activitypub/linked_data_signature.rb`, `request.rb`, `private_address_check.rb` | not patched | **LOW** | No action |
| `app/models/account_migration.rb` (normalize username) | `Account` ← include `AccountConcern`, `AccountSearchConcern` | **LOW** | Unrelated method; re-run account specs as a precaution |
| FASP: `app/models/fasp/provider.rb`, `api/fasp/base_controller.rb`, `workers/fasp/base_worker.rb` | not patched | **LOW** | No action |
| `config/initializers/fog_connection_cache.rb` (new) | not patched | **LOW** | No action |
| `app/javascript/**` + locale json/yml (~200 files) | gem does not touch JS/locales | **LOW** | No action |
| `db/migrate/**` | core added **no** migrations in this range | **NONE** | No core-vs-gem migration conflict from the upgrade |

## Migration-specific notes

The gem ships migrations that add columns to core tables:

| Gem migration target | Risk | Check |
|---|---|---|
| `statuses` (is_banned, local_only, fetched_replies_at) | MED | `fetched_replies_at` may already exist in 4.5.x core — guard with `if_not_exists` |
| `status_edits` (quote_id) | MED | `quote_id` may already exist in core quote feature — verify schema before migrating |
| `announcements` (notification_sent_at) | MED | May already exist in core — verify |
| `media_attachments` (patchwork_drafted_status_id FK) | LOW | Custom column, no core overlap |
| `users` (alttext_enabled) | LOW | Custom column |
| `accounts` (is_banned) | LOW | Custom column |

Note: the upgrade itself adds **no** core migrations; the above are pre-existing gem migrations to re-validate against the 4.5.10 schema.

## Gem-specific actions

- [ ] Create `newsmast_mastodon` branch `mastodon-4.5.10`.
- [ ] Update auth concerns for Devise 5.0 (sessions, tokens, password override) — the #1 risk.
- [ ] Update `Status` / `Quote` concern call sites for the new `accept!(approval_uri:)` signature.
- [ ] Guard gem migrations with `if_not_exists` / column-existence checks.
- [ ] Run `MASTODON_ROOT=/path/to/patchwork-mastodon bundle exec rspec` in the gem against the upgraded core.
- [ ] Verify all prepend/include concerns load at boot with no `already defined` / `NoMethodError`.
