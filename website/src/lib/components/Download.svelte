<script lang="ts">
  import { BUILD_FROM_SOURCE_URL, downloads, RELEASES_PAGE_URL } from '$lib/content/downloads';
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="download" class="page-section">
  <SectionHeader
    label="Download"
    heading="Free, and yours to build."
    description="Each release on GitHub carries these five files."
  />

  <ul class="download-list">
    {#each downloads as download (download.file)}
      <li>
        <div class="download-text">
          <h3>{download.platform}</h3>
          <p>{download.detail}</p>
          <p class="file">{download.file}</p>
        </div>
        <a class="bar bar-primary" href={download.url} aria-label={`Download ${download.file}`}>Download</a>
      </li>
    {/each}
  </ul>

  <p class="note">
    There is no App Store or Google Play listing yet: the Android APK and the iOS IPA above are the builds.
    Every file is on the <a href={RELEASES_PAGE_URL} target="_blank" rel="noopener noreferrer">releases page</a>
    when a release is published, and you can
    <a href={BUILD_FROM_SOURCE_URL} target="_blank" rel="noopener noreferrer">build from source</a> today.
  </p>
</section>

<style>
  .download-list {
    display: grid;
    gap: 0.75rem;
  }

  li {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    border-radius: var(--radius-card);
    padding: 1rem 1.25rem;
    background: var(--color-surface-container);
  }

  h3 {
    font-family: var(--font-display);
    font-size: 1.0625rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }

  p {
    margin-top: 0.25rem;
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.6;
  }

  .file {
    color: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  .note {
    max-width: 46rem;
    margin-top: 1.5rem;
    font-size: 0.9375rem;
    line-height: 1.7;
  }

  .note a {
    text-decoration: underline;
    text-underline-offset: 0.2em;
  }
</style>
