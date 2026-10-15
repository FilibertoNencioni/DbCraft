# DbCraft design system

The visual world is **macOS-native Operate UI**: the window chrome recedes into one calm gray layer and SQL and data take the space. The tokens live in `lib/ui/theme/app_theme.dart` (`DbColors`, `Gap`, `Radii`, `TypeSize`) and every widget reads them through `DbColors.of(context)`. Do not hard-code colors in widgets.

## Surfaces

| Token | Light | Dark | Use |
|---|---|---|---|
| `content` | `#FFFFFF` | `#1E1E20` | Editors, grids, dialogs body |
| `chrome` | `#F4F4F6` | `#2A2A2D` | Unified toolbar, tab strip, status bars, grid header, form groups |
| `sidebar` | `#EDEDF0` | `#252528` | Source list (navigator, settings sidebar) |
| `raised` | `#FFFFFF` | `#323236` | Menus, popovers, sheets |
| `separator` | black 10% | white 15% | 1px hairlines only; no heavy borders |
| `zebra` | `#F7F7F9` | `#232326` | Alternate rows in tables and logs |

Elevation is either a hairline or a shadow, never both, except on sheets and menus.

## Color

- **One accent**: system blue (`#007AFF` light, `#0A84FF` dark). Use it only for the primary action (Esegui, Crea/Salva), selection, focus rings and the active state.
- **Semantic colors**: `success` (connected, commit), `warning` (pending changes), `danger` (errors, destructive actions, Interrompi).
- **Environment colors** (`ConnectionType`): green for development, orange for test, red for production. A dot or badge appears **only for test and production**; development is the default and stays silent.
- **Connection state** uses a separate signal: a solid green dot means connected and an empty ring means disconnected. Never reuse the environment dot to show state.
- **Driver brand colors** appear only on connection icons.

## Typography

- System font (SF on macOS) at 13pt body, 12 small, 11 caption, 15 titles, 17 sheet titles, 26 display (welcome only).
- `SF Mono` (falling back to Menlo/Consolas) for SQL, connection strings, error messages and data cells in value views.
- Tabular figures (`kTabular`) on every number: grid, counts, timings.
- Labels use sentence case. There are no eyebrows and no uppercase section headers; `SectionLabel` is 11pt semibold secondary.
- `textTertiary` (`#8A8A8E` light, `#7C7C82` dark) is for placeholders, dates and counts only, never for labels a user must read to orient.
- Shortcut glyphs: use ⌘ ⇧ ⌥ together with the word "Invio". Avoid ↩, which falls back to an emoji.

## Shape and spacing

- 4pt grid (`Gap`).
- Radii (`Radii`): 6 for controls, 8 for panels and form groups, 12 for sheets.
- Control height is 28 (buttons, fields, segmented controls). Toolbars are 52 (unified, macOS) or 44 (other platforms) for the app toolbar, 40 for the editor toolbar, 34 for the tab strip and 24 for status bars.
- Icon glyphs: 17 in controls (`ToolButton` default), 19–21 on 32pt buttons in the unified toolbar, 16–17 in source-list rows. Material glyphs draw smaller than SF Symbols, so never go below 16.
- Grid rows are 26 and the grid header is 30. Source-list rows (navigator, scripts) are 28 (`kSidebarRowHeight`).

## Components (`lib/ui/widgets/common.dart`)

