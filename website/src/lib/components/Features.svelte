<script lang="ts">
  import approval from '$lib/assets/approval.webp';
  import piDither from '$lib/assets/pi-dither.png';
  import { REPO_URL } from '$lib/content/downloads';
  import TurnReplay from './TurnReplay.svelte';

  const machines = [
    { name: 'This computer', route: 'Local' },
    { name: 'build-server', route: 'SSH' },
    { name: 'dev-box', route: 'SSH via bastion' },
    { name: 'studio', route: 'Tailscale' },
  ];

  const route = [
    { label: 'This device', text: 'ompanion' },
    { label: 'Jump hosts', text: 'if you use them' },
    { label: 'Your machine', text: 'omp runs here' },
    { label: 'AI providers', text: 'the ones you set up' },
  ];
  const links = ['SSH', 'SSH', 'API'];

  const dock = ['Agent Hub', 'Todos', 'Session tree', 'Files and git diffs', 'Terminal'];
  const settings = ['omp settings', 'Model roles', 'Providers', 'MCP servers', 'Plugins', 'Skills', 'Stats', 'Usage limits'];
</script>

<section id="features" class="page-section features" aria-labelledby="features-title">
  <div class="section-head">
    <p class="mono-label">Features</p>
    <h2 id="features-title" class="display">Drive omp from any screen.</h2>
    <p>Every step of a session as it happens, from whichever device is in your hand.</p>
  </div>

  <div class="grid">
    <article class="tile replay" aria-labelledby="t-replay">
      <p class="mono-label">01 · Chat</p>
      <h3 id="t-replay">Watch the turn, then fold it away.</h3>
      <p class="body">
        Replies stream in with every tool call. A quiet line counts the wait until the first word, and a
        finished turn folds into one line: time, tool calls, files edited.
      </p>
      <div class="visual"><TurnReplay /></div>
    </article>

    <article class="tile machines" aria-labelledby="t-machines">
      <p class="mono-label">02 · Machines</p>
      <h3 id="t-machines">Every machine you own.</h3>
      <ul class="rows">
        {#each machines as machine (machine.name)}
          <li>
            <span class="dot" aria-hidden="true"></span>
            <span class="machine">{machine.name}</span>
            <span class="mono-label kind">{machine.route}</span>
          </li>
        {/each}
      </ul>
      <p class="body">
        This computer on desktop, any SSH host, hosts behind a chain of jump hosts, and Tailscale peers.
      </p>
    </article>

    <article class="tile detached" aria-labelledby="t-detached">
      <p class="mono-label">03 · Sessions</p>
      <h3 id="t-detached">Lock the phone.<br />The turn keeps going.</h3>
      <div class="lanes" aria-hidden="true">
        <span class="mono-label">Machine</span>
        <span class="lane"><span class="fill"></span></span>
        <span class="mono-label">Phone</span>
        <span class="lane phone"><span class="fill"></span></span>
        <span></span>
        <span class="marks mono-label"><span>Locked</span><span>Caught up</span></span>
      </div>
      <p class="body">
        Sessions run detached on the machine. A dropped connection or a closed app does not stop the turn; the
        app reconnects and catches up.
      </p>
    </article>

    <article class="tile route-tile" aria-labelledby="t-route">
      <div class="route-copy">
        <div class="route-title">
          <p class="mono-label">04 · Where it runs</p>
          <h3 id="t-route">The work happens on your machine.</h3>
        </div>
        <p class="body">
          The app talks SSH to your machine. omp runs there and calls the AI providers configured there, with
          your own accounts. Nothing passes through a server of ours.
        </p>
      </div>
      <ol class="route" aria-label="The route of a prompt">
        {#each route as stop, index (stop.label)}
          <li class="stop" class:home={index === 2} style={`--delay: ${index * -0.9}s`}>
            <span class="rail" aria-hidden="true">
              <span class="node"></span>
              {#if index < links.length}
                <span class="wire"><span class="packet"></span></span>
              {/if}
            </span>
            <span class="mono-label">{stop.label}</span>
            <span class="stop-text">{stop.text}</span>
            {#if index < links.length}
              <span class="mono-label via">{links[index]}<span class="visually-hidden"> to</span></span>
            {/if}
          </li>
        {/each}
      </ol>
    </article>

    <article class="tile trust" aria-labelledby="t-trust">
      <p class="mono-label">05 · Privacy</p>
      <h3 id="t-trust" class="display">No account.<br />No daemon.<br />No telemetry.</h3>
      <p class="body">
        Stock omp on the machine, plus a small companion extension the app uploads. No sign-up, no analytics,
        no crash reporting.
      </p>
      <a class="text-link more" href="/privacy">Privacy policy</a>
    </article>

    <article class="tile approve" aria-labelledby="t-approve">
      <p class="mono-label">06 · Approvals</p>
      <h3 id="t-approve">Answer tool calls in the chat.</h3>
      <p class="body">
        Approvals, questions from the ask tool and extension dialogs, inline. On a session open on several
        devices, the first answer settles it everywhere.
      </p>
      <div class="crop">
        <img
          src={approval}
          width="832"
          height="356"
          loading="lazy"
          alt="An approval card in the app: Allow bash? Smoke-testing the staging deploy, the command sh scripts/smoke.sh, and the buttons Approve and Deny."
        />
      </div>
    </article>

    <article class="tile tree" aria-labelledby="t-tree">
      <p class="mono-label">07 · Tree</p>
      <h3 id="t-tree">Branch from any message.</h3>
      <!-- Squares are your messages, circles the replies; the lime one is where the reset happened. -->
      <svg class="branches" viewBox="0 0 250 150" aria-hidden="true">
        <path class="trunk" d="M96 14 V136" />
        <path class="fork" d="M96 62 H140 Q158 62 158 80 V136" pathLength="1" />
        <rect class="node you" x="90" y="8" width="12" height="12" />
        <circle class="node" cx="96" cy="38" r="6" />
        <rect class="node here" x="90" y="56" width="12" height="12" />
        <circle class="node old" cx="96" cy="94" r="6" />
        <rect class="node old" x="90" y="118" width="12" height="12" />
        <circle class="node new" cx="158" cy="98" r="6" />
        <rect class="node new" x="152" y="122" width="12" height="12" />
        <text x="78" y="65" text-anchor="end" class="here-label">Reset here</text>
        <text x="78" y="113" text-anchor="end">Kept</text>
        <text x="176" y="113">Branch</text>
      </svg>
      <p class="body">
        Reset to a message or branch into a new session. The replies left behind stay in the session tree.
      </p>
    </article>

    <article class="tile index" aria-labelledby="t-index">
      <p class="mono-label">08 · Around the chat</p>
      <h3 id="t-index">The rest of omp, a tap away.</h3>
      <div class="lists">
        <div>
          <p class="mono-label">Dock</p>
          <ul>
            {#each dock as item (item)}<li>{item}</li>{/each}
          </ul>
        </div>
        <div>
          <p class="mono-label">Settings</p>
          <ul>
            {#each settings as item (item)}<li>{item}</li>{/each}
          </ul>
        </div>
      </div>
    </article>

    <article class="tile platforms" aria-labelledby="t-platforms">
      <p class="mono-label">09 · Platforms</p>
      <h3 id="t-platforms">One app, five platforms.</h3>
      <div class="layouts" aria-hidden="true">
        <figure class="wide-figure">
          <div class="wide">
            <span class="pane side"><i></i><i></i><i></i></span>
            <span class="pane chat"><i></i><i class="long"></i><i></i><i class="long"></i></span>
            <span class="pane side"><i></i><i></i></span>
          </div>
          <figcaption class="mono-label">Wide window</figcaption>
        </figure>
        <figure>
          <div class="narrow">
            <span class="pane chat"><i></i><i class="long"></i><i></i></span>
          </div>
          <figcaption class="mono-label">Phone</figcaption>
        </figure>
      </div>
      <p class="body">
        macOS, Windows, Linux, iOS and Android. Wide windows show machines, chat and dock side by side; narrow
        ones show one screen at a time.
      </p>
    </article>

    <article class="tile gpl" aria-labelledby="t-gpl">
      <img class="pi" src={piDither} alt="" width="168" height="159" />
      <p class="mono-label">10 · Source</p>
      <h3 id="t-gpl">Open source, GPLv3.</h3>
      <a class="text-link more" href={REPO_URL} target="_blank" rel="noopener noreferrer">Read the source</a>
    </article>
  </div>
</section>

<style>
  /* The hero's foot, where its light dissolves, is already the space above this section. */
  .features {
    padding-top: 0;
  }

  .grid {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: var(--tile-gap);
  }

  .tile {
    position: relative;
    display: flex;
    min-width: 0;
    flex-direction: column;
    gap: 0.9rem;
    border: 1px solid var(--tile-line);
    border-radius: var(--radius-tile);
    padding: var(--tile-pad);
    background: var(--tile-bg);
    overflow: hidden;
  }

  h3 {
    font-family: var(--font-display);
    font-size: var(--type-tile);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.15;
    text-wrap: balance;
  }

  .body {
    color: var(--color-text-muted);
    font-size: 0.9375rem;
    line-height: 1.6;
    text-wrap: pretty;
  }

  .more {
    align-self: flex-start;
    margin-top: auto;
    font-size: 0.9375rem;
    font-weight: 600;
  }

  /* The replay fills whatever height the row gives the tile. */
  .visual {
    display: flex;
    flex: 1;
    min-height: 26rem;
    margin-top: 0.4rem;
  }

  /* 02 — machine rows with their route. */
  .rows {
    display: grid;
    margin-block: 0.2rem 0.4rem;
  }

  .rows li {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    gap: 0.75rem;
    padding-block: 0.7rem;
  }

  .rows li + li {
    border-top: 1px solid var(--tile-line);
  }

  .dot {
    width: 6px;
    height: 6px;
    background: var(--color-emerald);
  }

  .machine {
    overflow: hidden;
    font-size: 0.9375rem;
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .kind {
    white-space: nowrap;
  }

  /* 03 — two lanes: the machine works through the gap in the phone's. */
  .lanes {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    align-items: center;
    gap: 0.9rem 1rem;
    margin-block: 0.4rem;
  }

  .lane {
    position: relative;
    height: 15px;
    /* Scanline cells: 3 px squares, every other row, as in the hero. */
    background: repeating-linear-gradient(90deg, #1a1a1a 0 3px, transparent 3px 6px);
    -webkit-mask-image: repeating-linear-gradient(180deg, #000 0 3px, transparent 3px 6px);
    mask-image: repeating-linear-gradient(180deg, #000 0 3px, transparent 3px 6px);
  }

  .fill {
    position: absolute;
    inset: 0;
    background: repeating-linear-gradient(90deg, var(--color-emerald) 0 3px, transparent 3px 6px);
    animation: run 7s linear infinite;
  }

  .phone .fill {
    /* Dark while the phone is locked, lit again once it has caught up. */
    -webkit-mask-image: linear-gradient(90deg, #000 32%, transparent 32% 64%, #000 64%);
    mask-image: linear-gradient(90deg, #000 32%, transparent 32% 64%, #000 64%);
  }

  /* Under the phone's lane: where it went dark, and where it caught up. */
  .marks {
    position: relative;
    height: 1em;
    margin-top: -0.4rem;
    font-size: 0.5625rem;
  }

  .marks span {
    position: absolute;
    top: 0;
    white-space: nowrap;
  }

  .marks span:first-child {
    left: 48%;
    translate: -50% 0;
  }

  .marks span:last-child {
    right: 0;
    color: var(--color-lime);
  }

  @keyframes run {
    from {
      clip-path: inset(0 100% 0 0);
    }
    82%,
    to {
      clip-path: inset(0 0 0 0);
    }
  }

  /* 04 — the route of a prompt, device to provider: nodes on a rail, a signal running along it. */
  .route-copy,
  .route-title {
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
  }

  .route {
    display: grid;
    margin-top: 1.5rem;
  }

  /* Phones: the rail runs down the left edge. */
  .stop {
    display: grid;
    grid-template-columns: 11px minmax(0, 1fr);
    grid-template-rows: auto auto 1fr;
    column-gap: 1.1rem;
    row-gap: 0.3rem;
  }

  .rail {
    display: flex;
    grid-row: 1 / span 4;
    flex-direction: column;
    align-items: center;
    padding-top: 0.2rem;
  }

  .node {
    width: 11px;
    height: 11px;
    flex-shrink: 0;
    background: var(--color-surface-highest);
  }

  .home .node {
    background: var(--color-lime);
  }

  .home .mono-label:not(.via) {
    color: var(--color-lime);
  }

  .wire {
    position: relative;
    width: 3px;
    min-height: 3.5rem;
    flex: 1;
    margin-block: 6px;
    background: repeating-linear-gradient(180deg, #2e2e2e 0 3px, transparent 3px 6px);
    container-type: size;
  }

  .packet {
    position: absolute;
    top: 0;
    left: 0;
    width: 3px;
    height: 12px;
    background: var(--color-lime);
    animation: down 2.7s steps(16, end) infinite;
    animation-delay: var(--delay);
  }

  .stop-text {
    font-size: 0.9375rem;
    font-weight: 600;
  }

  .via {
    align-self: start;
    padding-block: 0.9rem 1.5rem;
    font-size: 0.5625rem;
  }

  @keyframes down {
    from {
      translate: 0 0;
    }
    to {
      translate: 0 calc(100cqh - 12px);
    }
  }

  @keyframes across {
    from {
      translate: 0 0;
    }
    to {
      translate: calc(100cqw - 12px) 0;
    }
  }

  /* 05 — the promise, as type, on the page's own black. */
  .trust {
    background: var(--color-bg);
  }

  .trust h3 {
    font-size: clamp(2rem, 1.4rem + 2vw, 2.75rem);
    letter-spacing: -0.04em;
    line-height: 1.02;
  }

  /* 06 — the one capture in the grid: a real approval card. */
  .crop {
    margin-top: auto;
    padding-top: 0.5rem;
  }

  .crop img {
    width: 100%;
  }

  /* 07 — a trunk with a fork. */
  .branches {
    width: 100%;
    max-width: 16rem;
    margin-block: 0.25rem 0.5rem;
    overflow: visible;
  }

  .branches path {
    fill: none;
    stroke: var(--color-surface-highest);
    stroke-width: 2;
  }

  .branches .fork {
    stroke: var(--color-emerald);
    stroke-dasharray: 1;
    animation: grow 6s var(--ease-standard) infinite;
  }

  .node {
    fill: var(--color-text);
  }

  .node.old {
    fill: var(--color-surface-highest);
  }

  .node.new {
    fill: var(--color-emerald);
  }

  .node.here {
    fill: var(--color-lime);
  }

  .branches .here-label {
    fill: var(--color-lime);
  }

  .branches text {
    fill: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 9px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }

  @keyframes grow {
    from {
      stroke-dashoffset: 1;
    }
    40%,
    to {
      stroke-dashoffset: 0;
    }
  }

  /* 08 — the dock and the settings, as an index. */
  .lists {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 1.25rem;
    margin-top: 0.25rem;
  }

  .lists ul {
    display: grid;
    gap: 0.4rem;
    margin-top: 0.75rem;
    font-size: 0.9375rem;
  }

  /* 09 — a wide window and a phone, drawn as panes. */
  .layouts {
    display: flex;
    align-items: flex-end;
    gap: 0.9rem;
    margin-block: 0.25rem;
  }

  .layouts figure {
    display: grid;
    gap: 0.6rem;
  }

  .wide-figure {
    flex: 1;
  }

  .wide,
  .narrow {
    display: flex;
    gap: 4px;
    border-radius: 10px;
    padding: 6px;
    background: var(--color-surface-container);
  }

  .wide {
    height: 7rem;
  }

  .narrow {
    width: 4.25rem;
    height: 8.5rem;
    border-radius: 12px;
  }

  .pane {
    display: flex;
    flex-direction: column;
    gap: 6px;
    border-radius: 6px;
    padding: 8px 7px;
    background: #000000;
  }

  .pane.side {
    width: 22%;
  }

  .pane.chat {
    flex: 1;
  }

  .pane i {
    display: block;
    width: 60%;
    height: 3px;
    background: var(--color-surface-highest);
  }

  .pane i.long {
    width: 90%;
  }

  /* 10 — the glyph, dithered on the same cell grid as the hero's light. */
  .pi {
    width: 168px;
    margin-bottom: 0.75rem;
    image-rendering: pixelated;
  }

  @media (min-width: 40rem) {
    .grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
      grid-template-areas:
        'replay replay'
        'machines detached'
        'route route'
        'trust approve'
        'gpl tree'
        'index platforms';
    }

    .replay { grid-area: replay; }
    .machines { grid-area: machines; }
    .detached { grid-area: detached; }
    .route-tile { grid-area: route; }
    .trust { grid-area: trust; }
    .approve { grid-area: approve; }
    .tree { grid-area: tree; }
    .index { grid-area: index; }
    .platforms { grid-area: platforms; }
    .gpl { grid-area: gpl; }

    /* The route runs left to right once there is room for it: each node's wire reaches the next. */
    .route {
      grid-template-columns: repeat(4, minmax(0, 1fr));
    }

    .stop {
      grid-template-columns: minmax(0, 1fr);
      grid-template-rows: auto;
      row-gap: 0.35rem;
      padding-right: 1rem;
    }

    .rail {
      grid-row: auto;
      flex-direction: row;
      margin-bottom: 0.9rem;
      padding-top: 0;
      /* The wire runs on through the column gap to the next node. */
      margin-right: -1rem;
    }

    .wire {
      width: auto;
      height: 3px;
      min-height: 0;
      margin-block: 0;
      margin-inline: 8px;
      background: repeating-linear-gradient(90deg, #2e2e2e 0 3px, transparent 3px 6px);
    }

    .packet {
      width: 12px;
      height: 3px;
      animation-name: across;
    }

    /* The link's name sits on its wire, above it. */
    .via {
      position: absolute;
      top: -1.35rem;
      left: calc(11px + 8px);
      padding: 0;
    }

    .stop {
      position: relative;
    }
  }

  @media (min-width: 64rem) {
    .grid {
      grid-template-columns: repeat(12, minmax(0, 1fr));
      grid-template-areas:
        'replay replay replay replay replay replay replay machines machines machines machines machines'
        'replay replay replay replay replay replay replay detached detached detached detached detached'
        'route route route route route route route route route route route route'
        'trust trust trust trust approve approve approve approve approve gpl gpl gpl'
        'tree tree tree tree index index index index platforms platforms platforms platforms';
    }

    .route-copy {
      display: grid;
      grid-template-columns: minmax(0, 5fr) minmax(0, 6fr);
      align-items: end;
      gap: 3rem;
    }

    .route {
      margin-top: 2.25rem;
    }
  }

  @media print {
    .fill,
    .packet,
    .branches .fork {
      animation: none;
    }
  }
</style>
