<script lang="ts">
  import tabletChat from '$lib/assets/screenshots/tablet-chat.webp?enhanced';
  import phoneApproval from '$lib/assets/screenshots/phone-02-approval.webp?enhanced';
  import phoneTerminal from '$lib/assets/screenshots/phone-05-terminal.webp?enhanced';
  import phoneFiles from '$lib/assets/screenshots/phone-06-files.webp?enhanced';
  import phoneAgents from '$lib/assets/screenshots/phone-07-agents.webp?enhanced';
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
</script>

<section id="screenshots" class="page-section">
  <SectionHeader
    label="Screenshots"
    heading="Captured from the app."
    description="Real captures from the shipped app, on a tablet and on a phone."
  />

  <figure class="tablet">
    <enhanced:img
      src={tablet.src}
      alt={tablet.alt}
      sizes="(min-width: 1180px) 1088px, 96vw"
      loading="lazy"
      decoding="async"
    />
    <figcaption>
      <strong>{tablet.headline}</strong>
      <span>{tablet.subline}</span>
    </figcaption>
  </figure>

  <div class="phone-strip">
    {#each phone as shot (shot.headline)}
      <figure>
        <enhanced:img
          src={shot.src}
          alt={shot.alt}
          sizes="(min-width: 62rem) 260px, 75vw"
          loading="lazy"
          decoding="async"
        />
        <figcaption>
          <strong>{shot.headline}</strong>
          <span>{shot.subline}</span>
        </figcaption>
      </figure>
    {/each}
  </div>
</section>

<style>
  .tablet {
    border-radius: var(--radius-card);
    background: var(--color-surface-container);
    overflow: hidden;
  }

  .tablet :global(img),
  .phone-strip :global(img) {
    width: 100%;
    height: auto;
  }

  /* A scroll-snap strip on narrow screens; four equal columns once there is room. */
  .phone-strip {
    display: flex;
    gap: 1rem;
    overflow-x: auto;
    margin: 1rem calc(var(--page-gutter) * -1) 0;
    padding: 0.25rem var(--page-gutter);
    scroll-padding-inline: var(--page-gutter);
    scroll-snap-type: x mandatory;
  }

  .phone-strip figure {
    flex: 0 0 clamp(10rem, 75vw, 19rem);
    scroll-snap-align: center;
    border-radius: var(--radius-card);
    background: var(--color-surface-container);
    overflow: hidden;
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

  @media (min-width: 62rem) {
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
  }
</style>
