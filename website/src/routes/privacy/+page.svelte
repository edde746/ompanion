<script lang="ts">
  import Logo from '$lib/components/Logo.svelte';
  import PageMetadata from '$lib/components/PageMetadata.svelte';
  import { GITHUB_PRIVACY_URL, ISSUES_URL, OMP_URL, SITE_URL } from '$lib/content/downloads';

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
      <span>Back to ompanion</span>
    </a>

    <h1>Privacy Policy</h1>
    <p class="updated">Last updated: September 26, 2026</p>

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
            <strong>SSH keys</strong>: a key you generate or import is stored as a key pair. The private key, and
            any passphrase you let the app remember, are kept in the platform's secure storage (the Keychain on
            Apple platforms, Keystore-backed encrypted storage on Android). Only the public key and its
            fingerprint are in the app's database. Private keys never leave the device.
          </li>
          <li><strong>Host keys you have trusted</strong>, so a machine that changes its key is flagged instead of trusted.</li>
          <li><strong>Settings</strong>: your preferences, and where you left off in the session list.</li>
          <li><strong>Read markers</strong>: per session file, the modification time up to which you have read it.</li>
          <li>
            <strong>Image previews</strong>: when a reply names an image on your machine and the machine has
            ffmpeg, the app fetches a preview over SSH and caches it in the app's cache directory so it does not
            fetch it again.
          </li>
          <li>
            <strong>Session data</strong>: the transcript you see is read from the machine over SSH. Messages,
            files and attached files live on the machine, in your own project and session directories.
          </li>
        </ul>
        <p>
          Nothing in that list is a copy of your AI provider credentials. Those stay on your machine, in omp's own
          configuration, and the app never reads them.
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
            <strong>To GitHub, when you ask the app to install omp on a machine that lacks it.</strong> Either the
            machine downloads the release asset itself, or the app downloads it from <code>github.com</code> and
            uploads it to your machine over SFTP, with a checksum check. This is a request for a public
            open-source file; it carries no information about you beyond what any web request carries, and it goes
            only to GitHub.
          </li>
          <li>
            <strong>To the host of a link, only when you tap it.</strong> The app opens links in your browser. This
            includes provider sign-in pages for OAuth logins configured in omp, and a web image named in a model
            reply: such an image is fetched from its own URL only after you tap it, and never on its own.
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
      </section>

      <section aria-labelledby="website">
        <h2 id="website">This website</h2>
        <p>
          This site sets no cookies and runs no analytics. It loads nothing from a third party: no web fonts from
          a CDN, no scripts, no images and no embeds. Every asset on the page is served from this domain with the
          page itself.
        </p>
        <p>
          The pages are hosted on GitHub Pages, which receives visitors' IP addresses in its server logs as any
          web server does. That logging is GitHub's, under the
          <a href={GITHUB_PRIVACY_URL} target="_blank" rel="noopener noreferrer">GitHub General Privacy Statement</a>.
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
            <strong>Remove a machine</strong> in the app: its definition, its jump hosts, its remembered secrets
            and its cached data are deleted from the device. Nothing is deleted on the machine itself.
          </li>
          <li>
            <strong>Uninstall the app</strong>: everything the app stored on the device goes with it. Note that
            the platform's secure storage may keep entries until the app is fully removed by the operating system;
            on iOS the Keychain items are removed with the app.
          </li>
          <li>
            <strong>On the machine</strong>: sessions, transcripts and files uploaded for a session live on the
            machine, in your own directories, and are yours to delete there. The companion extension is one file
            per omp version under <code>~/.ompanion/companion/</code>, and deleting that directory removes it.
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
    gap: 0.5rem;
    border-radius: var(--radius);
    padding: 0.5rem 0.75rem 0.5rem 0.5rem;
    margin-left: -0.5rem;
    color: var(--color-text-muted);
    font-size: 0.875rem;
    font-weight: 600;
    transition: color var(--motion-fast) var(--ease-standard);
  }

  .back-link:hover,
  .back-link:focus-visible {
    color: var(--color-text);
  }

  h1 {
    margin-top: 2rem;
    font-family: var(--font-display);
    font-size: clamp(2.25rem, 7vw, 3.5rem);
    font-weight: 700;
    letter-spacing: -0.04em;
    line-height: 1.05;
  }

  .updated {
    margin-top: 0.75rem;
    color: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 0.75rem;
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
    font-size: clamp(1.25rem, 3vw, 1.5rem);
    font-weight: 700;
    letter-spacing: -0.025em;
    line-height: 1.25;
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

  li::before {
    content: '';
    position: absolute;
    margin-left: -1.25rem;
    margin-top: 0.7em;
    width: 0.375rem;
    height: 2px;
    border-radius: var(--radius-full);
    background: var(--color-surface-highest);
  }

  .prose a {
    color: var(--color-text);
    text-decoration: underline;
    text-decoration-color: var(--color-text-muted);
    text-underline-offset: 0.2em;
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
