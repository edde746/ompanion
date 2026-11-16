// Markdown preview of a Files document: TranscriptMarkdown plus Obsidian-flavoured rules, images from the file's
// folder.
import { createEffect, createMemo, createSignal, For, onCleanup, onSettled, Show } from "solid-js";
import { call } from "../../../../bridge";
import type { LiveSession } from "../../../../core/session/live_session";
import { parseFrontmatter } from "../../../../markdown/frontmatter";
import { FilePreviewScope, takePreviewHeading } from "../../../../markdown/preview_scope";
import {
  collectWikiTargets,
  findVaultRoot,
  headingId,
  isMarkdownExtension,
  resolveWikilink,
} from "../../../../markdown/wikilink";
import { useImages, useSessions } from "../../../app_state";
import type { FileDocument } from "../../../files/file_document";
import { baseName, extensionOf, parentPath } from "../../../files/file_paths";
import type { FileWorkspace } from "../../../files/file_workspace";
import { t } from "../../../i18n/i18n";
import type { Machine } from "../../../models/machine";
import { showSnackBar } from "../../../widgets/snackbar";
import { TranscriptMarkdown } from "../../chat/transcript/markdown";
import { type TranscriptActions, TranscriptScope } from "../../chat/transcript/transcript_actions";
import "./file_preview.css";

export function FilePreview(props: {
  readonly workspace: FileWorkspace;
  readonly document: FileDocument;
  readonly machine: Machine;
  readonly session: LiveSession | undefined;
}) {
  const images = useImages();
  const sessions = useSessions();
  const [resolved, setResolved] = createSignal<ReadonlyMap<string, string | undefined>>(new Map());
  let page: HTMLElement | undefined;
  let resolveGen = 0;

  const folder = createMemo(() => parentPath(props.document.path()));
  const text = createMemo(() => {
    props.document.dirty();
    props.document.revision();
    return props.document.text();
  });
  const parsed = createMemo(() => parseFrontmatter(text()));
  const title = () => parsed().matter?.title ?? pageTitle(baseName(props.document.path()));
  const sessionImages = createMemo(() =>
    images.forCwd(props.machine, sessions.runtimeFor(props.machine), {
      cwd: folder(),
      sessionPath: props.session?.sessionPath,
    }),
  );

  const scrollToHeading = (id: string) => {
    if (id === "" || page === undefined) return;
    page.querySelector(`#${CSS.escape(id)}`)?.scrollIntoView({ block: "start" });
  };

  const failed = (error: unknown) => showSnackBar(t.dock.fileBrowser.openFailed({ error: String(error) }));

  const actions = createMemo((): TranscriptActions => {
    const cwd = folder();
    const workspace = props.workspace;
    return {
      canReset: false,
      onCopy: (copied) => {
        void call("shell.clipboardWrite", { text: copied }).then(
          () => showSnackBar(t.common.copied),
          (error: unknown) => failed(error),
        );
      },
      onOpenFile: (path, options) => {
        workspace.resolve(path, { cwd }).then(
          (openPath) => workspace.open(openPath, options).catch(failed),
          (error: unknown) => failed(error),
        );
      },
      onOpenSubagent: () => undefined,
      images: sessionImages(),
    };
  });

  const preview = createMemo(() => ({
    path: props.document.path(),
    resolved: resolved(),
    scrollToHeading,
  }));
  const wikiTargets = createMemo(() => collectWikiTargets(parsed().body));

  createEffect(
    () => [folder(), wikiTargets(), props.workspace, props.workspace.homeDir()] as const,
    ([dir, targets, workspace]) => {
      const gen = ++resolveGen;
      if (targets.length === 0) {
        setResolved(new Map());
        return;
      }
      void resolveAll(workspace, dir, targets).then(
        (map) => {
          if (gen === resolveGen) setResolved(map);
        },
        (error: unknown) => {
          if (gen !== resolveGen) return;
          setResolved(new Map());
          failed(error);
        },
      );
    },
  );

  onSettled(() => {
    const heading = takePreviewHeading(props.document.path());
    if (heading === undefined) return;
    const id = headingId(heading);
    let tries = 0;
    let frame = 0;
    const tick = () => {
      if (page?.querySelector(`#${CSS.escape(id)}`)) {
        scrollToHeading(id);
        return;
      }
      if (++tries < 30) frame = requestAnimationFrame(tick);
    };
    tick();
    onCleanup(() => cancelAnimationFrame(frame));
  });

  const matter = () => parsed().matter;
  const properties = createMemo(() => {
    const current = matter();
    if (current === undefined) return undefined;
    if (current.tags.length === 0 && current.aliases.length === 0 && current.fields.length === 0) return undefined;
    return current;
  });

  return (
    <div class="file-preview">
      <div class="file-preview-page" ref={(el) => (page = el)}>
        <h1 class="file-preview-title" id={headingId(title())}>
          {title()}
        </h1>
        <Show when={parsed().error}>
          {(error) => <p role="alert">{t.dock.fileBrowser.invalidFrontmatter({ error: error() })}</p>}
        </Show>
        <Show when={properties()}>
          {(shown) => (
            <div class="file-preview-properties">
              <Show when={shown().tags.length > 0}>
                <div class="file-preview-tags">
                  <For each={shown().tags}>{(tag) => <span class="file-preview-chip">#{tag}</span>}</For>
                </div>
              </Show>
              <Show when={shown().aliases.length > 0}>
                <div class="file-preview-aliases">
                  <span class="file-preview-key">{t.dock.fileBrowser.aliases}</span>
                  <span>{shown().aliases.join(", ")}</span>
                </div>
              </Show>
              <Show when={shown().fields.length > 0}>
                <dl class="file-preview-fields">
                  <For each={shown().fields}>
                    {(field) => (
                      <>
                        <dt>{field.key}</dt>
                        <dd>{field.value}</dd>
                      </>
                    )}
                  </For>
                </dl>
              </Show>
            </div>
          )}
        </Show>
        <TranscriptScope value={actions}>
          <FilePreviewScope value={preview}>
            <TranscriptMarkdown text={parsed().body} />
          </FilePreviewScope>
        </TranscriptScope>
      </div>
    </div>
  );
}

function pageTitle(name: string): string {
  const ext = extensionOf(name);
  return isMarkdownExtension(ext) ? name.slice(0, name.length - ext.length - 1) : name;
}

async function resolveAll(
  workspace: FileWorkspace,
  folder: string,
  targets: readonly string[],
): Promise<ReadonlyMap<string, string | undefined>> {
  const files = await workspace.files();
  const stat = (path: string) => files.stat(path);
  const home = workspace.homeDir();
  const vaultRoot = await findVaultRoot(folder, stat, home === undefined ? undefined : { stopAt: home });
  const found = await Promise.all(
    targets.map(async (target) => [target, await resolveWikilink(target, stat, { folder, vaultRoot })] as const),
  );
  return new Map(found);
}
