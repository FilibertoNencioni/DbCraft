# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users
- **Primary: software developers** who write queries, explore schemas and edit development/test data many times a day.
- **Also: DBAs** who juggle many connections and environments, production included.
- **Also: analysts** who mainly browse, filter and export data.

## Product Purpose
DbCraft is a desktop database client (DBeaver-style) built with Flutter for macOS, Windows and Linux. It connects to any database that has an ODBC driver and covers connection management, schema navigation, a SQL editor, a data grid editor, an ER diagram, import/export and query history. Success: daily SQL and data work feels faster and calmer than in Java-based tools.

## Positioning
Native-feeling, lightweight Flutter app with ODBC connectivity (no JVM, no JDBC drivers): any installed ODBC driver or DSN is immediately usable.

## Operating Context
Long working sessions with many open editors; keyboard-driven (Cmd/Ctrl+Enter, Alt+X, F4, F5); dense data tables; dev/test/production connections side by side, where production safety matters.

## Capabilities and Constraints
- Desktop only: macOS, Windows, Linux. On macOS the app uses the native menu bar; on Windows/Linux an in-window menu bar stays.
- ODBC via dart:ffi; one isolate per session.
- UI language: Italian.

## Brand Commitments
Name: DbCraft. No logo assets yet (do not invent claims or badges).

## Evidence on Hand
Demo SQLite database in `sample/demo.db`; end-to-end screenshots produced by `integration_test/app_test.dart`.

## Product Principles
1. Data first: chrome recedes, results and code get the space.
2. Keyboard and mouse both first-class; every frequent action has a shortcut and needs no animation.
3. Make the environment obvious: which connection, which type (dev/test/prod), which transaction mode.
4. Simple for occasional users (analysts) without slowing developers down.
5. Feel native on each platform.
