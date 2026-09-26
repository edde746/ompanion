<script lang="ts">
  import { features } from '$lib/content/features';
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="features" class="page-section">
  <SectionHeader
    index="02"
    label="Features"
    heading="Everything omp does, in a window."
    description="The same surface on every platform, from the transcript to the machines behind it."
  />

  <ul class="bento">
    {#each features as feature (feature.title)}
      <li class:large={Boolean(feature.crop)}>
        <div class="tile">
          <img src={feature.icon} alt="" width="22" height="22" />
        </div>
        <h3>{feature.title}</h3>
        <p>{feature.body}</p>
        {#if feature.crop}
          <div class="crop frame fold">
            <span class="rim" aria-hidden="true"></span>
            <enhanced:img
              src={feature.crop.src}
              alt={feature.crop.alt}
              sizes="(min-width: 62rem) 545px, 92vw"
              loading="lazy"
              decoding="async"
            />
          </div>
        {/if}
      </li>
    {/each}
  </ul>
</section>

<style>
  .bento {
    display: grid;
    grid-template-columns: 1fr;
    gap: 1rem;
  }

  li {
    display: flex;
    flex-direction: column;
    padding: 1.25rem;
    border-radius: var(--radius-card);
    background: var(--color-surface-container);
    overflow: hidden;
  }

  /* A large card ends on a window onto the app, inset like its text. */
  li.large p {
    margin-bottom: 1.25rem;
  }

  /* The icon tile, with the rim light on hover or when something inside it has focus. */
  .tile {
    position: relative;
    display: grid;
    width: 2.5rem;
    height: 2.5rem;
    place-items: center;
    border-radius: var(--radius);
    background: var(--color-surface-high);
    overflow: hidden;
  }

  .tile::before {
    content: "";
    position: absolute;
    inset: 0 0 auto;
    height: 1.5px;
    background: var(--rim);
    opacity: 0;
    transition: opacity var(--motion-fast) var(--ease-standard);
  }

  li:hover .tile::before,
  li:focus-within .tile::before {
    opacity: 1;
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

  /* A window onto the app, inset like the card's text: its own edge, its top rim-lit, its foot
     folding into the card instead of being cut off. */
  .crop {
    margin: auto 0 0;
    border-radius: 10px;
    border: 1px solid var(--color-surface-highest);
    border-top-color: transparent;
  }

  .crop :global(img) {
    display: block;
    width: 100%;
    height: auto;
  }

  @media (min-width: 40rem) {
    .bento {
      grid-template-columns: repeat(2, 1fr);
    }

    li.large {
      grid-column: span 2;
    }
  }

  @media (min-width: 62rem) {
    .bento {
      grid-template-columns: repeat(6, 1fr);
    }

    li {
      grid-column: span 2;
    }

    li.large {
      grid-column: span 3;
    }
  }
</style>
