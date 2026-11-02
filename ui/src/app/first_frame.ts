// The app frame's first render, kept for the next launch: first_frame_restore.js, inline in index.html, paints it
// while that launch's code loads, when what this render read is unchanged (docs/research/web-ui/startup.md). It holds
// no data from the core: it is taken before the core first answers.
declare global {
  interface Window {
    /** Set by first_frame_restore.js, which index.html runs; absent on iOS and elsewhere (tests, the dev galleries). */
    ompFirstFrame?: {
      readonly key: string;
      /** What the app's first render reads, as one string. */
      inputs(): string;
      /** The kept frame as the script read it. */
      readonly saved: string | null;
      /** Whether the script put the kept frame in #root. */
      readonly shown: boolean;
      /** The kept frame's first animation frame callback (performance.now()); undefined until then or when not shown. */
      readonly frameAt: number | undefined;
      /** The task right after that frame painted (performance.now()). */
      readonly paintedAt: number | undefined;
    };
  }
}

/** Empties `root` of the kept frame, for the app's own first render. */
export function clearFirstFrame(root: HTMLElement): void {
  if (window.ompFirstFrame?.shown) root.replaceChildren();
}

/**
 * Takes the frame `root` holds right after the app's first render, with the attributes it set on the document, and
 * returns what stores it for the next launch: call that once the frame painted, off the first frame's path.
 */
export function takeFirstFrame(root: HTMLElement): () => void {
  const first = window.ompFirstFrame;
  if (first === undefined) return () => undefined;
  const text = JSON.stringify({
    inputs: first.inputs(),
    attributes: [...document.documentElement.attributes].map((attribute) => [attribute.name, attribute.value]),
    html: root.innerHTML,
  });
  return () => {
    if (text !== first.saved) localStorage.setItem(first.key, text);
  };
}
