// Port of lib/files/file_language.dart. The web highlights with Shiki: extensions, aliases and the Docker and make file
// names resolve through the transcript highlighter's table (`languageForPath`, `languageForFence`), so this file only
// adds the whole file names that table lacks.
import { languageForFence, languageForPath } from "../screens/chat/transcript/highlighter";

/** Whole file names that name their language. */
const byName = new Map([
  ["cmakelists.txt", "cmake"],
  [".bashrc", "bash"],
  [".bash_profile", "bash"],
  [".zshrc", "bash"],
  [".zprofile", "bash"],
  [".profile", "bash"],
  ["gemfile", "ruby"],
  ["rakefile", "ruby"],
  ["podfile", "ruby"],
  ["jenkinsfile", "groovy"],
]);

/** The highlighter language for `fileName`, or undefined when none is known. */
export function languageFor(fileName: string): string | undefined {
  const name = fileName.toLowerCase();
  const language = byName.get(name) ?? (name.startsWith("dockerfile.") ? "dockerfile" : undefined);
  return language === undefined ? languageForPath(name) : languageForFence(language);
}
