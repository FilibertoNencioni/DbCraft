// Built-in Apache Cassandra driver (CQL native protocol v4/v3, pure Dart).
import 'package:flutter/material.dart';

import '../db_session.dart';
import '../native_driver.dart';
import 'cassandra_session.dart';

const _yesNo = ['no', 'sì'];

class CassandraDriver extends NativeDriver {
  const CassandraDriver();

  @override
  String get id => 'cassandra';
  @override
  String get label => 'Apache Cassandra';
  @override
  String get description =>
      'Database a colonne larghe Apache Cassandra 3.0+ (anche ScyllaDB, DataStax Enterprise e Astra con TLS). '
      'Query CQL con paginazione.';
  @override
  IconData get icon => Icons.remove_red_eye_outlined;
  @override
  Color get color => const Color(0xFF1287B1);
  @override
  String get defaultPort => '9042';
  @override
  String get queryLanguage => 'cql';
  @override
  String get databaseLabel => 'Keyspace';
  @override
  String get databaseHint => 'Facoltativo';

  @override
  List<NativeDriverField> get fields => const [
    NativeDriverField(
      'consistency',
      'Consistency level',
      options: ['LOCAL_ONE', 'ONE', 'TWO', 'THREE', 'QUORUM', 'LOCAL_QUORUM', 'EACH_QUORUM', 'ALL', 'ANY'],
      defaultValue: 'LOCAL_ONE',
    ),
    NativeDriverField(
      'localDatacenter',
      'Datacenter locale',
      hint: 'datacenter1',
      help: 'Se indicato, la sessione usa un nodo di questo datacenter.',
    ),
    NativeDriverField('pageSize', 'Righe per pagina', hint: 'Predefinito: dimensione di fetch delle impostazioni'),
    NativeDriverField('tls', 'TLS/SSL', options: _yesNo, defaultValue: 'no'),
    NativeDriverField('tlsCaFile', 'File CA (PEM)', file: true, hint: 'Facoltativo: certificati di sistema'),
    NativeDriverField('tlsCertFile', 'Certificato client (PEM con chiave)', file: true),
    NativeDriverField('tlsKeyPassword', 'Password della chiave client', secret: true),
    NativeDriverField('tlsAllowInvalid', 'Accetta certificati non validi', options: _yesNo, defaultValue: 'no'),
  ];

  @override
  String get sampleQuery => 'SELECT keyspace_name, table_name FROM system_schema.tables;';

  @override
  Future<DbSession> open(NativeConnectParams params) => CassandraSession.open(params);
}

const cassandraDriver = CassandraDriver();
