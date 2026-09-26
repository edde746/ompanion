# Design system

The app is monochrome, flat and dense. Dark mode is OLED black. Code: `lib/app/theme.dart` (tokens and
component themes), `lib/widgets/` (shared controls). Every screen follows these rules; a screen that needs
something the rules do not cover extends this document first.

## Rules

1. No strokes. No borders, outlines or dividers on any control, card, field, chip, dialog, pane or table.
   Separation comes from surface tone and spacing. `OutlinedButton`, `OutlineInputBorder` with a visible
   side, `Border.all`, `BorderSide`, `Divider` and `VerticalDivider` are not used in `lib/`.
2. Monochrome. Chrome, accents, selection, focus and buttons are grey scale. Colour appears only where it
   carries meaning in content: errors, warnings, success, diff additions and removals, syntax highlighting,
   ANSI terminal output. Those colours come from `AppColors`, muted, never from `ColorScheme.primary`.
3. Flat. Elevation 0 everywhere. Surfaces never tint or change colour on scroll
   (`scrolledUnderElevation: 0`, transparent `surfaceTintColor`).
4. One control height. Every inline control (button, text field, search field, select, segmented control,
   chip used as a control) is `AppSizes.control` (36 logical px) tall, so controls placed in one row line up.
   Rows of controls use `crossAxisAlignment: center` and 8 px gaps.
5. Nothing blocks the app. Agent requests (tool approvals, questions, select/confirm/input/editor from
   extensions) render inline in the chat, never as modal dialogs or bottom sheets. Modal dialogs are only for
   short, user-initiated confirmations (delete, discard) and the new-session form.
6. No help text that explains standard input (key hints under the composer, "Enter sends").
7. Search fields filter as you type (250 ms debounce, Enter searches at once). They never have a separate
   search button.
8. Two corner shapes. Controls, cards and dialogs have rounded corners (`radius`, `cardRadius`,
   `sheetRadius`). Navigation marks the shown destination with a stadium (fully rounded ends): the config
   navigation rail and its phone section strip, settings tabs, the dock's pane tabs, terminal tabs and open-file
   tabs.
9. A pill inside a track fills it: the selected segment is inset 3 px on every side of its 36 px track
   (30 px tall) with radius `radius − 3`, so both corners share a centre.
10. A navigation pane is one surface from the window's top edge down. Its header (the sidebar's title and
    actions, the config screen's back button) sits on the pane's tone; the page's title bar covers only the
    page beside it.
11. Equal tabs, centred icons. Icon-only tabs get equal slots with the icon centred in its slot and the
    selected pill filling the slot, so the pill is centred on the icon.
12. On macOS the app draws the title bar. The window has no title text and no title bar tone; the top header
    rows (`titleBarHeight`, 52 px) are the title bar. The traffic lights sit in the sidebar's header, centred on
    it, and the header's content starts 12 px after the zoom button (92 px in on macOS 26); with the sidebar
    hidden the page's header keeps that room instead, and in full screen nobody does. The empty parts of every
    top header row move the window, and a double click does what System Settings says for title bars. Windows
    and Linux keep their native frames.

## Tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| `surface` | `#000000` | `#FFFFFF` | app background, chat |
| `surfaceContainerLow` | `#0B0B0B` | `#F7F7F7` | sidebar, dock, config navigation |
| `surfaceContainer` | `#121212` | `#F0F0F0` | cards, tool cards, composer, code blocks |
| `surfaceContainerHigh` | `#1A1A1A` | `#E8E8E8` | fields, chips, tonal buttons |
| `surfaceContainerHighest` | `#262626` | `#DDDDDD` | hover, selected rows, focused fields, selected segment, navigation indicators |
| `surfaceBright` | `#1E1E1E` | `#E4E4E4` | popovers: menus, select and dropdown menus, popup menus. One quiet step off the cards and composer (`#121212` / `#F0F0F0`) they open over; a brighter tone makes the whole popover louder than the content it serves |
| `onSurface` | `#EDEDED` | `#111111` | primary text, primary button fill |
| `onSurfaceVariant` | `#8F8F8F` | `#5C5C5C` | secondary text, icons |
| `primary` / `onPrimary` | `#EDEDED` / `#000000` | `#111111` / `#FFFFFF` | primary buttons, switches on, progress |

