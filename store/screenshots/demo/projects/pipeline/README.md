# pipeline

Deployment glue for the api-server: apply the manifest, wait for the rollout, smoke it.

```sh
DEPLOY_TOKEN_FILE=~/.config/deploy/token ./deploy.sh
./scripts/smoke.sh
```
