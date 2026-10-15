// Mock data generator engine (DBeaver PRO "Generate mock data"): pure Dart,
// no Flutter. Every column gets a generator, chosen automatically from its
// name and type and overridable by the user; rows are reproducible for a
// given seed.
import 'dart:math';
import 'dart:typed_data';

import '../../model/db_objects.dart';
import '../../odbc/odbc_ffi.dart';
import '../../services/sql_dialect.dart';
import '../data_compare/sql_values.dart';
import 'mock_lists.dart';

enum MockLocale {
  it('Italiano'),
  en('Inglese');

  const MockLocale(this.label);
  final String label;
}

enum MockKind {
  auto('Automatico'),
  sequence('Sequenza'),
  integer('Intero'),
  decimal('Decimale'),
  lorem('Testo lorem'),
  pattern('Testo da modello'),
  list('Lista di valori'),
  dateTime('Data/ora'),
  boolean('Booleano'),
  uuid('UUID'),
  firstName('Nome'),
  lastName('Cognome'),
  fullName('Nome completo'),
  email('Email'),
  phone('Telefono'),
  address('Indirizzo'),
  city('Città'),
  zip('CAP'),
  province('Provincia'),
  country('Paese'),
  company('Azienda'),
  fiscalCode('Codice fiscale'),
  vatNumber('Partita IVA'),
  iban('IBAN'),
  url('URL'),
  username('Username'),
  passwordHash('Hash password'),
  ip('Indirizzo IP'),
  color('Colore'),
  bytes('Byte casuali'),
  constant('Costante'),
  nullValue('NULL'),
  foreignKey('Chiave esterna'),
  skip('Salta');

  const MockKind(this.label);
  final String label;
}

class MockGenerationException implements Exception {
  MockGenerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Distinct values (tuples for composite keys) sampled from the table
/// referenced by a foreign key. Shared by the columns of the same key so
/// that each generated row uses a coherent tuple.
class MockFkSample {
  MockFkSample({required this.name, required this.refTable, required this.refColumns, this.tuples = const []});
  final String name;
  final String refTable;
  final List<String> refColumns;
  List<List<Object?>> tuples;
  String? error;
  bool loaded = false;
}

/// Generator settings of a column (edited in the dialog).
class MockColumnConfig {
  MockColumnConfig(
    DbColumn column, {
    this.isPrimaryKey = false,
    this.isUniqueIndex = false,
    this.fkSample,
    this.fkPosition = 0,
    this.compositeKey = false,
  }) : column = normalizeMockColumn(column) {
    autoKind = suggestKind(this.column, isForeignKey: fkSample != null, isPrimaryKey: isPrimaryKey);
    unique = (isPrimaryKey && !compositeKey) || isUniqueIndex;
    _defaults();
  }

  final DbColumn column;
  final bool isPrimaryKey;
  final bool isUniqueIndex;

  /// Part of a multi-column primary key (uniqueness is checked on the tuple).
  final bool compositeKey;
  final MockFkSample? fkSample;
  final int fkPosition;

  late final MockKind autoKind;
  MockKind kind = MockKind.auto;

  MockKind get effectiveKind => kind == MockKind.auto ? autoKind : kind;
  bool get included => effectiveKind != MockKind.skip;

  // Parameters of the generators.
  int seqStart = 1;
  int seqStep = 1;
  int intMin = 1;
  int intMax = 1000;
  double decMin = 0;
  double decMax = 1000;
  int scale = 2;
  int minWords = 3;
  int maxWords = 10;
  String pattern = 'ORD-#####-??';

  /// Comma separated values, optionally weighted: `attivo=70, chiuso=30`.
  String listValues = '';
  DateTime dateFrom = DateTime(DateTime.now().year - 5, 1, 1);
  DateTime dateTo = DateTime.now();
  double truePercent = 50;
  String constant = '';

  /// Percentage of NULLs (only for nullable columns).
  double nullPercent = 0;
  late bool unique;

  String get name => column.name;
  String get lname => column.name.toLowerCase();

  /// Maximum length of text values (0 = unlimited).
  int get maxLength {
    final s = column.size ?? 0;
    if (!isTextSqlType(column.dataType) && !_isTextLike(column)) return 0;
    if (s <= 0 || s >= 1 << 30) return 0;
    return s;
  }