`AppColors` (a `ThemeExtension`): `error`, `errorSurface`, `warning`, `success`, `diffAdd`, `diffAddSurface`,
`diffRemove`, `diffRemoveSurface`, `running` (grey). Muted values; one set per brightness.

`AppSizes`: `control = 36`, `radius = 10` (controls), `cardRadius = 12`, `sheetRadius = 16`, `gap = 8`,
`rowHeight = 32` (dense list rows on desktop; 44 on phones).

## Components

| Need | Use |
|---|---|
| Primary action | `FilledButton` (onSurface fill) |
| Secondary action | `FilledButton.tonal` (surfaceContainerHigh fill) |
| Low-emphasis action | `TextButton` |
| Text input | `TextField` with the theme's filled, borderless decoration |
| Label of a field or select | `LabeledField`: the label above the control. Filled fields never float a label inside the fill |
| Search | `AppSearchField` |
| Choice from a list | `AppSelect<T>`: a flat filled button showing the value and a chevron, opening a flat menu |
| Two to four exclusive options | `AppSegmented<T>`: flat `surfaceContainerHigh` track, the selected segment a `surfaceContainerHighest` pill inset 3 px (rule 9), no check icon |
| On/off | `Switch` (monochrome through the theme) |
| Grouping | a `surfaceContainer` block with `cardRadius`, no border |
| Long list of choices (providers, models) | a searchable list: `AppSearchField` above dense rows |
| Content inside a popover | an 8 px inset on every side (the popover adds no padding of its own around a custom list). Tones step up from the popover's own as `onSurface` overlays: a field 6 % (8 % focused), the selected row 10 % with `radius`. Two-line rows take 4 px above and below their text; a group label sits 8 px under the row above it and 4 px over its first row |
| Menu from the composer toolbar | opens `gap` (8 px) above the composer block, never over it; the model list starts at the block's left edge and is at most as wide as the block |
| Composer | a `surfaceContainer` block with `cardRadius`. The text's ink and the toolbar's first icon share one left edge 12 px inside the block; 12 px above the first line box; the toolbar's 36 px controls sit 8 px from the bottom and right edges |
| Composer attachments | a wrapping row above the text, 12 px inside the block's top and sides, 8 px gaps, in the order they came. Images: 64 px thumbnails (radius 8) that open the zoom viewer, a 24 px `surfaceContainerHighest` remove disc in the corner. Files, folders and pasted texts: `surfaceContainerHigh` chips one control tall with `radius`: a 16 px icon, the name (a file's size after it in `onSurfaceVariant`) or `Pasted text · N lines`, and a remove button. A pasted text opens a read-only preview in `codeTextStyle` with "Paste inline" |
| Drop target | while files from the OS hover over the chat pane, a `surfaceContainerHigh` layer at 92 % covers it 8 px inside its edges, with `cardRadius`, an attach icon and "Drop to attach" centred. A tone, never a stroke or dashed outline |
| Sidebar session row | one mark in the icon column, under the project's folder icon: the status (working, needs input, failed, disconnected, open in omp on the machine), else the unread dot. Unread with a status shows through the bold title alone. The title starts in the project path's column; the relative time sits at the end |
| Sidebar project row | the machine row's chevron (`expand_more`, `chevron_right` while collapsed) in the column before the folder icon, then the path. The chevron, a click on the row, Enter and Space toggle it; the collapsed state is an app setting per machine and folder. Collapsed, it hides its sessions and "Show more", and shows the session row's mark at the end for the first of needs input, working, open in omp on the machine that any of its sessions has |
| Sidebar list | one flat list of rows with known heights: machine, project, session and "Show more" rows are `rowHeight` (`rowHeightTouch` on phones), a notice 44 px (52 on phones) with its text cut to two lines and the whole of it in a tooltip, a 4 px gap after each machine. The scroll extent is their sum, so the scrollbar's thumb keeps its size |
| Sidebar search | a search icon before the header's add button; it opens an `AppSearchField` over the header's title and actions, focused. Cmd/Ctrl+F opens it from anywhere, showing a hidden sidebar. It keeps the listed sessions whose title or project path holds the text (case-insensitive), every one of them, under their project and machine rows, open whatever their collapsed state, with the match on an `onSurface` 22 % tone. Machines and projects without a match, notices and "Show more" go. Esc, or leaving the emptied field, closes it; the tree comes back with its collapse states as they were |
| Token count or context window | `formatTokens` (`lib/utils/token_count.dart`): `950`, `12.3K`, `128K`, `1.5M`, one decimal unless whole. A model's context window reads `128K context` |
| Modal dialog | `surfaceContainer` with `sheetRadius`, over a black scrim (80 % dark, 50 % light), so a dialog opened from a dialog stands apart from it. Not `surfaceContainerHigh`: the fields, selects and tonal buttons inside have that tone |
| Monospace text (ids, paths, keys, scripts) | `codeTextStyle`, the code blocks' font; the generic `monospace` family does not resolve on macOS |
| Status of a quota, limit or machine | an 8 px dot in `AppColors` `success`, `warning` or `error` (`onSurfaceVariant` when unknown) at the start of the row; a limit an account lacks gets a `surfaceContainerHighest` dot |
| Quota bar | 6 px tall, radius 3, a `surfaceContainerHighest` track filled to the used fraction in `onSurface`; `warning` or `error` fill only once the limit warns or is exhausted; an empty track when the provider reports no fraction |
| Machines an entry came from | `ConfigTag` pills at the end of the entry's first line |
| Turn summary (a settled turn's folded work in the chat) | one flat line directly under the turn's user message, left-aligned: `bodySmall` in `onSurfaceVariant`, the facts the transcript holds joined by `  ·  ` (`Worked for 1m 12s  ·  8 tool calls  ·  2 files edited`), then a 16 px `expand_more` chevron, `expand_less` while open. No card, border or leading icon. The line is an `InkWell` (radius 6) that hugs its text and toggles on click, tap, Enter and Space; the turn's rows open below it in transcript order and the line stays where it is |
| File mention in a user message (`@path`, `@"path"`, `@'path'` by omp's rules, `local://…`) and in a queued message | an inline chip in the text: `surfaceContainerHighest`, radius 6, a 14 px file, folder or pasted-text (`notes`) icon in `onSurfaceVariant` and the base name in the message's style; the full path in a tooltip. A click opens the path in Files; a `local://` chip shows its tooltip instead. Copy message copies the text omp received |
| Long user message (over 12 lines or 1200 characters) | its first 6 lines, at most 600 characters (`…` where a line is cut), then a flat toggle inside the bubble like the turn summary line: `Show all (N lines)` with `expand_more`, `Show less` with `expand_less`. The open state lives with the row |
| Settings link row (About) | the whole row is the target: a flat InkWell across its card, one control tall with 4 px above and below its text and taller when the label wraps or a muted `bodySmall` `onSurfaceVariant` detail line takes the second line (44 px), so no label is cut; a 16 px `onSurfaceVariant` mark at the end — `open_in_new` for a link that leaves the app through `openExternalLink`, `chevron_right` for a page inside it (`showLicensePage`). No start icon, no divider; the card is a `Material` on `surfaceContainer` with `cardRadius`, so the row's ink lands on the block's tone |

## Markdown

Assistant replies, thinking blocks, summaries and extension messages render markdown in one vertical rhythm:
GitHub's markdown spacing scaled to the 14 px body. Code: `TranscriptMarkdown` in
`lib/screens/chat/transcript/markdown.dart`. Gaps are between line boxes, in logical pixels at text scale 1, and
grow with the text scale.

| Between | Gap |
|---|---|
| Two blocks (paragraphs, lists, code blocks, tables, quotes, rules, maths) | 12 |
| Any block and a heading below it | 20 |
| A heading and the block below it | 8 |
| Two items of one list, single- or multi-line, tight or loose | 6 |
| A list item's first line and its nested list | 4 |
| Two nested items; the last nested item and its parent's next item | 6; 8 |

Body text of markdown and of user messages has line height 1.5 (21 px lines); headings 1.3. The rhythm does not come
from gpt_markdown, which stacks the blocks of one blank-line segment without space and separates segments by 1.15
lines: `TranscriptMarkdown` cuts the text into top-level blocks (every list item one) where gpt_markdown's parser
starts them, renders each with its own `GptMarkdown` and spaces them itself. A long text split into several rows keeps
the gap its blocks have in one piece: each part after the first is spaced from the last block of the part above it
(`TranscriptMarkdown.previous`).
