# Release and deploy flow: developer guide

How to ship code with the new flow. For the overview, see [README.md](README.md).

## The rules

| You do                                                                      | What happens                                                                                        |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Merge code into `release/4.7` (POC: this branch)                            | Nothing is deployed. Code and deploys are separate.                                                 |
| Push a tag `v4.7.6-pw.N`                                                    | `release-build.yml` builds `web` + `streaming` once and pushes them as `v4.7.6-pw.N`                |
| "Run workflow" on **Release build** for a branch                            | Ad-hoc images `sha-<commit>`. Allowed on staging only.                                              |
| Merge a PR that changes `image_tag` in `deploy/projects/<name>/project.yml` | Only that project/environment deploys                                                               |
| Change `deploy/projects/_defaults.yml`                                      | Nothing deploys automatically, because it affects every project. Roll it out by hand, wave by wave. |
| Add a new project folder                                                    | Its first deploy is never automatic                                                                 |
| "Run workflow" on **Deploy**                                                | Deploys the selected projects to one environment                                                    |

Production only accepts release tags (`v4.7.6-pw.N`) and hotfix tags
(`v4.7.6-pw.N-<project>.M`). `sha-*` builds are refused there, and so is `latest`.

A pin must name a tag that already exists in the repository (or, for `sha-*`,
a commit that exists). Push the tag first, so that **Release build** has made
the images, and pin it afterwards. Otherwise the Plan job fails with "has no git
tag or commit", and nothing is deployed.

## Cutting a release

```bash
git switch release/4.7 && git pull
git tag v4.7.6-pw.2
git push origin v4.7.6-pw.2
```

Wait for **Release build** to finish. Its summary shows the image digests.

How to number tags:

- `v<mastodon version>-pw.<n>`; `<n>` goes up by one for each Patchwork release on that Mastodon version.
- A Mastodon upgrade starts over at `pw.1`, e.g. `v4.8.0-pw.1`.

## Deploying to staging, then production

```bash
deploy/bin/rollout v4.7.6-pw.2 --env staging --select newsmast
git switch -c rollout/staging-v4.7.6-pw.2
git add deploy/projects && git commit -m "Roll out v4.7.6-pw.2 to staging: newsmast"
git push -u origin HEAD
```

Open the PR. When it merges, the **Deploy** workflow:

- plans and deploys `newsmast/staging` only;
- shows the plan in the run summary;
- deploys under the `newsmast-staging` GitHub environment, which records it in the deployment history.

Check staging, then do the same with `--env production`. Production
environments require an approval in GitHub before the job starts.

## Rolling out to specific projects

Each project pins its own tag, so a rollout only touches the projects you pick.
`rollout` and the manual **Deploy** run take the same selectors:

| Selector                                       | Picks                                           |
| ---------------------------------------------- | ----------------------------------------------- |
| `newsmast`                                     | one project                                     |
| `newsmast,csidnet`                             | a list                                          |
| `wave:canary`, `wave:1`, `wave:2`, `wave:last` | a rollout wave (`wave:` in project.yml)         |
| `tag:small`, `tag:fr-region`                   | projects with that tag (`tags:` in project.yml) |
| `provider=ovh`, `wave=1`                       | any top-level field                             |
| `all`                                          | every project                                   |

A typical production rollout of a new release goes through the waves, one PR each:

```bash
deploy/bin/rollout v4.7.6-pw.2 --env production --select wave:canary      # PR 1
deploy/bin/rollout v4.7.6-pw.2 --env production --select wave:1           # PR 2, a day later
deploy/bin/rollout v4.7.6-pw.2 --env production --select wave:2,wave:last # PR 3
```

Add `--dry-run` to see what would change without writing anything. Projects
that already run that tag are reported as `same` and left alone.

To redeploy without changing a pin (after a credentials change on the VM, for
example), use **Actions → Deploy → Run workflow** with `projects: newsmast` and
the environment, and leave `image_tag` empty.

## Hotfix for one project

Prefer fixing in `release/4.7` and cutting a normal release. If one project
needs a fix now:

