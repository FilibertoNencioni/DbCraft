---
version: 1
slug: "lib-ui-home-page-dart"
primary_target: "lib/ui/home_page.dart"
related_targets: ["lib/ui"]
---

Scope: whole desktop app shell (lib/ui/**) · Mode: Operate.

## Direction contract
THESIS: A database client that feels like a first-party Mac app: chrome recedes into one calm gray layer and data and SQL take the space. It refuses the category default of DBeaver/Eclipse: stacked toolbars, in-window menus, colored icon confetti, heavy panel headers.
OWN-WORLD: macOS system materials. Light: white content, #F3F3F5 chrome, #ECECEF sidebar, hairline separators at 10% black. Dark: #1E1E20 content, #2A2A2D chrome. One accent (system blue #007AFF / #0A84FF) only for selection, focus and the primary action. Connection-type dots (green/orange/red) are the only other hues. SF system font 13pt, SF Mono for code and data, tabular numerals. 6px radii on controls, 10–12px on sheets, no ripples, hover tints.
STORY: Users see at a glance which connection and environment they are on, run SQL with one obvious Esegui button or ⌘↩, read results in a quiet zebra-striped table, and find everything else in the native menu bar.
FIRST VIEWPORT: unified 52px toolbar (traffic lights, sidebar toggle, connection picker pill with environment dot, transaction control, run/history/settings on the right); source-list sidebar on the left; editor tabs and content on the right; 22px status bar.
FORM: macOS-native Operate shell (brief-pinned; no concept roll). Seed key: brief-pinned.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
