// The companion's `html_render` call in the transcript: while the page streams, its title so far and how much of it
// has arrived; once shown, a title bar (full screen, save as .html) over the page in its frame (PageFrame), or over a
// note and Run when the page was loading when the app last stopped (page_runs.ts). A failed or interrupted call is the
// ordinary tool line.
import { createSignal, Match, onSettled, Show, Switch, untrack, useContext } from "solid-js";
import { saveFile } from "../../../files/save_file";
import { t } from "../../../i18n/i18n";
import { ActivityMark } from "../../../widgets/activity_mark";
import { IconButton, TonalButton } from "../../../widgets/button";
import { Icon } from "../../../widgets/icon";
import { popPage, pushPage } from "../../../widgets/navigator";
import { showSnackBar } from "../../../widgets/snackbar";
import * as Symbols from "../../../widgets/symbols";
import { WindowAppBar } from "../../../window_chrome";
import { PageFrame, type PageFrameProps } from "../../page_frame/page_frame";
import { errorText } from "../chat_header_actions";
import { PageRuns, pageKey } from "./page_runs";
import "./page_view.css";
import { ToolCard } from "./tool_card";
import { pageCall, pageFileName, pageWriting, type ToolData } from "./tool_data";
import { TranscriptStorage } from "./transcript_actions";

export function PageView(props: { data: ToolData }) {
  const storage = useContext(TranscriptStorage);
  // The page's last height: a row built again (scrolled out and back) keeps its size while the page loads anew.
  const heightKey = untrack(() => `transcript-page-height:${props.data.row.key}`);
  const stored = storage.get(heightKey);
  const page = () => pageCall(props.data);
  const status = () => props.data.status;
  return (
    <Switch fallback={<ToolCard data={props.data} />}>
      <Match when={status() === "pending" || status() === "running"}>
        <div class="page-view-bar">
          <ActivityMark color="var(--running)" />
          <span class="page-view-title">{page().title}</span>
          <span class="page-view-writing">{pageWriting(props.data)}</span>
        </div>
      </Match>
      <Match when={status() === "done"}>
        <div class="page-view">
          <div class="page-view-bar">
            <Icon icon={Symbols.web} size={14} />
            <span class="page-view-title">{page().title}</span>
            <span class="page-view-actions">
              <IconButton
                icon={Symbols.fullscreen}
                iconSize={18}
                size={36}
                tooltip={t.transcript.page.fullScreen}
                onClick={() => {
                  const { title, html } = page();
                  void pushPage(() => <PageScreen title={title} html={html} />);
                }}
              />
              <IconButton
                icon={Symbols.download}
                iconSize={18}
                size={36}
                tooltip={t.transcript.page.save}
                onClick={() => savePage(page().title, page().html)}
              />
            </span>
          </div>
          <GuardedFrame
            html={page().html}
            title={page().title}
            initialHeight={typeof stored === "number" ? stored : undefined}
            onHeight={(height) => storage.set(heightKey, height)}
          />
        </div>
      </Match>
    </Switch>
  );
}

/** Offers the page in the platform's save panel as `<title>.html`, through the machine export's save path. */
function savePage(title: string, html: string): void {
  void saveFile(pageFileName(title), html).catch((error: unknown) =>
    showSnackBar(t.transcript.page.saveFailed({ error: errorText(error) }), { error: true }),
  );
}

/** The page over the whole app: titled with its title, back and save in its bar, the page scrolling in its frame. */
function PageScreen(props: { title: string; html: string }) {
  return (
    <div class="page-view-screen">
      <WindowAppBar
        title={props.title}
        onBack={popPage}
        actions={
          <IconButton
            icon={Symbols.download}
            tooltip={t.transcript.page.save}
            onClick={() => savePage(props.title, props.html)}
          />
        }
      />
      <div class="page-view-screen-body">
        <GuardedFrame html={props.html} title={props.title} fill />
      </div>
    </div>
  );
}

const runs = new PageRuns(localStorage);
/**
 * How long after its page loaded a frame keeps the page's run record: a page whose scripts start their work right
 * after loading (a timer, an animation frame) still stops the app within it.
 */
const loadedRunMs = 1000;

/**
 * The page in its frame, unless it was loading when the app last stopped (page_runs.ts): then a note says so and the
 * page runs once the reader asks.
 */
function GuardedFrame(props: PageFrameProps) {
  const key = pageKey(untrack(() => props.html));
  const [paused, setPaused] = createSignal(runs.stoppedLastTime(key));
  return (
    <Show
      when={!paused()}
      fallback={
        <div class={["page-view-paused", { "page-view-paused-fill": props.fill }]}>
          <span class="page-view-paused-note">{t.transcript.page.stopped}</span>
          <TonalButton icon={Symbols.play_arrow} onClick={() => setPaused(false)}>
            {t.transcript.page.run}
          </TonalButton>
        </div>
      }
    >
      <RunningFrame {...props} runKey={key} />
    </Show>
  );
}

/** A page that runs: recorded from before its frame gets it until a second after it loaded, or until the frame goes. */
function RunningFrame(props: PageFrameProps & { runKey: string }) {
  let end = () => {};
  let loaded: number | undefined;
  onSettled(() => {
    end = runs.start(props.runKey);
    return () => {
      clearTimeout(loaded);
      end();
    };
  });
  return (
    <PageFrame
      html={props.html}
      title={props.title}
      initialHeight={props.initialHeight}
      onHeight={props.onHeight}
      onLoaded={() => {
        // The app's own timer: a page that stops the app before it fires keeps its record.
        clearTimeout(loaded);
        loaded = window.setTimeout(() => end(), loadedRunMs);
      }}
      fill={props.fill}
    />
  );
}
