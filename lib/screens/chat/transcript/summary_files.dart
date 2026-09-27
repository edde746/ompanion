import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import 'code_style.dart';
import 'transcript_actions.dart';

/// What the summarized turns did to a file, as omp's compaction lists it.
enum SummaryFileOperation { read, write, readWrite, unknown }

/// A file omp's compaction summary lists.
typedef SummaryFile = ({String path, SummaryFileOperation operation});

/// A compaction summary split into its prose and the file lists omp appends to it (`packages/agent/src/compaction`):
/// a `<files>` block of `name (Read|Write|RW)` lines under `#`-per-depth directory headings, ending with a
/// `[…N files elided…]` line when capped, and the older `<read-files>` and `<modified-files>` blocks of one path per
/// line. [elided] counts the files omp left out.
({String text, List<SummaryFile> files, int elided}) splitSummaryFiles(String summary) {
  final files = <SummaryFile>[];
  var elided = 0;
  final text = summary.replaceAllMapped(_block, (match) {
    final lines = match[2]!.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty);
    switch (match[1]) {
      case 'read-files':
        files.addAll([for (final line in lines) (path: line, operation: SummaryFileOperation.read)]);
      case 'modified-files':
        files.addAll([for (final line in lines) (path: line, operation: SummaryFileOperation.write)]);
      default:
        final directories = <String>[];
        for (final line in lines) {
          if (_elided.firstMatch(line) case final count?) {
            elided += int.parse(count[1]!);
          } else if (_heading.firstMatch(line) case final heading?) {
            final depth = heading[1]!.length - 1;
            if (directories.length > depth) directories.length = depth;
            final name = heading[2]!;
            directories.add(name.endsWith('/') ? name : '$name/');
          } else {
            final entry = _entry.firstMatch(line);
            files.add((
              path: '${directories.join()}${entry?[1] ?? line}',
              operation: switch (entry?[2]) {
                'Read' => SummaryFileOperation.read,
                'Write' => SummaryFileOperation.write,
                'RW' => SummaryFileOperation.readWrite,
                _ => SummaryFileOperation.unknown,
              },
            ));
          }
        }
    }
    return '';
  });
  return (text: text.trimRight(), files: files, elided: elided);
}

final _block = RegExp(r'<(files|read-files|modified-files)>\n?([\s\S]*?)</\1>\s*');
final _heading = RegExp(r'^(#+) (.+)$');
final _entry = RegExp(r'^(.+) \((Read|Write|RW)\)$');
final _elided = RegExp(r'^\[…(\d+) files? elided…\]$');

/// The files of a compaction summary, one dense row each; a row opens its file.
class SummaryFiles extends StatelessWidget {
  const SummaryFiles({super.key, required this.files, required this.elided});

  final List<SummaryFile> files;
  final int elided;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final dim = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final code = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(t.summaryFiles, style: dim),
          ),
          for (final file in files)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => TranscriptScope.of(context).onOpenFile(file.path),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      file.operation == SummaryFileOperation.read ? Symbols.description : Symbols.edit_note,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: code),
                    ),
                    Text(switch (file.operation) {
                      SummaryFileOperation.read => t.fileRead,
                      SummaryFileOperation.write => t.fileWritten,
                      SummaryFileOperation.readWrite => t.fileReadWritten,
                      SummaryFileOperation.unknown => '',
                    }, style: dim),
                  ],
                ),
              ),
            ),
          if (elided > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(t.filesElided(n: elided), style: dim),
            ),
        ],
      ),
    );
  }
}
