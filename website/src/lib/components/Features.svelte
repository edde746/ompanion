<script lang="ts">
  import { features } from '$lib/content/features';
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="features" class="page-section">
  <SectionHeader
    label="Features"
    heading="Everything omp does, in a window."
    description="The same surface on every platform, from the transcript to the machines behind it."
  />

  <ul class="feature-grid">
    {#each features as feature (feature.title)}
      <li class="card">
        <img src={feature.icon} alt="" width="22" height="22" />
        <h3>{feature.title}</h3>
        <p>{feature.body}</p>
      </li>
    {/each}
  </ul>
</section>

<style>
  .feature-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 16rem), 1fr));
    gap: 1rem;
  }

  li {
    padding: 1.25rem;
  }

  h3 {
    margin: 1rem 0 0.5rem;
    font-family: var(--font-display);
    font-size: 1.125rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  p {
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.65;
  }
</style>
