# deploy/

Projects as config, and the scripts that deploy them. Start with
[docs/deploy/README.md](../docs/deploy/README.md).

```
projects/_defaults.yml          defaults for every project
projects/<name>/project.yml     one Mastodon instance: environments and their image_tag pins
projects/<name>/compose.override.yml   optional, rarely needed
compose/mastodon.yml            the one compose file every OVH project runs
bin/rollout                     move pins:   bin/rollout v4.6.5-pw.2 --env staging --select newsmast
bin/plan-deploy                 preview:     PLAN_PROJECTS=wave:1 PLAN_ENVIRONMENT=production bin/plan-deploy
bin/ovh-deploy.sh               on the VM:   deploy | rollback [release] | status
lib/patchwork_deploy.rb         shared logic (Ruby stdlib only)
test/                           ruby deploy/test/patchwork_deploy_test.rb
```
