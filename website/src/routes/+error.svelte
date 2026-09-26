<script lang="ts">
  import { page } from '$app/state';
</script>

<main class="error-page">
  <h1>{page.status}</h1>
  <p>{page.error?.message ?? 'Something went wrong.'}</p>
  <a class="bar bar-primary" href="/">Landing page</a>
</main>

<style>
  .error-page {
    display: flex;
    min-height: 100dvh;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 1rem;
    padding: var(--page-gutter);
    text-align: center;
  }

  h1 {
    font-family: var(--font-display);
    font-size: clamp(2rem, 8vw, 3.5rem);
    font-weight: 700;
    letter-spacing: -0.04em;
  }

  p {
    max-width: 34rem;
    color: var(--color-text-muted);
    line-height: 1.7;
  }
</style>
