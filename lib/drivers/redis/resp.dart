// RESP2 / RESP3 protocol: command encoder, incremental reply parser and the
// redis-cli style command tokenizer.
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../common/native_exception.dart';

/// Error reply (`-ERR …`).
class RedisError extends NativeDbException {
  RedisError(String text)
    : super(
        text.contains(' ') ? text.substring(text.indexOf(' ') + 1) : text,
        code: text.contains(' ') ? text.substring(0, text.indexOf(' ')) : 'ERR',
        source: 'Redis',
      );
}

/// RESP3 map reply, kept distinct from arrays.
class RespMap {
  RespMap(this.entries);
  final List<MapEntry<Object?, Object?>> entries;
}

/// RESP3 set reply.
class RespSet {
  RespSet(this.items);
  final List<Object?> items;
}

/// Encodes a command as a RESP array of bulk strings.
Uint8List encodeCommand(List<Object> args) {
  final b = BytesBuilder(copy: false);
  b.add(ascii.encode('*${args.length}\r\n'));
  for (final a in args) {
    final bytes = a is Uint8List ? a : utf8.encode(a.toString());
    b.add(ascii.encode('\$${bytes.length}\r\n'));
    b.add(bytes);
    b.add(const [13, 10]);
  }
  return b.toBytes();
}

class _Frame {
  _Frame(this.kind, this.expected);
  final int kind; // '*', '%', '~', '>', '|'
  final int expected;
  final List<Object?> items = [];
}

/// Incremental RESP parser: [feed] bytes, take complete replies from
/// [replies]. Bulk strings are returned as [Uint8List], simple strings as
/// [String], integers as [int], errors as [RedisError], arrays as [List],
/// RESP3 maps / sets as [RespMap] / [RespSet], null as null.
class RespParser {
  Uint8List _buf = Uint8List(16384);
  int _start = 0;
  int _end = 0;
  final List<_Frame> _stack = [];
  final Queue<Object?> replies = Queue();

  void feed(List<int> data) {
    if (_end + data.length > _buf.length) {
      final live = _end - _start;
      var size = _buf.length;
      while (size < live + data.length) {
        size *= 2;
      }
      final nb = size == _buf.length ? _buf : Uint8List(size);
      nb.setRange(0, live, _buf, _start);
      _buf = nb;
      _start = 0;
      _end = live;
    }
    _buf.setRange(_end, _end + data.length, data);
    _end += data.length;
    _parse();
  }

  int _lineEnd(int from) {
    for (var i = from; i + 1 < _end; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10) return i;
    }
    return -1;
  }

  void _parse() {
    while (_start < _end) {
      final type = _buf[_start];
      final le = _lineEnd(_start + 1);
      if (le < 0) return;
      final line = utf8.decode(Uint8List.sublistView(_buf, _start + 1, le), allowMalformed: true);
      final after = le + 2;
      Object? value;
      switch (type) {
        case 0x2B: // +
          value = line;
        case 0x2D: // -
          value = RedisError(line);
        case 0x3A: // :
          value = int.tryParse(line) ?? BigInt.parse(line).toString();
        case 0x5F: // _
          value = null;
        case 0x23: // #
          value = line == 't';
        case 0x2C: // ,
          value = switch (line) {
            'inf' => double.infinity,
            '-inf' => double.negativeInfinity,
            'nan' => double.nan,
            _ => double.parse(line),
          };
        case 0x28: // (
          value = line;
        case 0x24 || 0x21 || 0x3D: // $ ! =
          final n = int.parse(line);
          if (n < 0) {
            value = null;
            break;
          }
          if (_end < after + n + 2) return; // wait for the whole payload
          final data = Uint8List.fromList(Uint8List.sublistView(_buf, after, after + n));
          _start = after + n + 2;
          if (type == 0x21) {
            _emit(RedisError(utf8.decode(data, allowMalformed: true)));
          } else if (type == 0x3D) {
            _emit(data.length >= 4 ? Uint8List.sublistView(data, 4) : data);
          } else {
            _emit(data);
          }
          continue;
        case 0x2A || 0x25 || 0x7E || 0x3E || 0x7C: // * % ~ > |
          final n = int.parse(line);
          _start = after;
          if (n < 0) {
            _emit(null);
          } else {
            final count = (type == 0x25 || type == 0x7C) ? n * 2 : n;
            final f = _Frame(type, count);
            if (count == 0) {
              _emit(_build(f));
            } else {
              _stack.add(f);
            }
          }
          continue;
        default:
          throw NativeDbException('Risposta Redis non valida (tipo "${String.fromCharCode(type)}")');
      }
      _start = after;
      _emit(value);
    }
    if (_start == _end) _start = _end = 0;
  }

  Object? _build(_Frame f) => switch (f.kind) {
    0x25 => RespMap([for (var i = 0; i + 1 < f.items.length; i += 2) MapEntry(f.items[i], f.items[i + 1])]),
    0x7E => RespSet(f.items),
    _ => f.items,
  };

  void _emit(Object? v) {
    while (true) {
      if (_stack.isEmpty) {
        replies.add(v);
        return;
      }
      final top = _stack.last;
      top.items.add(v);
      if (top.items.length < top.expected) return;
      _stack.removeLast();
      if (top.kind == 0x7C) {
        // Attribute: metadata preceding the real reply; skip it.
        return;
      }
      if (top.kind == 0x3E && _stack.isEmpty) {
        // Out-of-band push message: ignored.
        return;
      }
      v = _build(top);
    }
  }
}

