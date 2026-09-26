#!/bin/sh
# Puts one demo project into the state the store captures expect: a git repository with a small history, and
# (for api-server) the locked toolchain the test run needs.
#
#   store/screenshots/demo/prepare-project.sh <project-dir> <api-server|dashboard-web|pipeline>
#
# `demo/seed-host.sh` runs this on the SSH demo host and `demo/rehearse.ts` runs it on a local copy, so the
# captured history is the same either way. Needs git, and node and npm for api-server.
set -eu

dir=$1
name=$2
cd "$dir"

git init -q -b main 2>/dev/null || git init -q
git config user.email dev@example.com
git config user.name dev
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com

# commit <date> <subject>  — commits what is staged, dates fixed so the history does not move between runs.
commit() {
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q -m "$2"
}

case "$name" in
api-server)
  # Everything but the rate-limit test, which the history adds red and the scripted session turns green.
  git add -A
  git reset -q -- test/rate-limit.test.ts
  commit "2026-09-02T09:12:00+00:00" "feat: store uploads by digest behind a size limit"
  npm install --silent --no-audit --no-fund >/dev/null 2>&1
  git add package-lock.json
  commit "2026-09-08T14:40:00+00:00" "chore: lock the toolchain"
  git add test/rate-limit.test.ts
  commit "2026-09-11T08:05:00+00:00" "test: pin the upload rate limit contract"
  ;;
dashboard-web)
  git add -A
  git reset -q -- src/api.ts
  commit "2026-08-18T11:30:00+00:00" "feat: upload queue with per-file progress"
  git add -A
  commit "2026-08-26T16:02:00+00:00" "fix: keep the queue order across retries"
  ;;
pipeline)
  git add -A
  git reset -q -- deploy.sh .omp
  commit "2026-09-04T10:00:00+00:00" "feat: apply the staging deployment and wait for the rollout"
  git add -A
  commit "2026-09-15T09:25:00+00:00" "chore: ask before every tool call in this repo"
  ;;
*)
  echo "unknown project: $name" >&2
  exit 2
  ;;
esac

git status --short
git --no-pager log --oneline
