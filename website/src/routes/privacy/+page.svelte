<script lang="ts">
  import Logo from '$lib/components/Logo.svelte';
  import PageMetadata from '$lib/components/PageMetadata.svelte';
  import { CLOUDFLARE_PRIVACY_URL, ISSUES_URL, OMP_URL, SITE_URL } from '$lib/content/downloads';

  const title = 'Privacy Policy — ompanion';
  const description =
    'What the ompanion app stores on your device, what it sends over SSH, and what this website does: no cookies, no analytics, no third-party requests.';
  const url = `${SITE_URL}/privacy`;
</script>

<PageMetadata {title} {description} {url} />

<article class="policy">
  <div class="column">
    <a class="back-link" href="/">
      <Logo size={22} />
      <span class="mono-label">Back to ompanion</span>
    </a>

    <h1 class="display">Privacy Policy</h1>
    <p class="updated mono-label">Last updated: September 27, 2026</p>

    <div class="prose">
      <p>
        ompanion is a client for <a href={OMP_URL} target="_blank" rel="noopener noreferrer">omp</a>, an
        open-source coding agent, on machines you own. This policy describes exactly what the app stores and
        what it sends. It describes the shipped app; it is not legal advice.
      </p>

      <section aria-labelledby="short-version">
        <h2 id="short-version">The short version</h2>
        <ul>
          <li>There is no account, no sign-up and no service run by us.</li>
          <li>The app has no analytics, no crash reporting, no advertising and no tracking of any kind.</li>
          <li>
            Nothing is sent to us, because there is nowhere to send it: the app talks to machines you own, over
            SSH, and to nothing else on its own.
          </li>
          <li>
            What you type goes to the agent on your machine, which calls the AI providers <strong>you</strong>
            configured there.
          </li>
        </ul>
      </section>

      <section aria-labelledby="device-data">
        <h2 id="device-data">What the app stores on your device</h2>
        <ul>
          <li>
            <strong>Machine definitions</strong>: the name you gave a machine, its host and port, the user name,
            the authentication method (key, password, keyboard-interactive, SSH config or agent), the list of jump
            hosts in the order they are dialed, and whether it is a mesh VPN peer. This is in the app's local
            database on the device.
          </li>
          <li>
            <strong>SSH keys and passwords</strong>: a key you generate or import is stored as a key pair. The
            private key, its passphrase, and any password you choose to save for a machine are kept in the
            platform's secure storage (the Keychain on Apple platforms, Keystore-backed encrypted storage on
            Android). Only the public key and its fingerprint are in the app's database. The app never sends a
            private key, passphrase or saved password anywhere; it signs on the device.
          </li>
          <li><strong>Host keys you have trusted</strong>, so a machine that changes its key is flagged instead of trusted.</li>
          <li>
            <strong>Settings</strong>: your preferences (theme, which panels are open, which projects are
            collapsed in the session list), and a random id the app creates once per install. The app puts that
            id in its requests to omp on your machines, so that when several of your devices share a session,
            each one recognises the replies to its own requests.
          </li>
          <li><strong>Read markers</strong>: per session file, the modification time up to which you have read it.</li>
          <li>
            <strong>Images from your machines</strong>: when the app shows an image file from one of your
            machines, it fetches it over SSH (a large file as a smaller preview, when the machine has ffmpeg to
            make one) and caches it in the app's cache directory, up to 256 MB, oldest first out.
          </li>
          <li>
            <strong>Session data</strong>: the transcript you see is read from the machine over SSH. Messages,
            files and attached files live on the machine, in your own project and session directories. What
            you are typing, pasted attachments and terminal scrollback stay in memory and are gone when the app
            closes.
          </li>
        </ul>
        <p>
          Nothing in that list is a copy of your AI provider credentials. Those stay on your machine, in omp's own
          configuration, and the app never reads them. If you type a provider API key or another secret setting
          into the app, it goes over SSH to omp on your machine, and the app keeps no copy.
        </p>
        <p>
          On iOS, the app's database is part of your own device backups, as for any app, and the secure-storage
          items above are part of encrypted ones; the image cache is not backed up. On Android, the app opts out
          of backup.
        </p>
        <p>
          The desktop builds from GitHub can also run omp on the computer itself ("this computer"), read your
          <code>~/.ssh/config</code>, <code>~/.ssh/known_hosts</code> and Tailscale peer list to fill in machines,
          and sign with your ssh-agent's keys. Those files, that list and those keys never leave the computer; the
          phone and tablet builds do none of it.
        </p>
      </section>

      <section aria-labelledby="sends">
        <h2 id="sends">What the app sends, and where</h2>
        <ul>
          <li>
            <strong>To your machines, over SSH.</strong> Connection setup, host-key checks, the session list,
            transcripts, prompts you send, files you open, save or attach, terminal input, configuration changes,
            and the small companion extension the app uploads to <code>~/.ompanion/companion/</code> on the
            machine and omp loads with <code>-e</code>, so that omp exposes the events the client needs.
          </li>
          <li>
            <strong>To GitHub, when you ask the app to install omp on a machine that lacks it.</strong> The
            machine downloads the release itself when it has curl or wget (or PowerShell on Windows); otherwise the
            app downloads it from <code>github.com</code> and streams it to your machine over SFTP. Either way the
            machine checks the file against a SHA-256 checksum the app carries. This is a request for a public
            open-source file; it carries no information about you beyond what any web request carries, and it goes
            only to GitHub.
          </li>
          <li>
            <strong>To the host of a link or image, only when you tap it.</strong> Links open in your browser,
            including provider sign-in pages for OAuth logins in omp. A web image named in a model reply is
            fetched by the app from its own URL only after you tap Load image, and never on its own. While a
            sign-in is open, the app listens on the device's own loopback address for the provider's redirect and
            relays it over SSH to omp on your machine, which completes the sign-in and keeps the token there.
          </li>
          <li>
            <strong>To a place you choose, when you export machines.</strong> The export holds machine names,
            hosts, ports, user names, authentication methods, key fingerprints, jump hosts and trusted host keys,
            never a private key, passphrase or password. It goes to the clipboard or to a file you pick.
          </li>
          <li>
            <strong>Nowhere else.</strong> The app has no server of ours, no telemetry endpoint, no push service
            and no third-party SDK that reports anything. The app has no update check of its own either: the
            <code>startup.checkUpdate</code> setting in the app's settings screen belongs to
            <strong>omp on your machine</strong>, and that check, if you turn it on, happens from your machine and
            nowhere else.
          </li>
        </ul>
      </section>

      <section aria-labelledby="providers">
        <h2 id="providers">Your AI providers</h2>
        <p>
          The app does not talk to AI providers. The agent on your machine does, using the accounts
          <strong>you</strong> configured in omp on that machine. When you send a prompt, it travels over SSH to
          your machine and from there to your provider, under that provider's terms and privacy policy, with your
          credentials. Model access, data retention and pricing are therefore between you and the provider you
          chose — the same as running omp in a terminal.
        </p>
        <p>
          Some pages of the app ask omp on your machine to go online: the usage page has omp fetch your
          subscription limits from your providers, and the plugin and skill pages have omp query its plugin
          marketplaces and skill registry. Those requests come from your machine, not from the device.
        </p>
      </section>

      <section aria-labelledby="website">
        <h2 id="website">This website</h2>
        <p>
          This site sets no cookies and runs no analytics. It loads nothing from a third party: no web fonts from
          a CDN, no scripts, no images and no embeds. Every asset on the page is served from this domain with the
          page itself.
        </p>
        <p>
          The pages are hosted on Cloudflare, which receives visitors' IP addresses in its server logs as any
          web server does. That logging is Cloudflare's, under the
          <a href={CLOUDFLARE_PRIVACY_URL} target="_blank" rel="noopener noreferrer">Cloudflare Privacy Policy</a>.
        </p>
      </section>

      <section aria-labelledby="not-do">
        <h2 id="not-do">What we do not do</h2>
        <ul>
          <li>
            We do not collect, see, sell or share your data. There is no analytics SDK, no crash-reporting SDK, no
            advertising SDK and no identifier that we could tie to you.
          </li>
          <li>We do not require an account, an email address or a phone number to use the app.</li>
          <li>We do not read your prompts, your files, your keys or your provider credentials.</li>
          <li>The app does not use the Advertising Identifier or any other tracking mechanism.</li>
        </ul>
      </section>

      <section aria-labelledby="children">
        <h2 id="children">Children</h2>
        <p>
          ompanion is a developer tool. It connects to machines with SSH credentials, runs commands on them, and
          shows whatever the agent on those machines produces, without any moderation of its own. It is not
          directed to children, and we recommend it only for adults who administer the machines they connect to.
        </p>
      </section>

      <section aria-labelledby="retention">
        <h2 id="retention">Retention and deletion</h2>
        <p>Your data lives on your device and on your machines, and you delete it by deleting it:</p>
        <ul>
          <li>
            <strong>Remove a machine</strong> in the app: everything the app stored for it is deleted from the
            device: its definition, its jump hosts, its saved passwords, its read markers, its session-list
            settings, the host keys you trusted for it that no other machine of yours uses, and the images cached
            from it. Nothing is deleted on the machine itself.
          </li>
          <li>
            <strong>Delete a key</strong> in the app: its private key and passphrase are deleted from secure
            storage.
          </li>
          <li>
            <strong>Uninstall the app</strong>: on Android, everything the app stored on the device goes with it.
            On iOS, the database and caches go with it, but the Keychain can keep private keys, passphrases and
            saved passwords after the app is deleted; delete your keys and machines in the app first to remove
            them.
          </li>
          <li>
            <strong>On the machine</strong>: sessions, transcripts and files uploaded for a session live on the
            machine, in your own directories, and are yours to delete there. The app also keeps its own files
            under <code>~/.ompanion/</code>: the companion extension, one file per omp version, and the input and
            output streams of each running session, which it deletes once that session's omp has exited. Deleting
            that directory removes all of it.
          </li>
          <li>There is no server-side copy for us to delete.</li>
        </ul>
      </section>

      <section aria-labelledby="changes">
        <h2 id="changes">Changes</h2>
        <p>
          This policy is part of the source repository, so every change to it is a public commit. The date at the
          top changes whenever the text changes. If a future version of the app collects anything, this document
          will say what, why and how to turn it off before that version ships.
        </p>
      </section>

      <section aria-labelledby="contact">
        <h2 id="contact">Contact</h2>
        <p>
          Questions, corrections or a privacy concern: open an issue at
          <a href={ISSUES_URL} target="_blank" rel="noopener noreferrer">github.com/edde746/ompanion/issues</a>.
          That is also the support and bug-report channel.
        </p>
      </section>
    </div>
  </div>
