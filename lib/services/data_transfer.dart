import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sql_dialect.dart';

enum ExportFormat {
  csv('CSV', 'csv'),
  tsv('TSV (tab)', 'tsv'),
  json('JSON', 'json'),
  xml('XML', 'xml'),
  html('HTML', 'html'),
  markdown('Markdown', 'md'),
  sql('SQL INSERT', 'sql'),
  txt('Testo (tabella)', 'txt');

  const ExportFormat(this.label, this.extension);
  final String label;
  final String extension;
}

class ExportOptions {
  ExportOptions({
    this.format = ExportFormat.csv,
    this.delimiter = ',',
    this.header = true,
    this.quoteAll = false,
    this.nullText = '',
    this.tableName = 'table_name',
    this.insertBatch = 1,
    this.dialect,
  });

  ExportFormat format;
  String delimiter;
  bool header;
  bool quoteAll;
  String nullText;
  String tableName;
  int insertBatch;
  SqlDialect? dialect;
}

/// Serializes tabular data in several formats. Data can be written in pages
/// so very large tables can be exported without loading them in memory.
class DataExporter {
  DataExporter(this.columns, this.options);

  final List<String> columns;
  final ExportOptions options;
  bool _first = true;
  int _rowCount = 0;
  final List<List<Object?>> _txtBuffer = [];

  SqlDialect get _d => options.dialect ?? SqlDialect(dbmsName: '');

  String _csvCell(Object? v, String delim) {
    if (v == null) return options.nullText;
    final s = v is Uint8List ? base64Encode(v) : v.toString();
    final needs =
        options.quoteAll || s.contains(delim) || s.contains('"') || s.contains('\n') || s.contains('\r');
    return needs ? '"${s.replaceAll('"', '""')}"' : s;
  }

  static String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String _xmlName(String s) {
    final n = s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return RegExp(r'^[A-Za-z_]').hasMatch(n) ? n : '_$n';
  }

  Object? _jsonValue(Object? v) {
    if (v is Uint8List) return base64Encode(v);
    if (v is double && (v.isNaN || v.isInfinite)) return v.toString();
    return v;
  }

  String begin() {
    switch (options.format) {
      case ExportFormat.csv:
      case ExportFormat.tsv:
        if (!options.header) return '';
        final d = options.format == ExportFormat.tsv ? '\t' : options.delimiter;
        return '${columns.map((c) => _csvCell(c, d)).join(d)}\n';
      case ExportFormat.json:
        return '[\n';
      case ExportFormat.xml:
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<export table="${_xmlEscape(options.tableName)}">\n';
      case ExportFormat.html:
        return '<!DOCTYPE html>\n<html><head><meta charset="utf-8">'
            '<title>${_xmlEscape(options.tableName)}</title>'
            '<style>table{border-collapse:collapse;font-family:sans-serif;font-size:13px}'
            'td,th{border:1px solid #ccc;padding:3px 6px}th{background:#eee}</style>'
            '</head><body>\n<table>\n<tr>${columns.map((c) => '<th>${_xmlEscape(c)}</th>').join()}</tr>\n';
      case ExportFormat.markdown:
        return '| ${columns.map(_mdCell).join(' | ')} |\n'
            '|${columns.map((_) => '---').join('|')}|\n';
      case ExportFormat.sql:
      case ExportFormat.txt:
        return '';
    }
  }

  String _mdCell(Object? v) =>
      (v == null ? options.nullText : v.toString()).replaceAll('|', r'\|').replaceAll('\n', ' ');