  void _defaults() {
    final c = column;
    final t = c.dataType;
    final n = _Name(c.name);
    // Integer ranges bounded by the type.
    var hi = switch (t) {
      SQL_TINYINT => 100,
      SQL_SMALLINT => 1000,
      SQL_BIGINT => 1000000,
      _ => 100000,
    };
    if ((t == SQL_DECIMAL || t == SQL_NUMERIC) && (c.size ?? 0) > 0) {
      final digits = (c.size! - (c.decimals ?? 0)).clamp(1, 15);
      final cap = pow(10, digits).toInt() - 1;
      if (cap < hi) hi = cap;
    }
    intMin = 1;
    intMax = hi;
    scale = (t == SQL_DECIMAL || t == SQL_NUMERIC) ? (c.decimals ?? 2).clamp(0, 6) : 2;
    if (isIntegerSqlType(t) || ((t == SQL_DECIMAL || t == SQL_NUMERIC) && (c.decimals ?? 0) == 0)) scale = 0;
    decMin = 1;
    decMax = min(1000, hi.toDouble());
    if (n.hasAny(const ['quantita', 'qta', 'qty', 'quantity', 'pezzi', 'pieces'])) {
      intMin = 1;
      intMax = min(100, hi);
    } else if (n.hasAny(const ['eta', 'age'])) {
      intMin = 18;
      intMax = min(90, hi);
    } else if (n.hasAny(const ['anno', 'year'])) {
      intMin = 2000;
      intMax = min(DateTime.now().year + 2, max(hi, 2000));
    }
    if (n.hasAny(const ['nascita', 'birth', 'nato', 'dob', 'birthday', 'compleanno'])) {
      dateFrom = DateTime(1950, 1, 1);
      dateTo = DateTime(2005, 12, 31);
    }
    if (n.hasAny(const ['sesso', 'gender', 'sex', 'genere'])) {
      listValues = 'M, F';
    } else if (n.hasAny(const ['stato', 'status', 'state']) && autoKind == MockKind.list) {
      listValues = (isTextSqlType(t) ? itStatusValues : const ['1', '2', '3', '4']).join(', ');
    } else if (autoKind == MockKind.list) {
      listValues = 'A, B, C';
    }
    if (autoKind == MockKind.lorem && n.hasAny(const ['nome', 'name', 'titolo', 'title', 'oggetto', 'subject'])) {
      minWords = 1;
      maxWords = 4;
    }
    final ml = maxLength;
    if (ml > 0) {
      maxWords = min(maxWords, (ml ~/ 8).clamp(1, 10));
      minWords = min(minWords, maxWords);
    }
    if (autoKind == MockKind.pattern) {
      pattern = _defaultPattern(ml);
    }
  }

  static String _defaultPattern(int ml) {
    if (ml <= 0 || ml >= 12) return '???-#####';
    if (ml <= 3) return '?' * ml;
    return '${'?' * 2}${'#' * (ml - 2).clamp(1, 8)}';
  }

  /// Short description of the parameters (column list in the dialog).
  String get summary {
    final k = effectiveKind;
    final s = switch (k) {
      MockKind.sequence => 'da $seqStart, passo $seqStep',
      MockKind.integer => '$intMin … $intMax',
      MockKind.decimal => '${decMin.toStringAsFixed(scale)} … ${decMax.toStringAsFixed(scale)}',
      MockKind.lorem => '$minWords–$maxWords parole',
      MockKind.pattern => pattern,
      MockKind.list => listValues,
      MockKind.dateTime => '${_fmtDate(dateFrom)} … ${_fmtDate(dateTo)}',
      MockKind.boolean => '${truePercent.round()}% vero',
      MockKind.constant => constant,
      MockKind.foreignKey =>
        fkSample == null
            ? 'nessun riferimento'
            : '${fkSample!.refTable}.${fkSample!.refColumns[fkPosition]}'
                  '${fkSample!.loaded ? ' (${fkSample!.tuples.length} valori)' : ''}',
      _ => '',
    };
    final extra = [
      if (nullPercent > 0 && column.nullable && k != MockKind.nullValue) '${nullPercent.round()}% NULL',
      if (unique && k != MockKind.sequence) 'univoco',
    ];
    return [if (s.isNotEmpty) s, ...extra].join(' · ');
  }
}

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

bool _isTextLike(DbColumn c) {
  final t = c.typeName.toLowerCase();
  return t.contains('char') || t.contains('text') || t.contains('string') || t == 'clob' || t == 'nclob';
}

bool _isBoolean(DbColumn c) {
  final t = c.typeName.toLowerCase();
  return c.dataType == SQL_BIT || t == 'bool' || t == 'boolean';
}

bool _isGuid(DbColumn c) {
  final t = c.typeName.toLowerCase();
  return c.dataType == SQL_GUID || t == 'uuid' || t == 'uniqueidentifier';
}

/// Tokens of a column name (snake_case, camelCase, accents removed).
class _Name {
  _Name(String name) {
    final spaced = name
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .toLowerCase()
        .replaceAll(RegExp('[àá]'), 'a')
        .replaceAll(RegExp('[èé]'), 'e')
        .replaceAll(RegExp('[ìí]'), 'i')
        .replaceAll(RegExp('[òó]'), 'o')
        .replaceAll(RegExp('[ùú]'), 'u');
    tokens = spaced.split(RegExp(r'[^a-z0-9]+')).where((e) => e.isNotEmpty).toList();
    joined = tokens.join('_');
    compact = tokens.join();
  }

  late final List<String> tokens;
  late final String joined;
  late final String compact;

  /// True when a word is a token, or a multi-word phrase (`codice_fiscale`)
  /// appears in the name.
  bool hasAny(List<String> words) {
    for (final w in words) {
      if (w.contains('_')) {
        if (joined.contains(w) || compact.contains(w.replaceAll('_', ''))) return true;
      } else if (tokens.contains(w)) {
        return true;
      }
    }
    return false;
  }

