# DbCraft design system

The visual world is **macOS-native Operate UI**, modelled on macOS Sonoma/Sequoia (Xcode, Finder, System Settings) without Liquid Glass. The window chrome recedes into one calm gray layer and SQL and data take the space.

Everything is built from a small set of components in `lib/ui/widgets/` (all re-exported by `common.dart`) on top of the tokens in `lib/ui/theme/`. UI code outside those two folders uses only components, `AppIcons` and `DbColors`; `test/design_guardrail_test.dart` fails the build otherwise (see [Forbidden](#forbidden)).

`lib/ui/dev/control_gallery.dart` (Aiuto ▸ Galleria controlli, debug builds) shows every component in light, dark and inactive-window states. `integration_test/gallery_test.dart` saves it as a PNG with the real system fonts, to compare against native screenshots.

## Foundations

Tokens live in `lib/ui/theme/app_theme.dart` (`DbColors`, `Gap`, `Radii`, `TypeSize`, `uiText`) and `lib/ui/theme/tokens.dart` (`ControlSize`, `BarHeight`, `Tint`, `Elevation`, `Motion`). Widgets read colors through `DbColors.of(context)`. Never hard-code colors, alphas, shadows, sizes or durations.

### Surfaces

| Token | Light | Dark | Use |
|---|---|---|---|
| `content` | `#FFFFFF` | `#1E1E20` | Editors, grids, field fills |
| `chrome` | `#F4F4F6` | `#2A2A2D` | Toolbars, tab strips, pane bars, status bars, grid header |
| `sidebar` | `#EDEDF0` | `#252528` | Source lists (navigator, settings sidebar) |
| `windowBackground` | `#ECECEC` | `#2B2B2E` | Sheets, alerts, inspectors, settings pages |
| `raised` | `#FFFFFF` | `#323236` | Popovers, canvas nodes, HUD |
| `menuBackground` / `tooltipBackground` | `#F6F6F6` / `#F7F7F7` | `#2E2E31` / `#3A3A3C` | Menus, completion lists / tooltips |
| `separator` | black 10% | white 15% | Hairlines only |
| `zebra` | `#F7F7F9` | `#232326` | Alternate rows |

A surface has a hairline or a shadow, never both, except menus, popovers and sheets (0.5px border plus shadow).

### Color

- **One accent**: the user's system accent color (`NSColor.controlAccentColor`, default blue), delivered by `WindowBridge`. Use it only for the default action, selection, focus rings and the "on" state.
- **Inactive window**: when the window is not key, `DbColors.resolve` turns `selection`, `selectionEmphasized` and `defaultButton` gray, as AppKit does. Use those tokens, never `accent`, for selections and the default button.
- **Semantic colors**: `success` (connected, commit, added), `warning` (pending changes, changed), `danger` (errors, destructive actions, removed). Diffs and edit states use the aliases `diffAdded`, `diffRemoved`, `diffChanged`, `diffHunk`.
- **Environment** (`ConnectionType.colorOf(c)`): green development, orange test, red production. A dot or `Tag` appears **only for test and production**; development stays silent.
- **Connection state** is a separate signal: a solid green dot means connected, an empty ring disconnected. Never reuse the environment dot for state.
- **Data colors**: `keyIcon` (primary keys), `foreignKeyIcon`, `codeKeyword`/`codeFunction`/`codeTable`/`codeColumn`/`codeType` (completion kinds). Driver and cloud brand colors appear only on connection and account icons.
- **Tints** (`Tint`): `subtle` 0.08 (notice fills), `regular` 0.14 (tags, tokens), `strong` 0.22 (grid selection, changed cells), `border` 0.35 (tinted hairlines). No other alphas.

### Typography

- System font (`.AppleSystemUIFont`): 13 body, 12 small, 11 caption, 10 mini, 15 title, 17 sheet title, 20 headline, 26 display (welcome only). Build styles with `uiText(size, …)`: it applies SF's size-specific tracking (−0.08 at 13pt), which Flutter does not apply. No fractional sizes.
- `monoStyle` (SF Mono, falling back to Menlo/Consolas) at `TypeSize.mono` 12 or `monoSmall` 11, for SQL, values, connection strings and errors.
- Tabular figures (`kTabular`) on every number: grid, counts, timings.
- Sentence case everywhere; no uppercase section headers. `textTertiary` is for placeholders, dates and counts, never for labels a user needs to orient.
- Shortcuts are always formatted by `shortcutLabel()` / `ShortcutText` (⌘ ⇧ ⌥ ⌃ plus "Invio", "Canc", "Ins"). Never type glyphs by hand, and avoid ↩, which renders as an emoji.

### Shape, size and spacing

- 4pt grid (`Gap`: 4, 8, 12, 16, 24, 32).
- Radii (`Radii`): 4 small (tags, keycaps, tooltips), 5 controls and rows, 6 menus, 8 panels, form groups, notices and code boxes, 10 sheets, alerts and popovers.
- Control heights (`ControlSize` / `ControlScale`): 22 regular (buttons, fields, pop-ups, segmented controls in forms and bars), 19 small (dense bars), 16 mini (inline accessories), 28 toolbar.
- Bars (`BarHeight`): 52 window toolbar, 36 pane toolbar (`PaneBar`), 28 pane header and inner strips (`PaneHeader`, `PaneTabs`), 30 document tabs, 22 status bar.
- Rows: 28 source list (`kSidebarRowHeight`), 24 dense lists and tables (`kDenseRowHeight`, `GridMetrics`); 38 for two-line `ListRow`s.
- Focus: a 3.5px outer halo in `focusRing` (`FocusRing`, `MacFieldBorder`), shown only for keyboard focus. Never a thicker inner border.

### Icons

Only `AppIcons` (`lib/ui/theme/app_icons.dart`): the Phosphor font bundled in `assets/fonts/phosphor`, Regular by default, Bold for chevrons and tiny marks, Fill for selected states. Sizes: 16 in controls, 18 in the window toolbar, 14 in dense rows. Action menus have no icons; value menus (pop-ups, combo fields) may show an item image, such as the driver icon, in its own column after the checkmark.

### Elevation and motion tokens

- `Elevation.control` (bezel buttons, checkboxes), `node` (canvas boxes), `menu`/`popover`, `sheet`, and `Elevation.scrim` for the backdrop behind sheets and alerts.
- `Motion.fast` 100ms (focus ring, menu highlight, chevrons), `Motion.regular` 200ms (sheets, sidebar). `Motion.of(context, d)` returns zero under Reduce Motion.

## Component catalog

One line per component: what it is for, and what to use instead when it is not the right one. The gallery shows each in every state.

### Buttons (`buttons.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `PushButton` | Bezel buttons: Annulla, secondary actions, row actions. `small` in bars. | Toolbar icons (`ToolButton`), links (`LinkButton`). |
| `PushButton.primary` | The single default action of a sheet, alert or bar (Invio): Esegui, Crea, Salva. Gray when the window is inactive. | More than one per surface. |
| `PushButton(kind: destructive)` | Interrompi, Elimina. Filled red only inside alerts. | Undoable actions. |
| `ToolButton` | Icon buttons in toolbars and pane bars: bezel on hover and press only, accent glyph when `active`. `label:` only when the text adds meaning (Commit). | Primary actions; it is outside the Tab order, as in AppKit. |
| `PulldownButton` | An icon or text plus ⌄ that opens a menu of actions ("…", AI). | Choosing a value (`PopUpButton`). |
| `LinkButton` | Inline links in prose and rows: Dettagli…, Apri, Vai a. | Sheet footers. |
| `DisclosureButton` / `DisclosureChevron` | Show/hide a section (Avanzate, groups); with `icon`/`subtitle` it is an item row (ODBC drivers) and `contentIndent` aligns the disclosed content. | Navigation. |
| `ToolSeparator` | 1×16 divider between toolbar groups. | Lists. |

### Fields (`fields.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `MacTextField` | Text entry: 22pt, 0.5px outline, outer focus ring; mono, multiline, `expands` (fills its parent, Value dialog), text `color`, unit suffix and token prefix variants. Errors with `FieldMessage` below. | Secrets (`SecureField`), numbers (`NumberField`). |
| `SecureField` | Passwords, keys and tokens, with its own reveal eye; `maxLines` for multi-line secrets (one masked line until revealed) and `onChoose` for a "Scegli…" that loads a key file. | — |
| `SearchField` | Filtering lists and grids (filled, rounded, clear button). | Free text. |
| `ComboField` | Free text with suggestions (driver, DSN, column type, AI model): inline completion with `autocomplete:`, `leading` icon in the field, menu rows with `optionDetail`/`optionIcon`, extra `actions` after a divider (Installa driver…), `onSelected` only for menu picks. | A fixed list (`PopUpButton`). |
| `PathField` | A file or folder path plus "Scegli…". | — |
| `NumberField` / `MacStepper` | Port, LIMIT, timeouts, counts: tabular, right aligned, arrows and scroll; clamps on blur. | Free numbers in prose. |
| `DateField` / `MiniCalendar` | Dates with editable segments and a calendar popover; `time: true` adds hh:mm (timestamps); `clearable:`. | — |
| `TokenField` / `FilterToken` | Removable tokens (visual filter conditions). | Status labels (`Tag`). |
| `cellEditorDecoration` / `CellFieldBorder` | The in-cell editor of grids. | Forms. |

### Selection (`selection.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `MacCheckbox` / `CheckboxRow` | Options in forms, bars and tables (tristate supported); `CheckboxRow` makes the label clickable and takes a `tooltip` and a `labelColor` (red for a destructive option). | Settings that apply immediately in a `FormRow` (`DbSwitch`). |
| `MacRadio` / `MacRadioGroup` | 3–5 mutually exclusive options with descriptions. The group is one Tab stop; arrow keys move the selection. | Two or three short modes (`Segmented`). |
| `DbSwitch` | On/off settings in `FormRow`s only (HIG). | Toolbars and bars (`CheckboxRow` small). |
| `Segmented` | Mode switches (Griglia/Record, Auto/Manuale); `dot:` for the environment picker. | Long or many options (`PopUpButton`); never two stacked. |
| `PopUpButton` (`form`, `inline`, `toolbar`) / `SelectField` | A value from a fixed list, `null` included ("Numero di riga"); type-to-select; `SelectField` is the full-width form variant; `entries:` for custom rows. | Actions (`PulldownButton`). |
| `ScopeBar` / `ScopeItem` / `ToggleButton` | Recessed filter toggles with dot, count (Italian thousands separators) and tooltip (Finder scope bar). | Page switching. |
| `MacSlider` | Continuous values (font size, percentages). | Exact numbers (`NumberField`). |

### Menus, popovers, tooltips (`menus.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `showMacMenu` + `MenuEntry` | Every context menu and pop-up menu: 22pt items, accent highlight, a checkmark column and a separate `leading` column (status dots, value images), right-aligned shortcuts, submenus, `MenuEntry.connection` rows. No action icons. | Rich content (`showPopover`). |
| `showPopover` | Anchored editors and information (filter editor, calendar). | Choosing from a list. |
| `CompletionList` | SQL completion, Xcode style, with letter badges in the `code*` colors. | Menus. |
| `RichTooltip` | Tooltips with a title and key/value lines (grid header). | Plain hints (the theme `Tooltip`, 800ms delay). |

### Sheets and alerts (`sheets.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `showSheet` + `SheetScaffold` | Every modal task: title, scrolling body, footer with secondary actions or inline status on the left and Annulla plus the default button on the right. Sizes `SheetSize.small` 420, `medium` 560, `large` 780×560, `xlarge` 900×640. | Confirmations (`showAlert`). |
| `showAlert` / `confirmDialog` / `promptText` / `showErrorDialog` / `guarded` | Short questions and errors: app icon, bold title, message; two short buttons side by side (default on the right), three or more stacked; error details in a disclosure with Copia. | Forms. |
| `showListPicker` | Picking one item from a searchable list (connection, table, overload); `load:` fetches the items with a spinner and shows errors and the `empty:` text inside the picker; `iconColor:` tints the icons. | Fixed short lists (`PopUpButton`). |
| `showAboutPanel` / `AboutPanel`, `showShortcutsSheet` | The About panel and the keyboard shortcuts sheet. | — |
| `SettingsWindow` (`dialogs/app_dialogs.dart`) | Preferenze: System Settings layout with a source-list sidebar and "Fine". | — |

Sheets and alerts are centered over a dimmed window (`Elevation.scrim`) and fade in while growing from 96% (fade only under Reduce Motion). Esc cancels (respecting `PopScope`), Invio runs the default button except in multi-line fields (⌘Invio always does). Sheets have no close X: Annulla, Fine or Esc. Sheets that run destructive work (sync, DDL, mock data) register no default button, so Invio cannot start them.

### Navigation (`navigation.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `WindowTabBar` / `WindowTab` | Document tabs (Safari/Xcode): flexible width, close button on the left on hover, dirty dot, environment accessory, reorder, middle click closes. | Inner panes (`PaneTabs`). |
| `PaneTabs` / `PaneTab` | Tabs inside a pane (results, Output, Log, debugger messages), with counts, an `iconColor` (danger for a failed result) and close on hover or middle click. | Documents. |
| `SidebarTabs` / `SidebarTab` | The navigator switcher at the top of the sidebar: icons only, Fill and accent when selected. | Anywhere else. |
| `PageSwitcher` | Pages of an object editor (NSTabView style, a centered `Segmented` on the hairline), with an optional `trailing` accessory (Dettagli). | Modes (`Segmented`). |
| `PathBar` / `PathSegment` | Jump bars and breadcrumbs (cloud browser, table editor). | — |

### Lists (`lists.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `SourceList` + `OutlineRow` | Sidebars and trees (navigator, cloud, scripts, git files, schema diff): 28 or 24 rows, chevron, an optional `leading` control (checkbox) before the icon, right-aligned tertiary detail (sized to its text: it takes what the title leaves free and gives way down to 40% of the row, so the title keeps priority), accessories; accent selection when focused, gray otherwise. Actions from right click or a "…" on hover; no permanent row buttons, no two-line rows. | Content lists (`ListRow`). |
| `SidebarRow` | A single source-list row without a tree. | — |
| `ListRow` | Lists in the content area (welcome, history, log, commits, drivers): 24 single or 38 double line, leading icon, trailing accessory, `trailingOnHover` for an action shown only on hover (Apri). | Sidebars. |
| `SectionLabel` | Group titles (11 semibold secondary); collapsible with `onToggle`. | Page titles. |
| `RecordView` / `RecordField` | One record as a read-only form (grid record mode); `onFieldDoubleTap` opens a field's value. | Editing forms. |

### Tables (`tables.dart`, `results/result_grid.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `ResultGrid` | Query results and table data: 24 header and rows, zebra, `TableHeaderCell` with name, `TypeLabel` and sort chevron, `ColumnResizeHandle`, row-state markers, cursor `FocusRing` only while focused, in-cell editor. | Metadata (`MacTable`). |
| `MacTable` | Read-only and lightly interactive tables (`dense:`): sortable header with `headerLeading` icons, zebra, `leading` slot for indent, status stripe, `cellTint`, inline controls, `flex` columns, `wrap` for multi-line rows, a `footer` row. Single selection, or multi-selection with `selection`/`onSelectionChanged` (⇧/⌘-click, ⇧↑↓, ⌘A); ⌘C copies the selected rows; `emphasizeSelection` for the Finder look. | Large editable data (`ResultGrid`). |
| `SimpleGrid` | A bordered `MacTable` sized to its content (columns, indexes). | — |
| `PropertyTable` | Read-only key/value pairs (a `FormGroup` with secondary labels). | — |
| `EditableGrid` (`editable_grid.dart`) | Rows of controls: the column grid of the table designer, column pairs. 28 rows, zebra, a 3px `diffAdded` / `diffChanged` marker for new and changed rows, ↑ ↓ ⊖ on each row, "Aggiungi" under it; ⌘↑ / ⌘↓ move the selected row and ⌫ removes it while the grid (not a field) has the focus. | Data (`ResultGrid`), read-only lists (`MacTable`). |

### Badges and markers (`badges.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `CountBadge` | Counts: neutral capsule, `prominent` accent only to draw attention. | Labels (`Tag`). |
| `Tag` | Status and type labels (vista, nuova, pericoloso, Produzione): radius 4, tinted. | Counts. |
| `StatusDot`, `EnvDot`, `IconBadge` | Connection state, environment (test and production only), state over an icon. | — |
| `StatusLetter` | Git-style letters (M, A, D). | — |
| `ActivityView` | The connection pill in the window toolbar (Xcode activity view). | — |
| `KeyCap` / `KeyCaps` / `ShortcutText` | Shortcuts in sheets, welcome and tooltips. | — |
| `TypeLabel`, `DirtyDot`, `Capsule`, `RowTint` | SQL types (with a state `color` for modified columns); unsaved marker; base capsule; white accessories on accent rows. | — |

### Progress and status (`progress.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `Spinner` (`small` 12, `regular` 16, `large` 32) | Indeterminate work: 12-spoke macOS spinner. | Known progress. |
| `ProgressBar` | Determinate and indeterminate progress (export, import, transfers). | Under bars (`LoadingLine`). |
| `LoadingLine` / `PaneBar(loading:)` | A 2px line under a bar while a pane loads. | — |
| `LevelIndicator` | Shares and levels with warning/danger thresholds (plan cost); `value: null` sweeps (transfer of unknown size). | Determinate work with a label (`ProgressBar`). |
| `StatusLine` / `StatusLine.busy` | One-line results: Prova connessione, verifications, debugger state; `dot:` for a neutral state with a colored dot (in pausa, live/sospeso). | Problems to fix (`Notice`). |

### Feedback (`feedback.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `Notice` (`info`/`warning`/`danger`), `Notice.strip`, `Notice.card` | A problem the user can act on: inline box with one action (above the `FormGroup`s), full-width strip under a toolbar, card with several actions. | Transient confirmations (`showToast`). |
| `showToast` / `showHud` / `HudCapsule` | Brief confirmations: a capsule above the status bar for 3s. | Errors that need reading (`showErrorDialog`). |
| `EmptyState` / `EmptyState.error` | Empty panes: icon, title, one line on what to do next, optional `PushButton`. Never just "nothing here". | — |
| `ErrorDetails`, `FieldMessage` | Copyable error details; help or error text under a field. | — |

### Surfaces and bars (`surfaces.dart`, `bars.dart`, `split_view.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `FormGroup` + `FormRow` | Grouped forms in System Settings style on `windowBackground`; automatic label width, shared by all groups inside a `FormScope` (every `SheetScaffold` body has one) up to 30% of the width, so columns line up across groups; `help` under the label. | Data tables. |
| `CodeBox` / `CodeBox.lines` | Code, commands and previews: `codeBackground`, optional header with language and Copia. `CodeBox.lines` is the virtualized variant for streaming logs: it follows the last line unless scrolled up, with an optional `status` row. | Editable SQL (the code editor). |
| `DiffView` (`diffLines`, `parseUnifiedDiff`) | Every diff (AI fixes, git). | — |
| `PaneBar`, `PaneHeader`, `StatusBar` | The three bar heights (36, 28, 22), all on `chrome` with a hairline; `PaneBar.footer` / `hairline: BarHairline.top/both` for bars at the bottom of a pane. | Hand-built bars. |
| `SplitView` | Resizable panes; neutral hairline divider; collapsed panes stay mounted. | — |
| `AppMark` | The app icon tile (welcome, About, alerts). | — |

### Panels (`panels.dart`)

| Component | Use it for | Not for |
|---|---|---|
| `Inspector` + `InspectorSection` | Xcode-style side panes (chart, data compare, visual plan): 260–320 wide on `windowBackground`, hairline toward the content, collapsible sections with an 11pt header. | Sheets and forms. |
| `StatTile` | KPI tiles (performance dashboard): label, 17pt tabular value, `warning` state, optional sparkline. | Plain numbers in a table. |
| `InsetBox` | A bordered content box inside a sheet or page (column lists). | Code (`CodeBox`), forms (`FormGroup`). |
| `DragChip` | Drag feedback for tables and columns (query builder). | Static labels (`Tag`). |

## Patterns

- **Sheets with forms** (connection dialog): title only, one scrolling page of `FormGroup`s ordered identity, connection, authentication, behaviour, then an "Avanzate" disclosure. Results such as "Prova connessione" appear as a `StatusLine` in the footer, never in a dialog on top of the sheet.
- **Manager sheets** (Driver ODBC): `SheetSize.large`, title on the left, a centered `Segmented` for pages, "Fine". Rows act through `PushButton`s, never several default buttons. Long work shows a docked log with a `PaneHeader` (status, Copia, Interrompi).
- **Sidebar navigators** (Database, Script, Cloud, Git): the same opening on every tab, so switching keeps the eye in place: a `SectionLabel` with the panel's tools on the right (add, collapse, refresh; "…" `PulldownButton` for the rest), then the filter `SearchField` (or, for Git, the branch row), then the `SourceList` inset 10 from the edges. Open items have a semibold title, never an accent icon.
- **Source control** (Git navigator): the header is the repository (`owner/repo`, or "Repository locale") with Sincronizza and "…" (Pull, Push, Aggiorna, Impostazioni); the branch is an `OutlineRow` with ahead/behind arrows and the remote URL in its tooltip. A `Segmented` switches Modifiche (count in the label) and Cronologia. Modifiche is a dense `SourceList` of `StatusLetter` rows (double click or Invio shows the diff, "…" discards) with the commit composer pinned under it: message field, file count, `PushButton.primary` "Commit" (⌘Invio); with no changes the page is an `EmptyState` and the composer disappears. Cronologia is two-line `ListRow`s (subject; author · relative date) with an upload glyph on commits not yet pushed; the hash lives in the tooltip and "Copia hash".
- **Inspectors** (chart, data compare, visual plan): an `Inspector` with `InspectorSection`s holding compact fields, `FormRow`s or `CheckboxRow`s.
- **Manager tabs** (Utenti e ruoli): a source list of the items grouped by kind (`SectionLabel` headers, "+" `PulldownButton` for the new kinds) beside the editor of the selected one, which follows the editable object pages pattern; switching item with pending changes asks to discard them. Privilege matrices are `MacTable`s of `MacCheckbox`es with a first "Tutti (n)" row (tristate) that applies to every listed object. Passwords use `SecureField` plus a confirmation and reach the script only as secrets.
- **Editable object pages** (table designer): edits stay pending in a design session; the editor header shows the dirty dot, undo / redo, "Scarta" and one `PushButton.primary` "Salva" (⌘S), disabled with the first validation error as tooltip. A "Modifiche (n)" page lists every change with a checkbox to leave it out and the live script. Saving always goes through the script sheet (`showDdlScriptDialog`); new and changed items are labelled "· nuovo" / "· modificato" in `diffAdded` / `diffChanged`.
- **Data grid**: numbers right aligned and tabular; NULL tertiary italic; the key icon only for real primary keys; selection at `Tint.strong`; changed cells amber, inserted and deleted rows with a 3px green or red marker. Pending changes show a `CountBadge`, Annulla and "Salva (⌘S)" only while there are changes.
- **Canvas** (ER diagram, query builder, visual plan): boxes on `raised` with `Elevation.node`, radius 6, a 24 header; selection with the focus ring; lines in `textTertiary`, accent when selected, `success` when new.

## Shell

- **macOS**: transparent title bar with a full-size content view (`MainFlutterWindow.swift`). An empty unified `NSToolbar` makes AppKit center the traffic lights on the 52pt toolbar; in full screen the toolbar auto-hides with the menu bar. AppKit's own title-bar double click is off (it also fired over Flutter buttons): Flutter counts clicks on the empty bar and zooms through the `dbcraft/window` channel, which also delivers the key state and the accent color. Menus are native (`PlatformMenuBar`): app, File, Database, SQL, Vista, Finestra, Aiuto.
- **Windows/Linux**: the same menu model as an in-window menu bar; no traffic-light inset.
- **Layout**: `SplitView` at the root. The sidebar runs the full window height: a 52pt strip under the traffic lights, `SidebarTabs`, then the panels. The content column has the toolbar (create actions on the left, `ActivityView` centered, transaction mode and history on the right), the `WindowTabBar`, the editor and the `StatusBar`, which sits under the content only.
- **Sidebar toggle**: fixed to the right of the traffic lights, over the sidebar strip or, with the sidebar closed, over the toolbar (Xcode 15); the toolbar padding animates with the slide.
- **SQL editor bar**: "Esegui" `PushButton.primary` small (or "Interrompi" destructive), `PulldownButton`s for "…" and AI, `PopUpButton(style: toolbar)` for catalog and connection.

## Motion

Motion is rare and functional:
- Disclosure chevrons rotate and the focus ring fades over `Motion.fast`.
- Sheets and alerts fade and grow from 96% over `Motion.regular`.
- The sidebar slides over 200ms with ease-out cubic from the toolbar button, keeping its width while the editor reflows; ⌘0, the menu item and Reduce Motion cut instantly, and a second toggle mid-slide reverses.
- Hover tints change instantly; there is no press scaling and no page-load sequence. Keyboard-initiated actions are never animated.

## Forbidden

Outside `lib/ui/widgets/` and `lib/ui/theme/`, `test/design_guardrail_test.dart` fails on:

- Material widgets: `FilledButton`, `OutlinedButton`, `TextButton`, `IconButton`, `SegmentedButton`, `DropdownButton*`, `DropdownMenu*`, `PopupMenuButton`, `PopupMenuItem`, `showMenu`, `AlertDialog`, `SimpleDialog`, `showAboutDialog`, `showDatePicker`, `Checkbox`, `CheckboxListTile`, `Radio*`, the chips, `ListTile`, `Card`, `ExpansionTile`, `TabBar`, `SnackBar`, `CircularProgressIndicator`, `LinearProgressIndicator`. Use the catalog component listed above.
- `Icons.*` (use `AppIcons`), `Colors.*` other than `transparent`, and literal colors (`Color(0x…)`, `Color.fromARGB`, `Color.fromRGBO`).

The only allowed literal colors are data, listed per file in the test: database and cloud brand colors (`model/connection_config.dart`, the native drivers, `cloud/ui/cloud_account_dialog.dart`) and the chart palette (`features/charts/chart_palette.dart`). The test also fails when an exception is no longer needed. Plain structural Material widgets (`Material`, `Divider`, `Scaffold`, `Tooltip`) remain allowed.
