// Parser of the MongoDB shell syntax accepted by the SQL editor:
//
//   db.coll.find({…}, {…}).sort({…}).limit(10)
//   db.getCollection('a.b').aggregate([…])
//   db.getSiblingDB('admin').runCommand({ping: 1})
//   show dbs | show collections | use <db>
//   { ping: 1 }                       (bare command document)
import '../common/relaxed_json.dart';
import 'bson.dart';

/// A method call in a chain: `name(args)`.
class ShellCall {
  const ShellCall(this.name, this.args);
  final String name;
  final List<Object?> args;

  Object? arg(int i) => i < args.length ? args[i] : null;
}

sealed class ShellStatement {
  const ShellStatement(this.text);

  /// Source text of the statement (for messages).
  final String text;
}

/// `show <what>`.
class ShellShow extends ShellStatement {
  const ShellShow(super.text, this.what);
  final String what;
}

/// `use <db>`.
class ShellUse extends ShellStatement {
  const ShellUse(super.text, this.database);
  final String database;
}

/// `db.method(…)` or `db.coll.method(…).modifier(…)…`.
class ShellCallStatement extends ShellStatement {
  const ShellCallStatement(
    super.text, {
    this.database,
    this.collection,
    required this.method,
    this.modifiers = const [],
  });

  /// Database selected with getSiblingDB (null: current database).
  final String? database;

  /// Collection (null for database methods).
  final String? collection;
  final ShellCall method;

  /// Cursor modifiers chained after the method (.sort, .limit, …).
  final List<ShellCall> modifiers;

