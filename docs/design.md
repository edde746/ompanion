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

## Tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| `surface` | `#000000` | `#FFFFFF` | app background, chat |
| `surfaceContainerLow` | `#0B0B0B` | `#F7F7F7` | sidebar, dock, config navigation |
| `surfaceContainer` | `#121212` | `#F0F0F0` | cards, tool cards, composer, code blocks |
| `surfaceContainerHigh` | `#1A1A1A` | `#E8E8E8` | fields, chips, tonal buttons |
| `surfaceContainerHighest` | `#262626` | `#DDDDDD` | hover, selected rows, focused fields, selected segment, navigation indicators |
| `surfaceBright` | `#2E2E2E` | `#D4D4D4` | popovers: menus, select and dropdown menus, popup menus. Distinct from every tone they open over; in light mode it is the darkest surface, because nothing is lighter than the white chat |
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
| Content inside a popover | tones step up from the popover's own as `onSurface` overlays: a field 6 % (8 % focused), the selected row 14 % with `radius`. The container ladder's field and selection tones would sink into `surfaceBright` |
| Menu from the composer toolbar | opens `gap` (8 px) above the composer block, never over it; the model list starts at the block's left edge and is at most as wide as the block |
| Composer | a `surfaceContainer` block with `cardRadius`. The text's ink and the toolbar's first icon share one left edge 12 px inside the block; 12 px above the first line box; the toolbar's 36 px controls sit 8 px from the bottom and right edges |
| Sidebar session row | one mark in the icon column, under the project's folder icon: the status (working, needs input, failed, disconnected, open in omp on the machine), else the unread dot. Unread with a status shows through the bold title alone. The title starts in the project path's column; the relative time sits at the end |
| Modal dialog | `surfaceContainer` with `sheetRadius`, over a black scrim (80 % dark, 50 % light), so a dialog opened from a dialog stands apart from it. Not `surfaceContainerHigh`: the fields, selects and tonal buttons inside have that tone |
| Monospace text (ids, paths, keys, scripts) | `codeTextStyle`, the code blocks' font; the generic `monospace` family does not resolve on macOS |
| Status of a quota, limit or machine | an 8 px dot in `AppColors` `success`, `warning` or `error` (`onSurfaceVariant` when unknown) at the start of the row; a limit an account lacks gets a `surfaceContainerHighest` dot |
| Quota bar | 6 px tall, radius 3, a `surfaceContainerHighest` track filled to the used fraction in `onSurface`; `warning` or `error` fill only once the limit warns or is exhausted; an empty track when the provider reports no fraction |
| Machines an entry came from | `ConfigTag` pills at the end of the entry's first line |
