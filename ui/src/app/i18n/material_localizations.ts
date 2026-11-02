// The strings Flutter's own widgets bring in each language (GlobalMaterialLocalizations, flutter_localizations'
// material_<locale>.arb), which the app's strings (en.i18n.json, de.i18n.json) do not hold because the Flutter app
// never wrote them: the back button's and a search field's clear button's tooltips.
import { type AppLocale, currentLocale } from "./i18n";

export interface MaterialLocalizations {
  readonly backButtonTooltip: string;
  readonly clearButtonTooltip: string;
  readonly closeButtonTooltip: string;
}

const strings: Readonly<Record<AppLocale, MaterialLocalizations>> = {
  en: { backButtonTooltip: "Back", clearButtonTooltip: "Clear text", closeButtonTooltip: "Close" },
  de: { backButtonTooltip: "Zurück", clearButtonTooltip: "Text löschen", closeButtonTooltip: "Schließen" },
};

/** `MaterialLocalizations.of(context)` for the app's language. */
export function materialLocalizations(): MaterialLocalizations {
  return strings[currentLocale()];
}
