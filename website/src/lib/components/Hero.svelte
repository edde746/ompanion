<script lang="ts">
  import desktop from '$lib/assets/hero-desktop.webp?enhanced';
  import phone from '$lib/assets/hero-phone.webp?enhanced';
  import { REPO_URL } from '$lib/content/downloads';
</script>

<section class="hero">
  <h1>A client for omp, on machines you own.</h1>
  <p class="subline">
    ompanion drives the oh-my-pi coding agent on machines you own over SSH, from your desktop, phone and
    tablet. No account and no daemon on the machine.
  </p>
  <div class="actions">
    <a class="bar bar-primary" href="#download">Download</a>
    <a class="bar bar-secondary" href={REPO_URL} target="_blank" rel="noopener noreferrer">Source on GitHub</a>
  </div>

  <div class="stage">
    <div class="glow" aria-hidden="true"></div>

    <figure class="device device-desktop frame">
      <span class="rim" aria-hidden="true"></span>
      <enhanced:img
        src={desktop}
        alt="ompanion on a desktop: the machine list beside the transcript of a running omp session, with a diff in it."
        sizes="(min-width: 60rem) 760px, 92vw"
        loading="eager"
      />
    </figure>

    <div class="link" aria-hidden="true">
      <span class="node"></span>
      <span class="rail"></span>
      <span class="pulse"></span>
      <span class="node node-end"></span>
      <span class="link-label mono-label">
        <b>SSH</b>
        <i>Same session</i>
      </span>
    </div>

    <figure class="device device-phone frame">
      <span class="rim" aria-hidden="true"></span>
      <enhanced:img
        src={phone}
        alt="The same session on a phone: the same transcript, with the diff table the agent wrote."
        sizes="(min-width: 60rem) 250px, 58vw"
        loading="eager"
      />
    </figure>
  </div>
</section>

<style>
  .hero {
    width: min(100%, var(--page-width));
    margin-inline: auto;
    padding: clamp(3rem, 9vw, 6rem) var(--page-gutter) clamp(2.5rem, 6vw, 4rem);
    text-align: center;
  }

  h1 {
    max-width: 48ch;
    margin-inline: auto;
    font-family: var(--font-display);
    font-size: clamp(1.75rem, 4.6vw, 3.25rem);
    font-weight: 700;
    letter-spacing: -0.04em;
    line-height: 1.05;
    text-wrap: balance;
  }

  .subline {
    max-width: 52rem;
    margin: 1.25rem auto 0;
    color: var(--color-text-muted);
    font-size: clamp(1rem, 1.4vw, 1.1875rem);
    line-height: 1.7;
    text-wrap: pretty;
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 0.75rem;
    margin-top: 2rem;
  }

  /* The two frames are the same capture at the same height, with the SSH link between them. */
  .stage {
    position: relative;
    display: grid;
    grid-template-columns: 1fr;
    justify-items: center;
    margin-top: clamp(2.5rem, 6vw, 4rem);
  }

  /* One quiet glow behind the desktop capture, offset to its left, the only colour above the fold. */
  .glow {
    position: absolute;
    z-index: 0;
    inset: -2% -2% auto;
    height: 36%;
    background-image: var(--glow);
    background-repeat: no-repeat;
    background-position: 0% 0%;
    background-size: 130% 100%;
  }

  .device {
    z-index: 1;
    width: 100%;
    /* The captures carry their own rounded frame and outline; the clip only trims the corner. */
    border-radius: 2%;
  }

  .device-phone {
    width: 58%;
    border-radius: 12%;
  }

  /* The SSH link: a rail with a node at each end, the label riding above it, and a slow pulse. */
  .link {
    position: relative;
    align-self: stretch;
    justify-self: stretch;
    height: 4.75rem;
  }

  .node,
  .rail,
  .pulse {
    position: absolute;
    left: 50%;
    translate: -50% 0;
  }

  .node {
    top: 0;
  }

  .node-end {
    top: auto;
    bottom: 0;
    background: var(--color-emerald);
  }

  .rail {
    top: 0;
    bottom: 0;
    width: 2px;
    background: linear-gradient(180deg, var(--color-lime), var(--color-emerald));
  }

  .pulse {
    top: 0;
    width: 2px;
    height: 26%;
    background: linear-gradient(180deg, transparent, rgb(237 237 237 / 0.7), transparent);
    animation: travel-y 6.5s linear infinite;
  }

  .link-label {
    position: absolute;
    top: 50%;
    left: 50%;
    translate: -50% -50%;
    display: grid;
    gap: 0.15rem;
    background: var(--color-bg);
    padding: 0.4rem 0.5rem;
  }

  .link-label b {
    color: var(--color-text);
    font-weight: 400;
  }

  .link-label i {
    color: var(--color-text-muted);
    font-style: normal;
    letter-spacing: 0.12em;
  }

  @keyframes travel-y {
    from {
      top: -26%;
    }

    to {
      top: 100%;
    }
  }

  @media (min-width: 60rem) {
    /* Equal heights: 66.3 % of 1280 px is 20.7 % of 400 px. */
    .stage {
      grid-template-columns: 66.3% 13% 20.7%;
      justify-items: stretch;
    }

    /* Behind the desktop capture, tipped to its left edge. */
    .glow {
      inset: -4% -2% -6%;
      height: auto;
      background-position: 6% 42%;
      background-size: 74% 96%;
    }

    .device-phone {
      width: 100%;
    }

    .link {
      height: auto;
    }

    .node,
    .rail,
    .pulse {
      top: 50%;
      left: auto;
      translate: 0 -50%;
    }

    .node {
      left: 0;
    }

    .node-end {
      right: 0;
      left: auto;
    }

    .rail {
      right: 0;
      bottom: auto;
      left: 0;
      width: auto;
      height: 2px;
      background: var(--signal);
    }

    .pulse {
      left: 0;
      width: 28%;
      height: 2px;
      background: linear-gradient(90deg, transparent, rgb(237 237 237 / 0.7), transparent);
      animation-name: travel-x;
    }

    /* Above the rail, so the pulse passes under the label and not through its word. */
    .link-label {
      top: 50%;
      translate: -50% calc(-50% - 1.55rem);
      text-align: center;
      white-space: nowrap;
    }
  }

  @keyframes travel-x {
    from {
      left: -28%;
    }

    to {
      left: 100%;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .pulse {
      animation: none;
      opacity: 0;
    }
  }
</style>
