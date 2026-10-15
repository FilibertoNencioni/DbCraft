import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbcraft/drivers/cassandra/cassandra_session.dart';
import 'package:dbcraft/drivers/cassandra/cql_connection.dart';
import 'package:dbcraft/drivers/cassandra/cql_protocol.dart';
import 'package:dbcraft/drivers/common/aws_sigv4.dart';
import 'package:dbcraft/drivers/common/dns.dart';
import 'package:dbcraft/drivers/common/native_exception.dart';
import 'package:dbcraft/drivers/common/relaxed_json.dart';
import 'package:dbcraft/drivers/common/sql_subset.dart';
import 'package:dbcraft/drivers/db_session.dart';
import 'package:dbcraft/drivers/mongodb/bson.dart';
import 'package:dbcraft/drivers/mongodb/mongo_driver.dart';
import 'package:dbcraft/drivers/mongodb/mongo_session.dart';
import 'package:dbcraft/drivers/mongodb/mongo_shell.dart';
import 'package:dbcraft/drivers/mongodb/mongo_uri.dart';
import 'package:dbcraft/drivers/mongodb/scram.dart';
import 'package:dbcraft/drivers/mongodb/wire.dart';
import 'package:dbcraft/drivers/native_driver.dart';
import 'package:dbcraft/drivers/redis/redis_driver.dart';
import 'package:dbcraft/drivers/redis/redis_session.dart';
import 'package:dbcraft/drivers/redis/resp.dart';
import 'package:dbcraft/drivers/cassandra/cassandra_driver.dart';
import 'package:dbcraft/services/sql_dialect.dart';
import 'package:flutter_test/flutter_test.dart';

NativeConnectParams _params(
  String host,
  int port, {
  String db = '',
  Map<String, String> options = const {},
  bool readOnly = false,
}) => NativeConnectParams(
  host: host,
  port: '$port',
  database: db,
  user: '',
  password: '',
  options: options,
  loginTimeoutSec: 5,
  readOnly: readOnly,
);

