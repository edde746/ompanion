<script lang="ts">
  import window1216 from '$lib/assets/hero-window-1216.webp';
  import window2432 from '$lib/assets/hero-window-2432.webp';
  import { REPO_URL } from '$lib/content/downloads';
  import HeroArt from './HeroArt.svelte';

  let shot: HTMLElement | undefined = $state();
</script>

<section class="hero" aria-labelledby="hero-title">
  <HeroArt {shot} />

  <div class="copy">
    <h1 id="hero-title" class="display">
      <span class="line">A client for omp,</span>
      <span class="line">on <span class="accent">machines you own</span>.</span>
    </h1>
    <p class="subline">
      ompanion drives the oh-my-pi coding agent over SSH, from your desktop, phone and tablet. No account, and
      no daemon on the machine.
    </p>
    <div class="actions">
      <a class="bar bar-primary" href="#download">Download</a>
      <a class="bar bar-secondary" href={REPO_URL} target="_blank" rel="noopener noreferrer">Source on GitHub</a>
    </div>
    <p class="mono-label platforms" data-art-ceiling>
      <span class="visually-hidden">Runs on</span> macOS · Windows · Linux · iOS · Android
    </p>
  </div>

  <div class="showcase" bind:this={shot}>
    <div class="glow" aria-hidden="true"></div>
    <img
      src={window2432}
      srcset={`${window1216} 1216w, ${window2432} 2432w`}
      sizes="(max-width: 39.99rem) calc(175vw - 56px), (min-width: 1184px) 1120px, calc(100vw - 64px)"
      width="1440"
      height="900"
      alt="The ompanion window on macOS: two machines with their projects and sessions in the sidebar, a finished task in the chat with its test run and answer, and the task's plan beside it."
      fetchpriority="high"
    />
  </div>
</section>

<style>
  .hero {
    position: relative;
    overflow: clip;
    /* The foot is room for the light to dissolve under the window. */
    padding: clamp(3.5rem, 9vw, 6.5rem) var(--page-gutter) clamp(8.5rem, 15vw, 12.5rem);
    text-align: center;
  }

  .copy,
  .showcase {
    position: relative;
    z-index: 1;
    width: min(100%, var(--page-width));
    margin-inline: auto;
  }

  h1 {
    font-size: var(--type-display);
  }

  /* Each half of the line wraps as a unit when it can, so the break falls after the comma. */
  .line {
    display: inline-block;
  }

  .subline {
    max-width: 41rem;
    margin: 1.5rem auto 0;
    color: var(--color-text-muted);
    font-size: clamp(1rem, 0.9rem + 0.4vw, 1.1875rem);
    line-height: 1.6;
    text-wrap: pretty;
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 0.75rem;
    margin-top: 2.25rem;
  }

  .platforms {
    margin-top: 1.5rem;
  }

  .showcase {
    max-width: 70rem;
    margin-top: clamp(3rem, 7vw, 5rem);
  }

  /* The static light: what a page without JavaScript shows, and what the art replaces once drawn. */
  .glow {
    position: absolute;
    z-index: 0;
    inset: -12% -4% -18%;
    background: radial-gradient(48% 52% at 50% 58%, rgb(196 240 66 / 0.1), rgb(34 197 94 / 0.05) 50%, transparent 74%);
    transition: opacity 600ms var(--ease-standard);
  }

  .hero:has(:global(.art.drawn)) .glow {
    opacity: 0;
  }

  /* The window without its macOS shadow: on the page's black a shadow only erases the art around it. */
  .showcase img {
    position: relative;
    z-index: 1;
    width: 100%;
  }

  /* A phone keeps the window's corner with the traffic lights, the sidebar and most of the chat, and lets the dock
     run off the right edge: the whole window at phone width is a quarter of its size and says nothing. */
  @media (max-width: 39.99rem) {
    .showcase {
      width: 175%;
      max-width: none;
      margin-inline: 0;
    }
  }

  @media print {
    .glow {
      display: none;
    }
  }
</style>
