// Relaxed JSON / JavaScript object-literal parser.
//
// Accepts what users type in the MongoDB shell: unquoted keys, single quoted
// strings, trailing commas, comments, regex literals (/…/i), constructor
// calls (ObjectId("…"), ISODate("…"), new Date(…), NumberLong(…)…). The
// meaning of calls, regexes and Extended JSON objects is delegated to hooks so
// the parser stays independent from BSON.
import 'dart:convert';
import 'dart:typed_data';

import 'native_exception.dart';

/// Converts a call such as `ObjectId("…")` (or `new Date(…)`) to a value.
typedef JsCallHook = Object? Function(String name, List<Object?> args);

/// Converts a parsed object (e.g. Extended JSON `{"$oid": "…"}`); returns the
/// map itself when no conversion applies.
typedef JsObjectHook = Object? Function(Map<String, Object?> map);

/// Converts a regex literal `/pattern/flags`.
typedef JsRegexHook = Object? Function(String pattern, String flags);

class JsSyntaxError extends NativeDbException {
  JsSyntaxError(super.message, this.offset);
  final int offset;
}

/// Character level scanner with a value parser. Other parsers (the MongoDB
/// shell parser) build on top of it.
class JsScanner {
  JsScanner(this.text, {this.onCall, this.onObject, this.onRegex});

  final String text;
  final JsCallHook? onCall;
  final JsObjectHook? onObject;
  final JsRegexHook? onRegex;
  int pos = 0;

  bool get atEnd {
    skipWs();
    return pos >= text.length;
  }

