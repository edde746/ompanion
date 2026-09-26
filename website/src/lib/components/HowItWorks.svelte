<script lang="ts">
  import SectionHeader from './SectionHeader.svelte';
</script>

<section id="how-it-works" class="page-section">
  <SectionHeader
    index="03"
    label="How it works"
    heading="It drives omp. It does not replace it."
    description="ompanion is a client: the agent and your accounts stay on the machine you already use."
  />

  <div class="diagram">
    <div class="step">
      <span class="rim" aria-hidden="true"></span>
      <p class="mono-label">01 — Device</p>
      <h3>Your device</h3>
      <p>The app, on macOS, Windows, Linux, iOS and Android.</p>
    </div>

    <div class="edge" aria-hidden="true">
      <span class="rail">
        <span class="node"></span>
        <span class="node node-end"></span>
      </span>
      <span class="mono-label">SSH</span>
    </div>

    <div class="step">
      <span class="rim" aria-hidden="true"></span>
      <p class="mono-label">02 — Machine</p>
      <h3>Your machine</h3>
      <p>
        Stock <code>omp</code> as you have it, plus one companion extension the app uploads and omp loads with
        <code>-e</code>. No daemon, no service. Sessions run detached, so a dropped connection does not stop the
        turn.
      </p>
    </div>

    <div class="edge" aria-hidden="true">
      <span class="rail">
        <span class="node"></span>
        <span class="node node-end"></span>
      </span>
      <span class="mono-label">HTTPS</span>
    </div>

    <div class="step">
      <span class="rim" aria-hidden="true"></span>
      <p class="mono-label">03 — Providers</p>
      <h3>Your AI providers</h3>
      <p>
        Prompted by omp on the machine, with the credentials you configured there. The app never reads them, and
        there is no server of ours in the path.
      </p>
    </div>
  </div>

  <div class="notes">
    <div>
      <p class="mono-label">Reaching a machine</p>
      <p>
        Any host you can reach with <code>ssh</code>: a key, a password, keyboard-interactive, your
        <code>~/.ssh/config</code> entries or an agent. Host keys are checked on every hop, including across a
        chain of jump hosts, and Tailscale peers are dialled by MagicDNS name or 100.x address.
      </p>
    </div>
    <div>
      <p class="mono-label">Missing omp</p>
      <p>
        Each machine is probed, and omp 18.3.1 or newer is installed on it with a checksum check — or the app
        shows you the commands to run yourself.
      </p>
    </div>
  </div>
</section>

<style>
  .diagram {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 0;
  }

  .step {
    position: relative;
    padding: 1.25rem;
    border-radius: var(--radius-card);
    background: var(--color-surface-container);
    overflow: hidden;
  }

  .step h3 {
    margin: 0.6rem 0 0.5rem;
    font-family: var(--font-display);
    font-size: 1.125rem;
    font-weight: 700;
    letter-spacing: -0.02em;
    text-wrap: balance;
  }

  .step p {
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.65;
  }

  code {
    color: var(--color-text);
    font-family: var(--font-mono);
    font-size: 0.875em;
  }

  /* The link between two nodes: a rail with a node at each end and its protocol beside it. */
  .edge {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.85rem;
    min-height: 3.5rem;
  }

  .rail {
    position: relative;
    display: block;
    width: 2px;
    height: 2.25rem;
    background: linear-gradient(180deg, var(--color-lime), var(--color-emerald));
  }

  .rail .node {
    position: absolute;
    top: 0;
    left: 50%;
    translate: -50% 0;
  }

  .rail .node-end {
    top: auto;
    bottom: 0;
    left: 50%;
    translate: -50% 0;
    background: var(--color-emerald);
  }

  .notes {
    display: grid;
    gap: 1.5rem 2rem;
    margin-top: clamp(2rem, 5vw, 3rem);
  }

  .notes p + p {
    margin-top: 0.6rem;
  }

  .notes p:last-child {
    max-width: 44rem;
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.7;
  }

  @media (min-width: 48rem) {
    .notes {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }

  @media (min-width: 62rem) {
    /* Device — ssh — machine — https — providers, one row. */
    .diagram {
      grid-template-columns: minmax(0, 1fr) 6rem minmax(0, 1fr) 6rem minmax(0, 1fr);
      /* One height for all three nodes, so their edges line up. */
      align-items: stretch;
    }

    .edge {
      min-height: 0;
    }

    .rail {
      width: 100%;
      height: 2px;
      background: var(--signal);
    }

    .rail .node {
      top: 50%;
      left: 0;
      translate: 0 -50%;
    }

    .rail .node-end {
      top: 50%;
      right: 0;
      left: auto;
      translate: 0 -50%;
    }

    /* Above the rail, so the word sits on the line without a gap in it. */
    .edge .mono-label {
      position: absolute;
      top: 50%;
      left: 50%;
      translate: -50% calc(-100% - 0.55rem);
    }
  }
</style>