  bool startsWithAny(List<String> words) => tokens.isNotEmpty && words.contains(tokens.first);
}

/// Some drivers (SQLite ODBC, dynamic typed sources) report declared types
/// such as `decimal(10,2)` or `date` as VARCHAR: the declared type name wins
/// so numbers and dates get the right generator.
DbColumn normalizeMockColumn(DbColumn c) {
  final t = c.dataType;
  if (isNumericSqlType(t) || temporalKindOf(t) != null || isBinarySqlType(t) || _isBoolean(c)) return c;
  final m = RegExp(r'^\s*([a-z ]+?)\s*(?:\(\s*(\d+)\s*(?:,\s*(\d+)\s*)?\))?\s*$').firstMatch(c.typeName.toLowerCase());
  if (m == null) return c;
  final base = m.group(1)!;
  final mapped = switch (base) {
    'decimal' || 'numeric' || 'number' || 'money' || 'smallmoney' => SQL_DECIMAL,
    'int' || 'integer' || 'int4' || 'mediumint' => SQL_INTEGER,
    'bigint' || 'int8' => SQL_BIGINT,
    'smallint' || 'int2' => SQL_SMALLINT,
    'tinyint' => SQL_TINYINT,
    'real' || 'float' || 'double' || 'double precision' || 'float8' || 'float4' => SQL_DOUBLE,
    'date' => SQL_TYPE_DATE,
    'time' => SQL_TYPE_TIME,
    'datetime' || 'timestamp' || 'datetime2' || 'smalldatetime' => SQL_TYPE_TIMESTAMP,
    _ => null,
  };
  if (mapped == null) return c;
  final size = int.tryParse(m.group(2) ?? '');
  final scale = int.tryParse(m.group(3) ?? '');
  return DbColumn(
    name: c.name,
    dataType: mapped,
    typeName: c.typeName,
    size: mapped == SQL_DECIMAL ? (size ?? c.size) : c.size,
    decimals: mapped == SQL_DECIMAL ? (scale ?? (size != null ? 0 : c.decimals)) : c.decimals,
    nullable: c.nullable,
    position: c.position,
    defaultValue: c.defaultValue,
    remarks: c.remarks,
    autoIncrement: c.autoIncrement,
  );
}

/// Picks a generator from the column name and type.
MockKind suggestKind(DbColumn c, {bool isForeignKey = false, bool isPrimaryKey = false}) {
  if (c.autoIncrement) return MockKind.skip;
  if (isForeignKey) return MockKind.foreignKey;
  final t = c.dataType;
  final n = _Name(c.name);
  if (_isGuid(c) || n.hasAny(const ['uuid', 'guid'])) return MockKind.uuid;
  if (isBinarySqlType(t)) return MockKind.bytes;
  if (_isBoolean(c)) return MockKind.boolean;
  if (temporalKindOf(t) != null) return MockKind.dateTime;
  final flag =
      n.startsWithAny(const ['is', 'has', 'flg', 'fl']) ||
      n.hasAny(const ['flag', 'attivo', 'active', 'enabled', 'abilitato', 'deleted', 'cancellato', 'visibile']);
  if (isNumericSqlType(t)) {
    if (isPrimaryKey && isIntegerSqlType(t)) return MockKind.sequence;
    if (flag && (t == SQL_TINYINT || t == SQL_SMALLINT || ((c.size ?? 0) == 1))) return MockKind.boolean;
    if (n.hasAny(const ['sesso', 'gender'])) return MockKind.list;
    if (n.hasAny(const ['stato', 'status']) && isIntegerSqlType(t)) return MockKind.list;
    final money = n.hasAny(const [
      'prezzo', 'importo', 'costo', 'totale', 'price', 'amount', 'cost', 'total', 'imponibile', 'iva', //
      'saldo', 'balance', 'stipendio', 'salary', 'sconto', 'discount', 'valore', 'value',
    ]);
    if (money && !isIntegerSqlType(t)) return MockKind.decimal;
    if (isIntegerSqlType(t) || ((t == SQL_DECIMAL || t == SQL_NUMERIC) && (c.decimals ?? 0) == 0)) {
      if (isPrimaryKey) return MockKind.sequence;
      return MockKind.integer;
    }
    return MockKind.decimal;
  }
  if (!isTextSqlType(t) && !_isTextLike(c)) {
    // Unknown types (XML, JSON, geometry, …): leave them to the database.
    return c.nullable ? MockKind.nullValue : MockKind.lorem;
  }
  if (n.hasAny(const ['email', 'mail', 'pec'])) return MockKind.email;
  if (n.hasAny(const [
    'codice_fiscale',
    'cod_fiscale',
    'cod_fisc',
    'codfisc',
    'cf',
    'fiscal_code',
    'tax_code',
    'ssn',
  ])) {
    return MockKind.fiscalCode;
  }
  if (n.hasAny(const ['partita_iva', 'p_iva', 'piva', 'vat', 'vat_number', 'vat_code'])) return MockKind.vatNumber;
  if (n.hasAny(const ['iban'])) return MockKind.iban;
  if (n.hasAny(const ['telefono', 'tel', 'phone', 'cellulare', 'cell', 'mobile', 'fax', 'telephone'])) {
    return MockKind.phone;
  }
  if (n.hasAny(const ['indirizzo_ip', 'ip', 'ip_address', 'ipaddr', 'ipv4'])) return MockKind.ip;
  if (n.hasAny(const ['indirizzo', 'address', 'via', 'street', 'addr', 'recapito'])) return MockKind.address;
  if (n.hasAny(const ['citta', 'city', 'comune', 'localita', 'town', 'municipality'])) return MockKind.city;
  if (n.hasAny(const ['cap', 'zip', 'zipcode', 'postal', 'postcode', 'postal_code'])) return MockKind.zip;
  if (n.hasAny(const ['provincia', 'province', 'prov', 'regione', 'region'])) return MockKind.province;
  if (n.hasAny(const ['paese', 'country', 'nazione', 'nation', 'nazionalita', 'nationality'])) {
    return MockKind.country;
  }
  if (n.hasAny(const [
    'azienda', 'company', 'ragione_sociale', 'ragionesociale', 'societa', 'ditta', 'fornitore', //
    'supplier', 'vendor', 'impresa', 'organization', 'organisation', 'employer',
  ])) {
    return MockKind.company;
  }
  if (n.hasAny(const ['url', 'website', 'sito', 'web', 'homepage', 'link', 'site'])) return MockKind.url;
  if (n.hasAny(const ['password', 'pwd', 'passwd', 'hash', 'password_hash'])) return MockKind.passwordHash;
  if (n.hasAny(const ['username', 'user_name', 'login', 'utente', 'nickname', 'nick', 'userid'])) {
    return MockKind.username;
  }
  if (n.hasAny(const ['colore', 'color', 'colour'])) return MockKind.color;
  if (n.hasAny(const ['nome_completo', 'full_name', 'fullname', 'nominativo', 'display_name', 'intestatario'])) {
    return MockKind.fullName;
  }
  if (n.hasAny(const ['nome', 'name', 'titolo', 'title']) &&
      n.hasAny(const [
        'prodotto', 'articolo', 'product', 'item', 'categoria', 'category', 'file', 'progetto', 'project', //
        'tabella', 'table', 'evento', 'event', 'corso', 'course', 'libro', 'book',
      ])) {
    return MockKind.lorem;
  }
  if (n.hasAny(const ['cognome', 'last_name', 'lastname', 'surname', 'family_name'])) return MockKind.lastName;
  if (n.hasAny(const ['nome', 'first_name', 'firstname', 'given_name', 'forename'])) return MockKind.firstName;
  if (n.hasAny(const ['name'])) return MockKind.fullName;
  if (n.hasAny(const ['sesso', 'gender', 'sex', 'genere'])) return MockKind.list;
  if (n.hasAny(const ['stato', 'status'])) return MockKind.list;
  if (n.hasAny(const [
    'descrizione', 'description', 'desc', 'note', 'notes', 'nota', 'commento', 'comment', 'comments', 'testo', //
    'text', 'body', 'messaggio', 'message', 'contenuto', 'content', 'titolo', 'title', 'oggetto', 'subject',
  ])) {
    return MockKind.lorem;
  }
  if (n.hasAny(const ['prezzo', 'importo', 'price', 'amount', 'costo', 'cost', 'totale', 'total'])) {
    return MockKind.decimal;
  }
  if (n.hasAny(const ['quantita', 'qta', 'qty', 'quantity'])) return MockKind.integer;
  if (n.hasAny(const ['codice', 'code', 'sku', 'riferimento', 'ref', 'reference', 'numero', 'number', 'matricola'])) {
    return MockKind.pattern;
  }
  final size = c.size ?? 0;
  if (size > 0 && size < 12) return MockKind.pattern;
  return MockKind.lorem;
}

// ---------------------------------------------------------------------------
// Italian identifiers
// ---------------------------------------------------------------------------

const _cfOdd = {
  '0': 1, '1': 0, '2': 5, '3': 7, '4': 9, '5': 13, '6': 15, '7': 17, '8': 19, '9': 21, //
  'A': 1, 'B': 0, 'C': 5, 'D': 7, 'E': 9, 'F': 13, 'G': 15, 'H': 17, 'I': 19, 'J': 21, 'K': 2, 'L': 4, 'M': 18,
  'N': 20, 'O': 11, 'P': 3, 'Q': 6, 'R': 8, 'S': 12, 'T': 14, 'U': 16, 'V': 10, 'W': 22, 'X': 25, 'Y': 24, 'Z': 23,
};

int _cfEven(String ch) {
  final c = ch.codeUnitAt(0);
  return c >= 48 && c <= 57 ? c - 48 : c - 65;
}

/// Check character of the Italian fiscal code (and of the bank CIN, which
/// uses the same tables) for the uppercase alphanumeric [s].
String italianCheckChar(String s) {
  var sum = 0;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    sum += i.isEven ? _cfOdd[ch]! : _cfEven(ch);
  }
  return String.fromCharCode(65 + sum % 26);
}

