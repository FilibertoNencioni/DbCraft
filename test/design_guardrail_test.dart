// Keeps the macOS design system from regressing (DESIGN.md, "Forbidden").
//
// Outside lib/ui/widgets and lib/ui/theme, code builds UI only from the
// design-system components: no Material controls, no Material icons, no
// literal colors. The few literal colors that are data (brand colors of
// databases and cloud providers, the chart palette) are allowed per file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Directories that implement the design system and may use anything.
const _systemDirs = ['lib/ui/widgets/', 'lib/ui/theme/'];

/// Material widgets and functions replaced by design-system components
/// (see the catalog in DESIGN.md for the replacement of each).
const _materialWidgets = [
  'FilledButton', 'OutlinedButton', 'TextButton', 'IconButton', 'SegmentedButton', //
  r'DropdownButton\w*', r'DropdownMenu\w*', 'PopupMenuButton', 'PopupMenuItem', 'CheckedPopupMenuItem',
  'showMenu', 'AlertDialog', 'SimpleDialog', 'SimpleDialogOption', 'showAboutDialog', 'showDatePicker',
  'Checkbox', 'CheckboxListTile', 'Radio', 'RadioListTile', 'RadioGroup', 'RadioMenuButton',
  'Chip', 'FilterChip', 'ChoiceChip', 'InputChip', 'ActionChip', 'RawChip',
  'ListTile', 'Card', 'ExpansionTile', 'TabBar', 'TabBarView', 'SnackBar',
  'CircularProgressIndicator', 'LinearProgressIndicator',
];

final _rules = <String, RegExp>{
  // A use is the name followed by a constructor call, a named constructor or
  // type arguments: `Checkbox(`, `FilledButton.icon(`, `showMenu<T>(`.
  'material widget': RegExp('\\b(${_materialWidgets.join('|')})\\s*(<[^>]*>)?\\s*[(.]'),
  'Material icon': RegExp(r'\bIcons\.'),
  'Material color': RegExp(r'\bColors\.(?!transparent\b)'),
  'literal color': RegExp(r'\bColor(\(0x|\.fromARGB|\.fromRGBO)'),
};

/// Files allowed to break a rule, and why. Keep this list short: a new entry
/// needs a reason that is data, not styling.
const _allowed = <String, Map<String, String>>{
  'lib/features/charts/chart_palette.dart': {'literal color': 'categorical data-viz palette'},
  'lib/model/connection_config.dart': {'literal color': 'brand colors of the database templates'},
  'lib/drivers/redis/redis_driver.dart': {'literal color': 'brand color'},
  'lib/drivers/bigquery/bigquery_driver.dart': {'literal color': 'brand color'},
  'lib/drivers/mongodb/mongo_driver.dart': {'literal color': 'brand color'},
  'lib/drivers/cassandra/cassandra_driver.dart': {'literal color': 'brand color'},
  'lib/cloud/ui/cloud_account_dialog.dart': {'literal color': 'brand colors of the cloud providers'},
};

/// Line comments are documentation, not UI ("Checkbox state of a table").
/// `://` (URLs in strings) is not a comment.
final _lineComment = RegExp(r'(?<![:/])//.*$');

/// Violations in [source] as (line, rule, text).
List<(int, String, String)> scan(String source) {
  final out = <(int, String, String)>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final code = lines[i].replaceFirst(_lineComment, '');
    for (final MapEntry(key: rule, value: re) in _rules.entries) {
      if (re.hasMatch(code)) out.add((i + 1, rule, lines[i].trim()));
    }
  }
  return out;
}

Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !_systemDirs.any((d) => f.path.startsWith(d)));

void main() {
  test('the scanner recognises each rule and ignores comments', () {
    const sample = '''
FilledButton(onPressed: null, child: x),
OutlinedButton.icon(onPressed: null),
showMenu<int>(context: context),
Icon(Icons.close),
color: Colors.red,
color: Colors.transparent,
color: const Color(0xFF112233),
MacCheckbox(value: true),
// Checkbox state of a table.
final url = 'https://example.com'; // Card(
''';
    final rules = scan(sample).map((v) => (v.$1, v.$2)).toList();
    expect(rules, [
      (1, 'material widget'),
      (2, 'material widget'),
      (3, 'material widget'),
      (4, 'Material icon'),
      (5, 'Material color'),
      (7, 'literal color'),
    ]);
  });

  test('UI code outside the design system uses only its components, icons and colors', () {
    final violations = <String>[];
    for (final f in _libFiles()) {
      final path = f.path.replaceAll(r'\', '/');
      final allowed = _allowed[path] ?? const {};
      for (final (line, rule, text) in scan(f.readAsStringSync())) {
        if (!allowed.containsKey(rule)) violations.add('$path:$line  [$rule]  $text');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'Use the design-system components (lib/ui/widgets), AppIcons and DbColors instead. '
          'See DESIGN.md, "Forbidden".',
    );
  });

  test('every exception is still needed', () {
    final stale = <String>[];
    for (final MapEntry(key: path, value: rules) in _allowed.entries) {
      final file = File(path);
      if (!file.existsSync()) {
        stale.add('$path (file removed)');
        continue;
      }
      final found = scan(file.readAsStringSync()).map((v) => v.$2).toSet();
      for (final rule in rules.keys) {
        if (!found.contains(rule)) stale.add('$path [$rule]');
      }
    }
    expect(stale, isEmpty, reason: 'Remove these entries from _allowed.');
  });
}
