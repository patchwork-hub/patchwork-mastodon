# Release and deploy flow: DevOps guide

One-time setup for the newsmast pilot, day-to-day operations, and the AWS
cutover. For the overview, see [README.md](README.md).

## What runs where

| Piece                   | Runs on                                                                         | Needs                                                                    |
| ----------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `release-build.yml`     | GitHub-hosted `ubuntu-latest`                                                   | `RELEASE_HARBOR_PASSWORD` (push robot of the shared Harbor project)      |
| `deploy.yml` → plan job | GitHub-hosted `ubuntu-latest`                                                   | nothing secret                                                           |
| `ovh-deploy.yml`        | self-hosted runner **on the project's VM**, label from `runner:` in project.yml | GitHub environment `<project>-<environment>` with `HARBOR_PULL_PASSWORD` |

The VM only ever **pulls** images, with a pull-only robot. CI never writes
credentials to the VM.

## 1. Harbor

Use the existing registry `44eda7q3.gra7.container-registry.ovh.net`, or change
`image.registry` in `deploy/projects/_defaults.yml`.

1. Create a **private** project named `patchwork`.
2. Create the robot accounts:

   | Robot (full name)                          | Permissions                  | Used by                                                         |
   | ------------------------------------------ | ---------------------------- | --------------------------------------------------------------- |
   | `robot$patchwork+release-push`             | push + pull on `patchwork/*` | `release-build.yml` → secret `RELEASE_HARBOR_PASSWORD`          |
   | `robot$patchwork+newsmast-staging-pull`    | pull on `patchwork/*`        | newsmast staging VM → environment secret `HARBOR_PULL_PASSWORD` |
   | `robot$patchwork+newsmast-production-pull` | pull on `patchwork/*`        | newsmast production VM (at cutover)                             |

   Each name follows `image.pull_username` in `_defaults.yml`
   (`robot$patchwork+{project}-{environment}-pull`). If your Harbor uses a
   different robot prefix, change that template once.

3. Add a tag retention policy. Suggested rules:
   - keep every `v*` tag for 180 days, and always keep the newest 20;
   - keep `sha-*` tags for 14 days.
4. Optional: for clients that must have their own registry (e.g. the eu-west-par
   registry used by lhumanite, ouest-france and pouet), add a **Harbor replication
   rule** from `patchwork/*` to their project, and set `image.registry` and
   `image.harbor_project` in that project's file. Images are still built only once.

## 2. GitHub

**Secrets.** The repository is at GitHub's 100-secret limit, so:

- add `RELEASE_HARBOR_PASSWORD` as an **organization** secret, with repository
  access limited to `patchwork-mastodon`;
