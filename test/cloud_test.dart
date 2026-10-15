import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dbcraft/cloud/auth/aws_auth.dart';
import 'package:dbcraft/cloud/auth/azure_auth.dart';
import 'package:dbcraft/cloud/auth/gcp_auth.dart';
import 'package:dbcraft/cloud/auth/token_cache.dart';
import 'package:dbcraft/cloud/cloud_accounts.dart';
import 'package:dbcraft/cloud/cloud_common.dart';
import 'package:dbcraft/cloud/storage/azure_blob_storage.dart';
import 'package:dbcraft/cloud/storage/gcs_storage.dart';
import 'package:dbcraft/cloud/storage/s3_storage.dart';
import 'package:dbcraft/cloud/ui/cloud_account_dialog.dart';
import 'package:dbcraft/cloud/ui/cloud_explorer_panel.dart';
import 'package:dbcraft/drivers/bigquery/bigquery_driver.dart';
import 'package:dbcraft/drivers/bigquery/bigquery_values.dart';
import 'package:dbcraft/state/app_state.dart';
import 'package:dbcraft/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:dbcraft/odbc/odbc_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

// Example credentials of the AWS documentation (Signature Version 4 examples
// of the Amazon S3 API reference).
const _awsCreds = AwsCredentials('AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY');
final _awsDate = DateTime.utc(2013, 5, 24);

String _signature(Map<String, String> headers) =>
    RegExp(r'Signature=([0-9a-f]{64})').firstMatch(headers['Authorization']!)!.group(1)!;

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _rsaKeyPair() {
  final rnd = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64), rnd));
  final pair = gen.generateKeyPair();
  return AsymmetricKeyPair(pair.publicKey, pair.privateKey);
}

/// PKCS#8 PEM of [k] (the format of Google service account keys).
String _pkcs8Pem(RSAPrivateKey k) {
  final e = BigInt.parse('65537');
  final rsa = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Integer(k.modulus),
      ASN1Integer(e),
      ASN1Integer(k.privateExponent),
      ASN1Integer(k.p),
      ASN1Integer(k.q),
      ASN1Integer(k.privateExponent! % (k.p! - BigInt.one)),
      ASN1Integer(k.privateExponent! % (k.q! - BigInt.one)),
      ASN1Integer(k.q!.modInverse(k.p!)),
    ],
  );
  final info = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Sequence(elements: [ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'), ASN1Null()]),
      ASN1OctetString(octets: rsa.encode()),
    ],
  );
  final b64 = base64Encode(info.encode());
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n-----END PRIVATE KEY-----\n';
}

bool _verifyRs256(RSAPublicKey pub, List<int> data, List<int> sig) {
  final v = RSASigner(SHA256Digest(), '0609608648016503040201')..init(false, PublicKeyParameter<RSAPublicKey>(pub));
  return v.verifySignature(Uint8List.fromList(data), RSASignature(Uint8List.fromList(sig)));
}

