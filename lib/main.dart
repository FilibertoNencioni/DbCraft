import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'cloud/auth/db_tokens.dart';
import 'drivers/session_factory.dart';
import 'services/storage.dart';
import 'services/vault.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/platform/window_bridge.dart';
import 'ui/security/lock_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  databaseTokenProvider = fetchDatabaseToken;
  // DBCRAFT_WORKSPACE allows using an alternative workspace folder.
  final ws = Platform.environment['DBCRAFT_WORKSPACE'];
  final (workspace, vault) = await AppState.openStorage(workspaceDir: ws == null || ws.isEmpty ? null : Directory(ws));
  if (!vault.isLocked) {
    runApp(DbCraftApp(state: await AppState.loadWith(workspace, vault)));
  } else {
    runApp(_UnlockApp(workspace: workspace, vault: vault, settings: await workspace.loadSettings()));
  }
}

/// Startup with a master password: asks it, then loads the application.
class _UnlockApp extends StatefulWidget {
  const _UnlockApp({required this.workspace, required this.vault, required this.settings});
  final Workspace workspace;
  final Vault vault;
  final AppSettings settings;

  @override
  State<_UnlockApp> createState() => _UnlockAppState();
}

class _UnlockAppState extends State<_UnlockApp> {
  AppState? _state;

  Future<bool> _unlock(String password) async {
    if (!await widget.vault.unlock(password)) return false;
    final s = await AppState.loadWith(widget.workspace, widget.vault);
    setState(() => _state = s);
    return true;
  }

  Future<void> _reset() async {
    await widget.vault.reset();
    final s = await AppState.loadWith(widget.workspace, widget.vault);
    setState(() => _state = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s != null) return DbCraftApp(state: s);
    return MaterialApp(
      title: 'DbCraft',
      debugShowCheckedModeBanner: false,
      themeMode: widget.settings.themeMode,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: LockScreen(onUnlock: _unlock, onReset: _reset)),
    );
  }
}

class DbCraftApp extends StatefulWidget {
  const DbCraftApp({super.key, required this.state});
  final AppState state;

  @override
  State<DbCraftApp> createState() => _DbCraftAppState();
}

class _DbCraftAppState extends State<DbCraftApp> {
  late final AppLifecycleListener _lifecycle;
  final _window = WindowBridge.instance;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.state.shutdown();
        return AppExitResponse.exit;
      },
    );
    _armIdleTimer();
  }

  @override
  void dispose() {
    _idle?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  /// Locks the window after the configured inactivity (master password only).
  void _armIdleTimer() {
    _idle?.cancel();
    final s = widget.state;
    final minutes = s.settings.autoLockMinutes;
    if (minutes <= 0 || !s.vault.usesMasterPassword || s.locked) return;
    _idle = Timer(Duration(minutes: minutes), s.lockUi);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.state;
    return AppScope(
      state: app,
      child: ListenableBuilder(
        listenable: Listenable.merge([app, _window.isKey, _window.accentColor]),
        builder: (context, _) => MaterialApp(
          title: 'DbCraft',
          debugShowCheckedModeBanner: false,
          themeMode: app.settings.themeMode,
          theme: buildTheme(Brightness.light, accent: _window.accentColor.value, active: _window.isKey.value),
          darkTheme: buildTheme(Brightness.dark, accent: _window.accentColor.value, active: _window.isKey.value),
          // Key-state and appearance changes switch instantly, as in AppKit.
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _armIdleTimer(),
            onPointerHover: (_) => _armIdleTimer(),
            child: Focus(
              canRequestFocus: false,
              onKeyEvent: (_, _) {
                _armIdleTimer();
                return KeyEventResult.ignored;
              },
              child: Stack(children: [
                // While locked the window content keeps its state but cannot
                // hold the keyboard focus (keys would reach the editors).
                if (child != null) ExcludeFocus(excluding: app.locked, child: child),
                if (app.locked)
                  // Above the navigator: the password field needs an Overlay
                  // of its own (selection, tooltips).
                  Positioned.fill(
                    child: Overlay(
                      initialEntries: [
                        OverlayEntry(
                          builder: (_) => Material(
                            child: LockScreen(
                              message: 'Finestra bloccata. Inserisci la master password per continuare.',
                              onUnlock: (p) async {
                                final ok = await app.unlockUi(p);
                                if (ok) _armIdleTimer();
                                return ok;
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ]),
            ),
          ),
          home: const HomePage(),
        ),
      ),
    );
  }
}
