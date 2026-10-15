// Small SQL subset understood by the NoSQL drivers so that the data editor,
// the result grid (UPDATE/INSERT/DELETE of edited rows) and the SQL
// generators work on document / key-value stores:
//
//   SELECT * | COUNT(*) | col, … FROM target [WHERE …] [ORDER BY …] [LIMIT n [OFFSET m]]
//   UPDATE target SET col = value, … [WHERE …]
//   INSERT INTO target (col, …) VALUES (…)[, (…)]
//   DELETE FROM target [WHERE …]
//
// WHERE supports = != <> < <= > >= [NOT] LIKE / ILIKE, [NOT] IN (…),
// IS [NOT] NULL, [NOT] BETWEEN … AND …, AND / OR / NOT and parentheses.
// Values: 'strings', numbers, TRUE/FALSE/NULL, ? parameters and – through
// [SqlValueHook] – driver specific literals such as ObjectId('…') or JSON.
import 'native_exception.dart';

/// Parses a driver specific literal (function call, JSON object / array).
typedef SqlValueHook = Object? Function(String text);

/// Table reference: [raw] is the unquoted full text, [parts] the dot
/// separated components (quotes removed).
class SqlTarget {
  const SqlTarget(this.raw, this.parts);
  final String raw;
  final List<String> parts;

  @override
  String toString() => raw;
}

sealed class SqlSubsetStatement {
  const SqlSubsetStatement(this.target);
  final SqlTarget target;
}

class SqlOrder {
  const SqlOrder(this.field, this.descending);
  final String field;
  final bool descending;
}

class SubsetSelect extends SqlSubsetStatement {
  const SubsetSelect(
    super.target, {
    this.columns,
    this.isCount = false,
    this.where,
    this.whereText = '',
    this.orderBy = const [],
    this.orderText = '',
    this.limit,
    this.offset,
  });

  /// Selected columns (null for `*`).
  final List<String>? columns;
  final bool isCount;
  final SqlExpr? where;

  /// Raw WHERE text (drivers may interpret JSON filters themselves).
  final String whereText;
  final List<SqlOrder> orderBy;
  final String orderText;
  final int? limit;
  final int? offset;
}

class SubsetUpdate extends SqlSubsetStatement {
  const SubsetUpdate(super.target, this.assignments, {this.where, this.whereText = ''});
  final List<(String, Object?)> assignments;
  final SqlExpr? where;
  final String whereText;
}

class SubsetInsert extends SqlSubsetStatement {
  const SubsetInsert(super.target, this.columns, this.rows);
  final List<String> columns;
  final List<List<Object?>> rows;
}

class SubsetDelete extends SqlSubsetStatement {
  const SubsetDelete(super.target, {this.where, this.whereText = ''});
  final SqlExpr? where;
  final String whereText;
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

sealed class SqlExpr {
  const SqlExpr();
}

/// `field op value`; op is one of = != < <= > >= like ilike (with [negated]
/// for NOT LIKE / NOT ILIKE).
class SqlCmp extends SqlExpr {
  const SqlCmp(this.field, this.op, this.value, {this.negated = false});
  final String field;
  final String op;
  final Object? value;
  final bool negated;
}

class SqlIn extends SqlExpr {
  const SqlIn(this.field, this.values, {this.negated = false});
  final String field;
  final List<Object?> values;
  final bool negated;
}

class SqlIsNull extends SqlExpr {
  const SqlIsNull(this.field, {this.negated = false});
  final String field;
  final bool negated;
}

class SqlBetween extends SqlExpr {
  const SqlBetween(this.field, this.low, this.high, {this.negated = false});
  final String field;
  final Object? low;
  final Object? high;
  final bool negated;
}

class SqlAnd extends SqlExpr {
  const SqlAnd(this.items);
  final List<SqlExpr> items;
}

class SqlOr extends SqlExpr {
  const SqlOr(this.items);
  final List<SqlExpr> items;
}

class SqlNot extends SqlExpr {
  const SqlNot(this.item);
  final SqlExpr item;
}

/// Equality conditions of a conjunction (`a = 1 AND b = 'x'`), used by the
/// key-value DML translation. Returns null when the expression contains
/// anything else.
Map<String, Object?>? sqlEqualities(SqlExpr? e) {
  final out = <String, Object?>{};
  bool walk(SqlExpr e) {
    switch (e) {
      case SqlAnd(:final items):
        return items.every(walk);
      case SqlCmp(:final field, :final op, :final value, :final negated) when op == '=' && !negated:
        out[field] = value;
        return true;
      case SqlIsNull(:final field, :final negated) when !negated:
        out[field] = null;
        return true;
      default:
        return false;
    }
  }

  if (e == null) return out;
  return walk(e) ? out : null;
}

/// Converts a SQL LIKE pattern to an anchored regular expression.
RegExp likeToRegExp(String pattern, {bool caseInsensitive = false}) =>
    RegExp(likeToRegexSource(pattern), caseSensitive: !caseInsensitive, dotAll: true);

String likeToRegexSource(String pattern) {
  final sb = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '\\' && i + 1 < pattern.length) {
      sb.write(RegExp.escape(pattern[++i]));
    } else if (c == '%') {
      sb.write('.*');
    } else if (c == '_') {
      sb.write('.');
    } else {
      sb.write(RegExp.escape(c));
    }
  }
  sb.write(r'$');
  return sb.toString();
}

