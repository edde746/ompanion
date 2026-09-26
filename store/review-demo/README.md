# Review demo

A throwaway SSH host that runs omp 18.3.1 against a fake model provider. App Review and Google Play review
add it in ompanion as a machine and use the app end to end — chat, tool cards, the file browser, the
terminal, machine configuration — with no AI account, no API key and no cost to anyone.

Two containers, one private network, one published port:

| Container | What runs | Reaches |
|---|---|---|
| `host` | Ubuntu, OpenSSH as the unprivileged user `review`, omp 18.3.1 in `~/.local/bin/omp`, a template home with the demo project | runs omp and the reviewer's shell; publishes `${REVIEW_SSH_PORT:-22222}` → 2222 |
| `provider` | `testing/fake-provider/server.ts --demo`: canned turns, neutral models `demo/fast` ("Fast") and `demo/reasoning` ("Reasoning") | the `host` container only; no published port |

The reviewer's home and the host keys live in the `review-data` volume. The host image holds the omp
release and ompanion uploads its companion into the home on the first connect.

## Requirements

- A **throwaway** VPS, 1 vCPU and 1 GB RAM: 2 GB of swap or 1 GB more RAM is comfortable while omp runs.
  ~4 GB free disk (the host image carries the 230–280 MB omp binary). Linux **x86_64 or arm64**, Docker
  Engine 20.10+ with the `docker compose` plugin. The compose file caps the host container at 768 MB,
  1 CPU and 512 processes, and the provider at 192 MB and 0.5 CPU.
- Outbound internet while `./up.sh` builds (the build downloads the omp release from GitHub and verifies
  its SHA-256). Inbound: only the published SSH port. The containers need no internet at runtime: omp's
  home turns the release and marketplace checks off.
- The repository checked out on the VPS — the compose build context is the repository root (it only reads
  a few files from it). Not your main server: the reviewer gets a shell inside the container, and outside
  it, nothing.
- `openssh-client` on the VPS is optional (`up.sh` uses `ssh-keyscan` to wait for sshd).

## Commands

```sh
cd store/review-demo
./setup.sh            # generates the password into .env and prints it once
./up.sh               # builds, starts, waits for sshd, prints the address and the credentials
./reset.sh            # puts the reviewer's home back (they may have edited files)
./down.sh             # stops the stack, keeps the home and the host keys
./down.sh --clean     # stops it and deletes the volume: the home and the host keys are gone
```

`./setup.sh --force` generates a new password (then `./up.sh` rebuilds, which recreates the container).

**Credentials.** `setup.sh` writes them to `store/review-demo/.env` (gitignored) and prints them once:
`REVIEW_PASSWORD` is 24 random alphanumeric characters (~143 bits) and is the password the reviewer logs in
with; `REVIEW_SSH_PORT` is the published port (default `22222`). Only the password's hash enters the host
image, as the `review` field of `/etc/passwd`. Read it again with:

```sh
sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env
```

**Firewall.** Allow only the published port from the internet, for example:

```sh
ufw default deny incoming && ufw allow 22222/tcp && ufw enable
```

## What the reviewer does

These are the app's own labels. An SSH machine does not dial until the reviewer asks it to, and on a phone
the session list is behind the machine's row.

1. Sidebar → **Add machine** (the `+` at the top). **Kind** SSH; **Name** anything, e.g. `omp demo`;
   **Host** the VPS's public address; **Port** `22222`; **User** `review`; **Authentication** **Password**;
   **Password** from `.env`. *Save password on this device* is optional (with it, the connect does not ask
   again). → **Save**
2. The machine's page opens. Under **System**, tap **Connect**. The first connection asks about a host key
   it has never seen: **Trust this host?** → **Trust**. `./up.sh` printed that key's fingerprint, and
   `docker compose --env-file .env exec host ssh-keygen -lf /data/ssh/ssh_host_ed25519_key.pub` prints it
   again.
3. The same section now lists **OS**, **Architecture**, **Shell**, **Home**, **omp**
   (`/data/review/.local/bin/omp`), **omp version** `18.3.1` and **Companion** *Uploaded*.
