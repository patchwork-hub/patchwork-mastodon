# Upgrade Plan: patchwork-mastodon v4.5.6 → v4.5.10

Target upstream tag: `v4.5.10` (commit `f80b1ba92e63c3da771b405b9100f5c9abda909f`)
Gem change: replace the six separate patchwork gems with the single consolidated `newsmast_mastodon` engine on branch `mastodon-4.5.10`.

## Summary of what changes

- **Core bump 4.5.6 → 4.5.10** is a point-release range: 235 files changed, but ~200 are locale translations. **No new core database migrations.**
- **Highest risk: Devise 4 → 5.** The gem prepends auth/session/token/user behavior, which is the most likely place to break.
- **Gem consolidation:** the current `Gemfile` references six gems on branch `mastodon-4.5.6`; these get replaced by one `newsmast_mastodon` gem on `mastodon-4.5.10`.

## Pre-flight

- [ ] Confirm a clean working tree (`git status`).
- [ ] Take a backup of the staging database before any migration.
- [ ] Confirm the `upstream` remote points to `https://github.com/mastodon/mastodon.git`.
- [ ] Confirm the gem branch `newsmast_mastodon` → `mastodon-4.5.10` exists (create it first if not — see "Gem-specific actions").

## Phase A — Branch & fetch

1. Create a working branch off the current staging branch:
   ```bash
   git checkout patchwork-mastodon-demo-4.5.6-staging
   git checkout -b patchwork-mastodon-demo-4.5.10-staging
   ```
2. Fetch upstream tags:
   ```bash
   git fetch upstream --tags
   ```

## Phase B — Merge the v4.5.10 tag

3. Merge without committing so the result can be reviewed:
   ```bash
   git merge v4.5.10 --no-commit --no-ff
   ```
4. Resolve conflicts. Because this fork carries no custom in-tree commits, most files apply cleanly. Watch:
   - `Gemfile` / `Gemfile.lock`
   - `config/initializers/devise.rb`
   - `lib/mastodon/version.rb`
5. Confirm `lib/mastodon/version.rb` now reports `4.5.10`.
6. Commit the merge.

## Phase C — Swap to the consolidated gem

7. In `Gemfile`, remove the six gems (`accounts`, `content_filters`, `conversations`, `custom_feeds`, `local_only_posts`, `posts`) and add:
   ```ruby
   gem 'newsmast_mastodon',
       git: 'https://github.com/patchwork-hub/newsmast_mastodon',
       branch: 'mastodon-4.5.10'
   ```
8. Update bundle and resolve dependency conflicts (especially `devise 5.0`):
   ```bash
   bundle install
   ```

## Phase D — Database & boot

9. Run migrations against a copy of the staging database:
   ```bash
   bin/rails db:migrate
   ```
   Verify the gem migrations apply and watch for `column already exists` on:
   - `status_edits.quote_id`
   - `statuses.fetched_replies_at`
   - `announcements.notification_sent_at`
   (These columns may already exist in the 4.5.x core schema — guard the gem migrations if so.)
10. Boot the app and confirm the prepend/include concerns load with no `already defined` / `NoMethodError`, focusing on the Devise 5 surface:
    ```bash
    bin/rails runner 'puts Mastodon::Version.to_s'
    ```
    Check: `Auth::SessionsController`, `Auth/OAuth::TokensController`, `User` password override.

## Phase E — Verify

11. Run the core test suite:
    ```bash
    bundle exec rspec
    ```
12. Run the gem's own suite against the upgraded core:
    ```bash
    cd ../newsmast_mastodon
    MASTODON_ROOT=/absolute/path/to/patchwork-mastodon bundle exec rspec
    ```
13. Manual smoke test of custom features:
    - Login / session (Devise)
    - OAuth token issuance
    - Password change
    - Posting + drafts
    - Local-only posts
    - Custom feeds / timelines
    - Banned-keyword filtering
    - Admin dashboard authentication
14. Build assets if needed:
    ```bash
    bin/vite build
    ```

## Phase F — Ship

15. Deploy to staging and re-run the smoke tests above.
16. Plan the production rollout once staging is verified.

## Gem-specific actions (newsmast_mastodon repo)

- [ ] Create branch `mastodon-4.5.10` from the current gem branch.
- [ ] Update prepend concerns for Devise 5.0 API changes (session strategies, token controllers, password reset flow).
- [ ] Re-run gem specs against 4.5.10 core; fix any signature mismatches in `Status` / `Quote` / `MediaAttachment` concerns.
- [ ] Guard gem migrations (`if_not_exists` / column checks) against columns already in the core schema.

## Rollback

- The work is isolated on `patchwork-mastodon-demo-4.5.10-staging`; abandoning it restores 4.5.6.
- Restore the staging database from the Pre-flight backup if migrations were applied.