/// Converts a SQL LIKE pattern to a Redis glob pattern.
String likeToGlob(String pattern) {
  final sb = StringBuffer();
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '\\' && i + 1 < pattern.length) {
      final n = pattern[++i];
      sb.write('*?[]\\'.contains(n) ? '\\$n' : n);
    } else if (c == '%') {
      sb.write('*');
    } else if (c == '_') {
      sb.write('?');
    } else if ('*?[]\\'.contains(c)) {
      sb.write('\\$c');
    } else {
      sb.write(c);
    }
  }
  return sb.toString();
}

int _compare(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is num && b is String) {
    final n = num.tryParse(b);
    if (n != null) return a.compareTo(n);
  }
  if (a is String && b is num) {
    final n = num.tryParse(a);
    if (n != null) return n.compareTo(b);
  }
  return a.toString().compareTo(b.toString());
}

bool _equals(Object? a, Object? b) {
  if (a == null || b == null) return false;
  return _compare(a, b) == 0;
}

/// Evaluates [e] client side; [get] returns the value of a field.
bool evalSqlExpr(SqlExpr e, Object? Function(String field) get) {
  switch (e) {
    case SqlAnd(:final items):
      return items.every((i) => evalSqlExpr(i, get));
    case SqlOr(:final items):
      return items.any((i) => evalSqlExpr(i, get));
    case SqlNot(:final item):
      return !evalSqlExpr(item, get);
    case SqlIsNull(:final field, :final negated):
      return (get(field) == null) != negated;
    case SqlIn(:final field, :final values, :final negated):
      final v = get(field);
      if (v == null) return false;
      return values.any((x) => _equals(v, x)) != negated;
    case SqlBetween(:final field, :final low, :final high, :final negated):
      final v = get(field);
      if (v == null) return false;
      return (_compare(v, low) >= 0 && _compare(v, high) <= 0) != negated;
    case SqlCmp(:final field, :final op, :final value, :final negated):
      final v = get(field);
      if (v == null || value == null) return false;
      final r = switch (op) {
        '=' => _equals(v, value),
        '!=' => !_equals(v, value),
        '<' => _compare(v, value) < 0,
        '<=' => _compare(v, value) <= 0,
        '>' => _compare(v, value) > 0,
        '>=' => _compare(v, value) >= 0,
        'like' => likeToRegExp(value.toString()).hasMatch(v.toString()),
        'ilike' => likeToRegExp(value.toString(), caseInsensitive: true).hasMatch(v.toString()),
        _ => false,
      };
      return r != negated;
  }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

enum _T { ident, string, number, param, op, lparen, rparen, comma, star, end }

class _Tok {
  _Tok(this.type, this.text, this.start, this.end, [this.value]);
  final _T type;
  final String text;
  final int start;
  final int end;
  final Object? value;

  bool kw(String k) => type == _T.ident && text.toUpperCase() == k;
}

class SqlSubsetError extends NativeDbException {
  SqlSubsetError(super.message);
}

/// Parses [sql] if it is one of the supported forms; returns null otherwise.
SqlSubsetStatement? parseSqlSubset(String sql, {List<Object?> params = const [], SqlValueHook? valueHook}) {
  final text = _stripComments(sql).trim().replaceFirst(RegExp(r';\s*$'), '');
  final head = RegExp(r'^(select|update|insert|delete)\b', caseSensitive: false).firstMatch(text);
  if (head == null) return null;
  return _Parser(text, params, valueHook).statement(head.group(1)!.toLowerCase());
}

/// Parses a stand-alone WHERE expression.
SqlExpr parseSqlWhere(String text, {List<Object?> params = const [], SqlValueHook? valueHook}) {
  final p = _Parser(text, params, valueHook);
  final e = p._expr();
  if (p._peek().type != _T.end) throw p._err('Testo inatteso "${p._peek().text}"');
  return e;
}

String _stripComments(String s) {
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"' || c == '`') {
      final end = _skipQuoted(s, i);
      sb.write(s.substring(i, end));
      i = end;
    } else if (s.startsWith('--', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      final e = s.indexOf('*/', i + 2);
      i = e < 0 ? s.length : e + 2;
      sb.write(' ');
    } else {
      sb.write(c);
      i++;
    }
  }
  return sb.toString();
}

