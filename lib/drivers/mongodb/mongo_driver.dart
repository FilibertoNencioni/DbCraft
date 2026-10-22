// Built-in MongoDB driver (wire protocol OP_MSG over TCP/TLS, pure Dart).
import 'package:flutter/material.dart';

import '../db_session.dart';
import '../native_driver.dart';
import 'mongo_session.dart';
import '../../ui/theme/app_icons.dart';

const _yesNo = ['no', 'sì'];

class MongoDriver extends NativeDriver {
  const MongoDriver();

  @override
  String get id => 'mongodb';
  @override
  String get label => 'MongoDB';
  @override
  String get description =>
      'Database documentale MongoDB (3.6 o successivo), anche Atlas e replica set. Comandi in sintassi shell '
      '(db.collezione.find(…)) e SELECT semplici sulle collezioni.';
  @override
  IconData get icon => AppIcons.leaf;
  @override
  Color get color => const Color(0xFF47A248);
  @override
  String get defaultPort => '27017';
  @override
  String get queryLanguage => 'mongo';
  @override
  bool get usesUri => true;
  @override
  String get uriHint => 'mongodb+srv://utente@cluster0.example.net/db?authSource=admin';
  @override
  String get databaseHint => 'test';

  @override
  List<NativeDriverField> get fields => const [
    NativeDriverField(
      'srv',
      'Record DNS SRV',
      options: _yesNo,
      defaultValue: 'no',
      help: 'Come mongodb+srv://: l\'elenco dei server e le opzioni vengono letti dal DNS; attiva TLS.',
    ),
    NativeDriverField('authSource', 'Database di autenticazione', hint: 'admin'),
    NativeDriverField(
      'authMechanism',
      'Meccanismo di autenticazione',
      options: ['DEFAULT', 'SCRAM-SHA-256', 'SCRAM-SHA-1', 'PLAIN', 'MONGODB-X509'],
      defaultValue: 'DEFAULT',
      help: 'PLAIN per LDAP; MONGODB-X509 richiede TLS e un certificato client.',
    ),
    NativeDriverField('replicaSet', 'Replica set', hint: 'rs0'),
    NativeDriverField(
      'readPreference',
      'Read preference',
      options: ['primary', 'primaryPreferred', 'secondary', 'secondaryPreferred', 'nearest'],
      defaultValue: 'primary',
    ),
    NativeDriverField(
      'directConnection',
      'Connessione diretta',
      options: _yesNo,
      defaultValue: 'no',
      help: 'Usa il server indicato senza cercare il primary del replica set.',
    ),
    NativeDriverField('tls', 'TLS/SSL', options: _yesNo, defaultValue: 'no'),
    NativeDriverField('tlsCaFile', 'File CA (PEM)', file: true, hint: 'Facoltativo: certificati di sistema'),
    NativeDriverField('tlsCertFile', 'Certificato client (PEM con chiave)', file: true),
    NativeDriverField('tlsKeyPassword', 'Password della chiave client', secret: true),
    NativeDriverField('tlsAllowInvalid', 'Accetta certificati non validi', options: _yesNo, defaultValue: 'no'),
    NativeDriverField(
      'sampleSize',
      'Documenti campionati per le colonne',
      defaultValue: '100',
      help: 'I campi di una collezione vengono dedotti da un campione casuale di documenti.',
    ),
    NativeDriverField('appName', 'Nome applicazione', defaultValue: 'DbCraft'),
  ];

  @override
  String get sampleQuery => 'show collections\n\ndb.getCollection("nome").find({}).sort({_id: -1}).limit(50)';

  @override
  Future<DbSession> open(NativeConnectParams params) => MongoSession.open(params);
}

const mongoDriver = MongoDriver();
