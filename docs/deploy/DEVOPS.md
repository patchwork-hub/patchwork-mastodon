# Release and deploy flow: DevOps guide

One-time setup for the newsmast pilot, day-to-day operations, and switching
newsmast production over to this flow. For the overview, see [README.md](README.md).

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
   | `robot$patchwork+newsmast-production-pull` | pull on `patchwork/*`        | newsmast production VM (at switch-over)                         |

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

1. **Size.** newsmast production runs web 2 vCPU / 4 GB, sidekiq 2 vCPU / 4 GB, streaming 0.25 vCPU / 0.5 GB (`docker-compose.newsmast.ovh.yml`).
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
   /home/ubuntu/deployment/credential/.env.production         # staging env (staging still runs on AWS ECS today)
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

1. Tag the POC branch head: `git tag v4.7.6-pw.1 && git push origin v4.7.6-pw.1`.
   Check that **Release build** pushed `patchwork/web:v4.7.6-pw.1` and `patchwork/streaming:v4.7.6-pw.1`.
2. Run **Deploy** with `projects=newsmast` and `environment=staging`. This first
   deploy is never automatic.
3. Watch the run. Its steps are: plan → (approval, if configured) → pull →
   pre-deploy migrations → switch → smoke test → post-deploy migrations.
4. On the VM, run `deploy/bin/ovh-deploy.sh status` (path in the runner's work
   folder), or read `/home/ubuntu/deployment/mastodon/deploy-history.log`.

Then try the normal flow: cut `v4.7.6-pw.2`, run
`deploy/bin/rollout v4.7.6-pw.2 --env staging --select newsmast`, and merge the
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
DEPLOY_DIR=/home/ubuntu/deployment/mastodon bash deploy/bin/ovh-deploy.sh rollback 20261127T101500Z-v4.7.6-pw.1
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

**Existing OVH hosts** (newsmast: see the next section; csidnet, democracy-book-club, mo-me, nithecs,
lhumanite-social, ouest-france-social, pouetfrance-social) keep their
directories. The new compose file uses the same project name (`mastodon`) and
the same `mastodon_uploads` volume, so the first new deploy takes over the
running containers. After that:

- delete that project's old `build-push-*-ovh-harbor.yml` / `ovh.yml` workflow;
- delete the old `docker-compose.*.ovh.yml` from the host.

For mo-me, stop copying `config/firebase-adminsdk.json` from the repo; place it
in the credential folder instead.

## Switching newsmast production to this flow

newsmast production has run on OVH since 2026-11-20. Today it is deployed by
`.github/workflows/build-push-newsmast-ovh-harbor.yml`. On every push to
`newsmast-4.7.6-production` it:

- builds images into the `newsmast-social` Harbor project, tagged per commit;
- deploys from a GitHub-hosted runner over SSH (`OVH_SSH_PRIVATE_KEY`, `vars.NEWSMAST_SERVER_IP`);
- runs `docker compose pull && docker compose up -d` in `/home/ubuntu/deployment/mastodon`;
- runs migrations when the web container starts.

Its deploy step also copies the CI runner's `~/.docker/config.json`, which holds
the Harbor login, onto the server. The new flow logs in on the VM with a
pull-only robot instead.

Keep `environments.production.enabled: false` until all of this is done, so
the two pipelines never deploy the same server:

1. Staging has run the new flow for a while without problems.
2. Production VM: install a runner labelled `newsmast-production` (section 3.5),
   and check `docker compose version` is 2.17 or newer. The credentials are
   already in `/home/ubuntu/deployment/credential/`; nothing to move.
3. Harbor robot `robot$patchwork+newsmast-production-pull`, and the environment
   `newsmast-production` with required reviewers (sections 1 and 2).
4. In one PR:
   - remove the `push:` trigger from `build-push-newsmast-ovh-harbor.yml`, keeping
     `workflow_dispatch` as an emergency path for a while;
   - set `enabled: true` for production and pin the tag that staging runs.
5. Merge and approve the deploy. The first run takes over the running `mastodon`
   containers and keeps the `mastodon_uploads` volume, because the compose
   project and volume names are the same.
6. On the VM, rename the old `/home/ubuntu/deployment/mastodon/docker-compose.yml`
   (e.g. to `docker-compose.yml.old`). Otherwise `docker compose up` run in that
   folder would bring the old images back under the same project name.
7. Afterwards, delete these files: `build-push-newsmast-ovh-harbor.yml`,
   `docker-compose.newsmast.ovh.yml` and the stub `newsmast-production.yml`.
   Also delete the `OVH_SSH_PRIVATE_KEY` and `NEWSMAST_HARBOR_PASSWORD`
   secrets, if nothing else uses them.

newsmast **staging** still deploys to AWS ECS through `newsmast-staging.yml`,
but the `.task/` definitions it reads no longer exist on the 4.7.6 branches.
The POC's staging environment on OVH replaces it.
