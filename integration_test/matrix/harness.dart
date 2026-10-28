// Shared helpers of the test matrix (docs/test-plan.md): start the real app on
// an isolated workspace, wait/pump helpers, screenshots and a per-case result
// log written as JSON lines.
//
//   flutter test integration_test/matrix/<suite>_test.dart -d macos \
//     --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix --dart-define=TARGET=pg
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dbcraft/main.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp/dbcraft-matrix');
const target = String.fromEnvironment('TARGET', defaultValue: 'none');

final shotKey = GlobalKey();

String get outDir => '$shotDir/$target';

Future<void> shot(WidgetTester tester, String name, {bool settleFirst = true}) async {
  if (settleFirst) await tester.pump(const Duration(milliseconds: 300));
  final ro = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await ro.toImage(pixelRatio: 1);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(outDir).createSync(recursive: true);
  File('$outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(WidgetTester tester, Finder f, {int seconds = 15, String? failShot}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  await shot(tester, failShot ?? 'zz_timeout_${DateTime.now().millisecondsSinceEpoch}');
  throw TestFailure('Timeout waiting for $f');
}

Future<void> doubleTap(WidgetTester tester, Finder f) async {
  final at = tester.getCenter(f);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(at);
  await settle(tester, 400);
}

/// Starts the app on a fresh workspace with [connections].
Future<AppState> startApp(
  WidgetTester tester, {
  List<Map<String, Object?>> connections = const [],
  Directory? workspace,
  Size size = const Size(1500, 920),
}) async {
  final ws = workspace ?? Directory.systemTemp.createTempSync('dbcraft_matrix_ws');
  if (connections.isNotEmpty) File('${ws.path}/connections.json').writeAsStringSync(jsonEncode(connections));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = await AppState.load(workspaceDir: ws);
  state.settings.themeMode = ThemeMode.light;
  _captureFlutterErrors();
  await tester.pumpWidget(RepaintBoundary(key: shotKey, child: DbCraftApp(state: state)));
  await settle(tester);
  return state;
}

void Function(FlutterErrorDetails)? _originalOnError;

/// Framework errors (assertions, layout overflows…) are recorded as defects
/// instead of failing the whole suite at the first one.
final frameworkErrors = <String>[];

void _captureFlutterErrors() {
  _originalOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString().split('\n').first;
    final where = details.stack?.toString().split('\n').where((l) => l.contains('package:dbcraft/')).take(3).join(' | ') ?? '';
    frameworkErrors.add(text);
    record('FRAMEWORK', Outcome.defect, '$text\n$where');
  };
}

/// A matrix test: framework errors become recorded defects, the error
/// handler is restored even when the body throws, and the app is shut down.
void matrixTest(String description, Future<void> Function(WidgetTester tester) body,
    {Duration timeout = const Duration(minutes: 30)}) {
  testWidgets(description, (tester) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      await body(tester);
    } catch (e, st) {
      failure = e;
      failureStack = st;
      record('ABORT', Outcome.defect, '$e\n${st.toString().split('\n').take(8).join('\n')}');
      try {
        await shot(tester, 'zz_abort');
      } catch (_) {}
    } finally {
      if (_originalOnError != null) FlutterError.onError = _originalOnError;
      _originalOnError = null;
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }, timeout: Timeout(timeout));
}

/// Shuts the app down at the end of a test body.
Future<void> finish(WidgetTester tester, AppState state) async {
  await state.shutdown();
  await settle(tester, 300);
}

/// Result of one (case, target) pair, appended to `results.jsonl`.
enum Outcome { ok, defect, limited, notApplicable, notRun }

void record(String caseId, Outcome outcome, [String note = '']) {
  Directory(outDir).createSync(recursive: true);
  File('$outDir/results.jsonl').writeAsStringSync(
    '${jsonEncode({'case': caseId, 'target': target, 'outcome': outcome.name, 'note': note, 'at': DateTime.now().toIso8601String()})}\n',
    mode: FileMode.append,
  );
}

/// Runs [body] as test case [caseId]: records ok, or a defect with the error
/// (and a screenshot) without stopping the rest of the suite.
Future<void> check(WidgetTester tester, String caseId, Future<void> Function() body) async {
  try {
    await body();
    record(caseId, Outcome.ok);
  } catch (e, st) {
    record(caseId, Outcome.defect, '$e\n${st.toString().split('\n').take(6).join('\n')}');
    try {
      await shot(tester, 'zz_fail_$caseId');
    } catch (_) {}
    // Close any sheet left open so the next case starts clean.
    for (var i = 0; i < 4; i++) {
      final close = [find.text('OK'), find.text('Annulla'), find.text('Chiudi'), find.text('Fine')].where((f) => f.evaluate().isNotEmpty).firstOrNull;
      if (close == null) break;
      await tester.tap(close.last, warnIfMissed: false);
      await settle(tester, 300);
    }
  }
}