const _cfMonths = 'ABCDEHLMPRST';

String _plainUpper(String s) => s
    .toUpperCase()
    .replaceAll(RegExp('[ÀÁ]'), 'A')
    .replaceAll(RegExp('[ÈÉ]'), 'E')
    .replaceAll(RegExp('[ÌÍ]'), 'I')
    .replaceAll(RegExp('[ÒÓ]'), 'O')
    .replaceAll(RegExp('[ÙÚ]'), 'U')
    .replaceAll(RegExp('[^A-Z]'), '');

String _cfPart(String s, {required bool firstName}) {
  final p = _plainUpper(s);
  final cons = p.replaceAll(RegExp('[AEIOU]'), '');
  final vow = p.replaceAll(RegExp('[^AEIOU]'), '');
  if (firstName && cons.length >= 4) return '${cons[0]}${cons[2]}${cons[3]}';
  return '$cons${vow}XXX'.substring(0, 3);
}

/// Builds a well-formed Italian fiscal code (codice fiscale).
String italianFiscalCode({
  required String lastName,
  required String firstName,
  required DateTime birth,
  required bool female,
  required String placeCode,
}) {
  final day = birth.day + (female ? 40 : 0);
  final base =
      '${_cfPart(lastName, firstName: false)}${_cfPart(firstName, firstName: true)}'
      '${(birth.year % 100).toString().padLeft(2, '0')}${_cfMonths[birth.month - 1]}'
      '${day.toString().padLeft(2, '0')}$placeCode';
  return '$base${italianCheckChar(base)}';
}

