import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/connection_config.dart';

/// Workspace folder (like DBeaver's workspace): settings, connections,
/// history and scripts.
class Workspace {
  Workspace._(this.root);

  final Directory root;

  static Future<Workspace> open({Directory? override}) async {
    final base = override ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'workspace'));
    await base.create(recursive: true);
    await Directory(p.join(base.path, 'scripts')).create(recursive: true);
    return Workspace._(base);
  }

  File get _connectionsFile => File(p.join(root.path, 'connections.json'));
  File get _settingsFile => File(p.join(root.path, 'settings.json'));
  File get _historyFile => File(p.join(root.path, 'history.json'));
  Directory get scriptsDir => Directory(p.join(root.path, 'scripts'));

  Future<Object?> _read(File f) async {
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(File f, Object? data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await tmp.rename(f.path);
  }

  Future<List<ConnectionConfig>> loadConnections() async {
    final data = await _read(_connectionsFile);
    if (data is! List) return [];
    return data.whereType<Map>().map((e) => ConnectionConfig.fromJson(e.cast<String, Object?>())).toList();
  }

  /// True when connections.json still holds clear text passwords (written
  /// by versions without the vault).
  Future<bool> connectionsContainPasswords() async {
    final data = await _read(_connectionsFile);
    return data is List && data.whereType<Map>().any((e) => (e['password'] as String? ?? '').isNotEmpty);
  }

  Future<void> saveConnections(List<ConnectionConfig> list) =>
      _write(_connectionsFile, list.map((e) => e.toJson()).toList());

  Future<AppSettings> loadSettings() async {
    final data = await _read(_settingsFile);
    return data is Map ? AppSettings.fromJson(data.cast()) : AppSettings();
  }

  Future<void> saveSettings(AppSettings s) => _write(_settingsFile, s.toJson());

  Future<List<HistoryEntry>> loadHistory() async {
    final data = await _read(_historyFile);
    if (data is! List) return [];
    return data.whereType<Map>().map((e) => HistoryEntry.fromJson(e.cast())).toList();
  }

  Future<void> saveHistory(List<HistoryEntry> h) => _write(_historyFile, h.map((e) => e.toJson()).toList());

  /// The .sql files of the workspace with their modification time, newest
  /// first. Files removed while listing are skipped.
  Future<List<({File file, DateTime modified})>> listScripts() async {
    if (!await scriptsDir.exists()) return [];
    final out = <({File file, DateTime modified})>[];
    await for (final e in scriptsDir.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.sql')) continue;
      final st = await e.stat();
      if (st.type == FileSystemEntityType.notFound) continue;
      out.add((file: e, modified: st.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<File> newScriptFile() async {
    var i = 1;
    while (true) {
      final f = File(p.join(scriptsDir.path, 'Script-$i.sql'));
      if (!await f.exists()) {
        await f.writeAsString('');
        return f;
      }
      i++;
    }
  }
}

class AppSettings {
  AppSettings({
    this.themeMode = ThemeMode.system,
    this.fetchSize = 200,
    this.odbcLibPath = '',
    this.editorFontSize = 14,
    this.gridFontSize = 13,
    this.nullText = '[NULL]',
    this.confirmDangerous = true,
    this.blankLineDelimiter = true,
    this.autoComplete = true,
    this.maxHistory = 1000,
    this.upperCaseKeywords = true,
    this.showServerOutput = true,
    this.rememberTabs = true,
    this.simpleMode = false,
    this.aiEnabled = true,
    this.aiModel = 'claude-opus-5-5',
    this.aiBaseUrl = 'https://api.anthropic.com',
    this.aiEffort = 'medium',
    this.aiIncludeSchema = true,
    this.perfRefreshSec = 5,
    this.autoLockMinutes = 0,
    this.hideSystemObjects = false,
  });

  ThemeMode themeMode;
  int fetchSize;
  String odbcLibPath;
  double editorFontSize;
  double gridFontSize;
  String nullText;
  bool confirmDangerous;
  bool blankLineDelimiter;
  bool autoComplete;
  int maxHistory;
  bool upperCaseKeywords;
  bool showServerOutput;
  bool rememberTabs;

  /// Simplified view for analysts: data first, fewer developer tools.
  bool simpleMode;

  /// AI assistant (Claude). The API key lives in the vault (`ai.apiKey`).
  bool aiEnabled;
  String aiModel;
  String aiBaseUrl;

  /// Effort level sent to the model: low, medium, high, xhigh, max.
  String aiEffort;

  /// Send table/column names of the connection as context.
  bool aiIncludeSchema;

  /// Refresh interval of the performance dashboard (seconds).
  int perfRefreshSec;

  /// Lock the vault after this many idle minutes (0 = never). Only used
  /// with a master password.
  int autoLockMinutes;

  /// Navigator: hide the system databases and schemas instead of grouping
  /// them in a "Sistema" folder.
  bool hideSystemObjects;

  String? get libPathOrNull => odbcLibPath.trim().isEmpty ? null : odbcLibPath.trim();

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'fetchSize': fetchSize,
    'odbcLibPath': odbcLibPath,
    'editorFontSize': editorFontSize,
    'gridFontSize': gridFontSize,
    'nullText': nullText,
    'confirmDangerous': confirmDangerous,
    'blankLineDelimiter': blankLineDelimiter,
    'autoComplete': autoComplete,
    'maxHistory': maxHistory,
    'upperCaseKeywords': upperCaseKeywords,
    'showServerOutput': showServerOutput,
    'rememberTabs': rememberTabs,
    'simpleMode': simpleMode,
    'aiEnabled': aiEnabled,
    'aiModel': aiModel,
    'aiBaseUrl': aiBaseUrl,
    'aiEffort': aiEffort,
    'aiIncludeSchema': aiIncludeSchema,
    'perfRefreshSec': perfRefreshSec,
    'autoLockMinutes': autoLockMinutes,
    'hideSystemObjects': hideSystemObjects,
  };

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
    themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
    fetchSize: (j['fetchSize'] as num?)?.toInt() ?? 200,
    odbcLibPath: j['odbcLibPath'] as String? ?? '',
    editorFontSize: (j['editorFontSize'] as num?)?.toDouble() ?? 14,
    gridFontSize: (j['gridFontSize'] as num?)?.toDouble() ?? 13,
    nullText: j['nullText'] as String? ?? '[NULL]',
    confirmDangerous: j['confirmDangerous'] as bool? ?? true,
    blankLineDelimiter: j['blankLineDelimiter'] as bool? ?? true,
    autoComplete: j['autoComplete'] as bool? ?? true,
    maxHistory: (j['maxHistory'] as num?)?.toInt() ?? 1000,
    upperCaseKeywords: j['upperCaseKeywords'] as bool? ?? true,
    showServerOutput: j['showServerOutput'] as bool? ?? true,
    rememberTabs: j['rememberTabs'] as bool? ?? true,
    simpleMode: j['simpleMode'] as bool? ?? false,
    aiEnabled: j['aiEnabled'] as bool? ?? true,
    aiModel: j['aiModel'] as String? ?? 'claude-opus-5-5',
    aiBaseUrl: j['aiBaseUrl'] as String? ?? 'https://api.anthropic.com',
    aiEffort: j['aiEffort'] as String? ?? 'medium',
    aiIncludeSchema: j['aiIncludeSchema'] as bool? ?? true,
    perfRefreshSec: (j['perfRefreshSec'] as num?)?.toInt() ?? 5,
    autoLockMinutes: (j['autoLockMinutes'] as num?)?.toInt() ?? 0,
    hideSystemObjects: j['hideSystemObjects'] as bool? ?? false,
  );
}

class HistoryEntry {
  HistoryEntry({
    required this.sql,
    required this.connectionId,
    required this.connectionName,
    required this.time,
    required this.durationMs,
    this.rows = -1,
    this.error,
  });

  final String sql;
  final String connectionId;
  final String connectionName;
  final DateTime time;
  final int durationMs;
  final int rows;
  final String? error;

  bool get success => error == null;

  Map<String, Object?> toJson() => {
    'sql': sql,
    'connectionId': connectionId,
    'connectionName': connectionName,
    'time': time.toIso8601String(),
    'durationMs': durationMs,
    'rows': rows,
    if (error != null) 'error': error,
  };

  factory HistoryEntry.fromJson(Map<String, Object?> j) => HistoryEntry(
    sql: j['sql'] as String? ?? '',
    connectionId: j['connectionId'] as String? ?? '',
    connectionName: j['connectionName'] as String? ?? '',
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    rows: (j['rows'] as num?)?.toInt() ?? -1,
    error: j['error'] as String?,
  );
}
