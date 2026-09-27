#!/bin/sh
# The half of provision.sh that runs on the demo server, as root, from the bundle provision.sh unpacks into
# /opt/ompanion-demo/src (this repository's layout: store/review-demo/ and scripts/fetch_omp.sh). The secrets
# arrive in /opt/ompanion-demo/src/secrets.env (REVIEW_PASSWORD, OPENROUTER_API_KEY), which this deletes.
# Every step can run again: a second run leaves the same server.
set -eu

src=/opt/ompanion-demo/src
demo=$src/store/review-demo
template=/opt/ompanion-demo/home

# shellcheck source=/dev/null  # written by provision.sh
. "$src/secrets.env"
rm -f "$src/secrets.env"
[ -n "${REVIEW_PASSWORD:-}" ] || { echo "server.sh: REVIEW_PASSWORD is empty" >&2; exit 1; }
[ -n "${OPENROUTER_API_KEY:-}" ] || { echo "server.sh: OPENROUTER_API_KEY is empty" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
missing=
for tool in git curl locale-gen; do
  command -v "$tool" >/dev/null 2>&1 || missing=1
done
if [ -n "$missing" ]; then
  apt-get update -q
  apt-get install -y -q --no-install-recommends ca-certificates curl git locales
fi
# SSH forwards the client's LANG/LC_* (AcceptEnv): without the locale, every session starts with
# "setlocale: cannot change locale". C.UTF-8 is built in; en_US.UTF-8 needs generating.
if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then
  locale-gen en_US.UTF-8 >/dev/null
fi

# omp uses a few hundred MB while it runs; on a 1-2 GB server, swap keeps a spike from killing it.
if [ -z "$(swapon --noheadings --show)" ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap -q /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# omp from the repository's own fetcher, which checks the release's SHA-256.
case "$(uname -m)" in
  x86_64) target=linux-x64 ;;
  aarch64 | arm64) target=linux-arm64 ;;
  *) echo "server.sh: omp has no Linux build for $(uname -m)" >&2; exit 1 ;;
esac
sh "$src/scripts/fetch_omp.sh" "$target"
install -m 755 "$src/.tools/omp/"*"/omp-$target" /usr/local/bin/omp
/usr/local/bin/omp --version

# Reviewers sign in as root with this password (the store consoles carry it). chpasswd reads it on stdin,
# so it never appears in a process list.
printf 'root:%s\n' "$REVIEW_PASSWORD" | chpasswd
sshd -T | grep -qx 'permitrootlogin yes' || { echo "server.sh: sshd does not allow root logins" >&2; exit 1; }
sshd -T | grep -qx 'passwordauthentication yes' || { echo "server.sh: sshd does not allow passwords" >&2; exit 1; }

# The template the reset command restores: the reviewer's README, omp's config with the key, and the demo
# project with a git history written here (fixed authors and dates, so the same files give the same history).
rm -rf "$template"
mkdir -p "$template"
cp -a "$demo/home-template/." "$template/"
sed -i "s|@OPENROUTER_API_KEY@|$OPENROUTER_API_KEY|" "$template/.omp/agent/models.yml"
chmod 700 "$template/.omp" "$template/.omp/agent"
chmod 600 "$template/.omp/agent/models.yml"
(
  cd "$template/work/notes-api"
  git init -q -b main
  git config user.name "ompanion demo"
  git config user.email "demo@example.com"
  git add package.json tsconfig.json .gitignore .editorconfig
  GIT_AUTHOR_DATE="2026-09-10T09:00:00Z" GIT_COMMITTER_DATE="2026-09-10T09:00:00Z" \
    git commit -q -m "chore: scaffold the notes service"
  git add src
  GIT_AUTHOR_DATE="2026-09-15T14:30:00Z" GIT_COMMITTER_DATE="2026-09-15T14:30:00Z" \
    git commit -q -m "feat: serve notes over HTTP"
  git add README.md docs CHANGELOG.md
  GIT_AUTHOR_DATE="2026-09-20T11:00:00Z" GIT_COMMITTER_DATE="2026-09-20T11:00:00Z" \
    git commit -q -m "docs: readme, api notes and changelog"
  git reflog expire --expire=now --all
  git gc -q --prune=now
)

install -m 755 "$demo/restore-home.sh" /usr/local/sbin/ompanion-demo-reset
/usr/local/sbin/ompanion-demo-reset

echo
echo "server.sh: done. Host key the app asks to trust:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
