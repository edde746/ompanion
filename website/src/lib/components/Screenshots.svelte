<script lang="ts">
  import tabletChat from '$lib/assets/screenshots/tablet-chat.webp?enhanced';
  import phoneApproval from '$lib/assets/screenshots/phone-02-approval.webp?enhanced';
  import phoneTerminal from '$lib/assets/screenshots/phone-05-terminal.webp?enhanced';
  import phoneFiles from '$lib/assets/screenshots/phone-06-files.webp?enhanced';
  import phoneAgents from '$lib/assets/screenshots/phone-07-agents.webp?enhanced';
  import roster from '$lib/assets/crops/roster.webp?enhanced';
  import approvalCard from '$lib/assets/crops/approval-card.webp?enhanced';
  import diff from '$lib/assets/crops/diff.webp?enhanced';
  import SectionHeader from './SectionHeader.svelte';

  // Headlines and sublines are the store listing's own (store/screenshots/captions.json).
  const tablet = {
    src: tabletChat,
    alt: 'ompanion on a tablet: the session list beside a transcript with a running task’s diffs and test output, and the agent roster in the dock.',
    headline: 'Chat with a running task',
    subline: 'Streaming answers, diffs and test runs',
  };

  const phone = [
    {
      src: phoneApproval,
      alt: 'ompanion on a phone: an edit diff and a command output, with an Allow bash? approval answered inline in the chat.',
      headline: 'Approve every tool call',
      subline: 'Read the diff and the command first',
    },
    {
      src: phoneTerminal,
      alt: 'ompanion on a phone: a terminal tab on a machine, showing git status output.',
      headline: 'A real terminal',
      subline: 'The machine’s own shell, over SSH',
    },
    {
      src: phoneFiles,
      alt: 'ompanion on a phone: the Files pane open on a diff of a source file.',
      headline: 'Browse and edit',
      subline: 'Files, search and git diffs',
    },
    {
      src: phoneAgents,
      alt: 'ompanion on a phone: the Agents pane, with each subagent’s task, tokens and tools.',
      headline: 'Subagents at work',
      subline: 'Progress, tokens and transcripts',
    },
  ];

  // Where the magnified crops sit in the capture they came from, in percentages of that image.
  const approvalRegion = { top: '65.9%', left: '0.8%', width: '98.4%', height: '18.6%' };
  const diffRegion = { top: '73.2%', left: '0.8%', width: '98.4%', height: '18.6%' };

  const regionStyle = (region: typeof approvalRegion) =>
    `--marker-top: ${region.top}; --marker-left: ${region.left}; --marker-width: ${region.width}; --marker-height: ${region.height}`;
</script>

