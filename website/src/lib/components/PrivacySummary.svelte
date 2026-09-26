<script lang="ts">
  import SectionHeader from './SectionHeader.svelte';

  const points = [
    'There is no account, no sign-up and no service run by us.',
    'The app has no analytics, no crash reporting, no advertising and no tracking of any kind.',
    'Nothing is sent to us, because there is nowhere to send it: the app talks to machines you own, over SSH, and to nothing else on its own.',
    'What you type goes to the agent on your machine, which calls the AI providers you configured there.',
  ];
</script>

<section id="privacy" class="page-section">
  <SectionHeader
    index="05"
    label="Privacy"
    heading="Nothing to collect, nobody to tell."
    description="The short version of the privacy policy, which the App Store, Google Play and the app itself all point to."
  />

  <ul class="points">
    {#each points as point (point)}
      <li>{point}</li>
    {/each}
  </ul>

  <a class="bar bar-secondary" href="/privacy">Read the privacy policy</a>
</section>

<style>
  .points {
    display: grid;
    gap: 0.75rem;
    max-width: 52rem;
    margin-bottom: 1.75rem;
  }

  li {
    position: relative;
    padding-left: 1.5rem;
    color: var(--color-text-muted);
    font-size: 1rem;
    line-height: 1.7;
  }

  li::before {
    content: '';
    position: absolute;
    top: 0.6em;
    left: 0;
    width: 0.5rem;
    height: 2px;
    border-radius: var(--radius-full);
    background: linear-gradient(90deg, var(--color-lime), var(--color-emerald));
  }
</style>