final fiscalCodePattern = RegExp(r'^[A-Z]{6}\d{2}[ABCDEHLMPRST]\d{2}[A-Z]\d{3}[A-Z]$');

bool isValidFiscalCode(String cf) => fiscalCodePattern.hasMatch(cf) && italianCheckChar(cf.substring(0, 15)) == cf[15];

/// Check digit of an Italian VAT number (partita IVA) from its first 10
/// digits (Luhn variant).
int vatCheckDigit(String first10) {
  var sum = 0;
  for (var i = 0; i < 10; i++) {
    var d = first10.codeUnitAt(i) - 48;
    if (i.isOdd) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  return (10 - sum % 10) % 10;
}

bool isValidVatNumber(String p) => RegExp(r'^\d{11}$').hasMatch(p) && vatCheckDigit(p) == p.codeUnitAt(10) - 48;

/// IBAN check digits for [country] and [bban] (ISO 13616, mod 97).
String ibanCheckDigits(String country, String bban) {
  final r = _mod97('$bban${country}00');
  return (98 - r).toString().padLeft(2, '0');
}

int _mod97(String s) {
  var r = 0;
  for (final ch in s.toUpperCase().split('')) {
    final c = ch.codeUnitAt(0);
    final v = c >= 65 ? (c - 55).toString() : ch;
    for (final d in v.split('')) {
      r = (r * 10 + int.parse(d)) % 97;
    }
  }
  return r;
}

bool isValidIban(String iban) {
  final s = iban.replaceAll(' ', '').toUpperCase();
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$').hasMatch(s)) return false;
  return _mod97('${s.substring(4)}${s.substring(0, 4)}') == 1;
}

/// Italian IBAN from ABI, CAB and account number (CIN computed).
String italianIban(String abi, String cab, String account) {
  final acc = account.toUpperCase().padLeft(12, '0');
  final cin = italianCheckChar('$abi$cab$acc');
  final bban = '$cin$abi$cab$acc';
  return 'IT${ibanCheckDigits('IT', bban)}$bban';
}

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h;
}

class _ColState {
  _ColState(this.cfg, int seed) : rng = Random(seed ^ _fnv(cfg.name.toLowerCase()));
  final MockColumnConfig cfg;
  final Random rng;
  int seq = 0;
  final Set<String> seen = {};
  int suffix = 0;
  List<(String, double)>? weighted;
  double weightTotal = 0;
}

/// Produces rows for the included columns of [columns].
class MockDataGenerator {
  MockDataGenerator(List<MockColumnConfig> columns, {int? seed, this.locale = MockLocale.it, this.maxAttempts = 100})
    : seed = seed ?? Random().nextInt(1 << 31),
      columns = columns.where((c) => c.included).toList() {
    for (final c in this.columns) {
      _state.add(_ColState(c, this.seed));
    }
    for (var i = 0; i < this.columns.length; i++) {
      final c = this.columns[i];
      if (c.isPrimaryKey && c.compositeKey) _pkIndexes.add(i);
      if (c.effectiveKind == MockKind.foreignKey && c.fkSample != null) {
        _fkRng.putIfAbsent(c.fkSample!, () => Random(this.seed ^ _fnv('fk:${c.fkSample!.name}')));
      }
    }
  }

  final int seed;
  final MockLocale locale;
  final int maxAttempts;

  /// Columns present in the generated rows (in order).
  final List<MockColumnConfig> columns;
  final List<_ColState> _state = [];
  final List<int> _pkIndexes = [];
  final Set<String> _pkTuples = {};
  final Map<MockFkSample, Random> _fkRng = {};
  final Map<MockFkSample, Set<int>> _fkUsed = {};
  int rowsGenerated = 0;

  bool get _it => locale == MockLocale.it;

  /// Generates the next row.
  List<Object?> next() {
    final fkPick = <MockFkSample, int>{};
    final row = List<Object?>.filled(columns.length, null);
    for (var i = 0; i < columns.length; i++) {
      row[i] = _valueFor(i, fkPick);
    }
    if (_pkIndexes.isNotEmpty) {
      var attempt = 0;
      while (!_pkTuples.add(_pkIndexes.map((i) => _uniqueKey(row[i])).join('\u0001'))) {
        if (++attempt > maxAttempts) {
          throw MockGenerationException(
            'Impossibile generare una chiave primaria univoca '
            '(${_pkIndexes.map((i) => columns[i].name).join(', ')}) dopo $rowsGenerated righe.',
          );
        }
        fkPick.clear();
        for (final i in _pkIndexes) {
          row[i] = _valueFor(i, fkPick);
        }
      }
    }
    rowsGenerated++;
    return row;
  }

  Iterable<List<Object?>> take(int n) sync* {
    for (var i = 0; i < n; i++) {
      yield next();
    }
  }

  static String _uniqueKey(Object? v) {
    if (v is String) return v.trim().toLowerCase();
    if (v is Uint8List) return v.join(',');
    return '$v';
  }