```bash
git switch -c hotfix/newsmast-push v4.7.6-pw.2
# fix, commit
git tag v4.7.6-pw.2-newsmast.1 && git push origin hotfix/newsmast-push v4.7.6-pw.2-newsmast.1
deploy/bin/rollout v4.7.6-pw.2-newsmast.1 --env production --select newsmast   # PR as usual
```

Then merge the fix into `release/4.7`. The next normal release
(`v4.7.6-pw.3`) moves newsmast back onto the shared line. Do not keep a hotfix
branch around: that is how project branches came about.

## Rollback

- **Normal:** revert the pin PR (`git revert`). Merging the revert redeploys the previous tag.
- **Automatic:** if the new containers fail their health checks, or the smoke
  test fails, `ovh-deploy.sh` starts the previous release again by itself. The
  run fails and its summary says so. The pin in git still points to the failed
  tag; revert it.
- **Emergency, on the VM:** `deploy/bin/ovh-deploy.sh rollback`. See [DEVOPS.md](DEVOPS.md#operations).

Database migrations are never undone. This is why migrations must keep the
previous release working (see below).

## Migrations

`ovh-deploy.sh` runs:

1. `rails db:migrate` with `SKIP_POST_DEPLOY_MIGRATIONS=true` **before** the
   switch, while the old release is still serving;
2. the plain `rails db:migrate` (post-deploy migrations) **after** the new
   release is healthy.

Mastodon already follows this pattern. For Patchwork migrations:

- Adding tables, columns or indexes → a normal migration (`db/migrate`). The old code must keep working with the new schema.
- Removing or renaming something the old code uses → a post-deploy migration (`db/post_migrate`), shipped one release after the code stops using it.
- The web container no longer migrates at startup. Never add `db:migrate` back to the compose `command`.

## Project differences without branches

In order of preference:

1. **Runtime config:** ENV in the VM's `.env.production`, or settings in the `newsmast_mastodon` engine or the admin UI.
2. **Feature flags** read from ENV, defaulting to the current upstream behaviour.
3. **Deploy config:** `deploy/projects/<name>/project.yml` (resources, Firebase path, runner, and so on).
4. **Compose override:** `deploy/projects/<name>/compose.override.yml`. It is picked up automatically and layered on `deploy/compose/mastodon.yml`. Use it for extra services such as Elasticsearch.
5. **Build variant:** a build argument in the Dockerfile, giving a second image "flavor". Only for differences that must be compiled in, and agreed with the team first.

Never create a long-lived project branch.

## Upgrading Mastodon

1. Create `release/4.8` from the upstream `v4.8.x` tag, merged with the Patchwork changes from `release/4.7`. Upgrade the `newsmast_mastodon` engine at the same time.
2. Tag `v4.8.0-pw.1`. CI builds the images.
3. Roll out: `--env staging --select all`, then production wave by wave, exactly as above.
4. Keep `release/4.7` for security fixes until no project pins a `v4.7.*` tag (`grep -r 'image_tag: v4.7' deploy/projects`).

There are no per-project branches to recreate. Each project changes one line.

## Adding a project

1. Copy `deploy/projects/newsmast/project.yml` to `deploy/projects/<name>/project.yml`.
   Set `display_name`, `wave`, `tags`, and for each environment `runner`, `public_url` and `image_tag`.
2. Ask DevOps to set up the Harbor pull robot, the GitHub environment and the VM ([DEVOPS.md](DEVOPS.md#adding-a-project)).
3. Merge it. A new project never deploys automatically: run **Deploy** once by hand.

## Previewing and testing locally

```bash
ruby deploy/test/patchwork_deploy_test.rb
PLAN_EVENT=workflow_dispatch PLAN_PROJECTS=wave:1 PLAN_ENVIRONMENT=production deploy/bin/plan-deploy
deploy/bin/rollout v4.7.6-pw.2 --env production --select tag:small --dry-run
```

The scripts need only the Ruby standard library (Ruby 3.0 or later); no bundle install.
Run `git fetch --tags` first: the planner checks pinned tags against your local tags.
