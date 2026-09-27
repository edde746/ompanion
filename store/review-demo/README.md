# Review demo

A dedicated server that App Review, Google Play review and Microsoft Store certification add in ompanion as
an SSH machine. They sign in as `root` on port 22 with a password and use the app end to end: chat with a
real model, tool cards, the file browser, the terminal, machine configuration. omp 18.3.1 runs there with one
model, GLM 5.3 Flash through OpenRouter, on a key with a $10 spending limit that the owner pays for.

Reviewers get root, and whoever has root's password controls the whole machine. So the demo runs on a server
of its own that holds nothing else and is destroyed after the review.

| | Now |
|---|---|
| Address | `217.160.119.181`, SSH on port 22 |
| System | Ubuntu 26.04, x86_64, 1 vCPU, 1.8 GB RAM + 2 GB swap |
| Sign-in | user `root`, authentication Password, the password is `REVIEW_PASSWORD` in `.env` |
| Host key | ED25519 `SHA256:4mwcsNjvhhIg85l4XQfYColo5dgLgr+6Z1zVspSC8A0` |
| omp | 18.3.1 at `/usr/local/bin/omp` |
| Model | `demo/z-ai/glm-5.3-flash`, "GLM 5.3 Flash", the only model the app's model picker shows |
| Home | `/root/README.md` (for the reviewer), `/root/work/notes-api` (the demo project), `/root/.omp/agent/{config.yml,models.yml}`, `/root/.gitconfig` |

Root's shell startup files and SSH keys are Ubuntu's; the demo does not touch them. ompanion uploads its
companion into `/root/.ompanion` on the first connect.

`harness/fake-provider` (scripted turns, no model) serves local development (its `--demo` mode) and the store
screenshots; the review demo does not use it.

## Requirements

- A **dedicated, disposable** Ubuntu or Debian server, x86_64 or arm64 (the architectures omp ships Linux
  builds for). The current one has 1 vCPU and 1.8 GB RAM; `server.sh` adds a 2 GB swapfile when the server
  has no swap, because omp uses a few hundred MB while it runs.
- Root SSH with password authentication: `sshd -T` must report `permitrootlogin yes` and
  `passwordauthentication yes`. `server.sh` checks both and stops if either is off; it does not edit sshd's
  configuration.
