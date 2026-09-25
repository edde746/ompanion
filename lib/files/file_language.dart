import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import 'file_paths.dart';

/// Extensions whose highlight.js language differs from the extension. `Mode.aliases` would give the same map, but
/// re_highlight nulls them once a mode is compiled, so they cannot be read at runtime.
const _byExtension = {
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'jsonc': 'json',
  'json5': 'json',
  'yml': 'yaml',
  'md': 'markdown',
  'mkd': 'markdown',
  'py': 'python',
  'pyi': 'python',
  'pyw': 'python',
  'rb': 'ruby',
  'gemspec': 'ruby',
  'rake': 'ruby',
  'rs': 'rust',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'h': 'c',
  'cc': 'cpp',
  'cxx': 'cpp',
  'c++': 'cpp',
  'hpp': 'cpp',
  'hh': 'cpp',
  'hxx': 'cpp',
  'cs': 'csharp',
  'm': 'objectivec',
  'mm': 'objectivec',
  'sh': 'bash',
  'zsh': 'bash',
  'ksh': 'bash',
  'ps1': 'powershell',
  'psm1': 'powershell',
  'psd1': 'powershell',
  'bat': 'dos',
  'cmd': 'dos',
  'html': 'xml',
  'htm': 'xml',
  'xhtml': 'xml',
  'svg': 'xml',
  'plist': 'xml',
  'xsd': 'xml',
  'xsl': 'xml',
  'toml': 'ini',
  'cfg': 'ini',
  'conf': 'ini',
  'pl': 'perl',
  'pm': 'perl',
  'hs': 'haskell',
  'ex': 'elixir',
  'exs': 'elixir',
  'erl': 'erlang',
  'clj': 'clojure',
  'cljs': 'clojure',
  'mk': 'makefile',
  'patch': 'diff',
  'gql': 'graphql',
  'proto': 'protobuf',
  'txt': 'plaintext',
  'log': 'plaintext',
  'gradle': 'gradle',
  'tf': 'plaintext',
};

/// Whole file names that name their language.
const _byName = {
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
  'cmakelists.txt': 'cmake',
  '.bashrc': 'bash',
  '.bash_profile': 'bash',
  '.zshrc': 'bash',
  '.zprofile': 'bash',
  '.profile': 'bash',
  'gemfile': 'ruby',
  'rakefile': 'ruby',
  'podfile': 'ruby',
  'jenkinsfile': 'groovy',
};

/// The re_highlight language for [fileName], or null when none is known.
String? languageFor(String fileName) {
  final name = fileName.toLowerCase();
  final byName = _byName[name];
  if (byName != null) return byName;
  if (name.startsWith('dockerfile.')) return 'dockerfile';
  final extension = extensionOf(name);
  if (extension.isEmpty) return null;
  final language = _byExtension[extension] ?? extension;
  return builtinAllLanguages.containsKey(language) ? language : null;
}

/// The highlighting mode of [language].
Mode? modeFor(String language) => builtinAllLanguages[language];