- put everything per project in **environment** secrets (environment secrets
  don't count toward the repository limit).

**Environments.** Under Settings → Environments, create:

| Environment           | Secret                 | Protection                                                           |
| --------------------- | ---------------------- | -------------------------------------------------------------------- |
| `newsmast-staging`    | `HARBOR_PULL_PASSWORD` | Deployment branches: `poc/ovh-release-deploy-flow` (later `main`)    |
| `newsmast-production` | `HARBOR_PULL_PASSWORD` | Required reviewers (2 people, prevent self-review); same branch rule |

The environment name must be exactly `<project folder>-<environment>`.

**Runner.** See section 3. Put self-hosted runners in a runner group that only
`patchwork-mastodon` can use, and allow only the branches above. A self-hosted
runner runs whatever workflow targets its label.

**Manual runs.** "Run workflow" only shows workflows that exist on the default
branch. For the POC, either copy the three workflow files to `main`, or use the
`gh` CLI after they are there:

```bash
gh workflow run deploy.yml --ref poc/ovh-release-deploy-flow -f projects=newsmast -f environment=staging
```

## 3. The VM (newsmast staging)

1. **Size.** newsmast's ECS tasks were sized at web 2 vCPU / 4 GB, sidekiq 2 vCPU / 4 GB, streaming 0.25 vCPU / 0.5 GB.
   - Production needs at least 8 vCPU / 16 GB, leaving room for nginx and two images during a swap.
   - Staging is set smaller in project.yml (1 vCPU / 2 GB each for web and sidekiq).
   - Postgres, Redis and object storage stay managed services outside the VM, as on the other OVH projects.
2. **Packages.** Docker Engine plus the compose plugin, version **2.17 or newer** (`docker compose version`), and `curl`.
   Add `ubuntu` to the `docker` group.
3. **Reverse proxy.** nginx with TLS, proxying to `127.0.0.1:3000` (web) and
   `127.0.0.1:4000` (streaming, `/api/v1/streaming`). This is the same as the
   current OVH hosts; copy the nginx site from one of them.
4. **Credentials,** placed by hand, mode `600`, owner `ubuntu`:

   ```
   /home/ubuntu/deployment/credential/.env.production         # from the newsmast staging env file in S3 (patchwork-private-env)
   /home/ubuntu/deployment/credential/firebase/firebase.json  # = fcm_newsmast_service.json
   ```

   Inside the containers, `firebase.json` is mounted as
   `/opt/mastodon/config/fcm_newsmast_service.json`
   (`runtime.firebase_container_path` in project.yml).

5. **GitHub Actions runner.**
   - Install it as a service, running as `ubuntu`.
   - Give it the label **`newsmast-staging`**. It must match `runner:` in project.yml.
   - Register it at repository level, or in the restricted organization runner group from section 2.

That's all. `ovh-deploy.sh` creates `/home/ubuntu/deployment/mastodon/releases/...` itself on the first deploy.

## 4. First deploy (staging)

1. Tag the POC branch head: `git tag v4.6.5-pw.1 && git push origin v4.6.5-pw.1`.
   Check that **Release build** pushed `patchwork/web:v4.6.5-pw.1` and `patchwork/streaming:v4.6.5-pw.1`.
2. Run **Deploy** with `projects=newsmast` and `environment=staging`. This first
   deploy is never automatic.
3. Watch the run. Its steps are: plan → (approval, if configured) → pull →
   pre-deploy migrations → switch → smoke test → post-deploy migrations.
4. On the VM, run `deploy/bin/ovh-deploy.sh status` (path in the runner's work
   folder), or read `/home/ubuntu/deployment/mastodon/deploy-history.log`.

Then try the normal flow: cut `v4.6.5-pw.2`, run
`deploy/bin/rollout v4.6.5-pw.2 --env staging --select newsmast`, and merge the
PR. Only `newsmast/staging` should deploy.

## Operations

On the VM:

```bash
cd /home/ubuntu/deployment/mastodon/current
docker compose ps
docker compose logs -f --tail=200 web
docker compose exec web bin/tootctl ...
```

Rollback and status, using the script from any checkout of the repo or the runner's work folder:

```bash
DEPLOY_DIR=/home/ubuntu/deployment/mastodon bash deploy/bin/ovh-deploy.sh status
DEPLOY_DIR=/home/ubuntu/deployment/mastodon bash deploy/bin/ovh-deploy.sh rollback
DEPLOY_DIR=/home/ubuntu/deployment/mastodon bash deploy/bin/ovh-deploy.sh rollback 20261127T101500Z-v4.6.5-pw.1
```

- The last 5 releases are kept (`KEEP_RELEASES`). Images older than 7 days that are not in use are pruned.
- After a manual rollback, tell the devs to revert the pin. Otherwise the next pin change brings the bad release back.
- Rollbacks never undo database migrations.

**When a deploy fails:**

| Symptom in the run                      | Meaning                                                  | Action                                                 |
| --------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------ |
| `.env.production is missing`            | Credentials are not placed                               | Section 3, step 4                                      |
| Fails at "Pulling images"               | Wrong pull robot or password, or the tag was never built | Check the environment secret and the Release build run |
| Fails at "Pre-deploy migrations"        | A migration error; the old release is still serving      | Developers fix it; nothing to roll back                |
| "did not become healthy … Rolling back" | The new release crashed; the previous one was restarted  | `docker compose logs` in `releases/<failed>`           |
| "post-deploy migrations failed"         | The new release is live; the cleanup migration failed    | Fix forward; don't roll back blindly                   |

**Downtime.** There is no `docker compose down` any more. Only containers whose
image or settings changed are recreated, so web has a short gap while the new
puma starts. Zero-downtime would need two web containers behind nginx; that is
a possible follow-up, not part of this POC.

## Adding a project

1. Harbor: a pull robot per environment (`robot$patchwork+<name>-<env>-pull`).
2. GitHub: an environment per deploy environment (`<name>-staging`, `<name>-production`), each with `HARBOR_PULL_PASSWORD`.
3. VM: sections 3.1 to 3.5, with the runner label from the project file.
4. Developers add `deploy/projects/<name>/project.yml` and run the first deploy by hand.

**Existing OVH hosts** (csidnet, democracy-book-club, mo-me, nithecs,
lhumanite-social, ouest-france-social, pouetfrance-social) keep their
directories. The new compose file uses the same project name (`mastodon`) and
the same `mastodon_uploads` volume, so the first new deploy takes over the
running containers. After that:

- delete that project's old `build-push-*-ovh-harbor.yml` / `ovh.yml` workflow;
- delete the old `docker-compose.*.ovh.yml` from the host.

For mo-me, stop copying `config/firebase-adminsdk.json` from the repo; place it
in the credential folder instead.

## Cutover of newsmast production from AWS

Keep `environments.production.enabled: false` until all of this is done:

1. Production VM, runner `newsmast-production`, environment `newsmast-production` with reviewers (sections 1 to 3).
2. Data plan agreed and rehearsed:
   - Postgres (replica or dump/restore, and the maintenance window);
   - Redis (can start empty, but timelines must be rebuilt: `tootctl feeds build`);
   - media storage (S3 bucket stays, or is synced to OVH Object Storage);
   - Elasticsearch, if used.
3. `.env.production` on the VM is built from `newsmast-prod.env`, with the new DB, Redis and storage endpoints.
4. Lower the DNS TTL beforehand.
5. On the day:
   - stop the AWS services (scale ECS to 0);
   - final data sync;
   - set `enabled: true` and pin the same tag as staging, in one PR, and merge it;
   - approve the deploy;
   - switch DNS.
6. Afterwards: remove `.github/workflows/newsmast-production.yml` (the AWS deploy),
   so that a push to `newsmast-4.6.5-production` no longer deploys to ECS.