  ShellCall? modifier(String name) {
    for (final m in modifiers.reversed) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// Bare command document typed on its own (`{ping: 1}`), run with runCommand.
class ShellCommandDoc extends ShellStatement {
  const ShellCommandDoc(super.text, this.command);
  final Map<String, Object?> command;
}

JsScanner _scanner(String text) =>
    JsScanner(text, onCall: mongoCallHook, onObject: mongoObjectHook, onRegex: mongoRegexHook);

/// Parses a script made of one or more shell statements separated by
/// newlines or semicolons.
List<ShellStatement> parseShellScript(String text) {
  final s = _scanner(text);
  final out = <ShellStatement>[];
  while (true) {
    s.skipWs();
    while (s.tryConsume(';')) {
      s.skipWs();
    }
    if (s.pos >= text.length) break;
    final start = s.pos;
    final st = _statement(s);
    out.add(st);
    // A statement must end at ';', a newline or the end of the text.
    s.skipWs(newlines: false);
    if (s.pos < text.length && text[s.pos] != ';' && text[s.pos] != '\n') {
      throw s.error('Fine istruzione attesa dopo "${text.substring(start, s.pos).trim()}"');
    }
  }
  return out;
}

String _restOfLine(JsScanner s) {
  final end = s.text.indexOf(RegExp(r'[;\n]'), s.pos);
  final e = end < 0 ? s.text.length : end;
  final v = s.text.substring(s.pos, e).trim();
  s.pos = e;
  return v;
}

ShellStatement _statement(JsScanner s) {
  final start = s.pos;
  if (s.peek() == '{') {
    final v = s.parseValue();
    if (v is! Map) throw s.error('Documento di comando atteso');
    return ShellCommandDoc(s.text.substring(start, s.pos), v.cast<String, Object?>());
  }
  final word = s.readIdentifier();
  if (word == null) throw s.error('Istruzione non riconosciuta');
  switch (word) {
    case 'show':
      final what = _restOfLine(s);
      if (what.isEmpty) throw s.error('show: argomento atteso (dbs, collections, users, roles, profile)');
      return ShellShow(s.text.substring(start, s.pos), what.toLowerCase());
    case 'use':
      var db = _restOfLine(s);
      if (db.length > 1 && (db.startsWith('"') || db.startsWith("'"))) db = db.substring(1, db.length - 1);
      if (db.isEmpty) throw s.error('use: nome del database atteso');
      return ShellUse(s.text.substring(start, s.pos), db);
    case 'db':
      return _dbChain(s, start);
  }
  throw s.error('Istruzione non riconosciuta "$word": usa db.<collezione>.<metodo>(…), show, use');
}

/// Element of a `db.` chain: a member (`.name` / `['name']`) or a call.
class _Elem {
  _Elem(this.name, [this.args]);
  final String name;
  final List<Object?>? args;
  bool get isCall => args != null;
}

ShellStatement _dbChain(JsScanner s, int start) {
  final elems = <_Elem>[];
  while (true) {
    // Allow chained calls on the next line (`.limit(5)`), not members.
    final save = s.pos;
    s.skipWs();
    if (s.pos < s.text.length && s.text[s.pos] == '.') {
      s.pos++;
      final name = s.readIdentifier();
      if (name == null) throw s.error('Nome atteso dopo "."');
      if (s.tryConsume('(')) {
        elems.add(_Elem(name, s.parseArguments()));
      } else {
        elems.add(_Elem(name));
      }
    } else if (s.pos < s.text.length && s.text[s.pos] == '[' && elems.every((e) => !e.isCall)) {
      s.pos++;
      final v = s.parseValue();
      s.expect(']');
      elems.add(_Elem(v.toString()));
    } else {
      s.pos = save;
      break;
    }
  }
  final text = s.text.substring(start, s.pos);
  var i = 0;
  String? database;
  while (i < elems.length && elems[i].isCall && (elems[i].name == 'getSiblingDB' || elems[i].name == 'getMongo')) {
    if (elems[i].name == 'getSiblingDB') {
      final a = elems[i].args!;
      if (a.isEmpty) throw s.error('getSiblingDB: nome del database atteso');
      database = a.first.toString();
    }
    i++;
  }
  if (i >= elems.length) {
    return ShellCallStatement(text, database: database, method: const ShellCall('getName', []));
  }
  String? collection;
  ShellCall method;
  if (elems[i].isCall && elems[i].name == 'getCollection') {
    final a = elems[i].args!;
    if (a.isEmpty) throw s.error('getCollection: nome della collezione atteso');
    collection = a.first.toString();
    i++;
    if (i >= elems.length || !elems[i].isCall) throw s.error('Metodo atteso dopo getCollection(…)');
    method = ShellCall(elems[i].name, elems[i].args!);
  } else if (elems[i].isCall) {
    method = ShellCall(elems[i].name, elems[i].args!);
  } else {
    final names = <String>[];
    while (i < elems.length && !elems[i].isCall) {
      names.add(elems[i].name);
      i++;
    }
    if (i >= elems.length) {
      throw s.error('Metodo atteso: ad esempio db.${names.join('.')}.find()');
    }
    collection = names.join('.');
    method = ShellCall(elems[i].name, elems[i].args!);
  }
  i++;
  final mods = <ShellCall>[];
  for (; i < elems.length; i++) {
    if (!elems[i].isCall) throw s.error('Metodo atteso al posto di ".${elems[i].name}"');
    mods.add(ShellCall(elems[i].name, elems[i].args!));
  }
  return ShellCallStatement(text, database: database, collection: collection, method: method, modifiers: mods);
}

/// Shell methods that modify data or schema (blocked on read-only
/// connections).
const shellWriteMethods = {
  'insert', 'insertOne', 'insertMany', 'update', 'updateOne', 'updateMany', 'replaceOne', 'remove', //
  'deleteOne', 'deleteMany', 'findOneAndUpdate', 'findOneAndReplace', 'findOneAndDelete', 'findAndModify',
  'bulkWrite', 'save', 'drop', 'createIndex', 'createIndexes', 'ensureIndex', 'dropIndex', 'dropIndexes',
  'renameCollection', 'createCollection', 'createView', 'dropDatabase', 'createUser', 'dropUser', 'updateUser',
  'killOp', 'shutdownServer', 'reIndex', 'hideIndex', 'unhideIndex',
};

/// Commands that modify data or schema (runCommand on a read-only connection).
const commandWriteNames = {
  'insert', 'update', 'delete', 'findandmodify', 'create', 'drop', 'dropdatabase', 'createindexes', //
  'dropindexes', 'renamecollection', 'collmod', 'createuser', 'dropuser', 'updateuser', 'grantrolestouser',
  'revokerolesfromuser', 'createrole', 'droprole', 'shutdown', 'compact', 'reindex', 'killop', 'applyops',
  'clonecollectionascapped', 'converttocapped', 'setparameter', 'fsync', 'dropallusersfromdatabase',
};
