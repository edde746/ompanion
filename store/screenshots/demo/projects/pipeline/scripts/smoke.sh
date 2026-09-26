#!/bin/sh
# Smoke test against a running deployment.
set -eu

base=${SMOKE_BASE:-http://127.0.0.1:8080}

health=$(curl -fsS "$base/health")
printf 'health: %s\n' "$health"

upload=$(curl -fsS -X POST --data-binary @README.md "$base/upload")
printf 'upload: %s\n' "$upload"
