<script lang="ts">
  // A replay of the turn behind the store screenshots (store/screenshots/demo/turns.ts, session "hero"):
  // the prompt, the quiet waiting line, each interim message with its tool call, then the fold into one
  // summary line and the answer. Everything on screen is a pure function of `clock`, so the page renders
  // the finished turn without JavaScript, in print and with reduced motion, and plays it otherwise.

  type Tool = { name: string; detail: string; runs: number };
  type Step = { text: string; tool: Tool };

  const PROMPT =
    'Add rate limiting to the upload endpoint so one client cannot exhaust the put path, then run the tests.';
  const STEPS: Step[] = [
    { text: 'Reading the upload route before touching it.', tool: { name: 'read', detail: 'src/routes/upload.ts', runs: 500 } },
    { text: 'Planning the change.', tool: { name: 'todo', detail: 'Plan · Implement · Verify', runs: 250 } },
    {
      text: 'The route is a buffer-and-store; the limiter belongs in front of the read.',
      tool: { name: 'todo', detail: 'done · Read the upload route', runs: 250 },
    },
    {
      text: 'Handing three things to subagents: the limiter contract, the README wording and the test names.',
      tool: { name: 'task', detail: 'contract · docs · tests', runs: 1800 },
    },
    {
      text: 'The contract is clear: a token bucket per client, allowance for the route, tooManyRequests for the answer.',
      tool: { name: 'todo', detail: 'done · Read the test that pins the limiter', runs: 250 },
    },
    { text: 'Adding the limiter module.', tool: { name: 'write', detail: 'src/lib/rate-limit.ts', runs: 600 } },
    { text: 'The module is in.', tool: { name: 'todo', detail: 'done · Add the rate-limit module', runs: 250 } },
    {
      text: 'Wiring the route: one import, and a guard before the body is read.',
      tool: { name: 'edit', detail: 'src/routes/upload.ts', runs: 500 },
    },
    { text: 'The guard is in place.', tool: { name: 'todo', detail: 'done · Wire the upload route', runs: 250 } },
    { text: 'Module and route are wired; running the suite.', tool: { name: 'bash', detail: 'npm test', runs: 1500 } },
    { text: 'Green. Writing the summary.', tool: { name: 'todo', detail: 'done · Run the type check and the tests', runs: 250 } },
  ];
  const ANSWER = 'Done. The upload route spends a token before it reads the body.';
  const CHANGES = [
    ['src/lib/rate-limit.ts', 'token bucket per client, 60 a minute'],
    ['src/routes/upload.ts', 'allowance() guard, 429 with Retry-After'],
  ];
  const CODE = [
    'const decision = allowance(request);',
    'if (!decision.allowed) {',
    '  tooManyRequests(response, decision.retryAfterSeconds);',
    '  return;',
    '}',
  ];
  const FILES_EDITED = STEPS.filter((step) => step.tool.name === 'write' || step.tool.name === 'edit').length;

  // The app shows the seconds of a wait from the third one on (lib/screens/chat/transcript/message_rows.dart).
  const COUNT_FROM_S = 3;
  const WAIT_FROM = 300;
  const THINK_FROM = 4400;
  const THINK_MS = 900;
  const TYPE_MS_PER_CHAR = 9;
  // Matches the .work transition below.
  const FOLD_MS = 520;

  // The schedule, in ms from the moment the prompt is sent.
  const schedule = (() => {
    let t = THINK_FROM + THINK_MS;
    const steps = STEPS.map((step) => {
      const at = t;
      const toolAt = at + 350;
      const doneAt = toolAt + step.tool.runs;
      t = doneAt + 250;
      return { ...step, at, toolAt, doneAt };
    });
    const foldAt = t + 300;
    const answerAt = foldAt + FOLD_MS;
    const end = answerAt + (2 + CHANGES.length + CODE.length) * 140;
    return { steps, foldAt, answerAt, end, loop: end + 5000 };
  })();
  const WORKED_S = Math.round(schedule.foldAt / 1000);

  let clock = $state(schedule.end);
  let playing = $state(false);
  let root: HTMLElement | undefined = $state();
  let live: HTMLElement | undefined = $state();

  const typed = (text: string, at: number, c: number) =>
    text.slice(0, Math.max(0, Math.floor((c - at) / TYPE_MS_PER_CHAR)));
  const stepsAt = (c: number) => schedule.steps.filter((step) => c >= step.at);
  const answerLinesAt = (c: number) => (c < schedule.answerAt ? 0 : Math.floor((c - schedule.answerAt) / 140) + 1);

  const folded = $derived(clock >= schedule.foldAt);
  // Changes whenever a row appears: a step's text or its tool call.
  const rows = $derived(stepsAt(clock).reduce((n, step) => n + (clock >= step.toolAt ? 2 : 1), 0));

  // Keep the newest row in view while the turn streams, and the top once it has folded.
  $effect(() => {
    void rows;
    if (!live) return;
    live.scrollTo({ top: folded ? 0 : live.scrollHeight, behavior: 'smooth' });
  });

  $effect(() => {
    if (!root) return;
    const target = root;
    const motion = window.matchMedia('(prefers-reduced-motion: no-preference)');
    let frame = 0;
    let origin = 0;
    let visible = false;

    const tick = (now: number) => {
      if (!origin) origin = now - clock;
      clock = now - origin;
      if (clock >= schedule.loop) {
        origin = now;
        clock = 0;
      }
      frame = requestAnimationFrame(tick);
    };
    const stop = () => {
      cancelAnimationFrame(frame);
      frame = 0;
      origin = 0;
    };
    const update = () => {
      if (!motion.matches) {
        stop();
        playing = false;
        clock = schedule.end;
        return;
      }
      const run = visible && !document.hidden;
      if (run && !frame) {
        // A replay that was showing the finished turn starts over from the prompt.
        if (clock >= schedule.end) clock = 0;
        playing = true;
        frame = requestAnimationFrame(tick);
      } else if (!run && frame) {
        stop();
      }
    };

    const seen = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        update();
      },
      { threshold: 0.35 },
    );
    seen.observe(target);
    document.addEventListener('visibilitychange', update);
    motion.addEventListener('change', update);
    return () => {
      stop();
      seen.disconnect();
      document.removeEventListener('visibilitychange', update);
      motion.removeEventListener('change', update);
    };
  });