4. Back to the list of machines (the back arrow on a phone). On the machine's row, tap **⋮** (More) →
   **New session** — on desktop, hover the row and use its **+**. **Working directory**
   `~/work/notes-api` (a small TypeScript service with a git history; leave **Model** empty, the home's
   default role is the demo's *Fast*), then **Start**.
5. Type anything in **Message omp** and send. The demo model answers with canned replies; omp's session
   runs detached, so the phone can be locked and picked up again. Expand the machine in the list (its
   chevron) to see the session list, and use **⋮** → **Refresh** to reload it.

Worth trying with the reviewer: **Files** (open `README.md`, edit, see the git diff), **Terminal** (a real
shell on the machine), the transcript's tool cards, and **Configure** on the machine.

## What the demo answers

The provider is `testing/fake-provider` in `--demo` mode: one canned scenario per prompt, in this order,
shared by every session and starting over when the cycle ends. `./reset.sh` restarts it, so a fresh
reviewer sees the sequence from the top.

| # | Reply |
|---|---|
| 1 | markdown: headings, lists, a table, a Dart and a shell code block, inline and display math |
| 2 | a `bash` tool card running `ls -la`, then a short answer |
| 3 | a `read` of the project's `README.md`, then an `edit` that toggles a marker on its first line |
| 4 | a `todo` list with three tasks, then a question |
| 5 | reasoning chunks, then the answer (visible as a thinking block on `demo/reasoning`) |
| 6 | an `ask` question with two options, then the chosen answer |
| 7 | a ~20 s streamed answer, long enough to pause, abort or steer |

Models in the home's `models.yml` are `demo/fast` ("Fast", the default role) and `demo/reasoning`
("Reasoning"); no vendor's model is named and no request leaves the stack.

## Console answers

Values the user fills in: `<HOST>` is the VPS's public address, `<PASSWORD>` is `REVIEW_PASSWORD` from
`.env`. Everything else is as written.

### App Store Connect → App Review Information

- **Sign-in required**: yes
- **User name**: `review`
- **Password**: `<PASSWORD>`
- **Notes**:

> ompanion is a client for omp, an AI coding agent that runs on the user's own machines. The app has no
> account of its own: to reach every screen, add the demo machine we run for this review.
>
> 1. In the sidebar, tap Add machine. Choose Kind: SSH. Enter Host: `<HOST>`, Port: `22222`, User:
>    `review`, Authentication: Password, Password: `<PASSWORD>`. Tap Save.
> 2. The machine's page opens. Under System, tap Connect. The app asks "Trust this host?" the first time;
>    tap Trust. The demo machine is a container we run only during this review and destroy afterwards; it
>    holds no personal data.
> 3. The System section then shows omp version 18.3.1 and Companion: Uploaded.
> 4. Go back to the list of machines, tap the ⋮ on the machine's row and choose New session. Set Working
>    directory to ~/work/notes-api and tap Start.
> 5. Type any message in the composer and send it. The demo machine's model is an offline demo model
>    that answers with canned replies (markdown, a shell command, a file read and edit, a todo list,
>    reasoning, a question, then a long streamed answer). It makes no request to any AI provider and
>    costs nothing.
>
> Everything else works on the same machine: the Files panel edits files and shows git diffs, the
> Terminal opens a shell, and Configure browses omp's settings, model roles, MCP servers, plugins and
> skills. Usage has no limits to show on the demo machine. No account, purchase or external service is
> needed to reach any of it. App Review may also connect to its own machine with omp 18.3.1 installed.

### Google Play Console → App access

Choose **All or some functionality is restricted** and answer with the same credentials and steps as
above (Play calls them "sign-in details" and "instructions"), including `/data/review/work/notes-api` as
the session directory and the note that the demo machine is destroyed after the review.

## Security

- **No root for the reviewer**: the image's user is `review`, `sudo` is not installed, `PermitRootLogin no`
  and `AllowUsers review`, password authentication only. The container itself runs unprivileged:
  `cap_drop: [ALL]`, `no-new-privileges`, a read-only root filesystem with tmpfs for `/tmp` and `/run`,
  `mem_limit`/`cpus`/`pids_limit`, and the `review-data` volume as its only mount.
- **Unprivileged sshd**: sshd runs as `review` on port 2222 (a privileged port needs root). Password auth
  works without `/etc/shadow` because the account's hash sits in `/etc/passwd`, so no root process is
  needed at all. `UsePAM no`. Two consequences of running without root, both harmless: sshd cannot write
  the login records, so its log says `Attempt to write login records by non-root user` and the VPS's
  `last`/`who` do not list the review sessions; and shell sessions and PTYs (the app's Terminal tab) work
  normally.
- **Rate limits**: `MaxAuthTries 3`, `MaxStartups 3:50:10`, `LoginGraceTime 30`, `ClientAliveInterval 30`
  with `ClientAliveCountMax 3` (`sshd_config`). Three wrong passwords in one connection end it with
  `maximum authentication attempts exceeded` in the host's log. Optional and not exercised here: fail2ban
  (or sshguard) on the VPS reading those lines — `docker compose --env-file .env logs host` shows
  `Failed password for review from <address> port <port> ssh2`; on a Linux VPS the client's own address is
  there (Docker's DNAT preserves it), so a jail can ban the real address. The container's limits already
  cap guessing at three tries per connection.
- **Only sshd is exposed**: the provider publishes no port and is reachable only on the compose network,
  so its control API (`/control/*`) is not on the internet. The provider serves one canned reply per
  request and has no credentials.
- **The reviewer can do what the app does**: read and write files in the demo home, run omp, open a
  shell. That is the point of the demo; everything they touch is in the volume.
- **Afterwards**: `./down.sh --clean` and destroy the VPS. Do not reuse the generated password anywhere,
  and do not commit `.env`.

## Verifying a running stack

Two scripts here drive the app's own code paths; both are documented in their headers. Run `./reset.sh`
first: the rotation is a cycle, and both checks expect it to start at its first scenario.

```sh
# From the repository root. The reviewer's path without the widgets: password SSH, probe, companion,
# session, three demo scenarios, exec, file browser, session list.
dart run store/review-demo/verify/verify.dart \
  --password "$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)"

# The same path in the real app (macOS desktop): add machine, trust, connect, new session, prompt, reply.
# Writes PNGs of the app's widget tree, by default to /tmp/ompanion-store/ReviewDemo.
REVIEW_DEMO_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
  flutter drive --driver=test_driver/integration_test.dart \
    --target=store/review-demo/verify/capture_test.dart -d macos
```

By hand: `ssh -p 22222 review@<host>` with the password (a shell running as `review`, no sudo), `docker
compose --env-file .env logs host` for sshd's own log, and `docker compose --env-file .env exec provider
bun -e "fetch('http://127.0.0.1:8787/control/requests').then(r => r.json()).then(console.log)"` to read the
provider's request log from inside the stack.

What was checked here, for the shape of the numbers to expect: `sshd -T` inside the container reports
`port 2222`, `passwordauthentication yes`, `pubkeyauthentication no`, `permitrootlogin no`, `usepam no`,
`maxauthtries 3`, `maxstartups 3:50:10`; three wrong passwords in one connection end it with `maximum
authentication attempts exceeded`; `docker inspect` shows `User=review`, `ReadonlyRootfs=true`,
`CapDrop=[ALL]`, `no-new-privileges`, `NanoCpus=1000000000`, `Memory=805306368`, `PidsLimit=512` and one
bind mount (`review-data:/data`), with no port bindings on the provider.

## Files

| Path | What it is |
|---|---|
| `docker-compose.yml` | the two services, the network, the limits, the volume |
| `Dockerfile.host` | Ubuntu + OpenSSH + omp (fetched by `scripts/fetch_omp.sh`, checksum-verified) + the template home with the demo project's git history |
| `Dockerfile.provider` | Bun + `testing/fake-provider` in `--demo` mode |
| `Dockerfile.host.dockerignore`, `Dockerfile.provider.dockerignore` | keep the build context to the handful of files each image copies |
| `sshd_config` | the drop-in `/etc/ssh/sshd_config.d/00-review.conf`: port, host keys, password auth, rate limits |
| `entrypoint.sh` | first start: host keys into the volume, seed the home, exec sshd |
| `restore-home.sh` | restores the template home and stops the app's omp runs (used by the entrypoint and `reset.sh`) |
| `setup.sh`, `up.sh`, `reset.sh`, `down.sh` | the four commands above |
| `home-template/` | the home the image ships: `.omp/agent/{models.yml,config.yml}`, shell startup files, `README.md`, `work/notes-api` |
| `verify/verify.dart`, `verify/capture_test.dart` | the two checks above |
| `.env` | generated by `setup.sh`, gitignored |

## Limits of this setup

- Verified on Docker Desktop for macOS (linux/arm64) only. The x86_64 path uses the same
  `scripts/fetch_omp.sh` targets and asset names, but was not run here.
- Not run on a VPS; nothing here depends on Docker Desktop.
- The fail2ban/sshguard suggestion above is not exercised.
- The provider's demo rotation is per container, not per session: two reviewers prompting at the same
  time take turns in the same cycle (`testing/README.md`, "Dev machine").
- omp 18.3.1 is preinstalled, so the review never sees the app's "install omp" dialog.
