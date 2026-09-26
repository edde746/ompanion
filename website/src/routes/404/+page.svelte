<script lang="ts">
  import PageMetadata from '$lib/components/PageMetadata.svelte';
  import Logo from '$lib/components/Logo.svelte';
  import { SITE_URL } from '$lib/content/downloads';

  const title = 'Page not found — ompanion';
  const description = 'That page does not exist. The ompanion landing page and privacy policy do.';
</script>

<PageMetadata {title} {description} url={`${SITE_URL}/404`} />

<main class="not-found">
  <a class="brand" href="/">
    <Logo size={28} />
    <span>ompanion</span>
  </a>
  <h1>Page not found</h1>
  <p>That page does not exist. Try the landing page, or the privacy policy.</p>
  <div class="links">
    <a class="bar bar-primary" href="/">Landing page</a>
    <a class="bar bar-secondary" href="/privacy">Privacy policy</a>
  </div>
</main>

<style>
  .not-found {
    display: flex;
    min-height: 100dvh;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 1rem;
    padding: var(--page-gutter);
    text-align: center;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-family: var(--font-display);
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  h1 {
    margin-top: 0.5rem;
    font-family: var(--font-display);
    font-size: clamp(1.75rem, 6vw, 2.75rem);
    font-weight: 700;
    letter-spacing: -0.04em;
  }

  p {
    max-width: 34rem;
    color: var(--color-text-muted);
    line-height: 1.7;
  }

  .links {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 0.75rem;
    margin-top: 0.5rem;
  }
</style>
