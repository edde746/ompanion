<script lang="ts" module>
  // The app's own glyph, from assets/ompanion_glyph.svg: three capsules that read as a pi.
  const GLYPH =
    'M268.2 340.25 C268.2 308.63 293.83 283 325.45 283 L698.55 283 C730.17 283 755.8 308.63 755.8 340.25 L755.8 340.25 C755.8 371.87 730.17 397.5 698.55 397.5 L325.45 397.5 C293.83 397.5 268.2 371.87 268.2 340.25 Z M342.4 340.25 C342.4 308.63 368.03 283 399.65 283 L399.65 283 C431.27 283 456.9 308.63 456.9 340.25 L456.9 594.65 C456.9 626.27 431.27 651.9 399.65 651.9 L399.65 651.9 C368.03 651.9 342.4 626.27 342.4 594.65 Z M567.1 340.25 C567.1 308.63 592.73 283 624.35 283 L624.35 283 C655.97 283 681.6 308.63 681.6 340.25 L681.6 683.75 C681.6 715.37 655.97 741 624.35 741 L624.35 741 C592.73 741 567.1 715.37 567.1 683.75 Z';
</script>

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

    <nav class="mono-label" aria-label="Footer">
      <a href="/privacy">Privacy</a>
      <a href={REPO_URL} target="_blank" rel="noopener noreferrer">Source</a>
      <a href={ISSUES_URL} target="_blank" rel="noopener noreferrer">Issues</a>
      <a href={OMP_URL} target="_blank" rel="noopener noreferrer">omp</a>
      <a href={LICENSE_URL} target="_blank" rel="noopener noreferrer">GPLv3</a>
    </nav>
  </div>

  <p class="copyright">© 2026 Edvard Wikhall</p>

  <!-- The glyph once, as an outline, off the page's corner. -->
  <svg class="watermark" viewBox="0 0 1024 1024" aria-hidden="true" focusable="false">
    <defs>
      <linearGradient id="glyph-outline" gradientUnits="userSpaceOnUse" x1="268" y1="283" x2="756" y2="741">
        <stop offset="0" stop-color="#C4F042" />
        <stop offset="1" stop-color="#22C55E" />
      </linearGradient>
      <!-- The glyph less the same glyph at 94 %, so only its silhouette's edge is left. -->
      <mask id="glyph-ring">
        <path d={GLYPH} fill="#ffffff" />
        <path d={GLYPH} fill="#000000" transform="matrix(0.94 0 0 0.94 30.72 30.72)" />
      </mask>
    </defs>
    <path d={GLYPH} fill="url(#glyph-outline)" mask="url(#glyph-ring)" />
  </svg>
</footer>

<style>
  .site-footer {
    position: relative;
    padding: clamp(3rem, 6vw, 4.5rem) var(--page-gutter) clamp(2.5rem, 5vw, 3.5rem);
    overflow: hidden;
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

  .watermark {
    position: absolute;
    z-index: -1;
    right: -2.5rem;
    bottom: -3.5rem;
    width: 14rem;
    opacity: 0.055;
  }
</style>