- Internet egress: apt, GitHub (the omp release) and, while reviewers use it, `openrouter.ai`.
- SSH access as root from this Mac to run `provision.sh` (a key, or root's password when asked).

## `.env`

`store/review-demo/.env` is gitignored and written by hand. Never copy either value into a tracked file: the
repository is public.

| Key | What it is |
|---|---|
| `REVIEW_PASSWORD` | root's password on the server; the store consoles give it to reviewers. Random letters and digits (reviewers type it), at least 15 of them. |
| `OPENROUTER_API_KEY` | the OpenRouter key omp uses; create it with a spending limit ($10 now) |

Read the password with:

```sh
sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env
```

## Commands

From the repository root on this Mac:

```sh
# Set the server up, or bring it up to date. Idempotent; prints the host key's fingerprint.
store/review-demo/provision.sh root@217.160.119.181

# Put root's home back between reviews (reviewers may have edited files or left sessions running).
ssh root@217.160.119.181 ompanion-demo-reset

# Smoke check through omp_core, the app's own SSH, probe, companion and session code. No model call.
REVIEW_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
  dart run store/review-demo/verify/verify.dart --host 217.160.119.181

# The same, plus one prompt that makes the model run a command: a real model call on the demo's key.
REVIEW_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
  dart run store/review-demo/verify/verify.dart --host 217.160.119.181 --prompt

# The reviewer's path in the real app (macOS desktop): add machine, trust, connect, new session, one real
# prompt, the reply. Writes PNGs of the app's widget tree, by default to /tmp/ompanion-store/ReviewDemo.
REVIEW_DEMO_HOST=217.160.119.181 \
REVIEW_DEMO_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
  flutter drive --driver=integration_test/driver/report_driver.dart \
    --target=store/review-demo/verify/capture_test.dart -d macos
```

`provision.sh` reads `.env`, streams `server.sh`, `restore-home.sh`, the home template,
`scripts/fetch_omp.sh` and the two secrets over SSH into `/opt/ompanion-demo/src`, and runs `server.sh` there.
The secrets travel inside that stream, never on a command line, and `server.sh` deletes them once read.
`server.sh` then:

1. installs `ca-certificates`, `curl`, `git` and `locales` if any is missing, and generates the
   `en_US.UTF-8` locale (SSH forwards the client's `LANG`);
2. adds a 2 GB swapfile if the server has no swap;
3. installs omp 18.3.1 as `/usr/local/bin/omp` through `scripts/fetch_omp.sh`, which checks the release's
   SHA-256;
4. sets root's password with `chpasswd` and checks that sshd allows root and passwords;
5. builds the template home in `/opt/ompanion-demo/home`: the home template with the key written into
   `models.yml`, and the demo project's three-commit git history (fixed authors and dates);
6. installs `restore-home.sh` as `/usr/local/sbin/ompanion-demo-reset` and runs it.

`ompanion-demo-reset` stops the omp runs the app started, removes `/root/.omp`, `/root/work`,
`/root/README.md` and `/root/.ompanion`, and copies the template home back into `/root`.

`verify.dart` defaults to port 22, user `root` and `<home>/work/notes-api`; `--port`, `--user`, `--project`
and `--companion` override them. Its header lists every step.

## What the reviewer does

These are the app's own labels. An SSH machine does not dial until the reviewer asks it to, and on a phone
the session list is behind the machine's row.

1. Sidebar → **Add machine** (the `+` at the top). **Name** anything, e.g. `Demo` (required); **Host**
   `217.160.119.181`; **Port** `22`; **User** `root`; **Authentication** **Password**; **Password** from
   `.env`. *Save password on this device* is optional (with it, the connect does not ask again). → **Save**. A
   desktop build that can still add *this computer* shows **Kind** first: pick SSH.
2. The machine's page opens. Under **System**, tap **Connect**. The first connection asks about a host key
   it has never seen: **Trust this host?** → **Trust**. Its fingerprint is the one in the table above.
3. The same section now lists **OS**, **Architecture**, **Shell**, **Home**, **omp** (`/usr/local/bin/omp`),
   **omp version** `18.3.1` and **Companion** *Uploaded*.
4. Back to the list of machines (the back arrow on a phone). On the machine's row, tap **⋮** (More) →
   **New session**; on desktop, hover the row and use its **+**. **Working directory** `~/work/notes-api` (a
   small TypeScript service with a three-commit git history); leave **Model (optional)** empty, every model
   role is GLM 5.3 Flash. Then **Start**.
5. Type anything in **Message omp** and send. GLM 5.3 Flash answers and uses omp's tools: it reads and edits
   the project's files and runs commands on the server. omp's session runs detached, so the phone can be
   locked and picked up again. Expand the machine in the list (its chevron) to see the session list, and
   use **⋮** → **Refresh** to reload it.

Worth trying with the reviewer: **Files** (open `README.md`, edit, see the git diff), **Terminal** (a root
shell on the server), the transcript's tool cards, and **Configure** on the machine.

## The model and what it costs

`home-template/.omp/agent/models.yml` defines a provider `demo` with one model: `z-ai/glm-5.3-flash`
("GLM 5.3 Flash") at `https://openrouter.ai/api/v1`, OpenAI chat completions, reasoning on, text and image
input, a 262,144-token context window (omp compacts before it) and 16,384 output tokens. It is not omp's
built-in `openrouter` provider: that one, given a key, makes every OpenRouter model selectable in the app,
and a reviewer could pick an expensive one. `config.yml` makes the model the `default`, `smol` and `slow`
role, so a new session needs no model choice.

OpenRouter charges $0.045 per million input tokens and $0.14 per million output tokens for it. For example,
a request that sends 50,000 tokens of context and gets 2,000 back costs about $0.0025, so the $10 limit pays
for about 4,000 such requests. Once the key reaches its limit, OpenRouter refuses its requests and the demo
stops answering until the limit is raised in OpenRouter's key settings.

Reviewers' prompts, and the files and command output the agent sends along, go to OpenRouter and the model's
provider, Z.ai, under their policies.

## Security and cost

- **Root is the reviewer.** Anyone with the password controls the server: they can read the OpenRouter key
  in `~/.omp/agent/models.yml`, change the password, add or remove SSH keys (including the owner's), install
  anything and use the server's network. The server holds nothing else, the key's $10 limit bounds what the
  key can cost, and the server is destroyed after the review.
- **The password** is in `.env` on this Mac and in the three store consoles (App Store Connect, Play
  Console, Partner Center). The repository carries `<PASSWORD>` in its place, and `ios/fastlane/Fastfile`
  refuses to upload review information that still contains it.
- **sshd runs the server image's configuration**, which allows root and passwords; `provision.sh` does not
  change it. `sshd -T` on the server reports `port 22`, `permitrootlogin yes`, `passwordauthentication yes`,
  `maxauthtries 6`, `logingracetime 120`, `maxstartups 10:30:100`, and `persourcepenalties` on (OpenSSH
  refuses connections for a while from addresses that fail to log in). TCP and X11 forwarding are on, so the
  password also makes the server an SSH proxy. No firewall (`ufw` inactive) and no fail2ban. Bots try root
  passwords on every public address, so the password must be long and random.
- **Rotate the password** by editing `REVIEW_PASSWORD` in `.env`, running `provision.sh` again and pasting
  the new one into the store consoles.
- **After the review**: revoke the key at OpenRouter, destroy the server, and delete `.env` or replace both
  values before the next review.

## Console answers

`<PASSWORD>` is `REVIEW_PASSWORD` from `.env`; it is the only value to fill in. Everything else is as
written. If the server changes, replace `217.160.119.181` everywhere `git grep 217.160.119.181` finds it
(this file, `ios/fastlane/metadata/review_information/notes.txt`, `store/README.md`, `store/app-store.md`,
`store/google-play.md`) and the host key fingerprint above.

### App Store Connect → App Review Information

- **Sign-in required**: yes
- **User name**: `root`
- **Password**: `<PASSWORD>`
- **Notes**: the text below. `ios/fastlane/metadata/review_information/notes.txt` holds it plus the guideline
  paragraphs, and that file is what `deliver` uploads.

> ompanion is a client for omp, an AI coding agent that runs on the user's own machines. The app has no
> account of its own: to reach every screen, add the demo server we run for this review.
>
> 1. In the sidebar, tap Add machine. Enter Name: Demo, Host: 217.160.119.181, Port: 22, User: root,
>    Authentication: Password, Password: `<PASSWORD>`. Tap Save.
> 2. The machine's page opens. Under System, tap Connect. The app asks "Trust this host?" the first time;
>    tap Trust. The demo server is a machine we run only for this review and destroy afterwards; it holds
>    no personal data.
> 3. The System section then shows omp version 18.3.1 and Companion: Uploaded.
> 4. Go back to the list of machines, tap the ⋮ on the machine's row and choose New session. Set Working
>    directory to ~/work/notes-api and tap Start.
> 5. Type a message in the composer and send it, for example "What does this project do?". The agent
>    answers with GLM 5.3 Flash, a real AI model we pay for through OpenRouter, and can read and edit the
>    project's files and run commands on the server.
>
> Everything else works on the same machine: the Files panel edits files and shows git diffs, the Terminal
> opens a shell, and Configure browses omp's settings, model roles, MCP servers, plugins and skills. Usage
> has no limits to show on the demo server. No account, purchase or AI subscription is needed to reach any
> of it. App Review may also connect to its own machine with omp 18.3.1 installed.

### Google Play Console → App access

Choose **All or some functionality is restricted** and add one set of sign-in details: user name `root`,
password `<PASSWORD>`. Play's "Any other information" field takes 500 characters, so the notes above do not
fit: paste the 483-character text in `store/google-play.md` §4.

### Partner Center → Submission options → Notes for certification

> ompanion is a client for omp, an AI coding agent that runs on the user's own machines. The app has no
> account of its own: to reach every screen, add the demo server we run for this review.
>
> 1. In the sidebar, click Add machine. If the form shows Kind, choose SSH. Enter Name: Demo, Host:
>    217.160.119.181, Port: 22, User: root, Authentication: Password, Password: `<PASSWORD>`. Click Save.
> 2. The machine's page opens. Under System, click Connect. The app asks "Trust this host?" the first time;
>    click Trust. The demo server is a machine we run only for this review and destroy afterwards; it holds
>    no personal data.
> 3. The System section then shows omp version 18.3.1 and Companion: Uploaded.
> 4. Hover the machine's row in the sidebar and click its +. Set Working directory to ~/work/notes-api and
>    click Start.
> 5. Type a message in the composer and send it, for example "What does this project do?". The agent
>    answers with GLM 5.3 Flash, a real AI model we pay for through OpenRouter, and can read and edit the
>    project's files and run commands on the server.
>
> Everything else works on the same machine: the Files panel edits files and shows git diffs, the Terminal
> opens a shell, and Configure browses omp's settings, model roles, MCP servers, plugins and skills. No
> account, purchase or AI subscription is needed to reach any of it.

## Files

| Path | What it is |
|---|---|
| `provision.sh` | runs on this Mac: reads `.env`, streams the files and secrets to the server, runs `server.sh` |
| `server.sh` | runs on the server as root: packages, locale, swap, omp, root's password, the template home, the reset command |
| `restore-home.sh` | installed as `/usr/local/sbin/ompanion-demo-reset`: stops omp runs and restores root's demo files |
| `home-template/` | what the reset command puts in `/root`: `README.md`, `.gitconfig`, `.omp/agent/{models.yml,config.yml}` (the key is a placeholder here), `work/notes-api` |
| `verify/verify.dart` | the omp_core smoke check; `--prompt` adds one real model call |
| `verify/capture_test.dart` | the reviewer's path in the real macOS app, with screenshots; sends one real prompt |
| `.env` | `REVIEW_PASSWORD` and `OPENROUTER_API_KEY`, written by hand, gitignored |

## Verified

On 2026-09-27, after `provision.sh`, `verify.dart` passed every step against `217.160.119.181`: probe
linux/x64 glibc, home `/root`, omp `/usr/local/bin/omp` 18.3.1, companion uploaded and loaded, file browser
read and write, SSH exec, companion `exec.bash`, session list, `get_available_models` listing only
`demo/z-ai/glm-5.3-flash` "GLM 5.3 Flash", and the settings schema. With `--prompt` the model ran
`git log --oneline` through the bash tool and answered "The project has 3 commits".

## Limits

- `capture_test.dart` was not run against this server.
- The App Store, Google Play and Microsoft Store review flows were not run.
- Only Ubuntu 26.04 on x86_64 was provisioned; Debian and arm64 were not.
- The reset command restores only the demo's paths. Packages a reviewer installed, files elsewhere, a changed
  password or removed SSH keys stay; `provision.sh` sets the password again if the owner can still sign in,
  and otherwise the server has to be rebuilt from its image and provisioned (with a new host key).
- Reviewers who sign in at the same time share one home and see each other's sessions.
- Disk is not capped: a reviewer can fill the server's disk.
- omp 18.3.1 is preinstalled, so the review never sees the app's "install omp" dialog.