int _skipQuoted(String s, int i) {
  final q = s[i];
  var j = i + 1;
  while (j < s.length) {
    if (s[j] == q) {
      if (j + 1 < s.length && s[j + 1] == q) {
        j += 2;
        continue;
      }
      return j + 1;
    }
    if (s[j] == '\\' && q != '"') j++;
    j++;
  }
  return s.length;
}

class _Parser {
  _Parser(this.text, this.params, this.hook);

  final String text;
  final List<Object?> params;
  final SqlValueHook? hook;
  int pos = 0;
  int _param = 0;
  _Tok? _peeked;

  SqlSubsetError _err(String msg) => SqlSubsetError('Sintassi non supportata: $msg');

  void _ws() {
    while (pos < text.length && text[pos].trim().isEmpty) {
      pos++;
    }
  }

  // -- lexer --------------------------------------------------------------

  _Tok _peek() => _peeked ??= _lex();

  _Tok _next() {
    final t = _peek();
    _peeked = null;
    return t;
  }

  _Tok _lex() {
    _ws();
    final s = pos;
    if (pos >= text.length) return _Tok(_T.end, '', s, s);
    final c = text[pos];
    if (c == "'") {
      final end = _skipQuoted(text, pos);
      pos = end;
      final body = text.substring(s + 1, end - 1).replaceAll("''", "'");
      return _Tok(_T.string, text.substring(s, end), s, end, _unescape(body));
    }
    if (c == '"' || c == '`') {
      final close = c;
      var j = pos + 1;
      final sb = StringBuffer();
      while (j < text.length) {
        if (text[j] == close) {
          if (j + 1 < text.length && text[j + 1] == close) {
            sb.write(close);
            j += 2;
            continue;
          }
          break;
        }
        sb.write(text[j]);
        j++;
      }
      pos = j + 1;
      var name = sb.toString();
      // Quoted identifiers may be followed by .more
      while (pos < text.length && text[pos] == '.') {
        final t = _lexIdentTail();
        name = '$name.$t';
      }
      return _Tok(_T.ident, name, s, pos, name);
    }
    if (RegExp(r'[0-9]').hasMatch(c) ||
        ((c == '-' || c == '.') && pos + 1 < text.length && RegExp(r'[0-9]').hasMatch(text[pos + 1]))) {
      pos++;
      while (pos < text.length && RegExp(r'[0-9.eE]').hasMatch(text[pos])) {
        if ((text[pos] == 'e' || text[pos] == 'E') && pos + 1 < text.length && '+-'.contains(text[pos + 1])) pos++;
        pos++;
      }
      final raw = text.substring(s, pos);
      final v = int.tryParse(raw) ?? double.tryParse(raw);
      if (v == null) throw _err('numero "$raw"');
      return _Tok(_T.number, raw, s, pos, v);
    }
    if (c == '?') {
      pos++;
      if (_param >= params.length) throw _err('parametro ? senza valore');
      return _Tok(_T.param, '?', s, pos, params[_param++]);
    }
    if (c == '(') {
      pos++;
      return _Tok(_T.lparen, c, s, pos);
    }
    if (c == ')') {
      pos++;
      return _Tok(_T.rparen, c, s, pos);
    }
    if (c == ',') {
      pos++;
      return _Tok(_T.comma, c, s, pos);
    }
    if (c == '*') {
      pos++;
      return _Tok(_T.star, c, s, pos);
    }
    for (final op in const ['<=', '>=', '<>', '!=', '==', '=', '<', '>']) {
      if (text.startsWith(op, pos)) {
        pos += op.length;
        return _Tok(_T.op, op == '<>' ? '!=' : (op == '==' ? '=' : op), s, pos);
      }
    }
    if (c == '{' || c == '[') {
      // JSON value: delegated to the hook.
      pos = _balanced(pos);
      return _Tok(_T.ident, text.substring(s, pos), s, pos, _Json(text.substring(s, pos)));
    }
    if (_identChar(c)) {
      while (pos < text.length && (_identChar(text[pos]) || text[pos] == '.')) {
        pos++;
      }
      return _Tok(_T.ident, text.substring(s, pos), s, pos);
    }
    throw _err('carattere "$c"');
  }