  String rows(List<List<Object?>> rows) {
    final sb = StringBuffer();
    switch (options.format) {
      case ExportFormat.csv:
      case ExportFormat.tsv:
        final d = options.format == ExportFormat.tsv ? '\t' : options.delimiter;
        for (final r in rows) {
          sb.write(r.map((v) => _csvCell(v, d)).join(d));
          sb.write('\n');
        }
      case ExportFormat.json:
        for (final r in rows) {
          if (!_first) sb.write(',\n');
          final m = <String, Object?>{};
          for (var i = 0; i < columns.length; i++) {
            m[columns[i]] = _jsonValue(r[i]);
          }
          sb.write('  ${jsonEncode(m)}');
          _first = false;
        }
      case ExportFormat.xml:
        for (final r in rows) {
          sb.write('  <row>\n');
          for (var i = 0; i < columns.length; i++) {
            final v = r[i];
            final tag = _xmlName(columns[i]);
            if (v == null) {
              sb.write('    <$tag null="true"/>\n');
            } else {
              final s = v is Uint8List ? base64Encode(v) : v.toString();
              sb.write('    <$tag>${_xmlEscape(s)}</$tag>\n');
            }
          }
          sb.write('  </row>\n');
        }
      case ExportFormat.html:
        for (final r in rows) {
          sb.write('<tr>');
          for (final v in r) {
            sb.write(
              '<td>${v == null ? '<i>${_xmlEscape(options.nullText)}</i>' : _xmlEscape(v is Uint8List ? base64Encode(v) : v.toString())}</td>',
            );
          }
          sb.write('</tr>\n');
        }
      case ExportFormat.markdown:
        for (final r in rows) {
          sb.write('| ${r.map(_mdCell).join(' | ')} |\n');
        }
      case ExportFormat.sql:
        final cols = columns.map(_d.quoteIdent).join(', ');
        final batch = options.insertBatch < 1 ? 1 : options.insertBatch;
        for (var i = 0; i < rows.length; i += batch) {
          final chunk = rows.sublist(i, i + batch > rows.length ? rows.length : i + batch);
          sb.write('INSERT INTO ${options.tableName} ($cols) VALUES\n');
          sb.write(chunk.map((r) => '\t(${r.map(_d.literal).join(', ')})').join(',\n'));
          sb.write(';\n');
        }
      case ExportFormat.txt:
        _txtBuffer.addAll(rows);
    }
    _rowCount += rows.length;
    return sb.toString();
  }

  String end() {
    switch (options.format) {
      case ExportFormat.json:
        return '\n]\n';
      case ExportFormat.xml:
        return '</export>\n';
      case ExportFormat.html:
        return '</table>\n<p>$_rowCount righe</p></body></html>\n';
      case ExportFormat.txt:
        return _textTable();
      default:
        return '';
    }
  }

  String _textTable() {
    String cell(Object? v) => (v == null ? options.nullText : v.toString()).replaceAll('\n', ' ');
    final widths = List<int>.generate(columns.length, (i) => columns[i].length);
    for (final r in _txtBuffer) {
      for (var i = 0; i < columns.length; i++) {
        final l = cell(r[i]).length;
        if (l > widths[i]) widths[i] = l > 60 ? 60 : l;
      }
    }
    String fmt(List<Object?> r) =>
        '|${List.generate(columns.length, (i) {
          var s = cell(r[i]);
          if (s.length > widths[i]) s = s.substring(0, widths[i]);
          return ' ${s.padRight(widths[i])} ';
        }).join('|')}|';
    final sep = '+${widths.map((w) => '-' * (w + 2)).join('+')}+';
    final sb = StringBuffer()
      ..writeln(sep)
      ..writeln(fmt(columns))
      ..writeln(sep);
    for (final r in _txtBuffer) {
      sb.writeln(fmt(r));
    }
    sb.writeln(sep);
    return sb.toString();
  }

  /// Convenience for in-memory export (clipboard / small result sets).
  static String exportAll(List<String> columns, List<List<Object?>> rows, ExportOptions o) {
    final e = DataExporter(columns, o);
    return e.begin() + e.rows(rows) + e.end();
  }

  /// Writes all pages provided by [pages] to [file]. Returns the row count.
  static Future<int> exportToFile(
    File file,
    List<String> columns,
    Stream<List<List<Object?>>> pages,
    ExportOptions o,
  ) async {
    final e = DataExporter(columns, o);
    final sink = file.openWrite(encoding: utf8);
    try {
      sink.write(e.begin());
      await for (final page in pages) {
        sink.write(e.rows(page));
      }
      sink.write(e.end());
    } finally {
      await sink.close();
    }
    return e._rowCount;
  }
}

/// Minimal RFC 4180 CSV parser used by the data import wizard.
List<List<String>> parseCsv(String text, {String delimiter = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  if (text.startsWith('﻿')) i = 1;
  while (i < text.length) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
      } else {
        field.write(c);
      }
      i++;
      continue;
    }
    if (c == '"') {
      inQuotes = true;
    } else if (c == delimiter) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
