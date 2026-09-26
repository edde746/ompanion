<script lang="ts">
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="how-it-works" class="page-section">
  <SectionHeader
    label="How it works"
    heading="It drives omp. It does not replace it."
    description="ompanion is a client: the agent and your accounts stay on the machine you already use."
  />

  <ol class="steps">
    <li>
      <h3>You connect over SSH</h3>
      <p>
        Any host you can reach with <code>ssh</code>: a key, a password, keyboard-interactive, your
        <code>~/.ssh/config</code> entries or an agent. Host keys are checked on every hop, including across a
        chain of jump hosts, and Tailscale peers are dialed by MagicDNS name or 100.x address.
      </p>
    </li>
    <li>
      <h3>omp runs on the machine</h3>
      <p>
        The app runs stock <code>omp</code> there — no daemon is installed. It uploads one small companion
        extension to <code>~/.ompanion/companion/</code>, which omp loads with <code>-e</code> for the events
        omp’s RPC does not expose. Sessions run detached, so a dropped connection or a locked phone does not
        stop the turn.
      </p>
    </li>
    <li>
      <h3>Your accounts stay on the machine</h3>
      <p>
        Prompts travel over SSH to omp, which calls the AI providers you configured there with your own
        credentials. The app never reads them, and there is no server of ours anywhere in the path.
      </p>
    </li>
    <li>
      <h3>Missing omp is installed for you</h3>
      <p>
        Each machine is probed, and omp 18.3.1 or newer is installed on it with a checksum check — or the app
        shows you the commands to run yourself.
      </p>
    </li>
  </ol>
</section>

<style>
  .steps {
    display: grid;
    grid-template-columns: 1fr;
    gap: 1rem;
    counter-reset: step;
    list-style: none;
  }

  @media (min-width: 48rem) {
    .steps {
      grid-template-columns: repeat(2, 1fr);
    }
  }

  li {
    padding: 1.25rem;
    border-radius: var(--radius-card);
    background: var(--color-surface);
    counter-increment: step;
  }

  li::before {
    content: counter(step, decimal-leading-zero);
    color: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  h3 {
    margin: 0.75rem 0 0.5rem;
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

  code {
    color: var(--color-text);
    font-family: var(--font-mono);
    font-size: 0.875em;
  }
</style>