  Object? _valueFor(int i, Map<MockFkSample, int> fkPick) {
    final st = _state[i];
    final c = st.cfg;
    final kind = c.effectiveKind;
    if (c.column.nullable && c.nullPercent > 0 && !c.isPrimaryKey && kind != MockKind.nullValue) {
      if (st.rng.nextDouble() * 100 < c.nullPercent) return null;
    }
    if (kind == MockKind.nullValue) return null;
    if (kind == MockKind.foreignKey) return _fkValue(st, fkPick);
    if (!c.unique || kind == MockKind.sequence) return _coerce(c, _raw(st, kind));
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final v = _coerce(c, _raw(st, kind));
      if (v == null || st.seen.add(_uniqueKey(v))) return v;
    }
    // Text: make the value unique with a numeric suffix.
    final base = _coerce(c, _raw(st, kind));
    if (base is String &&
        kind != MockKind.list &&
        kind != MockKind.constant &&
        kind != MockKind.boolean &&
        kind != MockKind.fiscalCode &&
        kind != MockKind.iban &&
        kind != MockKind.vatNumber) {
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final sfx = '-${++st.suffix}';
        final ml = c.maxLength;
        final b = ml > 0 && base.length + sfx.length > ml ? base.substring(0, max(0, ml - sfx.length)) : base;
        final v = '$b$sfx';
        if (ml > 0 && v.length > ml) break;
        if (st.seen.add(_uniqueKey(v))) return v;
      }
    }
    throw MockGenerationException(
      'Impossibile generare valori univoci per la colonna "${c.name}" dopo $rowsGenerated righe: '
      'i valori possibili sono esauriti. Allarga l\'intervallo o disattiva "Univoco".',
    );
  }

  Object? _fkValue(_ColState st, Map<MockFkSample, int> fkPick) {
    final c = st.cfg;
    final s = c.fkSample;
    if (s == null || s.tuples.isEmpty) {
      if (c.column.nullable) return null;
      throw MockGenerationException(
        'Nessun valore disponibile per la chiave esterna "${c.name}"'
        '${s == null ? '' : ' (${s.refTable} è vuota${s.error == null ? '' : ': ${s.error}'})'}.',
      );
    }
    var idx = fkPick[s];
    if (idx == null) {
      final rng = _fkRng[s] ?? st.rng;
      if (c.unique) {
        final used = _fkUsed.putIfAbsent(s, () => <int>{});
        if (used.length >= s.tuples.length) {
          throw MockGenerationException(
            'La chiave esterna "${c.name}" è univoca ma ${s.refTable} contiene solo ${s.tuples.length} valori.',
          );
        }
        do {
          idx = rng.nextInt(s.tuples.length);
        } while (!used.add(idx));
      } else {
        idx = rng.nextInt(s.tuples.length);
      }
      fkPick[s] = idx;
    }
    final t = s.tuples[idx];
    return c.fkPosition < t.length ? t[c.fkPosition] : null;
  }

  // -------------------------------------------------------------------------
  // Raw values
  // -------------------------------------------------------------------------

  T _pick<T>(Random r, List<T> l) => l[r.nextInt(l.length)];

  int _int(Random r, int lo, int hi) {
    if (hi <= lo) return lo;
    final span = hi - lo + 1;
    if (span <= 1 << 32 && span > 0) return lo + r.nextInt(span);
    return lo + (r.nextDouble() * (hi - lo)).round();
  }

  String _digits(Random r, int n) => List.generate(n, (_) => r.nextInt(10)).join();

  ({String first, String last, bool female}) _person(Random r) {
    final female = r.nextBool();
    final first = _pick(
      r,
      _it ? (female ? itFirstNamesFemale : itFirstNamesMale) : (female ? enFirstNamesFemale : enFirstNamesMale),
    );
    return (first: first, last: _pick(r, _it ? itLastNames : enLastNames), female: female);
  }

  static String _slug(String s) => _plainUpper(s).toLowerCase();

  Object? _raw(_ColState st, MockKind kind) {
    final r = st.rng;
    final c = st.cfg;
    switch (kind) {
      case MockKind.auto:
      case MockKind.skip:
      case MockKind.nullValue:
      case MockKind.foreignKey:
        return null;
      case MockKind.sequence:
        return c.seqStart + c.seqStep * st.seq++;
      case MockKind.integer:
        return _int(r, min(c.intMin, c.intMax), max(c.intMin, c.intMax));
      case MockKind.decimal:
        final lo = min(c.decMin, c.decMax), hi = max(c.decMin, c.decMax);
        final v = lo + r.nextDouble() * (hi - lo);
        if (isFloatSqlType(c.column.dataType)) {
          final f = pow(10, c.scale).toDouble();
          return (v * f).roundToDouble() / f;
        }
        return v.toStringAsFixed(c.scale);
      case MockKind.lorem:
        final lo = max(1, min(c.minWords, c.maxWords)), hi = max(lo, max(c.minWords, c.maxWords));
        final n = _int(r, lo, hi);
        final words = List.generate(n, (_) => _pick(r, loremWords));
        final s = words.join(' ');
        return '${s[0].toUpperCase()}${s.substring(1)}${n > 3 ? '.' : ''}';
      case MockKind.pattern:
        return expandPattern(c.pattern, r);
      case MockKind.list:
        return _listValue(st);
      case MockKind.dateTime:
        final a = c.dateFrom.millisecondsSinceEpoch, b = c.dateTo.millisecondsSinceEpoch;
        final lo = min(a, b), hi = max(a, b);
        final ms = lo + (r.nextDouble() * (hi - lo)).round();
        final d = DateTime.fromMillisecondsSinceEpoch(ms - ms % 1000);
        return switch (temporalKindOf(c.column.dataType)) {
          TemporalKind.date => _fmtDate(d),
          TemporalKind.time => _fmtTime(d),
          _ => '${_fmtDate(d)} ${_fmtTime(d)}',
        };
      case MockKind.boolean:
        return r.nextDouble() * 100 < c.truePercent;
      case MockKind.uuid:
        return uuidV4(r);
      case MockKind.firstName:
        return _person(r).first;
      case MockKind.lastName:
        return _pick(r, _it ? itLastNames : enLastNames);
      case MockKind.fullName:
        final p = _person(r);
        return '${p.first} ${p.last}';
      case MockKind.email:
        final p = _person(r);
        final n = r.nextInt(3);
        final local = switch (n) {
          0 => '${_slug(p.first)}.${_slug(p.last)}',
          1 => '${_slug(p.first)[0]}${_slug(p.last)}${r.nextInt(100)}',
          _ => '${_slug(p.first)}${r.nextInt(1000)}',
        };
        return '$local@${_pick(r, emailDomains)}';
      case MockKind.phone:
        final ml = c.maxLength;
        if (_it) {
          final mobile = r.nextInt(3) > 0;
          final prefix = mobile ? '3${_int(r, 20, 99)}' : '0${_int(r, 2, 99)}';
          final num = '$prefix${_digits(r, mobile ? 7 : 6)}';
          return ml > 0 && ml < 14 ? num : '+39 $prefix ${num.substring(prefix.length)}';
        }
        final area = _pick(r, const ['202', '212', '312', '415', '617', '713']);
        final tail = '01${_digits(r, 2)}';
        return ml > 0 && ml < 15 ? '${area}555$tail' : '+1 $area 555-$tail';
      case MockKind.address:
        final n = _int(r, 1, 250);
        return _it ? '${_pick(r, itStreets)}, $n' : '$n ${_pick(r, enStreets)}';
      case MockKind.city:
        return _it ? _pick(r, itCities).name : _pick(r, enCities).name;
      case MockKind.zip:
        return _it ? _pick(r, itCities).cap : '${_pick(r, enCities).zip}${_digits(r, 2)}';
      case MockKind.province:
        final ml = c.maxLength;
        if (_it) {
          final city = _pick(r, itCities);
          return ml > 0 && ml < 6 ? city.province : city.name;
        }
        return _pick(r, enCities).state;
      case MockKind.country:
        final ml = c.maxLength;
        if (ml > 0 && ml <= 3) return _pick(r, countryCodes);
        return _pick(r, _it ? itCountries : enCountries);
      case MockKind.company:
        final a = _pick(r, _it ? itLastNames : enLastNames);
        if (r.nextInt(3) == 0) {
          final b = _pick(r, _it ? itLastNames : enLastNames);
          return '$a & $b ${_pick(r, _it ? companySuffixIt : companySuffixEn)}';
        }
        return '$a ${_pick(r, _it ? companyWordsIt : companyWordsEn)} ${_pick(r, _it ? companySuffixIt : companySuffixEn)}';
      case MockKind.fiscalCode:
        final female = r.nextBool();
        final first = _pick(r, female ? itFirstNamesFemale : itFirstNamesMale);
        final birth = DateTime(_int(r, 1945, 2006), _int(r, 1, 12), _int(r, 1, 28));
        return italianFiscalCode(
          lastName: _pick(r, itLastNames),
          firstName: first,
          birth: birth,
          female: female,
          placeCode: _pick(r, itCities).code,
        );
      case MockKind.vatNumber:
        final first10 = '${_digits(r, 7)}${_int(r, 1, 100).toString().padLeft(3, '0')}';
        return '$first10${vatCheckDigit(first10)}';
      case MockKind.iban:
        return italianIban(_digits(r, 5), _digits(r, 5), _digits(r, 12));
      case MockKind.url:
        final w = _pick(r, loremWords);
        return 'https://www.${_pick(r, emailDomains)}/$w/${_int(r, 1, 9999)}';
      case MockKind.username:
        final p = _person(r);
        return '${_slug(p.first)}.${_slug(p.last)}${r.nextInt(2) == 0 ? '' : r.nextInt(100).toString()}';
      case MockKind.passwordHash:
        final ml = c.maxLength;
        if (ml == 0 || ml >= 60) {
          const alphabet = './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
          return '\$2b\$10\$${List.generate(53, (_) => alphabet[r.nextInt(alphabet.length)]).join()}';
        }
        return List.generate(min(ml, 64), (_) => r.nextInt(16).toRadixString(16)).join();
      case MockKind.ip:
        return '${_int(r, 10, 223)}.${r.nextInt(256)}.${r.nextInt(256)}.${_int(r, 1, 254)}';
      case MockKind.color:
        final ml = c.maxLength;
        if ((ml > 0 && ml <= 7) || _Name(c.name).hasAny(const ['hex', 'rgb'])) {
          return '#${r.nextInt(0x1000000).toRadixString(16).padLeft(6, '0').toUpperCase()}';
        }
        return _pick(r, _it ? itColors : enColors);
      case MockKind.bytes:
        final s = c.column.size ?? 0;
        final n = s > 0 && s < 16 ? s : 16;
        return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
      case MockKind.constant:
        return c.constant;
    }
  }

  Object? _listValue(_ColState st) {
    var w = st.weighted;
    if (w == null) {
      w = parseWeightedList(st.cfg.listValues);
      st.weighted = w;
      st.weightTotal = w.fold(0.0, (a, e) => a + e.$2);
    }
    if (w.isEmpty) return null;
    var x = st.rng.nextDouble() * st.weightTotal;
    for (final (v, weight) in w) {
      x -= weight;
      if (x < 0) return v;
    }
    return w.last.$1;
  }

  /// Converts [v] to the type of the column and truncates text values.
  static Object? _coerce(MockColumnConfig c, Object? v) {
    if (v == null) return null;
    final col = c.column;
    final t = col.dataType;
    if (_isBoolean(col)) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      final s = v.toString().trim().toLowerCase();
      return s == '1' || s == 'true' || s == 't' || s == 'y' || s == 's' || s == 'si' || s == 'yes';
    }
    if (isIntegerSqlType(t)) {
      if (v is int) return v;
      if (v is bool) return v ? 1 : 0;
      if (v is double) return v.round();
      return int.tryParse(v.toString().trim()) ?? double.tryParse(v.toString().trim())?.round() ?? v;
    }
    if (isFloatSqlType(t)) {
      if (v is num) return v.toDouble();
      if (v is bool) return v ? 1.0 : 0.0;
      return double.tryParse(v.toString().trim()) ?? v;
    }
    if (t == SQL_DECIMAL || t == SQL_NUMERIC) {
      if (v is bool) return v ? 1 : 0;
      if (v is double) return v.toStringAsFixed((col.decimals ?? c.scale).clamp(0, 20));
      return v;
    }
    if (v is Uint8List) return v;
    var s = v is bool ? (v ? '1' : '0') : v.toString();
    final ml = c.maxLength;
    if (ml > 0 && s.length > ml) s = s.substring(0, ml).trimRight();
    return s;
  }
}

