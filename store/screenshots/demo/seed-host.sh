#!/bin/sh
# Puts the demo content on an SSH machine: the isolated omp home the app drives, and the projects the
# scripted turns work in.
#
#   store/screenshots/demo/seed-host.sh --host localhost --port 22221 --user omp \
#     --key /Users/you/omp-app/.tools/ssh-test/id_ed25519 \
#     --provider-url http://host.docker.internal:18991/v1
#
# It writes, as the remote user:
#   ~/.omp/agent/models.yml   provider `local`: models `Fast` and `Reasoning` (never a real vendor name)
#   ~/.omp/agent/config.yml   the settings the fake provider needs, plus modelRoles.default
#   ~/code/api-server         TypeScript upload service with git history, its rate-limit test red
#   ~/code/dashboard-web      the upload queue UI, for a second project group in the sidebar
#   ~/work/pipeline           deploy glue; .omp/config.yml asks for tool approval (the approval screenshot)
#
# The machine needs git, node and npm (the seed runs `npm install` for typescript); without one, the seed stops
# and names it. In the `testing/sshd` target container capture.sh installs them over docker exec; on any other
# machine install them yourself.
set -eu

host=localhost
port=22
user=omp
key=
provider_url=
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --provider-url) provider_url=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$provider_url" ] || { echo "--provider-url is required" >&2; exit 2; }
[ -n "$key" ] || { echo "--key is required" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
projects="$here/projects"
[ -d "$projects" ] || { echo "missing $projects" >&2; exit 1; }

ssh_run() {
  ssh -i "$key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$user@$host" "$@"
}

staging=/tmp/ompanion-seed.$$
tar -c -C "$here" prepare-project.sh seed-session.mjs | ssh_run "rm -rf $staging && mkdir -p $staging && tar -x -C $staging 2>/dev/null"
tar -c -C "$projects" . | ssh_run "mkdir -p $staging/projects && tar -x -C $staging/projects 2>/dev/null"

ssh_run "PROVIDER_URL='$provider_url' STAGING='$staging' sh -s" <<'REMOTE'
set -eu

command -v git >/dev/null || { echo "git is missing on $(hostname); install it first" >&2; exit 1; }
command -v node >/dev/null || { echo "node is missing on $(hostname); install it first" >&2; exit 1; }
command -v npm >/dev/null || { echo "npm is missing on $(hostname); install it first" >&2; exit 1; }
if [ "$(id -u)" = 0 ]; then
  chown -R "$(stat -c '%U' "$HOME")" "$HOME" 2>/dev/null || true
fi

# The omp home the app drives. No real provider: only the fake one on the capture host.
mkdir -p "$HOME/.omp/agent"
cat >"$HOME/.omp/agent/models.yml" <<YAML
providers:
  local:
    baseUrl: $PROVIDER_URL
    apiKey: fake-key
    api: openai-completions
    models:
      - id: Fast
        name: Fast
        reasoning: false
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
      - id: Reasoning
        name: Reasoning
        reasoning: true
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
YAML
cat >"$HOME/.omp/agent/config.yml" <<'YAML'
startup:
  checkUpdate: false
marketplace:
  autoUpdate: "off"
power:
  sleepPrevention: "off"
lsp:
  enabled: false
ttsr:
  enabled: false
dev:
  autoqa: false
modelRoles:
  default: local/Fast
YAML

# The projects: each becomes ~/code/<name> or ~/work/<name> with its own git history.
mkdir -p "$HOME/code" "$HOME/work"
for project in api-server dashboard-web; do
  rm -rf "$HOME/code/$project"
  mv "$STAGING/projects/$project" "$HOME/code/$project"
  echo "-- $project"
  sh "$STAGING/prepare-project.sh" "$HOME/code/$project" "$project"
done
mkdir -p "$HOME/work"
rm -rf "$HOME/work/pipeline"
mv "$STAGING/projects/pipeline" "$HOME/work/pipeline"
echo "-- pipeline"
sh "$STAGING/prepare-project.sh" "$HOME/work/pipeline" pipeline

# Sessions of earlier runs keep asking the fake provider for turns, which would eat the queued plan, so the
# demo user's own omp runs are stopped here (this host exists only for captures).
pkill -f "omp --mode rpc-ui" 2>/dev/null || true
sleep 1
rm -rf "$HOME/.ompanion/run"/* 2>/dev/null || true

# History for the machine list: past sessions with titles of their own, written by a real omp.
omp="$HOME/.local/bin/omp"
if [ -x "$omp" ] && [ -f "$STAGING/seed-session.mjs" ]; then
  node "$STAGING/seed-session.mjs" "$omp" "$HOME" "$HOME/code/api-server" "Rate limits for the upload route" \
    "Sketch how a token bucket would fit behind POST /upload." || true
  node "$STAGING/seed-session.mjs" "$omp" "$HOME" "$HOME/code/api-server" "Flaky upload test" \
    "Why does test/upload.test.ts fail when the queue is busy?" || true
  node "$STAGING/seed-session.mjs" "$omp" "$HOME" "$HOME/work/pipeline" "Nightly deploy notes" \
    "Summarize what the nightly deploy does." || true
fi

cd "$HOME"
rm -rf "$STAGING"
echo "seeded $HOME on $(hostname)"
REMOTE
