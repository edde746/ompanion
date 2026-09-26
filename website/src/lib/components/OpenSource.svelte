<script lang="ts">
  import { LICENSE_EXCEPTION_URL, LICENSE_URL, OMP_URL, REPO_URL } from '$lib/content/downloads';
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="open-source" class="page-section">
  <SectionHeader
    label="Open source"
    heading="GPLv3, with a store exception."
    description="The whole app, the SSH and RPC layer, and the companion extension are in one repository."
  />

  <div class="columns">
    <p>
      ompanion is free software under the GNU General Public License, version 3. An additional permission
      under section 7 allows it to be conveyed through app stores whose terms add restrictions the GPL does
      not allow, as long as the source stays available under the GPLv3. Downstream distributors may drop that
      permission and use the plain GPLv3.
    </p>
    <p>
      It drives <a href={OMP_URL} target="_blank" rel="noopener noreferrer">omp (oh-my-pi)</a>, the open-source
      coding agent by can1357, and is not affiliated with it. No third-party GPL or AGPL code ships in any
      build.
    </p>
  </div>

  <ul class="links">
    <li><a class="bar bar-secondary" href={REPO_URL} target="_blank" rel="noopener noreferrer">Source code</a></li>
    <li><a class="bar bar-secondary" href={LICENSE_URL} target="_blank" rel="noopener noreferrer">LICENSE</a></li>
    <li>
      <a class="bar bar-secondary" href={LICENSE_EXCEPTION_URL} target="_blank" rel="noopener noreferrer">
        Licence exception
      </a>
    </li>
  </ul>
</section>

<style>
  .columns {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 22rem), 1fr));
    gap: 1rem 2rem;
    max-width: 60rem;
  }

  p {
    color: var(--color-text-muted);
    font-size: 1rem;
    line-height: 1.7;
  }

  p a {
    color: var(--color-text);
    text-decoration: underline;
    text-decoration-color: var(--color-text-muted);
    text-underline-offset: 0.2em;
  }

  p a:hover,
  p a:focus-visible {
    text-decoration-color: var(--color-text);
  }

  .links {
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem;
    margin-top: 1.75rem;
  }
</style>