/// Parses `a, b=3, c` into values with weights (default weight 1).
List<(String, double)> parseWeightedList(String text) {
  final out = <(String, double)>[];
  for (final part in text.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final m = RegExp(r'^(.*?)\s*=\s*(\d+(?:\.\d+)?)$').firstMatch(p);
    if (m != null && m.group(1)!.isNotEmpty) {
      out.add((m.group(1)!, double.parse(m.group(2)!)));
    } else {
      out.add((p, 1));
    }
  }
  return out;
}

/// Expands a template: `#` digit, `?` uppercase letter, `@` lowercase letter,
/// `*` uppercase letter or digit, `\x` literal x.
String expandPattern(String pattern, Random r) {
  const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final sb = StringBuffer();
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    switch (ch) {
      case '#':
        sb.write(r.nextInt(10));
      case '?':
        sb.write(upper[r.nextInt(26)]);
      case '@':
        sb.write(upper[r.nextInt(26)].toLowerCase());
      case '*':
        sb.write(alnum[r.nextInt(alnum.length)]);
      case r'\':
        if (i + 1 < pattern.length) sb.write(pattern[++i]);
      default:
        sb.write(ch);
    }
  }
  return sb.toString();
}

String uuidV4(Random r) {
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

/// Builds the configuration of every column of a table.
List<MockColumnConfig> mockConfigsFor(TableDetails d, {Map<String, (MockFkSample, int)> foreignKeys = const {}}) {
  final pk = {for (final c in d.primaryKey?.columns ?? const <String>[]) c.toLowerCase()};
  final uniqueSingle = {
    for (final ix in d.indexes)
      if (ix.unique && ix.columns.length == 1) ix.columns.first.toLowerCase(),
  };
  return [
    for (final c in d.columns)
      MockColumnConfig(
        c,
        isPrimaryKey: pk.contains(c.name.toLowerCase()),
        compositeKey: pk.length > 1,
        isUniqueIndex: uniqueSingle.contains(c.name.toLowerCase()),
        fkSample: foreignKeys[c.name.toLowerCase()]?.$1,
        fkPosition: foreignKeys[c.name.toLowerCase()]?.$2 ?? 0,
      ),
  ];
}

/// Maximum number of rows in a multi-row parameterized INSERT for [d] with
/// [columnCount] parameters per row (1 = single-row statements).
int rowsPerInsert(SqlDialect d, int columnCount) {
  final maxParams = switch (d.family) {
    DbFamily.sqlServer => 2000,
    DbFamily.sqlite => 999,
    DbFamily.postgres || DbFamily.mysql || DbFamily.db2 || DbFamily.snowflake => 30000,
    _ => 0,
  };
  if (maxParams == 0 || columnCount == 0) return 1;
  return (maxParams ~/ columnCount).clamp(1, d.family == DbFamily.sqlServer ? 1000 : 500);
}

/// `INSERT INTO t (a, b) VALUES (?, ?), (?, ?)…` for [rows] rows.
String parameterizedInsert(SqlDialect d, String tableName, List<String> columns, int rows) {
  final one = '(${List.filled(columns.length, '?').join(', ')})';
  return 'INSERT INTO $tableName (${columns.map(d.quoteIdent).join(', ')}) VALUES '
      '${List.filled(rows, one).join(', ')}';
}

/// SQL script with one INSERT per row (literals typed for the dialect).
String mockInsertScript(SqlDialect d, String tableName, List<MockColumnConfig> columns, Iterable<List<Object?>> rows) {
  final sb = StringBuffer();
  final cols = columns.map((c) => d.quoteIdent(c.name)).join(', ');
  for (final r in rows) {
    sb.write('INSERT INTO $tableName ($cols) VALUES (');
    for (var i = 0; i < columns.length; i++) {
      if (i > 0) sb.write(', ');
      sb.write(typedLiteral(d, columns[i].column.dataType, r[i]));
    }
    sb.writeln(');');
  }
  return sb.toString();
}
