<script lang="ts">
  import showcase from '$lib/assets/showcase.webp?enhanced';
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
  <div class="showcase">
    <div class="glow" aria-hidden="true"></div>
    <enhanced:img
      src={showcase}
      alt="ompanion on a desktop and on a phone: the session list, a transcript, the agent roster, the file diff viewer and a terminal."
      sizes="(min-width: 1180px) 1120px, 94vw"
      loading="eager"
    />
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

  .showcase {
    position: relative;
    margin-top: clamp(2.5rem, 6vw, 4rem);
  }

  /* One quiet lime-to-emerald glow behind the hero capture, the only colour above the fold. */
  .glow {
    position: absolute;
    z-index: 0;
    inset: -6% 0;
    background: radial-gradient(45% 55% at 50% 50%, rgb(196 240 66 / 0.09), rgb(34 197 94 / 0.05) 45%, transparent 72%);
  }

  .showcase :global(img) {
    position: relative;
    z-index: 1;
    width: 100%;
    border-radius: var(--radius-lg);
  }
</style>