- `ToolButton`: icon button with a hover tint and no ripple. `extent` is 28 for controls and 32 in the unified toolbar. Pass `label:` only when the text adds meaning (Commit).
- `SidebarTabs`: the navigator switcher at the top of the sidebar (Xcode style). Plain icons, the selected one in the accent, a hairline below. Never a segmented pill.
- `SidebarRow`: a single-line source-list row (icon, title, right-aligned tertiary detail such as a date). The hover/selection tint is the row itself. Row actions open from right click or from a "…" button that replaces the detail on hover; no permanent per-row buttons and no two-line rows in the sidebar.
- `PrimaryButton`: the single filled action of a surface, including empty-state actions. Flat accent fill with no colored glow. It scales to 0.97 on press over 120ms with ease-out.
- `Segmented`: macOS segmented control. Use it for mode switches (Griglia/Record, Auto/Manuale, object editor pages, dialog pages). An optional `dot:` adds a colored dot before a label, as in the environment picker (test and production only). Never stack two segmented controls as page tabs and a sub-mode.
- `SelectField`: macOS pop-up button for a fixed list of choices, with the ⌃⌄ glyph. Use it instead of the Material `DropdownButton`. Fields that also accept free text (driver, DSN) stay as text fields with a ⌃⌄ menu suffix.
- `SearchField`: filled, borderless and rounded. It shows a clear button while it has text.
- `FormGroup` + `FormRow`: grouped forms in the System Settings style (connection dialog, settings, constraints).
- `PropertyTable`: read-only key/value group.
- `SimpleGrid`: read-only zebra table for metadata.
- **Sheets** (connection dialog): the title only, with no icon tile and no subtitle. Use one scrolling page of `FormGroup`s ordered as identity, connection, authentication, behaviour, then an "Avanzate" disclosure for rarely used settings. Results such as "Prova connessione" appear inline in the footer, never in a dialog on top of the sheet.
- `EmptyState`: icon, title and a one-line explanation of what to do next. Never write just "nothing here".
- `InlineNotice`: a problem the user can fix without leaving the sheet (missing OpenSSL, ODBC unavailable). Tinted with `warning` or `danger` at 8% and a 35% hairline, never both a border and a shadow. It sits above the `FormGroup`s and carries at most one action or a command to copy.
- **Manager sheets** (Driver ODBC): fixed 780×560 like Preferenze. The title is on the left, a centered `Segmented` switches pages and a `ToolButton` closes. Pages are `FormGroup` lists with a one-line footer. Rows act through `OutlinedButton`s, never several `PrimaryButton`s. Long-running work shows a log docked at the bottom: a 34pt chrome bar with the status, Copia and a red Interrompi.
- `StatusDot`, `EnvDot`, `Badge2`, `DbSwitch` (a compact Cupertino switch).

## Shell

- **macOS**: the title bar is transparent with a full-size content view (`MainFlutterWindow.swift`). The Flutter toolbar sits next to the traffic lights and can be dragged and double-clicked through the `dbcraft/window` channel. Menus are native (`PlatformMenuBar`) and include the app, File, Database, SQL, Vista, Finestra and Aiuto menus.
- **Windows/Linux**: the same menu model is rendered as an in-window `MenuBar`.
- **Toolbar**: sidebar toggle and the create actions on the left; in the center, the connection pill (Xcode activity view) with a connect/disconnect toggle; on the right, transaction mode and history.
- **Editor tabs**: the active tab shares the content color. The close button appears on hover or when the tab is active, and a dirty dot replaces it otherwise. The environment dot appears only for test and production.

## Motion

Motion is rare and functional:
- Disclosure chevrons rotate over 120ms with ease-out.
- The sidebar slides in and out over 200ms with ease-out cubic when toggled from the toolbar button. It keeps its full width, pinned to the divider, while the editor area reflows. ⌘0 and the menu item cut instantly, and so does Reduce Motion. A second toggle mid-slide reverses from the current position.
- Collapsed panes (`SplitView`) stay mounted, so tree expansion, filters, scroll and editor state survive hide and show.
- `PrimaryButton` gives press feedback.
- Hover tints change instantly.

Keyboard-initiated actions are never animated, and there are no page-load sequences.

## Data grid

- Zebra rows. Cells use primary-color text; numbers are right aligned with tabular figures.
- NULL is shown as tertiary italic and slightly smaller.
- The header shows the column name in semibold followed by the lowercase type in caption tertiary. The key icon appears only for real primary keys.
- Selection uses the accent at about 18%. The cursor cell gets a 1.5px accent outline.
- Edit state: an amber cell marks a changed value. Green and red row markers (a 3px bar in the row header) mark inserted and deleted rows.
- Pending changes show a badge, an "Annulla" button and a filled "Salva (⌘S)" button in the grid toolbar. This is progressive disclosure: the controls only appear when there are changes.
