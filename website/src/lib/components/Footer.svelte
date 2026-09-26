<script lang="ts">
  import { ISSUES_URL, LICENSE_URL, OMP_URL, REPO_URL } from '$lib/content/downloads';
  import Logo from './Logo.svelte';
</script>

<footer class="site-footer">
  <div class="footer-inner">
    <div class="footer-brand">
      <Logo size={24} />
      <span>ompanion</span>
    </div>

    <nav aria-label="Footer">
      <a href="/privacy">Privacy</a>
      <a href={REPO_URL} target="_blank" rel="noopener noreferrer">Source</a>
      <a href={ISSUES_URL} target="_blank" rel="noopener noreferrer">Issues</a>
      <a href={OMP_URL} target="_blank" rel="noopener noreferrer">omp</a>
      <a href={LICENSE_URL} target="_blank" rel="noopener noreferrer">GPLv3</a>
    </nav>
  </div>

  <p class="copyright">© 2026 Edvard Wikhall</p>
</footer>

<style>
  .site-footer {
    padding: clamp(2.5rem, 6vw, 4rem) var(--page-gutter) clamp(2rem, 4vw, 3rem);
  }

  .footer-inner {
    display: flex;
    width: min(100%, var(--page-width));
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    margin-inline: auto;
  }

  .footer-brand {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-family: var(--font-display);
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  nav {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem 1.25rem;
    color: var(--color-text-muted);
    font-size: 0.8125rem;
    font-weight: 600;
  }

  nav a:hover,
  nav a:focus-visible {
    color: var(--color-text);
  }

  .copyright {
    width: min(100%, var(--page-width));
    margin: 1.5rem auto 0;
    color: var(--color-text-muted);
    font-size: 0.8125rem;
  }
</style>
