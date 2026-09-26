<script lang="ts">
  import { REPO_URL } from '$lib/content/downloads';
  import Logo from './Logo.svelte';
</script>

<header class="site-header">
  <div class="header-inner">
    <a class="brand" href="/">
      <Logo size={26} />
      <span>ompanion</span>
    </a>
    <nav aria-label="Main">
      <a href="#features">Features</a>
      <a href="#download">Download</a>
      <a href="/privacy">Privacy</a>
      <a href={REPO_URL} target="_blank" rel="noopener noreferrer">GitHub</a>
    </nav>
  </div>
</header>

<style>
  .site-header {
    position: sticky;
    z-index: 10;
    top: 0;
    background: rgb(0 0 0 / 0.85);
    backdrop-filter: blur(12px);
  }

  .header-inner {
    display: flex;
    width: min(100%, var(--page-width));
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.25rem 1rem;
    margin-inline: auto;
    padding: 0.75rem var(--page-gutter);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-family: var(--font-display);
    font-size: 1.0625rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  nav {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.8125rem;
    font-weight: 600;
  }

  nav a {
    border-radius: var(--radius-full);
    padding: 0.5rem 0.75rem;
    color: var(--color-text-muted);
    transition: color var(--motion-fast) var(--ease-standard);
  }

  nav a:hover,
  nav a:focus-visible {
    color: var(--color-text);
  }
</style>
