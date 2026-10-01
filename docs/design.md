# Design system

The app is monochrome, flat and dense. Dark mode is OLED black. Code: `lib/app/theme.dart` (tokens and
component themes), `lib/widgets/` (shared controls). Every screen follows these rules; a screen that needs
something the rules do not cover extends this document first.

## Rules

1. No strokes. No borders, outlines or dividers on any control, card, field, chip, dialog, pane or table.
   Separation comes from surface tone and spacing. `OutlinedButton`, `OutlineInputBorder` with a visible
   side, `Border.all`, `BorderSide`, `Divider` and `VerticalDivider` are not used in `lib/`.
2. Monochrome by default. In the built-in Light and Dark themes chrome, accents, selection, focus and buttons are
   grey scale, and colour appears only where it carries meaning in content: errors, warnings, success, diff additions
   and removals, syntax highlighting, ANSI terminal output. Those colours come from `AppColors`, muted, never from
   `ColorScheme.primary`. The Custom theme lets the user pick every token (Tokens); widgets still read tokens, never
   literal colours.
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
    hidden the page's header keeps that room instead. Full screen keeps the lights in the same place: AppKit
    hides its title bar there, so the window shows AppKit's standard buttons over the header (no symbols on
    hover; the menu bar's title bar strip still covers them while it is shown). The empty parts of every top
    header row move the window, except in full screen, and a double click does what System Settings says for
    title bars. Windows and Linux keep their native frames.

## Tokens

Every colour the app draws is one of 43 palette tokens (`ThemeToken`, `lib/app/palette.dart`). A theme is a base
(Dark or Light) plus the tokens picked over it: the built-in themes pick none, the Custom theme picks what the user
chose in the theme editor. Its brightness (keyboard, markdown, status bar) is the background's.

| Token | Role | Dark | Light | Use |
|---|---|---|---|---|
| `background` | `surface` | `#000000` | `#FFFFFF` | app background, chat |
| `pane` | `surfaceContainerLow` | `#0B0B0B` | `#F7F7F7` | sidebar, dock, config navigation |
| `card` | `surfaceContainer` | `#121212` | `#F0F0F0` | cards, composer, code blocks and output |
| `field` | `surfaceContainerHigh` | `#1A1A1A` | `#E8E8E8` | fields, chips, tonal buttons |
| `selected` | `surfaceContainerHighest` | `#262626` | `#DDDDDD` | hover, selected rows, focused fields, selected segment, navigation indicators |
| `popover` | `surfaceBright` | `#1E1E1E` | `#E4E4E4` | popovers: menus, select and dropdown menus, popup menus. One quiet step off the cards and composer (`#121212` / `#F0F0F0`) they open over; a brighter tone makes the whole popover louder than the content it serves |
| `text` | `onSurface` | `#EDEDED` | `#111111` | primary text, icons without a colour of their own |
| `textMuted` | `onSurfaceVariant` | `#8F8F8F` | `#5C5C5C` | secondary text, icons |
| `accent` / `onAccent` | `primary` / `onPrimary` | `#EDEDED` / `#000000` | `#111111` / `#FFFFFF` | primary buttons, switches on, progress |

A token also drives the roles that repeat it: `background` `surfaceContainerLowest`, `onInverseSurface`,
`onSecondary`, `onTertiary` and `onError`; `field` `secondaryContainer`; `selected` `primaryContainer`,
`tertiaryContainer` and `outlineVariant`; `text` `inverseSurface` and the `on…Container` roles; `error` and
`errorSurface` `error` and `errorContainer`. The roles no token drives (`secondary`, `tertiary`, `outline`,
`onErrorContainer`, `surfaceDim`, `inversePrimary`, `shadow`, `scrim`) keep the base's grey; the modal scrim stays
black.

