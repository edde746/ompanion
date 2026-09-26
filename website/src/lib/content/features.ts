import type { Picture } from '@sveltejs/enhanced-img';
import chat from '$lib/assets/icons/chat.svg';
import configuration from '$lib/assets/icons/configuration.svg';
import dock from '$lib/assets/icons/dock.svg';
import machines from '$lib/assets/icons/machines.svg';
import platform from '$lib/assets/icons/platform.svg';
import sessions from '$lib/assets/icons/sessions.svg';
import tools from '$lib/assets/icons/tools.svg';
import usage from '$lib/assets/icons/usage.svg';
import transcriptCrop from '$lib/assets/crops/transcript.webp?enhanced';
import machinesCrop from '$lib/assets/crops/machines.webp?enhanced';

export type Feature = {
  icon: string;
  title: string;
  body: string;
  /** The two large cards carry a real crop of the app; the rest carry their icon alone. */
  crop?: { src: Picture; alt: string };
};

// One card per feature group in the README. Every claim is a line of that file or of the store copy;
// desktop-only items say so. The two cards with a crop come first: they set the row the rest sit under.
export const features: Feature[] = [
  {
    icon: chat,
    title: 'Chat & transcript',
    body: 'A streaming transcript with markdown, LaTeX math, highlighted code, collapsible thinking and images. Steer the running turn or queue the next one, and fold a finished turn under its one-line summary.',
    crop: {
      src: transcriptCrop,
      alt: 'A transcript, magnified: the answer, the files the turn changed, and a highlighted code block.',
    },
  },
  {
    icon: machines,
    title: 'Machines',
    body: 'This computer on desktop, any SSH host, hosts behind a chain of jump hosts, and Tailscale peers. Sessions run detached on the machine, so a dropped connection or a locked phone does not stop the turn.',
    crop: {
      src: machinesCrop,
      alt: 'The machine list, magnified: two machines, the projects on them and their sessions, one of them waiting for an answer.',
    },
  },
  {
    icon: tools,
    title: 'Tools & approvals',
    body: 'Tool cards for bash, read, edit and write with word-level diffs, plus eval, todo, task, web search and fetch. Approvals and the ask tool are answered inline in the chat.',
  },
  {
    icon: sessions,
    title: 'Sessions & branching',
    body: 'Every session on a machine, grouped by project and marked working, waiting for input or unread. Search them, resume one started in omp’s terminal UI, or branch from any message in the tree.',
  },
  {
    icon: dock,
    title: 'Dock',
    body: 'Agent Hub with each subagent’s transcript and progress, todos by phase, the session tree, a file browser and editor with git diffs, and terminal tabs on the machine.',
  },
  {
    icon: configuration,
    title: 'Configuration',
    body: 'omp’s own settings schema, global or per project, with search and value provenance. Model roles, providers, MCP servers, plugins, skills and usage, all from the app.',
  },
  {
    icon: usage,
    title: 'Usage',
    body: 'Subscription limits from every online machine in one place, one entry per account, with reset times, account priority and disabled credentials.',
  },
  {
    icon: platform,
    title: 'Platform & design',
    body: 'One Flutter codebase for macOS, Windows, Linux, iOS and Android. Monochrome, flat, OLED black, with a light theme. Wide windows show machines, chat and dock side by side.',
  },
];
