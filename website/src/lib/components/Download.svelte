<script lang="ts">
  import { onMount } from 'svelte';
  import { BUILD_FROM_SOURCE_URL, downloads, RELEASES_PAGE_URL } from '$lib/content/downloads';

  // Every platform is one click. With JavaScript, this device's platform is drawn as the primary one.
  let primary = $state(-1);

  const guessPlatform = () => {
    const agent = navigator.userAgent;
    // iPadOS reports itself as a Mac; a touch screen gives it away.
    if (/iPhone|iPad|iPod/.test(agent) || (/Macintosh/.test(agent) && navigator.maxTouchPoints > 1)) return 'iOS';
    if (/Android/.test(agent)) return 'Android';
    if (/Windows/.test(agent)) return 'Windows';
    if (/Macintosh|Mac OS X/.test(agent)) return 'macOS';
    if (/Linux|X11/.test(agent)) return 'Linux';
    return undefined;
  };

  onMount(() => {
    const os = guessPlatform();
    primary = downloads.findIndex((download) => download.platform === os);
  });
</script>

<section id="download" class="page-section" aria-labelledby="download-title">
  <div class="head">
    <div class="title">
      <p class="mono-label">Download</p>
      <h2 id="download-title" class="display">Free, and yours to build.</h2>
    </div>
    <p class="status">
      These are the files of the latest GitHub release, and the first one is not out yet: until it is, the
      links open a 404 page.
      <a class="text-link" href={BUILD_FROM_SOURCE_URL} target="_blank" rel="noopener noreferrer">Build from source</a>
      meanwhile, or follow the
      <a class="text-link" href={RELEASES_PAGE_URL} target="_blank" rel="noopener noreferrer">releases page</a>.
    </p>
  </div>

  <ul class="platforms">
    {#each downloads as download, index (download.file)}
      <li>
        <a class="platform" class:primary={index === primary} href={download.url}>
          <span class="os">{download.platform}</span>
          <span class="file">{download.file}</span>
          <svg class="arrow" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"
            ><path d="M8 2.5v10M3.5 8.5 8 13l4.5-4.5M3 15h10" fill="none" stroke="currentColor" stroke-width="1.5" /></svg
          >
          <span class="note">{download.detail}</span>
        </a>
      </li>
    {/each}
  </ul>
</section>

<style>
  .head {
    display: grid;
    gap: 1.25rem;
    margin-bottom: clamp(1.5rem, 3vw, 2.25rem);
  }

  .title {
    display: grid;
    gap: 1rem;
  }

  h2 {
    font-size: var(--type-section);
  }

  .status {
    max-width: 34rem;
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.6;
    text-wrap: pretty;
  }

  /* One tile, five cells: hairline gaps between them show the tile's line colour. */
  .platforms {
    display: grid;
    gap: 1px;
    border: 1px solid var(--tile-line);
    border-radius: var(--radius-tile);
    background: var(--tile-line);
    overflow: hidden;
  }

  .platforms li {
    display: flex;
  }

  /* Phones: a row per platform, the name and the file on one line, the note under them. */
  .platform {
    display: grid;
    flex: 1;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    gap: 0.3rem 0.75rem;
    padding: 0.9rem 1.1rem;
    background: var(--tile-bg);
    transition:
      background-color var(--motion-fast) var(--ease-standard),
      color var(--motion-fast) var(--ease-standard);
  }

  .platform:hover {
    background: var(--color-surface-container);
  }

  .platform:focus-visible {
    outline-offset: -3px;
  }

  .os {
    font-family: var(--font-display);
    font-size: 1.0625rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  .file {
    overflow: hidden;
    color: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    text-align: end;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .arrow {
    color: var(--color-text-muted);
  }

  .platform:hover .arrow {
    color: var(--color-text);
  }

  .note {
    grid-column: 1 / -1;
    color: var(--color-text-muted);
    font-size: 0.8125rem;
    line-height: 1.5;
    text-wrap: pretty;
  }

  /* This device's platform: the page's one filled button, as Download in the hero. */
  .platform.primary {
    color: #000000;
    background: var(--color-text);
  }

  .platform.primary:hover {
    background: #ffffff;
  }

  .primary .file,
  .primary .note,
  .primary .arrow,
  .platform.primary:hover .arrow {
    color: #3a3a3a;
  }

  @media (min-width: 64rem) {
    .head {
      grid-template-columns: minmax(0, 1fr) minmax(0, 26rem);
      align-items: end;
      gap: 3rem;
    }

    /* Wide screens: the five side by side, each a column that reads top to bottom. */
    .platforms {
      grid-template-columns: repeat(5, minmax(0, 1fr));
    }

    .platform {
      grid-template-columns: minmax(0, 1fr) auto;
      grid-template-rows: auto auto 1fr;
      align-content: start;
      align-items: start;
      gap: 0.4rem 0.75rem;
      padding: 1.25rem 1.25rem 1.4rem;
    }

    .arrow {
      grid-column: 2;
      grid-row: 1;
    }

    /* The file name wraps at its hyphens rather than being cut. */
    .file {
      grid-column: 1 / -1;
      text-align: start;
      white-space: normal;
    }

    .note {
      margin-top: 0.35rem;
    }
  }

  @media print {
    .platform.primary {
      color: inherit;
      background: none;
    }
  }
</style>