<section id="screenshots" class="page-section">
  <SectionHeader
    index="01"
    label="Screenshots"
    heading="Captured from the app."
    description="Real captures from the shipped app, on a tablet and on a phone."
  />

  <figure class="tablet">
    <div class="tablet-stage">
      <div class="frame tablet-frame">
        <span class="rim" aria-hidden="true"></span>
        <enhanced:img
          src={tablet.src}
          alt={tablet.alt}
          sizes="(min-width: 62rem) 710px, 96vw"
          loading="lazy"
          decoding="async"
        />
        <span
          class="marker marker-roster"
          aria-hidden="true"
          style="--marker-top: 9.6%; --marker-left: 73.5%; --marker-width: 26.5%; --marker-height: 33.8%"
        ></span>
      </div>

      <div class="rail" aria-hidden="true">
        <span class="node"></span>
        <span class="node node-end"></span>
      </div>

      <div class="callout">
        <div class="frame callout-frame">
          <span class="rim" aria-hidden="true"></span>
          <enhanced:img
            src={roster}
            alt="The dock, magnified: the agent roster, with each subagent’s task, tokens and tools."
            sizes="(min-width: 62rem) 272px, 70vw"
            loading="lazy"
            decoding="async"
          />
        </div>
        <p class="mono-label">Detail · Agent roster</p>
      </div>
    </div>

    <figcaption>
      <strong>{tablet.headline}</strong>
      <span>{tablet.subline}</span>
    </figcaption>
  </figure>

  <div class="phone-strip">
    {#each phone as shot (shot.headline)}
      <figure>
        <div class="frame">
          <span class="rim" aria-hidden="true"></span>
          <enhanced:img
            src={shot.src}
            alt={shot.alt}
            sizes="(min-width: 62rem) 260px, 75vw"
            loading="lazy"
            decoding="async"
          />
        </div>
        <figcaption>
          <strong>{shot.headline}</strong>
          <span>{shot.subline}</span>
        </figcaption>
      </figure>
    {/each}
  </div>

  <div class="details">
    <figure class="detail">
      <div class="frame detail-source">
        <enhanced:img src={phoneApproval} alt="" aria-hidden="true" sizes="120px" loading="lazy" decoding="async" />
        <span class="marker" aria-hidden="true" style={regionStyle(approvalRegion)}></span>
      </div>
      <div class="rail" aria-hidden="true">
        <span class="node"></span>
        <span class="node node-end"></span>
      </div>
      <div class="frame detail-crop">
        <span class="rim" aria-hidden="true"></span>
        <enhanced:img
          src={approvalCard}
          alt="The Allow bash? approval card, magnified: the question, the command it runs, and the Approve and Deny buttons."
          sizes="(min-width: 62rem) 380px, 62vw"
          loading="lazy"
          decoding="async"
        />
      </div>
      <figcaption>
        <span class="mono-label">Detail · Approval card</span>
        <span>Answered inline in the chat; nothing is modal.</span>
      </figcaption>
    </figure>

    <figure class="detail">
      <div class="frame detail-source">
        <enhanced:img src={phoneFiles} alt="" aria-hidden="true" sizes="120px" loading="lazy" decoding="async" />
        <span class="marker" aria-hidden="true" style={regionStyle(diffRegion)}></span>
      </div>
      <div class="rail" aria-hidden="true">
        <span class="node"></span>
        <span class="node node-end"></span>
      </div>
      <div class="frame detail-crop fold" style="--fold: var(--color-bg)">
        <span class="rim" aria-hidden="true"></span>
        <enhanced:img
          src={diff}
          alt="A git diff from the Files pane, magnified: context lines and the lines the agent added."
          sizes="(min-width: 62rem) 380px, 62vw"
          loading="lazy"
          decoding="async"
        />
      </div>
      <figcaption>
        <span class="mono-label">Detail · Git diff</span>
        <span>Word-level diffs in every edit tool card, and in the Files pane.</span>
      </figcaption>
    </figure>
  </div>
</section>

<style>
  .tablet-stage {
    position: relative;
    display: grid;
    grid-template-columns: 1fr;
  }

  .tablet-frame {
    border-radius: var(--radius-lg);
  }

  .callout {
    justify-self: center;
    width: 72%;
    margin-top: 1.75rem;
  }

  .callout p {
    margin-top: 0.75rem;
  }

  .callout-frame,
  .detail-crop {
    box-shadow:
      0 20px 44px rgb(0 0 0 / 0.85),
      0 0 0 1px rgb(237 237 237 / 0.07);
  }

  /* The link between a marked region and the magnified crop of it. */
  .rail {
    position: relative;
    height: 2px;
    background: var(--signal);
  }

  .rail .node {
    position: absolute;
    top: 50%;
    left: 0;
    translate: 0 -50%;
  }

  .rail .node-end {
    right: 0;
    left: auto;
    background: var(--color-emerald);
  }

  figcaption {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    padding: 0.875rem 1rem 1rem;
  }

  figcaption strong {
    font-family: var(--font-display);
    font-size: 0.9375rem;
    font-weight: 700;
    letter-spacing: -0.01em;
  }

  figcaption span {
    color: var(--color-text-muted);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  /* The section's own captions sit under an image, not in a card. */
  .tablet figcaption,
  .phone-strip figcaption {
    padding-inline: 0;
  }

  /* A scroll-snap strip on narrow screens; four equal columns once there is room. */
  .phone-strip {
    display: flex;
    gap: 1rem;
    overflow-x: auto;
    margin: 2.5rem calc(var(--page-gutter) * -1) 0;
    padding: 0.25rem var(--page-gutter);
    scroll-padding-inline: var(--page-gutter);
    scroll-snap-type: x mandatory;
  }

  .phone-strip figure {
    flex: 0 0 clamp(10rem, 75vw, 19rem);
    scroll-snap-align: center;
  }

  /* The two magnified crops, each beside the region it was taken from. */
  .details {
    display: grid;
    gap: 2.5rem;
    margin-top: clamp(2.5rem, 6vw, 4rem);
  }

  .detail {
    display: grid;
    grid-template-columns: 6rem 1.5rem minmax(0, 1fr);
    align-items: center;
  }

  .detail-source {
    border-radius: 8px;
  }

  .detail figcaption {
    grid-column: 1 / -1;
    gap: 0.35rem;
    padding: 1rem 0 0;
  }

  @media (max-width: 61.99rem) {
    /* Stacked, the tablet's link runs down the page to the crop below it. */
    .tablet-stage .rail {
      justify-self: center;
      width: 2px;
      height: 2.5rem;
      background: linear-gradient(180deg, var(--color-lime), var(--color-emerald));
    }

    .tablet-stage .rail .node {
      top: 0;
      left: 50%;
      translate: -50% 0;
    }

    .tablet-stage .rail .node-end {
      top: auto;
      right: auto;
      bottom: 0;
      left: 50%;
    }
  }

  @media (min-width: 62rem) {
    /* The tablet keeps 65 % of the width and the magnified roster 25 %: a 1.45x crop of the pane.
       The link sits on the marked region's own centre line, so it is placed against the frame. */
    .tablet-stage {
      display: block;
      position: relative;
    }

    .tablet-frame {
      width: 65%;
    }

    .tablet-stage .rail {
      position: absolute;
      top: 26.5%;
      right: 25%;
      left: 65%;
      height: 2px;
    }

    .callout {
      position: absolute;
      top: 26.5%;
      right: 0;
      width: 25%;
      margin-top: 0;
      /* Half of the card, less the caption under it, so the crop's middle meets the rail. */
      translate: 0 calc(-50% + 0.5rem);
    }

    .phone-strip {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      overflow: visible;
      margin-inline: 0;
      padding-inline: 0;
    }

    .phone-strip figure {
      min-width: 0;
    }

    .details {
      grid-template-columns: repeat(2, 1fr);
      gap: 2rem;
    }

    .detail {
      grid-template-columns: 7.5rem 2.5rem minmax(0, 1fr);
    }
  }
</style>
