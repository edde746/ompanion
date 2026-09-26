<script lang="ts">
  import PageMetadata from '$lib/components/PageMetadata.svelte';
  import Header from '$lib/components/Header.svelte';
  import Hero from '$lib/components/Hero.svelte';
  import Screenshots from '$lib/components/Screenshots.svelte';
  import Features from '$lib/components/Features.svelte';
  import HowItWorks from '$lib/components/HowItWorks.svelte';
  import Download from '$lib/components/Download.svelte';
  import PrivacySummary from '$lib/components/PrivacySummary.svelte';
  import OpenSource from '$lib/components/OpenSource.svelte';
  import Footer from '$lib/components/Footer.svelte';
  import { SITE_URL } from '$lib/content/downloads';

  const title = 'ompanion — a client for omp, on machines you own';
  const description =
    'ompanion drives omp (oh-my-pi), the open-source coding agent, over SSH on your own machines, from macOS, Windows, Linux, iOS and Android. No account and no daemon on the machine.';
  const url = `${SITE_URL}/`;
</script>

<PageMetadata {title} {description} {url} />

<Header />

<main>
  <Hero />
  <Screenshots />
  <Features />
  <HowItWorks />
  <Download />
  <PrivacySummary />
  <OpenSource />
</main>

<Footer />