void main() {
  // -------------------------------------------------------------------------
  group('BSON', () {
    test('round trip of every supported type', () {
      final oid = ObjectId.parse('507f1f77bcf86cd799439011');
      final date = DateTime.utc(2024, 5, 6, 7, 8, 9, 123);
      final doc = <String, Object?>{
        '_id': oid,
        'd': 1.5,
        's': 'ciao è',
        'o': {
          'a': 1,
          'b': [true, null],
        },
        'arr': [1, 'x', 2.5],
        'bin': Uint8List.fromList([1, 2, 3]),
        'uuid': BsonBinary.fromUuid('123e4567-e89b-12d3-a456-426614174000'),
        'b': false,
        'dt': date,
        'n': null,
        're': const BsonRegex('^a.*', 'im'),
        'i32': 42,
        'ts': const BsonTimestamp(1700000000, 3),
        'i64': const BsonInt64(5),
        'big': 1 << 40,
        'dec': BsonDecimal128.parse('123.4500'),
        'min': const BsonMinKey(),
        'max': const BsonMaxKey(),
        'code': const BsonJavaScript('function() {}'),
      };
      final back = decodeBson(encodeBson(doc));
      expect(back.keys.toList(), doc.keys.toList());
      expect(back['_id'], oid);
      expect(back['d'], 1.5);
      expect(back['s'], 'ciao è');
      expect(back['o'], {
        'a': 1,
        'b': [true, null],
      });
      expect(back['arr'], [1, 'x', 2.5]);
      expect(back['bin'], Uint8List.fromList([1, 2, 3]));
      expect((back['uuid'] as BsonBinary).uuid, '123e4567-e89b-12d3-a456-426614174000');
      expect(back['b'], false);
      expect(back['dt'], date);
      expect(back['n'], isNull);
      expect(back['re'], const BsonRegex('^a.*', 'im'));
      expect(back['i32'], 42);
      expect(back['ts'], const BsonTimestamp(1700000000, 3));
      expect(back['i64'], const BsonInt64(5));
      expect(back['big'], const BsonInt64(1 << 40));
      expect(back['dec'].toString(), '123.4500');
      expect(back['min'], isA<BsonMinKey>());
      expect(back['max'], isA<BsonMaxKey>());
      expect((back['code'] as BsonJavaScript).code, 'function() {}');
    });

    test('known encoding of {"a": 1}', () {
      expect(encodeBson({'a': 1}), [12, 0, 0, 0, 0x10, 0x61, 0, 1, 0, 0, 0, 0]);
    });

    test('decimal128 formatting', () {
      final one = BsonDecimal128.parse('1');
      expect(one.bytes.sublist(0, 8), [1, 0, 0, 0, 0, 0, 0, 0]);
      expect(one.bytes.sublist(8), [0, 0, 0, 0, 0, 0, 0x40, 0x30]);
      for (final s in [
        '0',
        '1',
        '-1',
        '0.001',
        '123.456',
        '-0.000001',
        '1E+3',
        '1.23E-10',
        'Infinity',
        '-Infinity',
        'NaN',
      ]) {
        expect(BsonDecimal128.parse(s).toString(), s, reason: s);
      }
      expect(BsonDecimal128.parse('1000').toString(), '1000');
      expect(
        BsonDecimal128.parse('9999999999999999999999999999999999').toString(),
        '9999999999999999999999999999999999',
      );
    });

    test('grid values and shell json', () {
      expect(gridValue(ObjectId.parse('507f1f77bcf86cd799439011')), '507f1f77bcf86cd799439011');
      expect(gridValue(DateTime.utc(2020)), '2020-01-01T00:00:00.000Z');
      expect(gridValue(true), 'true');
      expect(gridValue(const BsonInt64(7)), 7);
      expect(
        gridValue({'a': ObjectId.parse('507f1f77bcf86cd799439011'), 'n': const BsonInt64(3)}),
        '{"a": ObjectId("507f1f77bcf86cd799439011"), "n": NumberLong(3)}',
      );
      // Shell JSON is parsed back to the same values.
      final v = parseMongoValue(shellJson({'d': DateTime.utc(2021, 2, 3), 'l': const BsonInt64(9)})) as Map;
      expect(v['d'], DateTime.utc(2021, 2, 3));
      expect(v['l'], const BsonInt64(9));
    });

    test('coercion to the sampled type', () {
      expect(coerceToBsonType('5', 'int'), 5);
      expect(coerceToBsonType('5', 'long'), const BsonInt64(5));
      expect(coerceToBsonType('2.5', 'double'), 2.5);
      expect(coerceToBsonType('true', 'bool'), true);
      expect(coerceToBsonType('2020-01-02T03:04:05Z', 'date'), DateTime.utc(2020, 1, 2, 3, 4, 5));
      expect(coerceToBsonType('507f1f77bcf86cd799439011', 'objectId'), isA<ObjectId>());
      expect(coerceToBsonType('{a: 1}', 'object'), {'a': 1});
      expect(() => coerceToBsonType('{a: ', 'object'), throwsA(isA<NativeDbException>()));
      expect(coerceToBsonType('abc', 'int'), 'abc');
    });
  });

  // -------------------------------------------------------------------------
  group('OP_MSG', () {
    test('encode / decode with document sequence', () {
      final bytes = encodeOpMsg(
        7,
        {'insert': 'c', r'$db': 'test'},
        sequences: {
          'documents': [
            {'a': 1},
            {'a': 2},
          ],
        },
      );
      final bd = ByteData.sublistView(bytes);
      expect(bd.getInt32(0, Endian.little), bytes.length);
      expect(bd.getInt32(4, Endian.little), 7);
      expect(bd.getInt32(12, Endian.little), opMsg);
      final m = decodeOpMsg(bytes);
      expect(m.requestId, 7);
      expect(m.body['insert'], 'c');
      expect(m.sequences['documents']!.map((d) => d['a']), [1, 2]);
    });
  });

  // -------------------------------------------------------------------------
  group('SCRAM', () {
    test('SCRAM-SHA-256 RFC 7677 test vector', () {
      final c = ScramClient(
        sha256Mode: true,
        username: 'user',
        password: 'pencil',
        clientNonce: 'rOprNGfwEbeRWgbNEkqO',
      );
      expect(c.clientFirst(), 'n,,n=user,r=rOprNGfwEbeRWgbNEkqO');
      final fin = c.clientFinal(
        r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096',
      );
      expect(
        fin,
        r'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
      );
      c.verifyServerFinal('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=');
      expect(() => c.verifyServerFinal('v=AAAA'), throwsA(isA<NativeDbException>()));
    });

    test('SCRAM-SHA-1 MongoDB test vector', () {
      final c = ScramClient(
        sha256Mode: false,
        username: 'user',
        password: 'pencil',
        clientNonce: 'fyko+d2lbbFgONRv9qkxdawL',
      );
      expect(c.clientFirst(), 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL');
      final fin = c.clientFinal(
        'r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000',
      );
      expect(fin, 'c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=');
      c.verifyServerFinal('v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=');
    });

    test('nonce mismatch and SASLprep', () {
      final c = ScramClient(sha256Mode: true, username: 'u', password: 'p', clientNonce: 'abc');
      c.clientFirst();
      expect(() => c.clientFinal('r=xyz,s=AAAA,i=4096'), throwsA(isA<NativeDbException>()));
      expect(saslPrep('I­X'), 'IX');
      expect(saslPrep('a b'), 'a b');
      expect(() => saslPrep('a\u0007b'), throwsA(isA<NativeDbException>()));
    });
  });

  // -------------------------------------------------------------------------
  group('Relaxed JSON', () {
    test('JS object literals', () {
      final v = parseMongoValue('''{
        name: 'Ann', // comment
        "age": {\$gt: 3, \$lt: 10,},
        tags: ['a', "b",],
        id: ObjectId("507f1f77bcf86cd799439011"),
        at: ISODate("2020-01-02T03:04:05Z"),
        d2: new Date(0),
        n: NumberLong("12"),
        i: NumberInt(3),
        dec: NumberDecimal("1.50"),
        re: /^ab+c/i,
        hex: 0x10, neg: -2.5e1,
        'a.b': null, u: undefined,
      }''') as Map;
      expect(v['name'], 'Ann');
      expect(v['age'], {r'$gt': 3, r'$lt': 10});
      expect(v['tags'], ['a', 'b']);
      expect(v['id'], ObjectId.parse('507f1f77bcf86cd799439011'));
      expect(v['at'], DateTime.utc(2020, 1, 2, 3, 4, 5));
      expect(v['d2'], DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(v['n'], const BsonInt64(12));
      expect(v['i'], 3);
      expect(v['dec'].toString(), '1.50');
      expect(v['re'], const BsonRegex('^ab+c', 'i'));
      expect(v['hex'], 16);
      expect(v['neg'], -25.0);
      expect(v.containsKey('a.b'), isTrue);
      expect(v['u'], isNull);
    });

    test('extended JSON', () {
      final v = parseMongoValue(
        '{"_id": {"\$oid": "507f1f77bcf86cd799439011"}, "d": {"\$date": "2020-01-01T00:00:00Z"}, '
        '"l": {"\$numberLong": "5"}, "b": {"\$binary": {"base64": "AQI=", "subType": "00"}}}',
      ) as Map;
      expect(v['_id'], isA<ObjectId>());
      expect(v['d'], DateTime.utc(2020));
      expect(v['l'], const BsonInt64(5));
      expect((v['b'] as BsonBinary).data, [1, 2]);
    });

    test('syntax errors report the position', () {
      expect(() => parseRelaxedJson('{a: [1, 2}'), throwsA(isA<JsSyntaxError>()));
      try {
        parseRelaxedJson('{\n  a: @}');
      } on JsSyntaxError catch (e) {
        expect(e.message, contains('riga 2'));
      }
    });
  });

  // -------------------------------------------------------------------------
  group('Mongo shell parser', () {
    test('find with modifiers', () {
      final s = parseShellScript('db.users.find({age: {\$gt: 3}}, {name: 1})\n  .sort({name: -1}).limit(10).skip(5)');
      expect(s, hasLength(1));
      final c = s.first as ShellCallStatement;
      expect(c.collection, 'users');
      expect(c.method.name, 'find');
      expect(c.method.args.first, {
        'age': {r'$gt': 3},
      });
      expect(c.modifiers.map((m) => m.name), ['sort', 'limit', 'skip']);
      expect(c.modifier('limit')!.arg(0), 10);
    });

    test('collection names, getCollection, getSiblingDB', () {
      final s = parseShellScript(
        'db.system.views.find()\n'
        'db.getCollection("a-b").aggregate([{\$match: {}}])\n'
        "db['x y'].countDocuments({})\n"
        "db.getSiblingDB('admin').runCommand({ping: 1});\n"
        'db.getCollectionNames()',
      );
      expect(s, hasLength(5));
      expect((s[0] as ShellCallStatement).collection, 'system.views');
      expect((s[1] as ShellCallStatement).collection, 'a-b');
      expect((s[2] as ShellCallStatement).collection, 'x y');
      final r = s[3] as ShellCallStatement;
      expect(r.database, 'admin');
      expect(r.collection, isNull);
      expect(r.method.name, 'runCommand');
      expect((s[4] as ShellCallStatement).method.name, 'getCollectionNames');
    });

    test('show, use and command documents', () {
      final s = parseShellScript('show dbs\nuse inventory\n{ping: 1}');
      expect((s[0] as ShellShow).what, 'dbs');
      expect((s[1] as ShellUse).database, 'inventory');
      expect((s[2] as ShellCommandDoc).command, {'ping': 1});
    });

    test('errors', () {
      expect(() => parseShellScript('db.users'), throwsA(isA<NativeDbException>()));
      expect(() => parseShellScript('select'), throwsA(isA<NativeDbException>()));
      expect(() => parseShellScript('db.a.find() db.b.find()'), throwsA(isA<NativeDbException>()));
    });
  });

  // -------------------------------------------------------------------------
  group('Mongo URI', () {
    test('standard and srv', () {
      final u = MongoUri.parse('mongodb://us%40r:p%3Ass@h1:27018,h2/shop?tls=true&authSource=admin&replicaSet=rs0');
      expect(u.srv, isFalse);
      expect(u.hosts, [const MongoHost('h1', 27018), const MongoHost('h2', 27017)]);
      expect(u.user, 'us@r');
      expect(u.password, 'p:ss');
      expect(u.database, 'shop');
      expect(u.option('authSource'), 'admin');
      expect(u.option('replicaset'), 'rs0');
      final s = MongoUri.parse('mongodb+srv://cluster0.example.net/?retryWrites=true');
      expect(s.srv, isTrue);
      expect(s.hosts.single.host, 'cluster0.example.net');
      expect(() => MongoUri.parse('mongodb+srv://a:27017'), throwsA(isA<NativeDbException>()));
      expect(MongoUri.mask('mongodb://u:secret@h/db'), 'mongodb://u:****@h/db');
      expect(MongoHost.parse('[::1]:27019'), const MongoHost('::1', 27019));
    });
  });

  // -------------------------------------------------------------------------
  group('SQL subset', () {
    test('select forms', () {
      final s = parseSqlSubset(
        "SELECT * FROM shop.users WHERE age > 3 AND name LIKE 'A%' ORDER BY name DESC, age LIMIT 10 OFFSET 5",
      ) as SubsetSelect;
      expect(s.target.parts, ['shop', 'users']);
      expect(s.columns, isNull);
      expect(s.where, isA<SqlAnd>());
      expect(s.orderBy.map((o) => '${o.field}:${o.descending}'), ['name:true', 'age:false']);
      expect(s.limit, 10);
      expect(s.offset, 5);
      final c = parseSqlSubset('SELECT COUNT(*) FROM db0.user:*') as SubsetSelect;
      expect(c.isCount, isTrue);
      expect(c.target.raw, 'db0.user:*');
      final j = parseSqlSubset('SELECT * FROM users WHERE {"age": {"\$gt": 3}} ORDER BY {age: -1}') as SubsetSelect;
      expect(j.whereText, '{"age": {"\$gt": 3}}');
      expect(j.orderText, '{age: -1}');
      expect(parseSqlSubset('db.users.find()'), isNull);
    });

    test('DML with parameters', () {
      final u = parseSqlSubset(
        'UPDATE c SET a = ?, "b c" = ? WHERE _id = ? AND x IS NULL',
        params: [1, 'two', 'id'],
      ) as SubsetUpdate;
      expect(u.assignments, [('a', 1), ('b c', 'two')]);
      expect(sqlEqualities(u.where), {'_id': 'id', 'x': null});
      final i = parseSqlSubset("INSERT INTO c (a, b) VALUES (1, 'it''s'), (?, NULL)", params: [2]) as SubsetInsert;
      expect(i.columns, ['a', 'b']);
      expect(i.rows, [
        [1, "it's"],
        [2, null],
      ]);
      final d = parseSqlSubset('DELETE FROM c WHERE k IN (1, 2) OR NOT v BETWEEN 1 AND 3') as SubsetDelete;
      expect(d.where, isA<SqlOr>());
      expect(() => parseSqlSubset('UPDATE c SET a = ? WHERE b = ?', params: [1]), throwsA(isA<NativeDbException>()));
    });

    test('client side evaluation and LIKE helpers', () {
      final e = parseSqlWhere("type = 'hash' AND (size > 10 OR key LIKE 'user:%') AND ttl IS NULL");
      bool ev(Map<String, Object?> row) => evalSqlExpr(e, (f) => row[f]);
      expect(ev({'type': 'hash', 'size': 20, 'key': 'x', 'ttl': null}), isTrue);
      expect(ev({'type': 'hash', 'size': 2, 'key': 'user:1', 'ttl': null}), isTrue);
      expect(ev({'type': 'hash', 'size': 2, 'key': 'x', 'ttl': null}), isFalse);
      expect(ev({'type': 'set', 'size': 20, 'key': 'x', 'ttl': null}), isFalse);
      expect(likeToGlob('user:%_[x]'), r'user:*?\[x\]');
      expect(likeToRegExp('a%b_').hasMatch('aXXbY'), isTrue);
    });

    test('translation to MongoDB filters', () {
      final types = {'born': 'date', 'n': 'long'};
      Map<String, Object?> f(String w, [List<Object?> p = const []]) =>
          sqlToMongoFilter(parseSqlWhere(w, params: p, valueHook: parseMongoValue), types);
      expect(f("name = 'Ann' AND age >= 18"), {
        'name': 'Ann',
        'age': {r'$gte': 18},
      });
      expect(f('a = 1 OR b <> 2'), {
        r'$or': [
          {'a': 1},
          {
            'b': {r'$ne': 2},
          },
        ],
      });
      final id = f('_id = ?', ['507f1f77bcf86cd799439011'])['_id'] as Map;
      expect((id[r'$in'] as List).first, isA<ObjectId>());
      expect(f("born > '2020-01-01'")['born'], {r'$gt': DateTime.utc(2020)});
      expect(f('n = 3')['n'], const BsonInt64(3));
      expect(f("name ILIKE 'a%'")['name'], const BsonRegex(r'^a.*$', 'is'));
      expect(f('x IN (1, 2)'), {
        'x': {
          r'$in': [1, 2],
        },
      });
      expect(f('x IS NOT NULL'), {
        'x': {r'$ne': null},
      });
      expect(f("id = ObjectId('507f1f77bcf86cd799439011')")['id'], isA<ObjectId>());
      expect(f('a = 1 AND a = 2'), {
        r'$and': [
          {'a': 1},
          {'a': 2},
        ],
      });
    });

    test('dialect produces parsable data editor statements', () {
      for (final name in ['MongoDB', 'Redis']) {
        final d = SqlDialect(dbmsName: name, quote: '');
        expect(d.isNoSql, isTrue);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('Mongo helpers', () {
    test('document keys and inferred types', () {
      final docs = [
        {'b': 1, '_id': 1, 'a': 'x'},
        {'_id': 2, 'c': DateTime.utc(2020), 'a': null},
        {'_id': 3, 'b': 2.5, 'a': 'y'},
      ];
      expect(documentKeys(docs), ['_id', 'b', 'a', 'c']);
      final t = inferFieldTypes(docs);
      expect(t['_id'], 'int');
      expect(t['a'], 'string');
      expect(t['c'], 'date');
      final fields = inferFields(docs);
      expect(fields.first.name, '_id');
      expect(fields.first.nullable, isFalse);
      expect(fields.firstWhere((f) => f.name == 'b').otherTypes, ['double']);
    });
  });

  // -------------------------------------------------------------------------
  group('RESP', () {
    test('encoder', () {
      expect(utf8.decode(encodeCommand(['SET', 'k', 'v è'])), '*3\r\n\$3\r\nSET\r\n\$1\r\nk\r\n\$4\r\nv è\r\n');
    });

    test('incremental parsing byte by byte', () {
      const text =
          '+OK\r\n-ERR wrong type\r\n:42\r\n\$5\r\nhello\r\n\$-1\r\n*2\r\n:1\r\n*2\r\n+a\r\n\$0\r\n\r\n*-1\r\n*0\r\n'
          '%2\r\n+k\r\n:1\r\n+j\r\n#t\r\n,1.5\r\n_\r\n|1\r\n+key\r\n+meta\r\n:7\r\n';
      final p = RespParser();
      for (final b in utf8.encode(text)) {
        p.feed([b]);
      }
      final r = p.replies.toList();
      expect(r[0], 'OK');
      expect(r[1], isA<RedisError>());
      expect((r[1] as RedisError).code, 'ERR');
      expect((r[1] as RedisError).message, 'wrong type');
      expect(r[2], 42);
      expect(respText(r[3]), 'hello');
      expect(r[4], isNull);
      expect(r[5], isA<List>());
      expect((r[5] as List)[0], 1);
      expect(((r[5] as List)[1] as List)[0], 'a');
      expect(respText(((r[5] as List)[1] as List)[1]), '');
      expect(r[6], isNull);
      expect(r[7], <Object?>[]);
      expect(r[8], isA<RespMap>());
      expect((r[8] as RespMap).entries.last.value, true);
      expect(r[9], 1.5);
      expect(r[10], isNull);
      expect(r[11], 7); // attribute skipped
      expect(r.length, 12);
    });

    test('large bulk in chunks', () {
      final payload = 'x' * 100000;
      final bytes = utf8.encode('\$${payload.length}\r\n$payload\r\n');
      final p = RespParser();
      for (var i = 0; i < bytes.length; i += 4096) {
        p.feed(bytes.sublist(i, i + 4096 > bytes.length ? bytes.length : i + 4096));
      }
      expect(respString(p.replies.single).length, 100000);
    });

    test('tokenizer', () {
      expect(tokenizeRedisCommand('SET "my key" \'it\\\'s\' "a\\nb\\x41"'), ['SET', 'my key', "it's", 'a\nbA']);
      expect(tokenizeRedisCommand('  HGETALL   h  '), ['HGETALL', 'h']);
      expect(tokenizeRedisCommand('SET k ""'), ['SET', 'k', '']);
      expect(() => tokenizeRedisCommand('GET "x'), throwsA(isA<NativeDbException>()));
      expect(splitRedisScript('# c\nGET a;\n\n  SCAN 0\n'), ['GET a', 'SCAN 0']);
    });

    test('reply rendering', () {
      final h = renderRedisReply(['HGETALL', 'h'], [utf8.encode('f'), utf8.encode('v')]);
      expect(h.cursor!.columns.map((c) => c.name), ['field', 'value']);
      final z = renderRedisReply(['ZRANGE', 'z', '0', '-1', 'WITHSCORES'], [utf8.encode('m'), utf8.encode('1.5')]);
      expect(z.cursor!.columns.map((c) => c.name), ['member', 'score']);
      final info = renderRedisReply(['INFO'], utf8.encode('# Server\r\nredis_version:7.2.0\r\n'));
      expect(info.cursor!.columns.map((c) => c.name), ['section', 'key', 'value']);
      final scan = renderRedisReply(
        ['SCAN', '0'],
        [
          utf8.encode('17'),
          [utf8.encode('a'), utf8.encode('b')],
        ],
      );
      expect(scan.messages.single, contains('17'));
      final arr = renderRedisReply(
        ['LRANGE', 'l', '0', '-1'],
        [
          utf8.encode('a'),
          [1, 2],
        ],
      );
      expect(arr.cursor!.columns.map((c) => c.name), ['#', 'value']);
    });
  });

  // -------------------------------------------------------------------------
  group('CQL', () {
    test('frame header', () {
      final f = encodeFrame(4, 5, opQuery, Uint8List.fromList([1, 2, 3]));
      expect(f.sublist(0, 9), [4, 0, 0, 5, opQuery, 0, 0, 0, 3]);
      final h = CqlFrameHeader.parse(Uint8List.fromList([0x84, 0, 0, 5, opResult, 0, 0, 0, 10]));
      expect(h.isResponse, isTrue);
      expect(h.version, 4);
      expect(h.stream, 5);
      expect(h.length, 10);
    });

    test('value codecs round trip', () {
      final cases = <(CqlType, Object?, Object?)>[
        (CqlType(CqlType.varchar), 'ciao è', 'ciao è'),
        (CqlType(CqlType.ascii), 'abc', 'abc'),
        (CqlType(CqlType.bigint), '-9000000000', -9000000000),
        (CqlType(CqlType.counter), 5, 5),
        (CqlType(CqlType.int_), '42', 42),
        (CqlType(CqlType.smallint), -3, -3),
        (CqlType(CqlType.tinyint), 7, 7),
        (CqlType(CqlType.boolean), 'true', 'true'),
        (CqlType(CqlType.double_), '1.25', 1.25),
        (CqlType(CqlType.float), 0.5, 0.5),
        (CqlType(CqlType.decimal), '-123.4500', '-123.4500'),
        (CqlType(CqlType.decimal), '0.001', '0.001'),
        (CqlType(CqlType.varint), '123456789012345678901234567890', '123456789012345678901234567890'),
        (CqlType(CqlType.varint), -128, -128),
        (CqlType(CqlType.timestamp), '2024-01-02T03:04:05.678Z', '2024-01-02T03:04:05.678Z'),
        (CqlType(CqlType.uuid), '123e4567-e89b-12d3-a456-426614174000', '123e4567-e89b-12d3-a456-426614174000'),
        (CqlType(CqlType.timeuuid), 'c4a8f0e0-0000-11ee-8000-000000000000', 'c4a8f0e0-0000-11ee-8000-000000000000'),
        (CqlType(CqlType.inet), '192.168.1.10', '192.168.1.10'),
        (CqlType(CqlType.date), '2024-02-29', '2024-02-29'),
        (CqlType(CqlType.date), '1900-01-01', '1900-01-01'),
        (CqlType(CqlType.time), '13:45:01.5', '13:45:01.5'),
        (CqlType(CqlType.blob), '0x0102ff', Uint8List.fromList([1, 2, 255])),
        (CqlType(CqlType.list, params: [CqlType(CqlType.int_)]), '[1,2,3]', '[1,2,3]'),
        (CqlType(CqlType.set, params: [CqlType(CqlType.varchar)]), '["a","b"]', '["a","b"]'),
        (CqlType(CqlType.map, params: [CqlType(CqlType.varchar), CqlType(CqlType.bigint)]), '{"a":1}', '{"a":1}'),
        (CqlType(CqlType.tuple, params: [CqlType(CqlType.int_), CqlType(CqlType.varchar)]), '[1,"x"]', '[1,"x"]'),
        (
          CqlType(
            CqlType.udt,
            keyspace: 'ks',
            name: 'addr',
            fields: [('street', CqlType(CqlType.varchar)), ('n', CqlType(CqlType.int_))],
          ),
          '{"street":"Via Roma","n":3}',
          '{"street":"Via Roma","n":3}',
        ),
      ];
      for (final (t, input, expected) in cases) {
        expect(cqlGridValue(t, encodeCqlValue(t, input)), expected, reason: '$t $input');
      }
      expect(encodeCqlValue(CqlType(CqlType.int_), null), isNull);
      expect(cqlGridValue(CqlType(CqlType.int_), null), isNull);
    });

    test('duration and type names', () {
      // months=14 (zigzag 28), days=3 (6), nanos=3h (zigzag of 10800000000000)
      final w = <int>[28, 6];
      // 21600000000000 = zigzag(10800000000000): encode as unsigned vint
      var v = 21600000000000;
      final bytes = <int>[];
      while (v > 0) {
        bytes.insert(0, v & 0xff);
        v >>= 8;
      }
      final extra = bytes.length; // 6 bytes follow a first byte with 6 leading ones
      w.add(0xff << (8 - extra) & 0xff);
      w.addAll(bytes);
      final t = CqlType(CqlType.custom0, custom: 'org.apache.cassandra.db.marshal.DurationType');
      expect(decodeCqlValue(t, Uint8List.fromList(w)), '1y2mo3d3h');
      expect(t.toString(), 'duration');
      expect(
        CqlType(
          CqlType.map,
          params: [
            CqlType(CqlType.varchar),
            CqlType(CqlType.list, params: [CqlType(CqlType.int_)]),
          ],
        ).toString(),
        'map<text, list<int>>',
      );
    });

    test('rows result parsing', () {
      final w = CqlWriter()
        ..int32(resultRows)
        ..int32(0x0001 | 0x0002)
        ..int32(2)
        ..bytes([9, 9])
        ..string('ks')
        ..string('t')
        ..string('id')
        ..short(CqlType.int_)
        ..string('name')
        ..short(CqlType.varchar)
        ..int32(1)
        ..bytes([0, 0, 0, 7])
        ..bytes(null);
      final r = parseCqlResult(CqlReader(w.take()));
      expect(r.kind, resultRows);
      expect(r.rows!.columns.map((c) => c.name), ['id', 'name']);
      expect(r.rows!.pagingState, [9, 9]);
      expect(r.rows!.rows.single[1], isNull);
    });

    test('script splitting and type mapping', () {
      expect(splitCql("SELECT ';' FROM t; -- x;\n/* ; */ INSERT INTO t (a) VALUES ('a''b');"), [
        "SELECT ';' FROM t",
        "/* ; */ INSERT INTO t (a) VALUES ('a''b')".replaceFirst('/* ; */', ' ').trim(),
      ]);
      expect(splitCql(r"CREATE FUNCTION f() RETURNS int LANGUAGE java AS $$ return 1; $$;"), hasLength(1));
      expect(sqlTypeForCql('frozen<list<int>>') != sqlTypeForCql('int'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('Misc', () {
    test('DNS SRV / TXT answer parsing with compression', () {
      final q = buildDnsQuery(0x1234, '_mongodb._tcp.c.example.com', dnsTypeSrv);
      final b = BytesBuilder()
        ..add(q.sublist(0, 2))
        ..add([0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0])
        ..add(q.sublist(12));
      // SRV answer: name pointer to the question (offset 12)
      b.add([0xc0, 12, 0, 33, 0, 1, 0, 0, 0, 60]);
      final target = [2, ...ascii.encode('h1'), 0xc0, 12 + 9 + 5]; // h1.<c.example.com>
      final rdata = [0, 1, 0, 5, 0x69, 0x89, ...target];
      b.add([0, rdata.length, ...rdata]);
      // TXT answer
      final txt = ascii.encode('authSource=admin');
      b.add([0xc0, 12, 0, 16, 0, 1, 0, 0, 0, 60, 0, txt.length + 1, txt.length, ...txt]);
      final m = DnsMessage(b.toBytes());
      expect(m.id, 0x1234);
      final srv = m.srv().single;
      expect(srv.port, 27017);
      expect(srv.target, 'h1.c.example.com');
      expect(m.txt().single, 'authSource=admin');
    });

    test('AWS SigV4 (AWS documentation example)', () {
      const creds = AwsCredentials('AKIDEXAMPLE', 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY');
      final auth = sigv4Authorization(
        method: 'GET',
        path: '/',
        query: const {'Action': 'ListUsers', 'Version': '2010-05-08'},
        headers: const {
          'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
          'host': 'iam.amazonaws.com',
          'x-amz-date': '20150830T123600Z',
        },
        payload: '',
        region: 'us-east-1',
        service: 'iam',
        credentials: creds,
        amzDateValue: '20150830T123600Z',
      );
      expect(auth, endsWith('Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7'));
      expect(parseIni('[default]\naws_access_key_id = A\n')['default']!['aws_access_key_id'], 'A');
    });

    test('driver descriptors', () {
      expect(mongoDriver.id, 'mongodb');
      expect(mongoDriver.queryLanguage, 'mongo');
      expect(redisDriver.id, 'redis');
      expect(redisDriver.queryLanguage, 'redis');
      expect(cassandraDriver.id, 'cassandra');
      expect(cassandraDriver.queryLanguage, 'cql');
      expect(SqlDialect(dbmsName: 'Apache Cassandra').family, DbFamily.cassandra);
    });
  });

  // -------------------------------------------------------------------------
  group('Redis end to end (in-process fake server)', () {
    late ServerSocket server;
    late _FakeRedis fake;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      fake = _FakeRedis(server);
    });

    tearDown(() async {
      await server.close();
    });

    test('commands, catalog, SQL subset and DML', () async {
      final s = await redisDriver.open(_params('127.0.0.1', server.port));
      final info = await s.info();
      expect(info['dbmsName'], 'Redis');
      expect(info['dbmsVersion'], '7.2.4');
      expect(info['currentCatalog'], 'db0');

      final cats = await s.catalog('tables', ['%', '', '', '']);
      expect(cats.rows.length, 16);

      final tables = await s.catalog('tables', ['db0', null, '%', null]);
      final names = {for (final r in tables.rows) r[2]: r[3]};
      expect(names['user:*'], 'TABLE');
      expect(names['counter'], 'STRING');
      expect(names['config'], 'HASH');

      final pk = await s.catalog('primaryKeys', ['db0', null, 'config']);
      expect(pk.rows.single[3], 'field');

      var p = await s.execute('GET counter');
      expect(p.rows.single.single, '10');

      p = await s.execute('HGETALL config');
      expect(p.columns.map((c) => c.name), ['field', 'value']);
      expect(p.rows.length, 2);

      p = await s.execute('SELECT * FROM config');
      expect(p.columns.map((c) => c.name), ['field', 'value']);
      expect(p.rows.length, 2);

      p = await s.execute("SELECT * FROM db0.user:* WHERE type = 'string' ORDER BY key DESC");
      expect(p.columns.map((c) => c.name), ['key', 'type', 'ttl', 'size']);
      expect(p.rows.map((r) => r[0]), ['user:3', 'user:2', 'user:1']);

      p = await s.execute('SELECT * FROM user:*', fetchSize: 2);
      expect(p.rows.length, 2);
      expect(p.hasMore, isTrue);
      final more = await s.fetchMore(p.cursorId!, 10);
      expect(more.rows.length, 1);
      expect(more.hasMore, isFalse);

      p = await s.execute('SELECT COUNT(*) FROM config');
      expect(p.rows.single.single, 2);
      p = await s.execute('SELECT COUNT(*) FROM db0.*');
      expect(p.rows.single.single, 5);

      p = await s.execute('UPDATE config SET value = ? WHERE field = ?', params: ['dark', 'theme']);
      expect(fake.data['config'], {'theme': 'dark', 'lang': 'it'});
      await s.execute('INSERT INTO config (field, value) VALUES (?, ?)', params: ['x', 'y']);
      expect((fake.data['config'] as Map)['x'], 'y');
      await s.execute('DELETE FROM config WHERE field = ?', params: ['x']);
      expect((fake.data['config'] as Map).containsKey('x'), isFalse);

      // Several commands: several result sets.
      p = await s.execute('GET counter\nHGETALL config');
      expect(p.hasNextResultSet, isTrue);
      final next = await s.nextResultSet(p.cursorId!, 100);
      expect(next!.columns.map((c) => c.name), ['field', 'value']);

      await expectLater(s.execute('GET "unterminated'), throwsA(isA<NativeDbException>()));
      await expectLater(s.execute('BOGUS'), throwsA(isA<RedisError>()));
      await s.close();
      expect(s.isClosed, isTrue);
    });

    test('read-only connections reject writes', () async {
      final s = await redisDriver.open(_params('127.0.0.1', server.port, readOnly: true));
      await expectLater(s.execute('SET a b'), throwsA(isA<NativeDbException>()));
      await expectLater(
        s.execute("UPDATE config SET value = 'x' WHERE field = 'theme'"),
        throwsA(isA<NativeDbException>()),
      );
      expect((await s.execute('GET counter')).rows.single.single, '10');
      await s.close();
    });
  });

  // -------------------------------------------------------------------------
  group('MongoDB end to end (in-process fake server)', () {
    test('handshake, find with getMore, count, update, catalog', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final fake = _FakeMongo(server);
      try {
        final s = await mongoDriver.open(_params('127.0.0.1', server.port, db: 'shop'));
        final info = await s.info();
        expect(info['dbmsName'], 'MongoDB');
        expect(info['dbmsVersion'], '7.0.5');
        expect(info['currentCatalog'], 'shop');

        final cats = await s.catalog('tables', ['%', '', '', '']);
        expect(cats.rows.map((r) => r[0]), containsAll(['shop', 'admin']));
        final tables = await s.catalog('tables', ['shop', null, '%', null]);
        expect({for (final r in tables.rows) r[2]: r[3]}, {'users': 'TABLE', 'v': 'VIEW'});

        var p = await s.execute('db.users.find({}).sort({name: 1})', fetchSize: 2);
        expect(p.columns.map((c) => c.name), ['_id', 'name', 'age', 'tags']);
        expect(p.rows.length, 2);
        expect(p.rows.first[0], '507f1f77bcf86cd799439011');
        expect(p.rows.first[3], '["a", "b"]');
        expect(p.columns.first.baseTable, 'users');
        expect(p.hasMore, isTrue);
        final more = await s.fetchMore(p.cursorId!, 10);
        expect(more.rows.length, 1);
        expect(more.hasMore, isFalse);

        p = await s.execute('SELECT COUNT(*) FROM shop.users');
        expect(p.rows.single.single, 3);
        expect(fake.lastCommand['count'], 'users');

        p = await s.execute("SELECT * FROM users WHERE age > 30 AND name = 'Bob'");
        expect(fake.lastFind['filter'], {
          'age': {r'$gt': 30},
          'name': 'Bob',
        });

        p = await s.execute('UPDATE users SET age = ? WHERE _id = ?', params: [41, '507f1f77bcf86cd799439011']);
        expect(p.rowsAffected, 1);
        final upd = (fake.lastCommand['updates'] as List).single as Map;
        expect(upd['u'], {
          r'$set': {'age': 41},
        });
        expect(((upd['q'] as Map)['_id'] as Map)[r'$in'], hasLength(2));

        p = await s.execute('db.users.insertOne({name: "Zed"})');
        expect(p.rowsAffected, 1);
        expect(((fake.lastCommand['documents'] as List).single as Map)['_id'], isA<ObjectId>());

        await expectLater(s.execute('db.users.find({a: 1}).bogus()'), throwsA(isA<NativeDbException>()));
        await expectLater(s.execute('db.users.find({\$bad: 1})'), throwsA(isA<NativeDbException>()));
        await s.close();
      } finally {
        await server.close();
      }
    });
  });

  // -------------------------------------------------------------------------
  group('Cassandra end to end (in-process fake server)', () {
    test('startup, paging and catalog', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _FakeCassandra(server);
      try {
        final DbSession s = await cassandraDriver.open(_params('127.0.0.1', server.port, db: 'ks'));
        final info = await s.info();
        expect(info['dbmsName'], 'Apache Cassandra');
        expect(info['dbmsVersion'], '4.1.3');
        expect(info['currentCatalog'], 'ks');
        var p = await s.execute('SELECT * FROM ks.t', fetchSize: 2);
        expect(p.columns.map((c) => c.name), ['id', 'name']);
        expect(p.rows, [
          [1, 'r1'],
          [2, 'r2'],
        ]);
        expect(p.hasMore, isTrue);
        final more = await s.fetchMore(p.cursorId!, 0);
        expect(more.rows, [
          [3, 'r3'],
        ]);
        expect(more.hasMore, isFalse);
        p = await s.execute('CREATE TABLE x (a int PRIMARY KEY)');
        expect(p.rowsAffected, -1);
        expect(p.messages.last, contains('CREATED TABLE ks.x'));
        final cols = await s.catalog('columns', ['ks', null, 't', null]);
        expect(cols.rows.map((r) => r[3]), ['id', 'name']);
        final pk = await s.catalog('primaryKeys', ['ks', null, 't']);
        expect(pk.rows.single[3], 'id');
        await expectLater(s.execute('SELEC x'), throwsA(isA<CqlException>()));
        await s.close();
      } finally {
        await server.close();
      }
    });
  });
}

// ===========================================================================
// Fake servers (loopback, in-process)
// ===========================================================================

class _FakeRedis {
  _FakeRedis(ServerSocket server) {
    server.listen((sock) {
      final p = RespParser();
      sock.listen((data) {
        p.feed(data);
        while (p.replies.isNotEmpty) {
          final cmd = (p.replies.removeFirst() as List).map(respString).toList();
          sock.add(_reply(cmd));
        }
      });
    });
  }

  final Map<String, Object> data = {
    'user:1': 'a',
    'user:2': 'bb',
    'user:3': 'ccc',
    'counter': '10',
    'config': <String, String>{'theme': 'light', 'lang': 'it'},
  };

  static List<int> _bulk(String? s) => s == null
      ? utf8.encode('\$-1\r\n')
      : [...utf8.encode('\$${utf8.encode(s).length}\r\n'), ...utf8.encode(s), 13, 10];

  static List<int> _arr(List<String> items) => [
    ...utf8.encode('*${items.length}\r\n'),
    for (final i in items) ..._bulk(i),
  ];

  static List<int> _int(int n) => utf8.encode(':$n\r\n');

  static List<int> _ok() => utf8.encode('+OK\r\n');

  String _type(String k) => switch (data[k]) {
    String() => 'string',
    Map() => 'hash',
    _ => 'none',
  };

  bool _glob(String pattern, String key) =>
      RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$').hasMatch(key);

  List<int> _reply(List<String> c) {
    final name = c.first.toUpperCase();
    switch (name) {
      case 'CLIENT':
      case 'SELECT':
        return _ok();
      case 'INFO':
        return _bulk('# Server\r\nredis_version:7.2.4\r\nredis_mode:standalone\r\n');
      case 'CONFIG':
        return _arr(['databases', '16']);
      case 'COMMAND':
        return utf8.encode('*0\r\n');
      case 'DBSIZE':
        return _int(data.length);
      case 'TYPE':
        return utf8.encode('+${_type(c[1])}\r\n');
      case 'TTL':
        return _int(-1);
      case 'STRLEN':
        return _int((data[c[1]] as String).length);
      case 'HLEN':
        return _int((data[c[1]] as Map).length);
      case 'GET':
        final v = data[c[1]];
        return _bulk(v is String ? v : null);
      case 'SET':
        data[c[1]] = c[2];
        return _ok();
      case 'HGETALL':
        final m = data[c[1]] as Map<String, String>;
        return _arr([
          for (final e in m.entries) ...[e.key, e.value],
        ]);
      case 'HGET':
        return _bulk((data[c[1]] as Map<String, String>)[c[2]]);
      case 'HSET':
        (data[c[1]] as Map<String, String>)[c[2]] = c[3];
        return _int(1);
      case 'HDEL':
        return _int((data[c[1]] as Map<String, String>).remove(c[2]) == null ? 0 : 1);
      case 'HSCAN':
        final m = data[c[1]] as Map<String, String>;
        return [
          ...utf8.encode('*2\r\n'),
          ..._bulk('0'),
          ..._arr([
            for (final e in m.entries) ...[e.key, e.value],
          ]),
        ];
      case 'SCAN':
        // Two pages: cursor 0 → 5 → 0.
        final match = c.indexOf('MATCH') > 0 ? c[c.indexOf('MATCH') + 1] : '*';
        final keys = data.keys.where((k) => _glob(match, k)).toList()..sort();
        final page = c[1] == '0' ? keys.take(2).toList() : keys.skip(2).toList();
        return [...utf8.encode('*2\r\n'), ..._bulk(c[1] == '0' ? '5' : '0'), ..._arr(page)];
      default:
        return utf8.encode("-ERR unknown command '${c.first}'\r\n");
    }
  }
}

class _FakeMongo {
  _FakeMongo(ServerSocket server) {
    server.listen((sock) {
      final buf = BytesBuilder();
      sock.listen((data) {
        buf.add(data);
        while (true) {
          final b = buf.toBytes();
          if (b.length < 4) return;
          final len = ByteData.sublistView(b).getInt32(0, Endian.little);
          if (b.length < len) return;
          final msg = decodeOpMsg(Uint8List.sublistView(b, 0, len));
          buf.clear();
          buf.add(b.sublist(len));
          sock.add(encodeOpMsg(1, _handle(msg.body), responseTo: msg.requestId));
        }
      });
    });
  }

  Map<String, Object?> lastCommand = {};
  Map<String, Object?> lastFind = {};

  final docs = [
    {
      '_id': ObjectId.parse('507f1f77bcf86cd799439011'),
      'name': 'Ann',
      'age': 30,
      'tags': ['a', 'b'],
    },
    {'_id': ObjectId.parse('507f1f77bcf86cd799439012'), 'name': 'Bob', 'age': 40},
    {'_id': ObjectId.parse('507f1f77bcf86cd799439013'), 'name': 'Cid', 'age': 50},
  ];

  Map<String, Object?> _handle(Map<String, Object?> cmd) {
    final name = cmd.keys.first;
    lastCommand = cmd;
    switch (name) {
      case 'hello':
        return {'ok': 1.0, 'isWritablePrimary': true, 'maxWireVersion': 21, 'minWireVersion': 0};
      case 'buildInfo':
        return {'ok': 1.0, 'version': '7.0.5'};
      case 'listDatabases':
        return {
          'ok': 1.0,
          'databases': [
            {'name': 'admin'},
            {'name': 'shop'},
          ],
        };
      case 'listCollections':
        return {
          'ok': 1.0,
          'cursor': {
            'id': const BsonInt64(0),
            'ns': 'shop.\$cmd.listCollections',
            'firstBatch': [
              {'name': 'users', 'type': 'collection'},
              {'name': 'v', 'type': 'view'},
            ],
          },
        };
      case 'find':
        lastFind = cmd;
        if ((cmd['filter'] as Map).containsKey(r'$bad')) {
          return {'ok': 0.0, 'errmsg': 'unknown top level operator: \$bad', 'code': 2, 'codeName': 'BadValue'};
        }
        final batch = cmd['batchSize'] as int? ?? 101;
        return {
          'ok': 1.0,
          'cursor': {
            'id': BsonInt64(batch < docs.length ? 99 : 0),
            'ns': 'shop.users',
            'firstBatch': docs.take(batch).toList(),
          },
        };
      case 'getMore':
        return {
          'ok': 1.0,
          'cursor': {'id': const BsonInt64(0), 'ns': 'shop.users', 'nextBatch': docs.skip(2).toList()},
        };
      case 'killCursors':
        return {'ok': 1.0};
      case 'count':
        return {'ok': 1.0, 'n': docs.length};
      case 'update':
        return {'ok': 1.0, 'n': 1, 'nModified': 1};
      case 'insert':
        return {'ok': 1.0, 'n': (cmd['documents'] as List).length};
      case 'aggregate':
        return {
          'ok': 1.0,
          'cursor': {'id': const BsonInt64(0), 'ns': 'shop.users', 'firstBatch': docs},
        };
      default:
        return {'ok': 0.0, 'errmsg': 'no such command: $name', 'code': 59, 'codeName': 'CommandNotFound'};
    }
  }
}

class _FakeCassandra {
  _FakeCassandra(ServerSocket server) {
    server.listen((sock) {
      final buf = BytesBuilder();
      sock.listen((data) {
        buf.add(data);
        while (true) {
          final b = buf.toBytes();
          if (b.length < 9) return;
          final h = CqlFrameHeader.parse(Uint8List.sublistView(b, 0, 9));
          if (b.length < 9 + h.length) return;
          final body = Uint8List.sublistView(b, 9, 9 + h.length);
          buf.clear();
          buf.add(b.sublist(9 + h.length));
          final (op, resp) = _handle(h.opcode, CqlReader(Uint8List.fromList(body)));
          final f = encodeFrame(h.version, h.stream, op, resp);
          f[0] = 0x80 | h.version;
          sock.add(f);
        }
      });
    });
  }

  Uint8List _rows(List<(String, int)> cols, List<List<List<int>?>> rows, {List<int>? paging}) {
    final w = CqlWriter()
      ..int32(resultRows)
      ..int32(0x0001 | (paging != null ? 0x0002 : 0))
      ..int32(cols.length);
    if (paging != null) w.bytes(paging);
    w
      ..string('ks')
      ..string('t');
    for (final (n, t) in cols) {
      w
        ..string(n)
        ..short(t);
    }
    w.int32(rows.length);
    for (final r in rows) {
      for (final v in r) {
        w.bytes(v);
      }
    }
    return w.take();
  }

  List<int> _i(int v) => (ByteData(4)..setInt32(0, v)).buffer.asUint8List();
  List<int> _s(String s) => utf8.encode(s);

  (int, Uint8List) _handle(int op, CqlReader r) {
    if (op == opStartup) return (opReady, Uint8List(0));
    if (op != opQuery) {
      return (
        opError,
        (CqlWriter()
              ..int32(0x000A)
              ..string('unsupported'))
            .take(),
      );
    }
    final q = r.longString();
    r.short(); // consistency
    final flags = r.byte();
    if (flags & 0x04 != 0) r.int32();
    final paging = flags & 0x08 != 0 ? r.bytes() : null;
    if (q.startsWith('USE')) {
      return (
        opResult,
        (CqlWriter()
              ..int32(resultSetKeyspace)
              ..string('ks'))
            .take(),
      );
    }
    if (q.contains('system.local')) {
      return (
        opResult,
        _rows(
          [('release_version', CqlType.varchar), ('cluster_name', CqlType.varchar)],
          [
            [_s('4.1.3'), _s('Test')],
          ],
        ),
      );
    }
    if (q.contains('system_schema.columns')) {
      return (
        opResult,
        _rows(
          [
            ('column_name', CqlType.varchar),
            ('clustering_order', CqlType.varchar),
            ('kind', CqlType.varchar),
            ('position', CqlType.int_),
            ('type', CqlType.varchar),
          ],
          [
            [_s('name'), _s('none'), _s('regular'), _i(-1), _s('text')],
            [_s('id'), _s('none'), _s('partition_key'), _i(0), _s('int')],
          ],
        ),
      );
    }
    if (q.startsWith('CREATE')) {
      return (
        opResult,
        (CqlWriter()
              ..int32(resultSchemaChange)
              ..string('CREATED')
              ..string('TABLE')
              ..string('ks')
              ..string('x'))
            .take(),
      );
    }
    if (q.startsWith('SELECT * FROM ks.t')) {
      const cols = [('id', CqlType.int_), ('name', CqlType.varchar)];
      if (paging == null) {
        return (
          opResult,
          _rows(
            cols,
            [
              [_i(1), _s('r1')],
              [_i(2), _s('r2')],
            ],
            paging: [1],
          ),
        );
      }
      return (
        opResult,
        _rows(cols, [
          [_i(3), _s('r3')],
        ]),
      );
    }
    return (
      opError,
      (CqlWriter()
            ..int32(0x2000)
            ..string('line 1:0 no viable alternative at input'))
          .take(),
    );
  }
}