</article>

<style>
  .policy {
    width: min(100%, var(--page-width));
    margin-inline: auto;
    padding: clamp(2rem, 6vw, 4rem) var(--page-gutter) clamp(4rem, 8vw, 6rem);
  }

  /* One readable measure, centred on wide screens. */
  .column {
    width: min(100%, 68ch);
    margin-inline: auto;
  }

  .back-link {
    display: inline-flex;
    align-items: center;
    gap: 0.6rem;
    border-radius: var(--radius);
    padding: 0.5rem 0.75rem 0.5rem 0.5rem;
    margin-left: -0.5rem;
  }

  .back-link .mono-label {
    transition: color var(--motion-fast) var(--ease-standard);
  }

  .back-link:hover .mono-label,
  .back-link:focus-visible .mono-label {
    color: var(--color-text);
  }

  h1 {
    margin-top: clamp(2.5rem, 7vw, 4rem);
    font-size: var(--type-section);
  }

  .updated {
    margin-top: 1rem;
  }

  .prose {
    margin-top: clamp(2rem, 5vw, 3rem);
    color: var(--color-text-muted);
    font-size: 1rem;
    line-height: 1.75;
  }

  section {
    margin-top: 2.5rem;
  }

  h2 {
    margin-bottom: 1rem;
    color: var(--color-text);
    font-family: var(--font-display);
    font-size: var(--type-tile);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.2;
  }

  p + ul,
  ul + p,
  p + p {
    margin-top: 1.125rem;
  }

  li + li {
    margin-top: 0.75rem;
  }

  li {
    position: relative;
    padding-left: 1.25rem;
  }

  /* The site's square cell as the bullet. */
  li::before {
    content: '';
    position: absolute;
    margin-left: -1.25rem;
    margin-top: 0.68em;
    width: 5px;
    height: 5px;
    background: var(--color-text-muted);
  }

  .prose a {
    color: var(--color-text);
    text-decoration: underline;
    text-decoration-color: var(--color-text-muted);
    text-decoration-thickness: 1px;
    text-underline-offset: 0.25em;
  }

  .prose a:hover,
  .prose a:focus-visible {
    text-decoration-color: var(--color-text);
  }

  code {
    color: var(--color-text);
    font-family: var(--font-mono);
    font-size: 0.875em;
  }

  strong {
    color: var(--color-text);
    font-weight: 600;
  }
</style>
