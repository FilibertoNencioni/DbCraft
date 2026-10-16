// Built-in Redis driver (RESP over TCP/TLS, pure Dart).
import 'package:flutter/material.dart';

import '../db_session.dart';
import '../native_driver.dart';
import 'redis_session.dart';
import '../../ui/theme/app_icons.dart';

const _yesNo = ['no', 'sì'];

class RedisDriver extends NativeDriver {
  const RedisDriver();

  @override
  String get id => 'redis';
  @override
  String get label => 'Redis';
  @override
  String get description =>
      'Archivio chiave-valore Redis (e Valkey, Azure Cache, ElastiCache). Comandi Redis una riga alla volta; '
      'le chiavi sono raggruppate per prefisso nel navigatore.';
  @override
  IconData get icon => AppIcons.bolt;
  @override
  Color get color => const Color(0xFFDC382D);
  @override
  String get defaultPort => '6379';
  @override
  String get queryLanguage => 'redis';
  @override
  bool get usesUri => true;
  @override
  String get uriHint => 'rediss://utente@host:6380/0';
  @override
  String get databaseLabel => 'Database (indice)';
  @override
  String get databaseHint => '0';

  @override
  List<NativeDriverField> get fields => const [
    NativeDriverField('tls', 'TLS/SSL', options: _yesNo, defaultValue: 'no'),
    NativeDriverField('tlsCaFile', 'File CA (PEM)', file: true, hint: 'Facoltativo: certificati di sistema'),
    NativeDriverField('tlsCertFile', 'Certificato client (PEM con chiave)', file: true),
    NativeDriverField('tlsKeyPassword', 'Password della chiave client', secret: true),
    NativeDriverField('tlsAllowInvalid', 'Accetta certificati non validi', options: _yesNo, defaultValue: 'no'),
    NativeDriverField(
      'separator',
      'Separatore delle chiavi',
      defaultValue: ':',
      help: 'Le chiavi con lo stesso prefisso (es. user:1, user:2) sono raggruppate in user:*.',
    ),
    NativeDriverField(
      'scanLimit',
      'Chiavi esaminate per il navigatore',
      defaultValue: '5000',
      help: 'Il navigatore usa SCAN fino a questo numero di chiavi (mai KEYS *).',
    ),
    NativeDriverField('clientName', 'Nome client', defaultValue: 'DbCraft'),
    NativeDriverField(
      'awsCacheName',
      'Cache ElastiCache (IAM)',
      hint: 'ID del replication group o della cache serverless',
      help: 'Solo per l\'autenticazione AWS IAM: l\'utente è l\'ID utente ElastiCache.',
    ),
    NativeDriverField('awsServerless', 'Cache ElastiCache serverless', options: _yesNo, defaultValue: 'no'),
  ];

  @override
  String get sampleQuery => 'INFO server\nSCAN 0 MATCH * COUNT 100';

  @override
  Future<DbSession> open(NativeConnectParams params) => RedisSession.open(params);
}

const redisDriver = RedisDriver();
