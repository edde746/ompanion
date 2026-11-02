// Pages pushed over the whole app (Flutter's `Navigator.push` of a MaterialPageRoute): the machine configuration, the
// theme editor, the licenses. Each covers the app, which stays mounted under it and moves as the route below the first
// page (page_stack.tsx); back (on Android with its predictive gesture), the page's own back button, or on iOS a swipe
// from the left edge pops it.
import type { JSX } from "@solidjs/web";
import { createSignal, onSettled } from "solid-js";
import { type Deferred, deferred } from "../../deferred";
import { type BackGesture, onBack } from "../platform";
import { PageStack } from "./page_stack";
import "./navigator.css";

interface Page {
  readonly render: () => JSX.Element;
  readonly done: Deferred<void>;
}

const [pages, setPages] = createSignal<readonly Page[]>([]);
let base: HTMLElement | undefined;
/** The pushed pages' stack's predictive back gesture, once it rendered. */
let gesture: BackGesture | undefined;

/** Shows `render`'s page over the app; resolves once it is popped. */
export function pushPage(render: () => JSX.Element): Promise<void> {
  const page: Page = { render, done: deferred<void>() };
  setPages((list) => [...list, page]);
  return page.done.promise;
}

/** Pops the top page. */
export function popPage(): void {
  const page = pages().at(-1);
  if (!page) return;
  setPages((list) => list.slice(0, -1));
  page.done.resolve();
}

/** Whether a pushed page covers the shell. */
export function pageOpen(): boolean {
  return pages().length > 0;
}

/** `ref={pageBase}` on the app under the pushed pages: it moves as the page under the first one and hides under it. */
export function pageBase(element: HTMLElement): void {
  base = element;
}

function PageLayer(props: { readonly page: Page }) {
  onSettled(() => onBack(popPage, { active: () => pages().at(-1) === props.page, gesture }));
  return <>{props.page.render()}</>;
}

/** Shows the pushed pages; the app renders one, after the app under them. */
export function PageHost() {
  return (
    <PageStack
      class="page-host"
      pageClass={() => "page-layer"}
      pages={pages()}
      base={() => base}
      render={(page) => <PageLayer page={page} />}
      onSwipeBack={popPage}
      gesture={(stack) => (gesture = stack)}
    />
  );
}
