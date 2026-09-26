<script lang="ts">
  import type { Snippet } from 'svelte';

  const {
    index,
    label,
    heading,
    description,
    children,
  }: { index: string; label: string; heading: string; description: string; children?: Snippet } = $props();
</script>

<div class="section-header">
  <p class="mono-label section-label">
    <span class="index">{index}</span>
    <span aria-hidden="true">—</span>
    <span>{label}</span>
  </p>
  <h2>{heading}</h2>
  <div class="accent-bar"></div>
  <p class="section-description">{description}</p>
  {@render children?.()}
</div>

<style>
  .section-header {
    margin-bottom: clamp(2rem, 5vw, 3.5rem);
  }

  .section-label {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    margin-bottom: 0.9rem;
  }

  .index {
    color: var(--color-text);
  }

  h2 {
    margin-bottom: 1rem;
    font-family: var(--font-display);
    font-size: clamp(1.875rem, 5vw, 3rem);
    font-weight: 700;
    letter-spacing: -0.035em;
    line-height: 1.05;
    text-wrap: balance;
  }

  .section-description {
    max-width: 46rem;
    margin-top: 1.25rem;
    color: var(--color-text-muted);
    font-size: 1.0625rem;
    line-height: 1.7;
  }
</style>