/// Splits a command line like redis-cli: blanks separate arguments,
/// "double quoted" strings support \n \t \xHH escapes, 'single quoted'
/// strings are literal (\' allowed).
List<String> tokenizeRedisCommand(String line) {
  final out = <String>[];
  var i = 0;
  while (true) {
    while (i < line.length && line[i].trim().isEmpty) {
      i++;
    }
    if (i >= line.length) return out;
    final sb = StringBuffer();
    var quoted = false;
    while (i < line.length && line[i].trim().isNotEmpty) {
      final c = line[i];
      if (c == '"') {
        quoted = true;
        i++;
        while (true) {
          if (i >= line.length) throw NativeDbException('Virgolette non chiuse nel comando');
          final d = line[i++];
          if (d == '"') break;
          if (d == '\\' && i < line.length) {
            final e = line[i++];
            switch (e) {
              case 'n':
                sb.write('\n');
              case 'r':
                sb.write('\r');
              case 't':
                sb.write('\t');
              case 'b':
                sb.write('\b');
              case 'a':
                sb.write('\x07');
              case 'x':
                if (i + 2 <= line.length && RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(line.substring(i, i + 2))) {
                  sb.writeCharCode(int.parse(line.substring(i, i + 2), radix: 16));
                  i += 2;
                } else {
                  sb.write('x');
                }
              default:
                sb.write(e);
            }
          } else {
            sb.write(d);
          }
        }
      } else if (c == "'") {
        quoted = true;
        i++;
        while (true) {
          if (i >= line.length) throw NativeDbException('Apici non chiusi nel comando');
          final d = line[i++];
          if (d == "'") break;
          if (d == '\\' && i < line.length && line[i] == "'") {
            sb.write("'");
            i++;
          } else {
            sb.write(d);
          }
        }
      } else {
        sb.write(c);
        i++;
      }
    }
    if (sb.isNotEmpty || quoted) out.add(sb.toString());
  }
}

/// Splits a script into command lines: one command per line, `#` and `//`
/// comment lines ignored, a trailing `;` removed.
List<String> splitRedisScript(String text) {
  final out = <String>[];
  for (var l in const LineSplitter().convert(text)) {
    l = l.trim();
    if (l.isEmpty || l.startsWith('#') || l.startsWith('//') || l.startsWith('--')) continue;
    if (l.endsWith(';')) l = l.substring(0, l.length - 1).trimRight();
    if (l.isNotEmpty) out.add(l);
  }
  return out;
}

/// Text of a reply element (bulk strings decoded as UTF-8 when valid).
Object? respText(Object? v) {
  if (v is Uint8List) {
    try {
      return utf8.decode(v);
    } on FormatException {
      return v;
    }
  }
  return v;
}

String respString(Object? v) {
  final t = respText(v);
  if (t is Uint8List) return latin1.decode(t);
  return t?.toString() ?? '';
}
