// Port of lib/screens/external_links.dart. url_launcher's external application is the shell's `shell.openUrl`.
import { call } from "../../bridge";
import { t } from "../i18n/i18n";
import { appLogger } from "../utils/app_logger";
import { FilledButton, TextButton } from "../widgets/button";
import { Dialog, showDialog } from "../widgets/dialog";
import * as Symbols from "../widgets/symbols";
import "./external_links.css";

/** The URL's scheme, lowercased as Dart's `Uri.scheme`; empty when it has none. */
function schemeOf(url: string): string {
  return /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(url)?.[1]?.toLowerCase() ?? "";
}

/** Whether `url` is a web page, the only kind of link an OAuth `open_url` from a machine opens. */
export function isWebLink(url: string): boolean {
  const scheme = schemeOf(url);
  return scheme === "http" || scheme === "https";
}

/**
 * Whether `url` opens without asking: a web page or a mail draft. Any other scheme starts whatever handler this device
 * registered for it (`ms-msdt:`, `smb:`, an app's own scheme), and link text in model output can hide it.
 */
export function opensWithoutAsking(url: string): boolean {
  return isWebLink(url) || schemeOf(url) === "mailto";
}

/**
 * Opens `url` from the transcript or a terminal with the system. A link opensWithoutAsking refuses shows its full URL
 * first and opens only when the user confirms.
 */
export async function openExternalLink(url: string): Promise<void> {
  if (!opensWithoutAsking(url)) {
    const body = t.links.confirmBody({ scheme: schemeOf(url) });
    const confirmed = await showDialog<boolean>((close) => <ConfirmLinkDialog url={url} body={body} close={close} />);
    if (confirmed !== true) return;
  }
  await launch(url);
}

/**
 * Opens a link the reader clicked in an agent's page (page_frame/page_frame.tsx). Whatever its scheme, it shows its
 * full URL first and opens only when the user confirms: a page's link text can say anything.
 */
export async function openPageLink(url: string): Promise<void> {
  const body = t.links.pageBody;
  const confirmed = await showDialog<boolean>((close) => <ConfirmLinkDialog url={url} body={body} close={close} />);
  if (confirmed === true) await launch(url);
}

/**
 * Opens an OAuth link from a machine in the browser; anything but isWebLink stays closed. Returns whether it was a web
 * link.
 */
export async function openWebLink(url: string): Promise<boolean> {
  if (!isWebLink(url)) return false;
  await launch(url);
  return true;
}

async function launch(url: string): Promise<void> {
  try {
    await call("shell.openUrl", { url });
  } catch (error) {
    appLogger.w(`No application opens ${url}`, { error });
  }
}

function ConfirmLinkDialog(props: { url: string; body: string; close: (confirmed: boolean) => void }) {
  return (
    <Dialog
      icon={Symbols.warning}
      iconColor="var(--error)"
      title={t.links.confirmTitle}
      actions={
        <>
          <TextButton onClick={() => props.close(false)}>{t.common.cancel}</TextButton>
          <FilledButton onClick={() => props.close(true)}>{t.links.open}</FilledButton>
        </>
      }
    >
      <p class="external-links-body">{props.body}</p>
      <p class="external-links-url">{props.url}</p>
    </Dialog>
  );
}
