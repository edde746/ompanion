// lib/app/language.dart: the languages the settings offer, and handing the chosen one to app/i18n.
import { type AppLocale, appLocales, baseLocale, loadLocale, setLocale } from "./i18n/i18n";

/** A language the settings offer: the device's, or one the app ships translations for. */
export type AppLanguage = "system" | AppLocale;

export const appLanguages: readonly AppLanguage[] = ["system", ...appLocales];

/**
 * What a language calls itself, so the choice reads the same whatever the app currently shows. `system` has none: its
 * label is translated.
 */
export const languageEndonyms: Readonly<Record<AppLocale, string>> = { en: "English", de: "Deutsch" };

let followDevice = false;
let listening = false;
let wanted: AppLocale = baseLocale;

/**
 * Shows `language`'s strings once they loaded (English is there from the start), and resolves then, or when a later
 * call took over; `system` shows the device's language and follows its changes.
 */
export function applyLanguage(language: AppLanguage): Promise<AppLocale> {
  followDevice = language === "system";
  if (followDevice && !listening) {
    listening = true;
    window.addEventListener("languagechange", () => {
      if (followDevice) void show(deviceLocale());
    });
  }
  return show(language === "system" ? deviceLocale() : language);
}

// The language asked for last wins, whichever loads first.
async function show(locale: AppLocale): Promise<AppLocale> {
  wanted = locale;
  await loadLocale(locale);
  if (wanted === locale) {
    setLocale(locale);
    document.documentElement.lang = locale;
  }
  return locale;
}

/** slang's `findDeviceLocale`: the device's first language by its language code, else English. */
function deviceLocale(): AppLocale {
  const code = navigator.language.split("-")[0]?.toLowerCase();
  return appLocales.find((locale) => locale === code) ?? baseLocale;
}