  JsSyntaxError error(String msg, [int? at]) {
    final p = at ?? pos;
    var line = 1, col = 1;
    for (var i = 0; i < p && i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        line++;
        col = 1;
      } else {
        col++;
      }
    }
    return JsSyntaxError('$msg (riga $line, colonna $col)', p);
  }

  /// Skips blanks and comments. When [newlines] is false, stops at a line
  /// break (used to detect statement ends).
  void skipWs({bool newlines = true}) {
    while (pos < text.length) {
      final c = text.codeUnitAt(pos);
      if (c == 32 || c == 9 || c == 13 || c == 0xFEFF || c == 0xA0) {
        pos++;
      } else if (c == 10) {
        if (!newlines) return;
        pos++;
      } else if (c == 47 && pos + 1 < text.length && text.codeUnitAt(pos + 1) == 47) {
        while (pos < text.length && text.codeUnitAt(pos) != 10) {
          pos++;
        }
      } else if (c == 47 && pos + 1 < text.length && text.codeUnitAt(pos + 1) == 42) {
        final end = text.indexOf('*/', pos + 2);
        pos = end < 0 ? text.length : end + 2;
      } else {
        return;
      }
    }
  }

  String? peek() {
    skipWs();
    return pos < text.length ? text[pos] : null;
  }

  bool tryConsume(String s) {
    skipWs();
    if (text.startsWith(s, pos)) {
      pos += s.length;
      return true;
    }
    return false;
  }

  void expect(String s) {
    if (!tryConsume(s)) {
      throw error(pos >= text.length ? 'Atteso "$s", trovata la fine del testo' : 'Atteso "$s"');
    }
  }

  static bool isIdentStart(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127;

  static bool isIdentPart(int c) => isIdentStart(c) || (c >= 48 && c <= 57);

  String? readIdentifier() {
    skipWs();
    if (pos >= text.length || !isIdentStart(text.codeUnitAt(pos))) return null;
    final s = pos;
    while (pos < text.length && isIdentPart(text.codeUnitAt(pos))) {
      pos++;
    }
    return text.substring(s, pos);
  }

  /// Parses any value (object, array, string, number, literal, call, regex).
  Object? parseValue() {
    skipWs();
    if (pos >= text.length) throw error('Valore atteso, trovata la fine del testo');
    final c = text.codeUnitAt(pos);
    if (c == 123) return _object();
    if (c == 91) return _array();
    if (c == 34 || c == 39 || c == 96) return readString();
    if ((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46) return _number();
    if (c == 47) return _regex();
    final start = pos;
    var id = readIdentifier();
    if (id == null) throw error('Carattere inatteso "${text[pos]}"');
    switch (id) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
      case 'undefined':
        return null;
      case 'NaN':
        return double.nan;
      case 'Infinity':
        return double.infinity;
    }
    if (id == 'new') {
      id = readIdentifier();
      if (id == null) throw error('Costruttore atteso dopo "new"');
    }
    // Dotted names (e.g. Number.MAX_SAFE_INTEGER, UUID.generate) are passed
    // to the hook as a whole.
    while (pos < text.length && text[pos] == '.' && pos + 1 < text.length && isIdentStart(text.codeUnitAt(pos + 1))) {
      pos++;
      id = '$id.${readIdentifier()}';
    }
    final args = <Object?>[];
    final hasArgs = tryConsume('(');
    if (hasArgs) args.addAll(parseArguments());
    final hook = onCall;
    if (hook == null) throw error('Identificatore non supportato "$id"', start);
    try {
      return hook(id!, hasArgs ? args : const [_noArgs]);
    } on JsSyntaxError {
      rethrow;
    } on NativeDbException catch (e) {
      throw error(e.message, start);
    } catch (e) {
      throw error('$id: $e', start);
    }
  }

  /// Parses comma separated values up to (and including) the closing ')'.
  List<Object?> parseArguments() {
    final args = <Object?>[];
    while (true) {
      if (tryConsume(')')) return args;
      args.add(parseValue());
      if (tryConsume(',')) continue;
      expect(')');
      return args;
    }
  }

  Map<String, Object?> parseObjectRaw() {
    expect('{');
    final m = <String, Object?>{};
    while (true) {
      if (tryConsume('}')) return m;
      skipWs();
      if (pos >= text.length) throw error('"}" atteso');
      final c = text.codeUnitAt(pos);
      String key;
      if (c == 34 || c == 39 || c == 96) {
        key = readString();
      } else if (c >= 48 && c <= 57 || c == 45) {
        key = _number().toString();
      } else {
        final s = pos;
        while (pos < text.length) {
          final k = text.codeUnitAt(pos);
          if (isIdentPart(k) || k == 46) {
            pos++;
          } else {
            break;
          }
        }
        if (s == pos) throw error('Nome di campo atteso');
        key = text.substring(s, pos);
      }
      if (!tryConsume(':')) {
        // Shorthand property { a } is not meaningful here.
        throw error('":" atteso dopo "$key"');
      }
      m[key] = parseValue();
      if (tryConsume(',')) continue;
      expect('}');
      return m;
    }
  }

  Object? _object() {
    final m = parseObjectRaw();
    final hook = onObject;
    return hook == null ? m : hook(m);
  }

  List<Object?> _array() {
    expect('[');
    final l = <Object?>[];
    while (true) {
      if (tryConsume(']')) return l;
      l.add(parseValue());
      if (tryConsume(',')) continue;
      expect(']');
      return l;
    }
  }

  String readString() {
    skipWs();
    final q = text.codeUnitAt(pos);
    final start = pos;
    pos++;
    final sb = StringBuffer();
    while (true) {
      if (pos >= text.length) throw error('Stringa non terminata', start);
      final c = text.codeUnitAt(pos++);
      if (c == q) break;
      if (c != 92) {
        sb.writeCharCode(c);
        continue;
      }
      if (pos >= text.length) throw error('Stringa non terminata', start);
      final e = text[pos++];
      switch (e) {
        case 'n':
          sb.write('\n');
        case 't':
          sb.write('\t');
        case 'r':
          sb.write('\r');
        case 'b':
          sb.write('\b');
        case 'f':
          sb.write('\f');
        case 'v':
          sb.write('\v');
        case '0':
          sb.write('\u0000');
        case 'x':
          sb.writeCharCode(_hex(2));
        case 'u':
          if (pos < text.length && text[pos] == '{') {
            final end = text.indexOf('}', pos);
            if (end < 0) throw error('Escape \\u{…} non valido');
            sb.writeCharCode(int.parse(text.substring(pos + 1, end), radix: 16));
            pos = end + 1;
          } else {
            sb.writeCharCode(_hex(4));
          }
        case '\n':
          break;
        case '\r':
          if (pos < text.length && text[pos] == '\n') pos++;
        default:
          sb.write(e);
      }
    }
    return sb.toString();
  }

  int _hex(int n) {
    if (pos + n > text.length) throw error('Escape esadecimale non valido');
    final v = int.tryParse(text.substring(pos, pos + n), radix: 16);
    if (v == null) throw error('Escape esadecimale non valido');
    pos += n;
    return v;
  }

  num _number() {
    final start = pos;
    var neg = false;
    if (text[pos] == '-' || text[pos] == '+') {
      neg = text[pos] == '-';
      pos++;
      skipWs();
      if (text.startsWith('Infinity', pos)) {
        pos += 8;
        return neg ? double.negativeInfinity : double.infinity;
      }
    }
    if (text.startsWith('0x', pos) || text.startsWith('0X', pos)) {
      pos += 2;
      final s = pos;
      while (pos < text.length && RegExp('[0-9a-fA-F]').hasMatch(text[pos])) {
        pos++;
      }
      final v = int.parse(text.substring(s, pos), radix: 16);
      return neg ? -v : v;
    }
    final s = pos;
    var isDouble = false;
    while (pos < text.length) {
      final c = text[pos];
      if (RegExp('[0-9_]').hasMatch(c)) {
        pos++;
      } else if (c == '.' || c == 'e' || c == 'E') {
        isDouble = true;
        pos++;
        if ((c == 'e' || c == 'E') && pos < text.length && (text[pos] == '-' || text[pos] == '+')) pos++;
      } else {
        break;
      }
    }
    final raw = text.substring(s, pos).replaceAll('_', '');
    if (raw.isEmpty || raw == '.') throw error('Numero non valido', start);
    if (!isDouble) {
      final v = int.tryParse(raw);
      if (v != null) return neg ? -v : v;
    }
    final d = double.tryParse(raw);
    if (d == null) throw error('Numero non valido', start);
    return neg ? -d : d;
  }

  Object? _regex() {
    final start = pos;
    pos++;
    final sb = StringBuffer();
    var inClass = false;
    while (true) {
      if (pos >= text.length) throw error('Espressione regolare non terminata', start);
      final c = text[pos++];
      if (c == '\\') {
        if (pos >= text.length) throw error('Espressione regolare non terminata', start);
        sb
          ..write(c)
          ..write(text[pos++]);
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (c == '/' && !inClass) break;
      if (c == '\n') throw error('Espressione regolare non terminata', start);
      sb.write(c);
    }
    final fs = pos;
    while (pos < text.length && RegExp('[a-z]').hasMatch(text[pos])) {
      pos++;
    }
    final flags = text.substring(fs, pos);
    final hook = onRegex;
    if (hook == null) return {r'$regex': sb.toString(), r'$options': flags};
    return hook(sb.toString(), flags);
  }
}

/// Marker passed as the only argument when a constructor is referenced
/// without parentheses (e.g. `MinKey`).
const Object _noArgs = _NoArgs();

class _NoArgs {
  const _NoArgs();
}

/// True when [args] is the "referenced without parentheses" marker.
bool jsNoArgs(List<Object?> args) => args.length == 1 && identical(args.first, _noArgs);

/// Parses a single value; the whole text must be consumed.
Object? parseRelaxedJson(String text, {JsCallHook? onCall, JsObjectHook? onObject, JsRegexHook? onRegex}) {
  final s = JsScanner(text, onCall: onCall, onObject: onObject, onRegex: onRegex);
  final v = s.parseValue();
  s.tryConsume(';');
  if (!s.atEnd) throw s.error('Testo inatteso dopo il valore');
  return v;
}

/// Compact JSON-like rendering. [special] renders values that are not plain
/// JSON (returns null to fall back to `toString()` as a string).
String compactJson(Object? v, {String? Function(Object? v)? special}) {
  final sb = StringBuffer();
  void w(Object? v) {
    final sp = special?.call(v);
    if (sp != null) {
      sb.write(sp);
      return;
    }
    if (v == null) {
      sb.write('null');
    } else if (v is String) {
      sb.write(jsonEncode(v));
    } else if (v is bool || v is int) {
      sb.write(v);
    } else if (v is double) {
      if (v.isNaN || v.isInfinite) {
        sb.write(v.isNaN ? 'NaN' : (v > 0 ? 'Infinity' : '-Infinity'));
      } else {
        sb.write(v == v.truncateToDouble() && v.abs() < 1e15 ? v.toStringAsFixed(1) : v.toString());
      }
    } else if (v is Map) {
      sb.write('{');
      var first = true;
      v.forEach((k, val) {
        if (!first) sb.write(', ');
        first = false;
        sb
          ..write(jsonEncode(k.toString()))
          ..write(': ');
        w(val);
      });
      sb.write('}');
    } else if (v is Uint8List) {
      sb.write(jsonEncode(base64.encode(v)));
    } else if (v is Iterable) {
      sb.write('[');
      var first = true;
      for (final e in v) {
        if (!first) sb.write(', ');
        first = false;
        w(e);
      }
      sb.write(']');
    } else if (v is DateTime) {
      sb.write(jsonEncode(v.toUtc().toIso8601String()));
    } else {
      sb.write(jsonEncode(v.toString()));
    }
  }

  w(v);
  return sb.toString();
}
