---
version: 1
slug: "lib-ui-home-page-dart"
primary_target: "lib/ui/home_page.dart"
related_targets: ["lib/ui"]
---

Scope: whole desktop app shell (lib/ui/**) · Mode: Operate.

## Direction contract
THESIS: A database client that feels like a first-party Mac app: chrome recedes into one calm gray layer and data and SQL take the space. It refuses the category default of DBeaver/Eclipse: stacked toolbars, in-window menus, colored icon confetti, heavy panel headers.
OWN-WORLD: macOS Sonoma/Sequoia system materials, no Liquid Glass, all from DbColors tokens. Light: white content, #F4F4F6 chrome, #EDEDF0 sidebar, #ECECEC window background for sheets and inspectors, hairline separators at 10% black. Dark: #1E1E20 content, #2A2A2D chrome, #2B2B2E window background. One accent, the user's system accent color, only for selection, focus and the default action, turning gray when the window is not key. Environment dots (test orange, production red; development silent) are the only other hues besides semantic success/warning/danger and data brand colors. SF system font with SF tracking (uiText), 13pt body, SF Mono for code and data, tabular numerals. Phosphor icons through AppIcons. 22pt controls, 5px radii on controls, 6 on menus, 8 on panels, 10 on sheets; outer focus ring; no ripples, hover tints. Components only from lib/ui/widgets (DESIGN.md catalog), enforced by test/design_guardrail_test.dart.
STORY: Users see at a glance which connection and environment they are on, run SQL with one obvious Esegui button or ⌘Invio, read results in a quiet zebra-striped table, and find everything else in the native menu bar.
FIRST VIEWPORT: full-height source-list sidebar on the left, its 52pt top strip under the traffic lights with the sidebar toggle, then the navigator switcher (SidebarTabs) and the tree; on the right a 52pt unified toolbar over the content only (create actions on the left; transaction control and history on the right), 30pt document tabs (WindowTabBar), the editor with its 36pt pane bar, and a 22pt status bar under the content only.
FORM: macOS-native Operate shell (brief-pinned; no concept roll). Seed key: brief-pinned.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
