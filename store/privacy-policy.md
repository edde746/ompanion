# ompanion privacy policy

ompanion is a client for [omp](https://github.com/can1357/oh-my-pi), an open-source coding agent, on
machines you own. This policy describes exactly what the app stores and what it sends. It describes the
app in this repository; it is not legal advice.

Last updated: 2026-09-26.

## The short version

- There is no account, no sign-up and no service run by us.
- The app has no analytics, no crash reporting, no advertising and no tracking of any kind.
- Nothing is sent to us, because there is nowhere to send it: the app talks to machines you own, over SSH,
  and to nothing else on its own.
- What you type goes to the agent on your machine, which calls the AI providers **you** configured there.

## What the app stores on your device

- **Machine definitions**: the name you gave a machine, its host and port, the user name, the
  authentication method (key, password, keyboard-interactive, SSH config or agent), the list of jump hosts
  in the order they are dialed, and whether it is a mesh VPN peer. This is in the app's local database on
  the device.
- **SSH keys**: a key you generate or import is stored as a key pair. The private key, and any passphrase
  you let the app remember, are kept in the platform's secure storage (the Keychain on Apple platforms,
  Keystore-backed encrypted storage on Android). Only the public key and its fingerprint are in the app's
  database. Private keys never leave the device.
- **Host keys you have trusted**, so a machine that changes its key is flagged instead of trusted.
- **Settings**: your preferences, and where you left off in the session list.
- **Read markers**: per session file, the modification time up to which you have read it.
- **Image previews**: when a reply names an image on your machine and the machine has ffmpeg, the app
  fetches a preview over SSH and caches it in the app's cache directory so it does not fetch it again.
- **Session data**: the transcript you see is read from the machine over SSH. Messages, files and
  attached files live on the machine, in your own project and session directories.

Nothing in that list is a copy of your AI provider credentials. Those stay on your machine, in omp's own
configuration, and the app never reads them.

## What the app sends, and where

- **To your machines, over SSH.** Connection setup, host-key checks, the session list, transcripts, prompts
  you send, files you open, save or attach, terminal input, configuration changes, and the small companion
  extension the app uploads to `~/.ompanion/companion/` on the machine and omp loads with `-e`, so that omp
  exposes the events the client needs.
- **To GitHub, when you ask the app to install omp on a machine that lacks it.** Either the machine
  downloads the release asset itself, or the app downloads it from `github.com` and uploads it to your
  machine over SFTP, with a checksum check. This is a request for a public open-source file; it carries no
  information about you beyond what any web request carries, and it goes only to GitHub.
- **To the host of a link, only when you tap it.** The app opens links in your browser. This includes
  provider sign-in pages for OAuth logins configured in omp, and a web image named in a model reply: such
  an image is fetched from its own URL only after you tap it, and never on its own.
- **Nowhere else.** The app has no server of ours, no telemetry endpoint, no push service and no
  third-party SDK that reports anything. The app has no update check of its own either: the `startup.checkUpdate`
  setting in the app's settings screen belongs to **omp on your machine**, and that check, if you turn it on,
  happens from your machine and nowhere else.

## Your AI providers

The app does not talk to AI providers. The agent on your machine does, using the accounts **you** configured
in omp on that machine. When you send a prompt, it travels over SSH to your machine and from there to your
provider, under that provider's terms and privacy policy, with your credentials. Model access, data
retention and pricing are therefore between you and the provider you chose — the same as running omp in a
terminal.

## What we do not do

- We do not collect, see, sell or share your data. There is no analytics SDK, no crash-reporting SDK, no
  advertising SDK and no identifier that we could tie to you.
- We do not require an account, an email address or a phone number to use the app.
- We do not read your prompts, your files, your keys or your provider credentials.
- The app does not use the Advertising Identifier or any other tracking mechanism.

## Children

ompanion is a developer tool. It connects to machines with SSH credentials, runs commands on them, and shows
whatever the agent on those machines produces, without any moderation of its own. It is not directed to
children, and we recommend it only for adults who administer the machines they connect to.

## Retention and deletion

Your data lives on your device and on your machines, and you delete it by deleting it:

- **Remove a machine** in the app: its definition, its jump hosts, its remembered secrets and its cached
  data are deleted from the device. Nothing is deleted on the machine itself.
- **Uninstall the app**: everything the app stored on the device goes with it. Note that the platform's
  secure storage may keep entries until the app is fully removed by the operating system; on iOS the
  Keychain items are removed with the app.
- **On the machine**: sessions, transcripts and files uploaded for a session live on the machine, in your
  own directories, and are yours to delete there. The companion extension is one file per omp version under
  `~/.ompanion/companion/`, and deleting that directory removes it.
- There is no server-side copy for us to delete.

## Changes

This policy is part of the source repository, so every change to it is a public commit. The date at the top
changes whenever the text changes. If a future version of the app collects anything, this document will say
what, why and how to turn it off before that version ships.

## Contact

Questions, corrections or a privacy concern: open an issue at
<https://github.com/edde746/ompanion/issues>. That is also the support and bug-report channel.
