#!/bin/sh
# Deploys the api-server image to the staging namespace.
set -eu

namespace=staging
image=registry.internal/api-server:0.4.0
token=${DEPLOY_TOKEN:-staging-deploy-token}

kubectl --namespace "$namespace" apply -f k8s/deployment.yaml
kubectl --namespace "$namespace" set image deployment/api-server api="$image"
kubectl --namespace "$namespace" rollout status deployment/api-server --timeout 90s

echo "deployed $image to $namespace with a ${#token}-character token"