  String _lexIdentTail() {
    pos++; // '.'
    if (pos < text.length && (text[pos] == '"' || text[pos] == '`')) {
      final t = _lex();
      return t.text;
    }
    final s = pos;
    while (pos < text.length && _identChar(text[pos])) {
      pos++;
    }
    return text.substring(s, pos);
  }

  static bool _identChar(String c) => RegExp(r'[A-Za-z0-9_$@#\u0080-￿]').hasMatch(c);

  int _balanced(int i) {
    var depth = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == "'" || c == '"' || c == '`') {
        i = _skipQuoted(text, i);
        continue;
      }
      if (c == '{' || c == '[' || c == '(') depth++;
      if (c == '}' || c == ']' || c == ')') {
        depth--;
        if (depth == 0) return i + 1;
      }
      i++;
    }
    throw _err('parentesi non bilanciate');
  }

  static String _unescape(String s) => s;

  // -- statements ---------------------------------------------------------

  void _kw(String k) {
    final t = _next();
    if (!t.kw(k)) throw _err('atteso $k');
  }

  SqlSubsetStatement statement(String kind) {
    switch (kind) {
      case 'select':
        return _select();
      case 'update':
        _kw('UPDATE');
        final target = _target();
        _kw('SET');
        final sets = <(String, Object?)>[];
        while (true) {
          final f = _next();
          if (f.type != _T.ident) throw _err('nome di colonna atteso in SET');
          final op = _next();
          if (op.type != _T.op || op.text != '=') throw _err('"=" atteso in SET');
          sets.add((f.value as String? ?? f.text, _value()));
          if (_peek().type == _T.comma) {
            _next();
            continue;
          }
          break;
        }
        final (where, whereText) = _where();
        _end();
        return SubsetUpdate(target, sets, where: where, whereText: whereText);
      case 'insert':
        _kw('INSERT');
        _kw('INTO');
        final target = _target(stopAtParen: true);
        final cols = <String>[];
        if (_peek().type == _T.lparen) {
          _next();
          while (true) {
            final f = _next();
            if (f.type != _T.ident) throw _err('nome di colonna atteso');
            cols.add(f.value as String? ?? f.text);
            final t = _next();
            if (t.type == _T.rparen) break;
            if (t.type != _T.comma) throw _err('"," o ")" attesi');
          }
        }
        if (_peek().kw('DEFAULT')) {
          _next();
          _kw('VALUES');
          _end();
          return SubsetInsert(target, cols, const [[]]);
        }
        _kw('VALUES');
        final rows = <List<Object?>>[];
        while (true) {
          if (_next().type != _T.lparen) throw _err('"(" atteso dopo VALUES');
          final row = <Object?>[];
          while (true) {
            row.add(_value());
            final t = _next();
            if (t.type == _T.rparen) break;
            if (t.type != _T.comma) throw _err('"," o ")" attesi');
          }
          if (cols.isNotEmpty && row.length != cols.length) throw _err('numero di valori diverso dalle colonne');
          rows.add(row);
          if (_peek().type == _T.comma) {
            _next();
            continue;
          }
          break;
        }
        _end();
        return SubsetInsert(target, cols, rows);
      default:
        _kw('DELETE');
        _kw('FROM');
        final target = _target();
        final (where, whereText) = _where();
        _end();
        return SubsetDelete(target, where: where, whereText: whereText);
    }
  }

  void _end() {
    if (_peek().type != _T.end) throw _err('testo inatteso "${_peek().text}"');
  }

  SubsetSelect _select() {
    _kw('SELECT');
    List<String>? cols;
    var isCount = false;
    final t = _peek();
    if (t.type == _T.star) {
      _next();
    } else if (t.kw('COUNT')) {
      _next();
      if (_next().type != _T.lparen) throw _err('"(" atteso dopo COUNT');
      final a = _next();
      if (a.type != _T.star && a.type != _T.ident && a.type != _T.number) throw _err('COUNT(*) atteso');
      if (_next().type != _T.rparen) throw _err('")" atteso');
      if (_peek().kw('AS')) {
        _next();
        _next();
      }
      isCount = true;
    } else {
      cols = [];
      while (true) {
        final c = _next();
        if (c.type != _T.ident) throw _err('nome di colonna atteso');
        cols.add(c.value as String? ?? c.text);
        if (_peek().type == _T.comma) {
          _next();
          continue;
        }
        break;
      }
    }
    _kw('FROM');
    final target = _target();
    final (where, whereText) = _where();
    var order = <SqlOrder>[];
    var orderText = '';
    int? limit, offset;
    while (_peek().type != _T.end) {
      final k = _next();
      if (k.kw('ORDER')) {
        _kw('BY');
        final start = _peek().start;
        if (_peek().value is _Json) {
          orderText = (_next().value as _Json).text;
        } else {
          order = [];
          while (true) {
            final f = _next();
            if (f.type != _T.ident && f.type != _T.number) throw _err('colonna attesa in ORDER BY');
            var desc = false;
            if (_peek().kw('DESC')) {
              _next();
              desc = true;
            } else if (_peek().kw('ASC')) {
              _next();
            }
            if (_peek().kw('NULLS')) {
              _next();
              _next();
            }
            order.add(SqlOrder(f.value is String ? f.value as String : f.text, desc));
            if (_peek().type == _T.comma) {
              _next();
              continue;
            }
            break;
          }
          orderText = text.substring(start, _peek().start).trim();
        }
      } else if (k.kw('LIMIT')) {
        final n = _next();
        if (n.value is! int) throw _err('numero atteso dopo LIMIT');
        limit = n.value as int;
        if (_peek().type == _T.comma) {
          _next();
          final m = _next();
          if (m.value is! int) throw _err('numero atteso dopo LIMIT');
          offset = limit;
          limit = m.value as int;
        }
      } else if (k.kw('OFFSET')) {
        final n = _next();
        if (n.value is! int) throw _err('numero atteso dopo OFFSET');
        offset = n.value as int;
        if (_peek().kw('ROWS') || _peek().kw('ROW')) _next();
      } else if (k.kw('FETCH')) {
        // FETCH FIRST n ROWS ONLY
        _next();
        final n = _next();
        if (n.value is! int) throw _err('numero atteso dopo FETCH FIRST');
        limit = n.value as int;
        while (_peek().type == _T.ident) {
          _next();
        }
      } else {
        throw _err('testo inatteso "${k.text}"');
      }
    }
    return SubsetSelect(
      target,
      columns: cols,
      isCount: isCount,
      where: where,
      whereText: whereText,
      orderBy: order,
      orderText: orderText,
      limit: limit,
      offset: offset,
    );
  }

  /// Reads a table reference as raw text (key patterns may contain any
  /// character except blanks).
  SqlTarget _target({bool stopAtParen = false}) {
    _peeked = null;
    _ws();
    final parts = <String>[];
    final raw = StringBuffer();
    var cur = StringBuffer();
    while (pos < text.length) {
      final c = text[pos];
      if (c.trim().isEmpty) break;
      if (stopAtParen && c == '(') break;
      if (c == '"' || c == '`') {
        final close = c;
        var j = pos + 1;
        while (j < text.length) {
          if (text[j] == close) {
            if (j + 1 < text.length && text[j + 1] == close) {
              cur.write(close);
              raw.write(close);
              j += 2;
              continue;
            }
            break;
          }
          cur.write(text[j]);
          raw.write(text[j]);
          j++;
        }
        pos = j + 1;
        continue;
      }
      if (c == '.') {
        parts.add(cur.toString());
        cur = StringBuffer();
        raw.write(c);
        pos++;
        continue;
      }
      cur.write(c);
      raw.write(c);
      pos++;
    }
    parts.add(cur.toString());
    if (raw.isEmpty) throw _err('nome di tabella atteso');
    return SqlTarget(raw.toString(), parts);
  }

  (SqlExpr?, String) _where() {
    if (!_peek().kw('WHERE')) return (null, '');
    final w = _next();
    final start = w.end;
    _ws();
    if (pos < text.length && text[pos] == '{') {
      // JSON filter: raw text up to ORDER BY / LIMIT at depth 0.
      _peeked = null;
      final end = _balanced(pos);
      pos = end;
      return (null, text.substring(start, end).trim());
    }
    final e = _expr();
    return (e, text.substring(start, _peek().start).trim());
  }

  // -- expressions ----------------------------------------------------------

  SqlExpr _expr() {
    final items = [_and()];
    while (_peek().kw('OR')) {
      _next();
      items.add(_and());
    }
    return items.length == 1 ? items.first : SqlOr(items);
  }

  SqlExpr _and() {
    final items = [_not()];
    while (_peek().kw('AND')) {
      _next();
      items.add(_not());
    }
    return items.length == 1 ? items.first : SqlAnd(items);
  }

  SqlExpr _not() {
    if (_peek().kw('NOT')) {
      _next();
      return SqlNot(_not());
    }
    return _primary();
  }

  SqlExpr _primary() {
    final t = _next();
    if (t.type == _T.lparen) {
      final e = _expr();
      if (_next().type != _T.rparen) throw _err('")" atteso');
      return e;
    }
    if (t.type != _T.ident || t.value is _Json) throw _err('nome di colonna atteso, trovato "${t.text}"');
    final field = t.value as String? ?? t.text;
    var negated = false;
    if (_peek().kw('NOT')) {
      _next();
      negated = true;
    }
    final op = _next();
    if (op.type == _T.op && !negated) return SqlCmp(field, op.text, _value());
    if (op.kw('LIKE') || op.kw('ILIKE')) {
      return SqlCmp(field, op.text.toLowerCase(), _value(), negated: negated);
    }
    if (op.kw('IN')) {
      if (_next().type != _T.lparen) throw _err('"(" atteso dopo IN');
      final values = <Object?>[];
      while (true) {
        values.add(_value());
        final s = _next();
        if (s.type == _T.rparen) break;
        if (s.type != _T.comma) throw _err('"," o ")" attesi');
      }
      return SqlIn(field, values, negated: negated);
    }
    if (op.kw('BETWEEN')) {
      final lo = _value();
      _kw('AND');
      return SqlBetween(field, lo, _value(), negated: negated);
    }
    if (op.kw('IS') && !negated) {
      var neg = false;
      if (_peek().kw('NOT')) {
        _next();
        neg = true;
      }
      _kw('NULL');
      return SqlIsNull(field, negated: neg);
    }
    throw _err('operatore atteso dopo "$field"');
  }

  Object? _value() {
    final t = _next();
    switch (t.type) {
      case _T.string:
      case _T.number:
      case _T.param:
        return t.value;
      case _T.ident:
        if (t.value is _Json) return _callHook((t.value as _Json).text);
        final u = t.text.toUpperCase();
        if (u == 'NULL') return null;
        if (u == 'TRUE') return true;
        if (u == 'FALSE') return false;
        if (_peek().type == _T.lparen) {
          // Function literal such as ObjectId('…'): raw text to the hook.
          final end = _balanced(_peek().start);
          _peeked = null;
          pos = end;
          return _callHook(text.substring(t.start, end));
        }
        throw _err('valore atteso, trovato "${t.text}"');
      default:
        throw _err('valore atteso, trovato "${t.text}"');
    }
  }

  Object? _callHook(String raw) {
    final h = hook;
    if (h == null) throw _err('valore "$raw" non supportato');
    return h(raw);
  }
}

class _Json {
  const _Json(this.text);
  final String text;
}