`AppColors` (a `ThemeExtension`) holds every token by name. Content colours: `error`, `errorSurface`, `warning`,
`success`, `running` (grey), `diffAdd`, `diffAddSurface`, `diffRemove`, `diffRemoveSurface`; syntax highlighting
`comment`, `keyword`, `tag`, `literal`, `string`, `number`, `title`, `builtIn` (Atom One's colours and scope groups);
the 16 ANSI colours `ansiBlack` … `ansiBrightWhite`, which the terminal pane draws as they are and the transcript
adapts (the colour's hue at the surface's contrast, `AnsiPalette`). Muted values in both bases.

`AppSizes`: `control = 36`, `radius = 10` (controls), `cardRadius = 12`, `sheetRadius = 16`, `gap = 8`,
`rowHeight = 32` (dense list rows on desktop; 44 on phones).

## Icons

Every icon is a Material Symbols glyph from the `material_symbols_icons` package: `Symbols.<name>`, the Outlined
family (`MaterialSymbolsOutlined`). Not Flutter's `Icons`, and not the package's `_rounded` or `_sharp` constants,
whose fonts the release build then drops. Names are the Material Symbols catalog's (<https://fonts.google.com/icons>),
not Material Icons' `_outlined` names or legacy aliases: `content_copy`, `delete`, `error`, `info`, `download`,
`upload`, `draft` (a file), `warning`, `close`.

Axes: weight 400, grade 0, fill 0, optical size 24 (`AppSizes.iconOpticalSize`, the font's default and the size its
glyphs are drawn for). Flutter falls back to optical size 48, whose strokes are about a third thinner at 14–20 px, so
the theme's `iconTheme` sets 24. Widgets that give their icon a fresh icon theme take it from their own theme
(`navigationRailTheme`'s icon themes, `chipTheme.iconTheme`) or on the icon (an `AlertDialog`'s `icon`).

Plain icons take the theme's `iconTheme` colour, `onSurface`. Icon buttons keep their variant's colour instead:
`onSurfaceVariant` for a standard one, `onPrimary` on a filled one. Flutter's `IconButton` would otherwise take the
ambient icon colour over its variant's, so `iconButtonTheme` sets its foreground and overlay to colours that resolve
to null. Because of that, an app bar's back button takes its `onSurface` from `appBarTheme.iconTheme`.

Fill 1, set with `Icon.fill` and never by another family, only where the solid glyph carries meaning:

- a solid status mark: `check_circle` (a done todo, a passed connection test, a completed subagent, a chosen answer
  in a finished question), `error` (a failed session, test or subagent), `help` (a session that needs input),
  `cancel` (an aborted subagent), the `circle` dot (a Tailscale peer, a changed file in Files);
- the on state of a toggle: a checked task box (`check_box`), the panels button while the panels show
  (`view_sidebar`), the file editor's diff button while the diff shows (`difference`);
- the session tree's current-leaf mark (`my_location`);
- the transport glyphs `play_arrow`, `pause` and `stop`: outlined, pause's bars read as two empty boxes at 14–18 px.

Flutter widgets that draw a Material Icons glyph of their own get a Material Symbols one: `BackButton` through
`ThemeData.actionIconTheme` (`arrow_back`; `arrow_back_ios_new` on iOS and macOS), `PopupMenuButton` through its
`icon` (`more_vert`), `InputChip` through its `deleteIcon` (`close`). A checked popup menu item is a `PopupMenuItem`
holding a `ListTile` with a `check`, not `CheckedPopupMenuItem`. Android's text selection toolbar still draws
`more_vert` and `arrow_back` from Material Icons when its items overflow; Flutter has no way to change them, so
`pubspec.yaml` keeps `uses-material-design`.

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
| Composer | a `surfaceContainer` block with `cardRadius`, in the transcript's column. The text is the app's `bodyMedium` (14 px on every screen, one step under the transcript's 15 px on tablets and desktop windows, which read too large in the input) at line height 1.5. The text's ink and the toolbar's first icon share one left edge 12 px inside the block; 12 px above the first line box; the toolbar's 36 px controls sit 8 px from the bottom and right edges |
| Goal and loop in the composer | while a goal is active, paused or budget-limited, and while a loop is on, one `ToolbarButton` each after the context meter, as omp's footer shows them: `flag` and `Goal 12.4K/50K` (`Goal 12.4K` without a budget, `formatTokens`); `repeat` and `Loop 7/10` (iterations left of the total), `Loop 4m30s left`, `Loop running`, `Loop waiting` or `Loop paused`. A paused goal (`pause`), a budget-limited goal (`warning`) and a paused loop (`pause`) take `AppColors` `warning` for icon and label; everything else stays `onSurfaceVariant`. The tooltip holds the state in words, the loop's limit and condition included. They take the room the model and thinking buttons leave, down to icon and chevron; where the toolbar is under 640 px (phones, narrow panes) they sit in a row of their own above it, from the toolbar's first icon edge. Each opens a menu above the composer block (at most 360 px wide): a header in `bodyMedium` (the objective, or the loop's prompt; `onSurfaceVariant` while the loop waits or is suspended) that scrolls past 160 px, the facts under it in `bodySmall` `onSurfaceVariant` (a held status in `warning`), then the actions as menu items. The goal's budget is a `LabeledField` in the menu (a number, or `off`; Enter or its check button sets it), never a dialog; Drop asks with a short confirmation dialog |
| Session menu (chat header) | the `more_vert` menu: `Set a goal…`, `Guided goal…` and `Loop a prompt…` while the session lists `/goal`, `/guided-goal` and `/loop` (`/loop` only while no loop is on), each putting its command before the draft's text and focusing the composer; then Copy session file path, Pin to top or Unpin, Close on this device, Stop the omp process |
| Composer attachments | a wrapping row above the text, 12 px inside the block's top and sides, 8 px gaps, in the order they came. Images: 64 px thumbnails (radius 8) that open the zoom viewer, a 24 px `surfaceContainerHighest` remove disc in the corner. Files, folders and pasted texts: `surfaceContainerHigh` chips one control tall with `radius`: a 16 px icon, the name (a file's size after it in `onSurfaceVariant`) or `Pasted text · N lines`, and a remove button. A pasted text opens a read-only preview in `codeTextStyle` with "Paste inline" |
| Drop target | while files from the OS hover over the chat pane, a `surfaceContainerHigh` layer at 92 % covers it 8 px inside its edges, with `cardRadius`, an attach icon and "Drop to attach" centred. A tone, never a stroke or dashed outline |
| Sidebar session row | one mark in the icon column, under the project's folder icon: the status (working, needs input, failed, disconnected, open in omp on the machine), else the unread dot. Unread with a status shows through the bold title alone. The title starts in the project path's column; the relative time sits at the end. A secondary click or a long press opens its menu: Pin to top, or Unpin; Mark as read, while it is unread. A tap shows the session once it is open, unless the user chose another session or page meanwhile: the last choice wins, and the session opens on this device without taking the center pane |
| Sidebar pinned sessions | above the machines, in the order they were pinned: a "Pinned" row with `push_pin` in the machine row's icon and name columns, then session rows with their machine's name (`labelSmall`, `onSurfaceVariant`, cut at 96 px) before the time, then a 4 px gap. A pinned session leaves its project's rows; while its machine is not listed, the row shows the title its pin stored |
| Sidebar sessions without a folder | a session in one of the directories omp moves to when started in the home directory (`HostProbe.scratchDirs`: `~/tmp`, `/tmp`, `/var/tmp`, the temporary directory; on Windows `~\tmp` and `%TEMP%`) lists right under its machine row, before the projects, with no project row for that directory: session rows, a short list of 5 plus the open ones, then "Show more". A directory inside one of them is a project like any other |
| Sidebar machine row | the chevron (`expand_more`, `chevron_right` while collapsed) in a 24 px column, the machine icon with its status dot, the name. A tap anywhere on the row toggles it: the chevron alone is too small a target on a phone. On hover (always on touch screens) a `settings` button opens the machine's page and `more_horiz` opens its menu; desktops also get a new session button. A secondary click or a long press opens the same menu where it happened. The menu: New session, Mark as read (every session of the machine, its pinned ones included; while one is unread), Refresh, Configure, and Install omp while the machine needs it. The machine's new session actions (the button, the menu, the machine page, Cmd/Ctrl+N) open the new session dialog on "No folder" |
| Sidebar project row | the machine row's chevron (`expand_more`, `chevron_right` while collapsed) in the column before the folder icon, then the path. The chevron, a click on the row, Enter and Space toggle it; the collapsed state is an app setting per machine and folder. Collapsed, it hides its sessions and "Show more", and shows the session row's mark at the end for the first of needs input, working, open in omp on the machine that any of its sessions has. On hover (always on touch screens) an `add` button starts a session in the folder right away, on omp's default model, without the new session dialog; the activity mark takes the button's place until the session shows, and a failure is a snackbar. A secondary click or a long press opens its menu: Mark as read, for its sessions, while one is unread |
| Sidebar list | one flat list of rows with known heights: pinned, machine, project, session and "Show more" rows are `rowHeight` (`rowHeightTouch` on phones), a notice 44 px (52 on phones) with its text cut to two lines and the whole of it in a tooltip, a 4 px gap after the pinned sessions and after each machine. The scroll extent is their sum, so the scrollbar's thumb keeps its size |
| Sidebar search | a search icon before the header's add button; it opens an `AppSearchField` over the header's title and actions, focused. Cmd/Ctrl+F opens it from anywhere, showing a hidden sidebar. It keeps the listed sessions whose title or project path holds the text (case-insensitive), every one of them, under their project and machine rows (a session without a folder right under its machine, found by its title alone), open whatever their collapsed state, and the pinned sessions whose title holds it, with the match on an `onSurface` 22 % tone. Machines and projects without a match, notices and "Show more" go. Esc, or leaving the emptied field, closes it; the tree comes back with its collapse states as they were |
| New session dialog | an `AppSegmented` "Folder" / "No folder" on top. "Folder": the directory field (focused) with its browse button, the recent projects (without omp's temporary directories). "No folder": one `onSurfaceVariant` line saying omp works in a temporary directory, and Start takes the focus, so Enter starts; the session runs in the first of `HostProbe.scratchDirs` that exists, where omp started in the home directory works. The model field follows in both |
| Pane widths | wide layouts: the sidebar (240–480 px, 300 at first) and the inline dock (280–800 px, 340) resize by dragging their inner edge, a 6 px strip with the column-resize cursor and no stroke. The strip lies on the side of the edge that has no scrollbar: the chat's left edge for the sidebar, the dock's own left edge for the dock. The dragged pane gives way to the other and the center keeps 400 px; a narrower window takes from the sidebar first. The widths are app settings: a window fits them without rewriting them. The drawer dock stays 360 px |
| Token count or context window | `formatTokens` (`lib/utils/token_count.dart`): `950`, `12.3K`, `128K`, `1.5M`, one decimal unless whole. A model's context window reads `128K context` |
| Modal dialog | `surfaceContainer` with `sheetRadius`, over a black scrim (80 % dark, 50 % light), so a dialog opened from a dialog stands apart from it. Not `surfaceContainerHigh`: the fields, selects and tonal buttons inside have that tone |
| Monospace text (ids, paths, keys, scripts) | `codeTextStyle`, the code blocks' font; the generic `monospace` family does not resolve on macOS |
| Status of a quota, limit or machine | an 8 px dot in `AppColors` `success`, `warning` or `error` (`onSurfaceVariant` when unknown) at the start of the row; a limit an account lacks gets a `surfaceContainerHighest` dot |
| Quota bar | 6 px tall, radius 3, a `surfaceContainerHighest` track filled to the used fraction in `onSurface`; `warning` or `error` fill only once the limit warns or is exhausted; an empty track when the provider reports no fraction |
| Work under way (loading, connecting, running, saving, searching) | `ActivityMark` (`lib/widgets/activity_mark.dart`), the app's one activity mark: omp's TUI activity spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) painted as a braille cell, two columns of three dots in the square of the slot's icon size (14 px in a line of text, 16 in a button, 20 centred in a page or pane that loads), `onSurfaceVariant` unless the slot has a status colour, the frame's dots lit and the rest at 13 %. It steps every 80 ms, the TUI spinner's step; every mark on screen steps from one clock, in one frame, repainting only its own layer, so a busy screen draws 12.5 frames a second. Still, on its first frame (`⠋`), when the device asks for less motion (`MediaQuery.disableAnimationsOf`) or tickers are off (a covered route, a hidden tab). `CircularProgressIndicator`, `RefreshProgressIndicator` and a `LinearProgressIndicator` without a value are not used in `lib/`. A known fraction may show as a bar or ring (install progress, an upload's bytes) that moves only when the count does |
| Chat header | where the session runs: the directory with the machine's home as `~`, then ` · machine`. An untitled session, whose name would repeat the first prompt right below, goes by that place alone: `codeTextStyle` at `bodyMedium` size (14 px), the directory in `onSurface` and ` · machine` in `onSurfaceVariant`. A titled one (a rename, a generated title) shows its title (`titleSmall`) over the place in `codeTextStyle` at `labelSmall` size in `onSurfaceVariant`. At the end, what the session does: the activity mark and `Connecting…` or `Working` (the mark alone on phones), then Pause/Resume and Stop, both `FilledButton.tonal` (the composer's send or steer is the one filled button while a run goes), then the session menu. Connecting shows only there, never as a bar over the transcript |
| Transcript column | rows at most 760 px wide with their 12 px side padding (about 100 characters of body text a line), centred in the chat. The status strip above the transcript and the panels and composer below it share the column, so their edges line up with the rows'. A transcript shorter than the pane starts at its top edge and does not scroll; a taller one stays at its bottom while the reader is there, from the update it overflows in. Where the screen's shorter side is at least 600 px (tablets, desktop windows) the transcript's text is one step up (`chatTextTheme`): body 15 px, `bodySmall` 13, `labelSmall` 12, code 13, table cells 14; phones keep 14/12/11, code 12, cells 13. Code is 2 px under the body, table cells 1 px, and a reply's footer is `bodySmall`. A user bubble pads its text 16 by 12. Gaps above rows: a user message 24 (a turn starts), a tool line 2, text, thinking and the turn summary 6, the awaiting line 10, a reply's footer 4 |
| Tool call (a row of the transcript) | one flat line, no card: a 14 px mark column (the activity mark while the call runs, else a 6 px dot, `success` done, `error` failed, `onSurfaceVariant` interrupted; a `schedule` icon while it works in the background), 8 px, the tool name in `codeTextStyle` at `bodySmall` size (13 px; 12 on phones) `w600`, the subject (`codeTextStyle` for paths and commands, `bodySmall` otherwise) in `onSurfaceVariant`, underlined at half strength when it opens a file, then the harness intent at 70 % in what room is left, cut with `…`; short facts (`labelSmall`, 12 px; 11 on phones; `error` when it failed) and a 16 px chevron at the end. The line is an `InkWell` (radius 6), 6 px above and below its text. An open body starts at the name's 22 px edge; code, output and diffs in it sit on their own code surface. Bash, edit, ask, web search and eval open by default, a todo only where it makes the plan, any call whose result carries images, and a failed call |
| Thinking (a reasoning block) | a line in the tool lines' columns: the activity mark while it streams, else a 14 px `neurology` icon, then `Thinking`, `Thought for 1.2s` or `Thought` in `bodySmall` `onSurfaceVariant` with `  ·  N reasoning tokens`, and the chevron. Open, the text shows at the 22 px edge in `onSurfaceVariant` |
| Code block, terminal output, JSON | a code surface (`surfaceContainer` on the transcript, `surfaceContainerHigh` inside a card) with radius `radius`, the full width of its column. A code block has no header: 12 px padding, and a compact copy button in its top right corner on the block's own tone while the pointer is over it (always on touch screens). No language label; highlighting says it |
| Machines an entry came from | `ConfigTag` pills at the end of the entry's first line |
| Turn summary (a settled turn's folded work in the chat) | one flat line directly under the turn's user message, left-aligned: `bodySmall` (13 px; 12 on phones) in `onSurfaceVariant`, the facts the transcript holds joined by `  ·  ` with the dot at half the text's alpha (`Worked for 1m 12s  ·  8 tool calls  ·  2 files edited`), then a 16 px `expand_more` chevron, `expand_less` while open. No card, border or leading icon. The line is an `InkWell` (radius 6) that hugs its text and toggles on click, tap, Enter and Space; the turn's rows open below it in transcript order and the line stays where it is |
| Awaiting reply (a turn runs and has shown nothing yet) | one flat line where the reply will be, at the end of the transcript: the activity mark in the tool lines' 14 px mark column, then at their 22 px text edge `bodySmall` in `onSurfaceVariant`, `Waiting for a reply`, and `Waiting for a reply · 12s` once it has waited 3 s (the count ticks once a second). No card, border or second mark: it stays away while the reply streams, a tool runs, the run compacts, retries or is parked (the status strip says so), or a request waits for an answer |
| File mention in a user message (`@path`, `@"path"`, `@'path'` by omp's rules, `local://…`) and in a queued message | an inline chip in the text: `surfaceContainerHighest`, radius 6, a 14 px file, folder or pasted-text (`notes`) icon in `onSurfaceVariant` and the base name in the message's style; the full path in a tooltip. A click opens the path in Files; a `local://` chip shows its tooltip instead. Copy message copies the text omp received |
| Model mention (`^provider/id` in the composer, `<model agent="m1" name="…"/>` in a user or queued message) | the file mention's inline chip with a 14 px `auto_awesome` icon and the model's name; in a message the pseudonym (`Subagent m1`) in a tooltip. In the composer the chip is one character of the text: the cursor steps over it, Backspace deletes it whole, Copy and Cut give `^provider/id`. The `^` list opens above the composer like the command palette (36 px rows: the icon, the name in `w600`, `provider/id` in `codeTextStyle` 12 px `onSurfaceVariant`; `ActivityMark` while the models load) |
| Long user message (over 12 lines or 1200 characters) | its first 6 lines, at most 600 characters (`…` where a line is cut), then a flat toggle inside the bubble like the turn summary line: `Show all (N lines)` with `expand_more`, `Show less` with `expand_less`. The open state lives with the row |
| Message actions | icon buttons, one click each, 18 px icons in `onSurfaceVariant` on compact `IconButton`s (32 px square on desktops, 40 px on touch screens), in this order: `call_split` Branch from here on your own messages, `restart_alt` Reset to here, `content_copy` Copy message. The tooltip names each. A user message's sit before the bubble and fade in together while the row is hovered (always on touch); an assistant reply's end the footer's facts line (model, tokens, cost, time), always visible, never on a line of its own. Reset to here is disabled while a turn runs, with a tooltip that says why, and turns back on when the turn ends. Reset moves the leaf in the same session file and the replies after it stay in the session tree: your message's text and images go back into the composer (a draft with text or attachments is replaced only after `Replace your draft?`), an assistant reply becomes the point to continue from. Branch from here asks first; Copy message confirms with a snackbar |
| Settings link row (About) | the whole row is the target: a flat InkWell across its card, one control tall with 4 px above and below its text and taller when the label wraps or a muted `bodySmall` `onSurfaceVariant` detail line takes the second line (44 px), so no label is cut; a 16 px `onSurfaceVariant` mark at the end — `open_in_new` for a link that leaves the app through `openExternalLink`, `chevron_right` for a page inside it (`showLicensePage`). No start icon, no divider; the card is a `Material` on `surfaceContainer` with `cardRadius`, so the row's ink lands on the block's tone |
| Settings switch row | the label in `bodyMedium`, an optional muted `bodySmall` `onSurfaceVariant` detail line under it, and a `Switch` at the end, 8 px from the card's right edge and 16 px of text inset on the left; at least one control tall plus 4 px above and below, taller when the detail wraps. It sits in the same `surfaceContainer` card as the About rows. A switch that depends on another one (the notification kinds) is disabled, not hidden, while that one is off |
| Theme (settings) | `AppSegmented` `System` / `Light` / `Dark` / `Custom`. While Custom is chosen, a card under it with one link row: `Edit colors`, its detail line the base and how many tokens were picked (`Dark base · 3 changed`), `chevron_right`. The first switch to Custom starts the custom theme from the base of the theme on screen |
| Theme editor | a page pushed over the app like the machine page, in the built-in theme of the custom theme's brightness, so no pick hides the editor's own controls. Its title bar: back, `Custom theme`, `Reset all` (a `TextButton`, disabled while nothing is picked). Then `Start from`, an `AppSegmented` Dark / Light (the picks stay), and one `surfaceContainer` card per group (Surfaces, Text, Accent, Status, Diff, Syntax highlighting, Terminal) under its title: token rows of a 24 px swatch (radius 6), the name over a muted `bodySmall` use line, the hex in `codeTextStyle` `onSurfaceVariant`, and a `restart_alt` reset button while the token differs from the base. A tap opens the colour picker under the row, one row at a time; a second tap closes it. The preview, drawn in the custom theme, sits beside the list (320 px wide) on a page at least 840 px wide, else in a 240 px strip above it; every token shows in it. Dragging changes the preview and the row; the pick is saved when the drag ends, a hex is applied or a token is reset |
| Colour picker | opaque colours. A saturation/value area 160 px tall across the row with radius `radius`, and a hue track 12 px tall, a stadium; each handle is a 14 px disc in the picked colour on an 18 px disc of white or black, whichever stands apart from the colour (a halo, not a stroke). Under them a hex field one control tall and 120 px wide in `codeTextStyle`: six hex digits with or without `#`, applied on Enter and when the field loses focus; anything else puts the current colour back |
| Notifications (settings) | a section after Theme. Desktops: one card with `Notifications` (the sessions open on this device) and the three kinds `A session needs input`, `A run finishes`, `A run fails`. Phones and tablets: the same card with `Push notifications` first, its detail line saying why when the build cannot receive them (the switch is then disabled unless push is on, so it can always be turned off), or that push was turned off because the phone no longer has its key (a restore from a backup); while push is on, a second card lists each connected machine as a row, its name and a `TextButton` `Send test notification` (disabled while one is on its way), or a muted line asking to connect a machine. Failures and results are `SnackBar`s |
| System notification | posted by the OS, one per session (a newer one replaces it; on iOS grouped by the run's thread): the title is the session's name, else the first line of its first message, else its directory's last component; the subtitle `<machine> · Needs input`, `Done` or `Failed` (Linux puts it as the body's first line, Windows as a third line); the body is the question, `Allow <tool>?`, `Goal complete: <objective>`, the first line of the last reply, `Finished`, or the error (docs/contracts/push.md, "Payload"). None for the session on screen; showing a session clears its notification. A tap brings the window forward (desktops) and opens the session, or says in a `SnackBar` that its machine is gone |

## Markdown

Assistant replies, thinking blocks, summaries and extension messages render markdown in one vertical rhythm:
GitHub's markdown spacing scaled to a 14 px body; the gaps stay as they are at 15. Code: `TranscriptMarkdown` in
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

Body text of markdown and of user messages has line height 1.5 (21 px lines at 14 px, 22.5 at 15); headings 1.3. The rhythm does not come
from gpt_markdown, which stacks the blocks of one blank-line segment without space and separates segments by 1.15
lines: `TranscriptMarkdown` cuts the text into top-level blocks (every list item one) where gpt_markdown's parser
starts them, renders each with its own `GptMarkdown` and spaces them itself. A long text split into several rows keeps
the gap its blocks have in one piece: each part after the first is spaced from the last block of the part above it
(`TranscriptMarkdown.previous`).

Tables fill the column: every column takes its content's width when they all fit and the last one takes what is left; else the narrow columns keep their width and the wide ones wrap at one shared width, never under 120 px nor under their widest code span (a path broken at its hyphen reads as two), and a table that still does not fit scrolls sideways. Cells have 12 px by 8 px padding; code in a cell has its font and no chip (a chip's tone would box it a second time on the striped rows); the header row's text is `w600` in `onSurfaceVariant`; rows alternate `surfaceContainer` and `surfaceContainerLow` with radius `radius`, no lines.