</script>

{#snippet transcript(c: number)}
  <p class="prompt">{PROMPT}</p>

  {#if c >= WAIT_FROM && c < THINK_FROM}
    {@const waited = Math.floor((c - WAIT_FROM) / 1000)}
    <p class="waiting">
      <span class="cell"></span>{waited < COUNT_FROM_S ? 'Waiting for a reply' : `Waiting for a reply · ${waited}s`}
    </p>
  {/if}

  {#if c >= schedule.foldAt}
    <p class="summary">
      <span class="facts"
        >Worked for {WORKED_S}s <span>·</span> {STEPS.length} tool calls <span>·</span> {FILES_EDITED} files edited</span
      >
      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"
        ><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5" /></svg
      >
    </p>
  {/if}

  <!-- The work rows go once their fold has played, so the finished turn reads as it does in the app. -->
  {#if c >= THINK_FROM && c < schedule.foldAt + FOLD_MS}
    <div class="work" class:folded={c >= schedule.foldAt}>
      <div class="work-inner">
        <p class="thought">{c < THINK_FROM + THINK_MS ? 'Thinking…' : 'Thought for 1s'}</p>
        {#each stepsAt(c) as step (step.at)}
          <p class="text">{typed(step.text, step.at, c)}</p>
          {#if c >= step.toolAt}
            <p class="tool">
              <span class="status" class:done={c >= step.doneAt}></span>
              <span class="name">{step.tool.name}</span>
              <span class="detail">{step.tool.detail}</span>
            </p>
          {/if}
        {/each}
      </div>
    </div>
  {/if}

  {#if answerLinesAt(c) > 0}
    {@const lines = answerLinesAt(c)}
    <p class="text">{ANSWER}</p>
    {#if lines > 1}
      <dl class="changes">
        {#each CHANGES.slice(0, lines - 1) as [file, change] (file)}
          <div><dt>{file}</dt><dd>{change}</dd></div>
        {/each}
      </dl>
    {/if}
    {#if lines > 1 + CHANGES.length}
      <pre class="code">{CODE.slice(0, lines - 1 - CHANGES.length).join('\n')}</pre>
    {/if}
  {/if}
{/snippet}

<figure class="replay" bind:this={root}>
  <figcaption class="bar">
    <span class="mono-label">~/code/api-server · dev-box</span>
    <span class="mono-label state" class:working={playing && !folded}>
      <span class="dot" aria-hidden="true"></span>{playing && !folded ? 'Working' : 'Done'}
    </span>
  </figcaption>

  <div class="panel">
    <!-- The finished turn: the static state, and the box the replay plays inside. -->
    <div class="layer final" class:ghost={playing}>{@render transcript(schedule.end)}</div>
    {#if playing}
      <div class="layer live" bind:this={live} aria-hidden="true">{@render transcript(clock)}</div>
    {/if}
  </div>

  <div class="composer" aria-hidden="true">
    <span>Message omp</span>
    <span class="send"
      ><svg viewBox="0 0 16 16" width="14" height="14"
        ><path d="M8 13V3M4 7l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.6" /></svg
      ></span
    >
  </div>
</figure>

<style>
  .replay {
    display: flex;
    min-width: 0;
    flex: 1;
    container-type: inline-size;
    flex-direction: column;
    border-radius: 14px;
    background: #000000;
    overflow: hidden;
  }

  .bar {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.8rem 1.1rem;
    background: #070707;
  }

  .bar .mono-label {
    overflow: hidden;
    font-size: 0.625rem;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .state {
    display: inline-flex;
    flex-shrink: 0;
    align-items: center;
    gap: 0.5rem;
  }

  .dot {
    width: 6px;
    height: 6px;
    background: var(--color-emerald);
  }

  .working .dot {
    background: var(--color-lime);
    animation: blink 1s steps(2, jump-none) infinite;
  }

  .panel {
    position: relative;
    display: flex;
    flex: 1;
    flex-direction: column;
    font-size: 0.875rem;
    line-height: 1.5;
  }

  .composer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin: 0 0.75rem 0.75rem;
    border-radius: 14px;
    padding: 0.55rem 0.55rem 0.55rem 0.9rem;
    background: var(--color-surface-container);
    color: var(--color-text-muted);
    font-size: 0.8125rem;
  }

  .send {
    display: grid;
    width: 1.75rem;
    height: 1.75rem;
    place-items: center;
    border-radius: var(--radius-full);
    background: var(--color-text);
    color: #000000;
  }

  .layer {
    display: flex;
    flex-direction: column;
    gap: 0.7rem;
    padding: 1.1rem 1.1rem 1.4rem;
  }

  .layer > *,
  .work-inner > * {
    flex-shrink: 0;
  }

  /* Still read by assistive technology while the replay plays over it. */
  .ghost {
    opacity: 0;
  }

  /* The replay plays over the finished turn, in the same box, and scrolls as rows arrive. */
  .live {
    position: absolute;
    inset: 0;
    overflow: hidden;
    -webkit-mask-image: linear-gradient(180deg, transparent, #000 1.5rem);
    mask-image: linear-gradient(180deg, transparent, #000 1.5rem);
  }

  .prompt {
    align-self: flex-end;
    max-width: 88%;
    border-radius: 14px;
    padding: 0.7rem 0.9rem;
    background: var(--color-surface-high);
    text-wrap: pretty;
  }

  .waiting,
  .summary,
  .thought {
    color: var(--color-text-muted);
    font-size: 0.8125rem;
  }

  .waiting {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }

  .cell {
    width: 6px;
    height: 6px;
    background: var(--color-lime);
    animation: blink 1s steps(2, jump-none) infinite;
  }

  .thought {
    font-style: italic;
  }

  /* One line, as in the app: the facts shorten, the chevron stays. */
  .summary {
    display: flex;
    align-items: center;
    gap: 0.2rem;
  }

  .facts {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .facts span {
    margin-inline: 0.3rem;
    opacity: 0.6;
  }

  .summary svg {
    flex-shrink: 0;
  }

  /* The fold: the work rows collapse to nothing under the summary line. */
  .work {
    display: grid;
    grid-template-rows: 1fr;
    transition:
      grid-template-rows 520ms var(--ease-standard),
      opacity 320ms var(--ease-standard);
  }

  /* Folded, the rows take no room; the negative margin takes back the gap they would leave. */
  .work.folded {
    grid-template-rows: 0fr;
    margin-top: -0.7rem;
    opacity: 0;
  }

  .work-inner {
    display: flex;
    min-height: 0;
    flex-direction: column;
    gap: 0.7rem;
    overflow: hidden;
  }

  .text {
    color: var(--color-text);
    text-wrap: pretty;
  }

  .tool {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 0.6rem;
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }

  .status {
    width: 6px;
    height: 6px;
    flex-shrink: 0;
    background: var(--color-lime);
    animation: blink 0.5s steps(2, jump-none) infinite;
  }

  .status.done {
    background: var(--color-emerald);
    animation: none;
  }

  .name {
    font-weight: 600;
  }

  .detail {
    overflow: hidden;
    color: var(--color-text-muted);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .changes {
    display: grid;
    border-radius: 10px;
    background: var(--color-surface);
    overflow: hidden;
    font-size: 0.8125rem;
  }

  .changes div {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 0.15rem 0.75rem;
    padding: 0.5rem 0.75rem;
  }

  @container (min-width: 30rem) {
    .changes div {
      grid-template-columns: minmax(0, 11rem) minmax(0, 1fr);
    }
  }

  .changes div + div {
    background: var(--color-surface-container);
  }

  dt {
    overflow: hidden;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  dd {
    color: var(--color-text-muted);
  }

  .code {
    margin: 0;
    border-radius: 10px;
    padding: 0.75rem;
    background: var(--color-surface);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    color: var(--color-text);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    line-height: 1.6;
  }

  @keyframes blink {
    to {
      opacity: 0.25;
    }
  }

  @media print {
    .replay,
    .bar,
    .code,
    .changes {
      background: #ffffff;
    }

    .live {
      display: none;
    }
  }
</style>
