// lib/app/app.dart: the providers, the theme and the shell, with the hosts of what opens over it. A dev gallery
// (main.tsx, `?gallery=`) takes the shell's place, under the same providers and theme.
import type { Component } from "solid-js";
import { createEffect, onSettled } from "solid-js";
import { type AppState, AppStateContext } from "./app/app_state";
import { Prefs } from "./app/providers/settings_provider";
import { ConnectPromptHost } from "./app/screens/shell/connect_prompt_host";
import { NotificationHost } from "./app/screens/shell/notification_host";
import { ShellScreen } from "./app/screens/shell/shell_screen";
import { applyPalette, shownPalette, watchSystemDark } from "./app/theme";
import { DialogHost } from "./app/widgets/dialog";
import { PageHost, pageBase } from "./app/widgets/navigator";
import { MenuHost } from "./app/widgets/popup_menu";
import { showSnackBar, SnackBarHost } from "./app/widgets/snackbar";
import { TooltipHost } from "./app/widgets/tooltip";
import { WindowChrome } from "./app/window_chrome";
import { onTransportError } from "./bridge";

export function App(props: { readonly state: AppState; readonly gallery?: Component }) {
  const Gallery = props.gallery;
  const settings = props.state.settings;
  const systemDark = watchSystemDark();
  createEffect(
    () => shownPalette(settings.get(Prefs.themeMode), settings.get(Prefs.customTheme), systemDark()),
    (palette) => applyPalette(palette),
  );
  // Only the dev bridge's socket can break; the shells' transports cannot.
  onSettled(() => onTransportError((error) => showSnackBar(error.message)));
  return (
    <AppStateContext value={props.state}>
      {Gallery ? (
        <Gallery />
      ) : (
        <div class="page-base" ref={pageBase}>
          <WindowChrome>
            <ConnectPromptHost>
              <NotificationHost>
                <ShellScreen />
              </NotificationHost>
            </ConnectPromptHost>
          </WindowChrome>
        </div>
      )}
      <PageHost />
      <DialogHost />
      <MenuHost />
      <SnackBarHost />
      <TooltipHost />
    </AppStateContext>
  );
}