void main() {
  group('AWS SigV4', () {
    final signer = SigV4Signer(credentials: _awsCreds, region: 'us-east-1', service: 's3');

    test('GET object (S3 documentation example)', () {
      final h = signer.sign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: {'Range': 'bytes=0-9'},
        payloadHash: emptySha256,
        now: _awsDate,
      );
      expect(_signature(h), 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
      expect(h['Authorization'], contains('SignedHeaders=host;range;x-amz-content-sha256;x-amz-date'));
      expect(h['x-amz-date'], '20130524T000000Z');
    });

    test('PUT object with encoded key (S3 documentation example)', () {
      final h = signer.sign(
        method: 'PUT',
        uri: buildUri('https://examplebucket.s3.amazonaws.com', '/${uriEncode(r'test$file.text')}'),
        headers: {'Date': 'Fri, 24 May 2013 00:00:00 GMT', 'x-amz-storage-class': 'REDUCED_REDUNDANCY'},
        payloadHash: sha256Hex(utf8.encode('Welcome to Amazon S3.')),
        now: _awsDate,
      );
      expect(_signature(h), '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd');
    });

    test('GET bucket lifecycle and list objects (S3 documentation examples)', () {
      final a = signer.sign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/?lifecycle'),
        payloadHash: emptySha256,
        now: _awsDate,
      );
      expect(_signature(a), 'fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543');
      final b = signer.sign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J'),
        payloadHash: emptySha256,
        now: _awsDate,
      );
      expect(_signature(b), '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7');
    });

    test('presigned URL (S3 documentation example)', () {
      final u = signer.presign(
        method: 'GET',
        uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        expires: const Duration(seconds: 86400),
        now: _awsDate,
      );
      expect(u.queryParameters['X-Amz-Signature'], 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
      expect(u.queryParameters['X-Amz-Credential'], 'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request');
      expect(
        u.toString(),
        contains('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'),
      );
    });

    test('RDS IAM token', () async {
      final t = await rdsAuthToken(
        host: 'mydb.abc123.eu-west-1.rds.amazonaws.com',
        port: 5432,
        region: 'eu-west-1',
        dbUser: 'app_user',
        creds: _awsCreds,
        now: _awsDate,
      );
      expect(t.startsWith('mydb.abc123.eu-west-1.rds.amazonaws.com:5432/?Action=connect&DBUser=app_user&'), isTrue);
      expect(t, isNot(contains('https://')));
      expect(t, contains('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Feu-west-1%2Frds-db%2Faws4_request'));
      expect(t, contains('X-Amz-Expires=900'));
      expect(RegExp(r'X-Amz-Signature=[0-9a-f]{64}$').hasMatch(t), isTrue);
      expect(regionFromRdsHost('mydb.abc123.eu-west-1.rds.amazonaws.com'), 'eu-west-1');
    });

    test('INI profiles and credential_process output', () {
      final ini = parseIni(
        '[default]\naws_access_key_id = AK\naws_secret_access_key=SK\n\n'
        '[profile dev]\nregion = eu-south-1\ns3 =\n  max_concurrent_requests = 4\n# comment\n',
      );
      expect(ini['default']!['aws_access_key_id'], 'AK');
      expect(ini['profile dev']!['region'], 'eu-south-1');
      expect(ini['profile dev']!.containsKey('max_concurrent_requests'), isFalse);
      final c = AwsCredentials.fromProcessJson(
        '{"Version":1,"AccessKeyId":"A","SecretAccessKey":"S","SessionToken":"T","Expiration":"2030-01-01T00:00:00Z"}',
      );
      expect(c.sessionToken, 'T');
      expect(c.isExpired, isFalse);
    });

    test('URI encoding', () {
      expect(uriEncode('a b/c+d~é'), 'a%20b%2Fc%2Bd~%C3%A9');
      expect(uriEncode('dir/x y', keepSlash: true), 'dir/x%20y');
    });
  });

  group('Azure', () {
    test('Shared Key string-to-sign and signature', () {
      final key = AzureSharedKey('myaccount', base64Encode(utf8.encode('secretkey0123456789')));
      final uri = Uri.parse(
        'https://myaccount.blob.core.windows.net/mycontainer?restype=container&comp=list'
        '&prefix=a%2Fb&maxresults=10',
      );
      final headers = {'x-ms-date': 'Fri, 26 Jun 2015 23:39:12 GMT', 'x-ms-version': '2015-02-21'};
      final sts = key.stringToSign('GET', uri, headers);
      expect(
        sts,
        'GET\n\n\n\n\n\n\n\n\n\n\n\n'
        'x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\nx-ms-version:2015-02-21\n'
        '/myaccount/mycontainer\ncomp:list\nmaxresults:10\nprefix:a/b\nrestype:container',
      );
      expect(
        key.authorization('GET', uri, headers),
        'SharedKey myaccount:A18MZvO0lupf7FRw55Sbbus4DAuc9SsHj1fJhk5bjFM=',
      );

      final put = Uri.parse('https://myaccount.blob.core.windows.net/mycontainer/dir/my%20file.txt');
      final putHeaders = {
        'Content-Length': '11',
        'Content-Type': 'text/plain',
        'x-ms-blob-type': 'BlockBlob',
        'x-ms-date': 'Fri, 26 Jun 2015 23:39:12 GMT',
        'x-ms-version': '2015-02-21',
      };
      expect(
        key.authorization('PUT', put, putHeaders),
        'SharedKey myaccount:iONXIrowSp3Uv4edwHKjZP8y4N/HT6CL8+4lJl/32tU=',
      );
    });

    test('connection string', () {
      final cs = AzureConnectionString.parse(
        'DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=a2V5;EndpointSuffix=core.windows.net',
      );
      expect(cs.accountName, 'acct');
      expect(cs.accountKey, 'a2V5');
      expect(cs.blobEndpoint, 'https://acct.blob.core.windows.net');
      final dev = AzureConnectionString.parse('UseDevelopmentStorage=true');
      expect(dev.blobEndpoint, 'http://127.0.0.1:10000/devstoreaccount1');
    });

    test('service SAS', () {
      final key = AzureSharedKey('acct', base64Encode(utf8.encode('k')));
      final sas = key.blobSas(container: 'c', blob: 'a b.csv', expiry: DateTime.utc(2030, 1, 2, 3, 4, 5));
      final q = Uri.splitQueryString(sas);
      expect(q['se'], '2030-01-02T03:04:05Z');
      expect(q['sr'], 'b');
      expect(q['sp'], 'r');
      expect(q['sig'], isNotEmpty);
    });

    test('List Blobs / List Containers XML', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults ServiceEndpoint="https://acct.blob.core.windows.net/" ContainerName="data">
  <Prefix>reports/</Prefix>
  <Delimiter>/</Delimiter>
  <Blobs>
    <Blob><Name>reports/</Name><Properties><Content-Length>0</Content-Length></Properties></Blob>
    <Blob>
      <Name>reports/q1.csv</Name>
      <Properties>
        <Last-Modified>Wed, 09 Sep 2026 10:00:00 GMT</Last-Modified>
        <Etag>0x8D</Etag>
        <Content-Length>2048</Content-Length>
        <Content-Type>text/csv</Content-Type>
        <AccessTier>Hot</AccessTier>
      </Properties>
    </Blob>
    <BlobPrefix><Name>reports/2026/</Name></BlobPrefix>
  </Blobs>
  <NextMarker>2!abc</NextMarker>
</EnumerationResults>''';
      final page = parseAzureBlobs(xml, 'data');
      expect(page.files.single.key, 'reports/q1.csv');
      expect(page.files.single.size, 2048);
      expect(page.files.single.storageClass, 'Hot');
      expect(page.files.single.modified, DateTime.utc(2026, 9, 9, 10));
      expect(page.folders.map((f) => f.key), ['reports/2026/']);
      expect(page.continuation, '2!abc');

      const containers = '''<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults ServiceEndpoint="https://acct.blob.core.windows.net/">
  <Containers>
    <Container><Name>data</Name><Properties><Last-Modified>Wed, 09 Sep 2026 10:00:00 GMT</Last-Modified></Properties></Container>
    <Container><Name>logs</Name><Properties /></Container>
  </Containers>
  <NextMarker />
</EnumerationResults>''';
      final (list, marker) = parseAzureContainers(containers);
      expect(list.map((c) => c.name), ['data', 'logs']);
      expect(marker, isNull);
    });
  });

  group('S3 XML', () {
    test('ListObjectsV2', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>bucket</Name><Prefix>data/</Prefix><KeyCount>3</KeyCount><MaxKeys>1000</MaxKeys>
  <Delimiter>/</Delimiter><IsTruncated>true</IsTruncated>
  <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
  <Contents><Key>data/</Key><Size>0</Size></Contents>
  <Contents>
    <Key>data/sales &amp; costs.csv</Key>
    <LastModified>2026-09-01T12:00:00.000Z</LastModified>
    <ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>
    <Size>434234</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <CommonPrefixes><Prefix>data/2026/</Prefix></CommonPrefixes>
</ListBucketResult>''';
      final page = parseS3ListObjects(xml, 'bucket');
      expect(page.files.single.key, 'data/sales & costs.csv');
      expect(page.files.single.name, 'sales & costs.csv');
      expect(page.files.single.parent, 'data/');
      expect(page.files.single.etag, '9b2cf535f27731c974343645a3985328');
      expect(page.files.single.size, 434234);
      expect(page.folders.single.key, 'data/2026/');
      expect(page.folders.single.name, '2026');
      expect(page.continuation, '1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=');
    });

    test('ListBuckets', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Owner><ID>x</ID></Owner>
  <Buckets>
    <Bucket><Name>a</Name><CreationDate>2020-01-01T00:00:00.000Z</CreationDate><BucketRegion>eu-west-1</BucketRegion></Bucket>
    <Bucket><Name>b</Name><CreationDate>2021-01-01T00:00:00.000Z</CreationDate></Bucket>
  </Buckets>
</ListAllMyBucketsResult>''';
      final (list, token) = parseS3Buckets(xml);
      expect(list.map((b) => b.name), ['a', 'b']);
      expect(list.first.region, 'eu-west-1');
      expect(list.last.region, isNull);
      expect(token, isNull);
    });

    test('GCS objects.list JSON', () {
      final page = parseGcsList(
        jsonEncode({
          'prefixes': ['x/y/'],
          'items': [
            {'name': 'x/', 'size': '0'},
            {'name': 'x/a.sql', 'size': '12', 'updated': '2026-01-01T00:00:00Z', 'storageClass': 'STANDARD'},
          ],
          'nextPageToken': 'tok',
        }),
        'b',
      );
      expect(page.files.single.size, 12);
      expect(page.folders.single.key, 'x/y/');
      expect(page.continuation, 'tok');
    });
  });

  group('Google auth', () {
    final pair = _rsaKeyPair();

    test('PKCS#8 parsing and RS256 JWT', () {
      final key = parseRsaPrivateKeyPem(_pkcs8Pem(pair.privateKey));
      expect(key.modulus, pair.privateKey.modulus);
      final sa = GcpServiceAccountCredential(
        clientEmail: 'svc@proj.iam.gserviceaccount.com',
        privateKey: key,
        privateKeyId: 'kid1',
      );
      final jwt = sa.assertion([gcpCloudPlatformScope], now: DateTime.utc(2026, 1, 1));
      final parts = jwt.split('.');
      expect(parts.length, 3);
      String pad(String s) => s + '=' * ((4 - s.length % 4) % 4);
      final header = jsonDecode(utf8.decode(base64Url.decode(pad(parts[0])))) as Map;
      final claims = jsonDecode(utf8.decode(base64Url.decode(pad(parts[1])))) as Map;
      expect(header, {'alg': 'RS256', 'typ': 'JWT', 'kid': 'kid1'});
      expect(claims['iss'], 'svc@proj.iam.gserviceaccount.com');
      expect(claims['aud'], 'https://oauth2.googleapis.com/token');
      expect(claims['scope'], gcpCloudPlatformScope);
      expect(claims['exp'], (claims['iat'] as int) + 3600);
      final ok = _verifyRs256(pair.publicKey, utf8.encode('${parts[0]}.${parts[1]}'), base64Url.decode(pad(parts[2])));
      expect(ok, isTrue);
      expect(_verifyRs256(pair.publicKey, utf8.encode('tampered'), base64Url.decode(pad(parts[2]))), isFalse);
    });

    test('service account JSON and GCS V4 signed URL', () {
      final cred = gcpCredentialFromJson({
        'type': 'service_account',
        'project_id': 'proj',
        'client_email': 'svc@proj.iam.gserviceaccount.com',
        'private_key': _pkcs8Pem(pair.privateKey),
      }) as GcpServiceAccountCredential;
      expect(cred.project, 'proj');
      final url = GcsStorage.signedUrl(
        cred,
        'bkt',
        'dir/a b.csv',
        const Duration(hours: 1),
        now: DateTime.utc(2026, 3, 4, 5, 6, 7),
      );
      expect(url.path, '/bkt/dir/a%20b.csv');
      expect(
        url.queryParameters['X-Goog-Credential'],
        'svc@proj.iam.gserviceaccount.com/20260304/auto/storage/goog4_request',
      );
      expect(url.queryParameters['X-Goog-Date'], '20260304T050607Z');
      expect(url.queryParameters['X-Goog-Expires'], '3600');
      expect(url.queryParameters['X-Goog-Signature'], matches(RegExp(r'^[0-9a-f]{512}$')));
    });
  });

  test('token cache: errors propagate, values are cached', () async {
    final cache = TokenCache();
    await expectLater(cache.get('k', () async => throw CloudException('boom')), throwsA(isA<CloudException>()));
    var calls = 0;
    Future<AccessToken> load() async {
      calls++;
      return AccessToken('t', DateTime.now().add(const Duration(hours: 1)));
    }

    final r = await Future.wait([cache.get('k', load), cache.get('k', load)]);
    expect(r.map((e) => e.token), ['t', 't']);
    expect((await cache.get('k', load)).token, 't');
    expect(calls, 1);
  });

  group('Cloud accounts', () {
    test('JSON round trip without secrets', () {
      final a = CloudAccount(
        name: 'Produzione',
        provider: CloudProvider.aws,
        authKind: CloudAuthKind.awsProfile,
        fields: {CloudField.profile: 'prod', CloudField.region: 'eu-west-1', CloudField.endpoint: ''},
      );
      final text = jsonEncode(a.toJson());
      expect(text, isNot(contains('endpoint')));
      final b = CloudAccount.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
      expect(b.id, a.id);
      expect(b.name, 'Produzione');
      expect(b.provider, CloudProvider.aws);
      expect(b.authKind, CloudAuthKind.awsProfile);
      expect(b.field(CloudField.profile), 'prod');
      expect(b.subtitle, 'eu-west-1 · profilo prod');
      final unknown = CloudAccount.fromJson({'id': 'x', 'name': 'n', 'provider': 'gcp', 'auth': 'nope'});
      expect(unknown.authKind.provider, CloudProvider.gcp);
    });

    test('auth kinds per provider', () {
      for (final p in CloudProvider.values) {
        expect(CloudAuthKind.forProvider(p), isNotEmpty);
      }
    });
  });

  group('BigQuery values', () {
    final schema = parseBqSchema({
      'fields': [
        {'name': 'id', 'type': 'INTEGER', 'mode': 'REQUIRED'},
        {'name': 'price', 'type': 'FLOAT'},
        {'name': 'ok', 'type': 'BOOLEAN'},
        {'name': 'ts', 'type': 'TIMESTAMP'},
        {'name': 'amount', 'type': 'NUMERIC'},
        {'name': 'tags', 'type': 'STRING', 'mode': 'REPEATED'},
        {
          'name': 'addr',
          'type': 'RECORD',
          'fields': [
            {'name': 'city', 'type': 'STRING'},
            {'name': 'zip', 'type': 'INT64'},
          ],
        },
        {'name': 'd', 'type': 'DATE'},
      ],
    });

    test('row conversion', () {
      final row = convertBqRow(schema, {
        'f': [
          {'v': '42'},
          {'v': '3.5'},
          {'v': 'true'},
          {'v': '1.7e9'},
          {'v': '123.4500'},
          {
            'v': [
              {'v': 'a'},
              {'v': 'b'},
            ],
          },
          {
            'v': {
              'f': [
                {'v': 'Roma'},
                {'v': '100'},
              ],
            },
          },
          {'v': null},
        ],
      });
      expect(row[0], 42);
      expect(row[1], 3.5);
      expect(row[2], true);
      expect(row[3], '2023-11-14T22:13:20Z');
      expect(row[4], '123.4500');
      expect(row[5], '["a","b"]');
      expect(row[6], '{"city":"Roma","zip":100}');
      expect(row[7], isNull);
    });

    test('timestamps with microseconds and type mapping', () {
      expect(bqTimestamp('1700000000.123456'), '2023-11-14T22:13:20.123456Z');
      expect(bqTimestamp('1700000000123456'), '2023-11-14T22:13:20.123456Z');
      expect(bqSqlType('INT64'), SQL_BIGINT);
      expect(bqSqlType('INTEGER'), SQL_BIGINT);
      expect(bqSqlType('FLOAT64'), SQL_DOUBLE);
      expect(bqSqlType('NUMERIC'), SQL_DECIMAL);
      expect(bqSqlType('BOOL'), SQL_BIT);
      expect(bqSqlType('TIMESTAMP'), SQL_TYPE_TIMESTAMP);
      expect(bqSqlType('STRING'), SQL_WVARCHAR);
      expect(bqSqlType('RECORD'), SQL_WLONGVARCHAR);
    });

    test('flattened columns', () {
      final cols = flattenBqFields(schema);
      expect(cols.map((c) => c.name), [
        'id',
        'price',
        'ok',
        'ts',
        'amount',
        'tags',
        'addr',
        'addr.city',
        'addr.zip',
        'd',
      ]);
      expect(cols.firstWhere((c) => c.name == 'tags').typeName, 'ARRAY<STRING>');
      expect(cols.firstWhere((c) => c.name == 'tags').remarks, 'REPEATED');
      expect(
        convertBqRow(schema.sublist(0, 1), {
          'f': [
            {'v': 'x'},
          ],
        }).single,
        'x',
      );
      expect(cols.firstWhere((c) => c.name == 'id').nullable, isFalse);
    });
  });

  group('Cloud UI', () {
    testWidgets('explorer empty state, account dialog and store persistence', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('dbcraft-cloud-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app = (await tester.runAsync(() => AppState.load(workspaceDir: dir)))!;
      final store = (await tester.runAsync(() async {
        final s = CloudAccountsStore.of(app);
        while (!s.isLoaded) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return s;
      }))!;
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: SizedBox(width: 300, child: CloudExplorerPanel())),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Nessun account cloud'), findsOneWidget);

      await tester.tap(find.text('Nuovo account…'));
      await tester.pumpAndSettle();
      expect(find.text('Nuovo account cloud'), findsOneWidget);
      await tester.tap(find.text('Azure'));
      await tester.pumpAndSettle();
      expect(find.text('Storage account'), findsOneWidget);
      await tester.tap(find.text('Google Cloud'));
      await tester.pumpAndSettle();
      expect(find.text('Progetto'), findsOneWidget);
      await tester.tap(find.text('AWS'));
      await tester.pumpAndSettle();
      expect(find.text('Profilo'), findsOneWidget);
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => store.add(
          CloudAccount(
            name: 'Archivio',
            provider: CloudProvider.aws,
            authKind: CloudAuthKind.awsKeys,
            fields: {CloudField.accessKeyId: 'AKIDEXAMPLE', CloudField.region: 'eu-west-1'},
          ),
          {CloudSecret.secretAccessKey: 'secret'},
        ),
      );
      await tester.pump();
      expect(find.text('Archivio'), findsOneWidget);
      final saved = File('${dir.path}/cloud_accounts.json').readAsStringSync();
      expect(saved, contains('AKIDEXAMPLE'));
      expect(saved, isNot(contains('"secret"')));
      expect(store.secrets(store.accounts.single)[CloudSecret.secretAccessKey], 'secret');
      await tester.runAsync(() => store.remove(store.accounts.single));
      await tester.pump();
      expect(find.text('Nessun account cloud'), findsOneWidget);
    });
  });

  test('BigQuery driver metadata', () {
    expect(bigQueryDriver.id, 'bigquery');
    expect(bigQueryDriver.usesHost, isFalse);
    expect(bigQueryDriver.usesUser, isFalse);
    expect(bigQueryDriver.usesPassword, isFalse);
    expect(bigQueryDriver.databaseLabel, 'Progetto');
    expect(cloudProviderColor(CloudProvider.gcp), isNotNull);
  });
}
