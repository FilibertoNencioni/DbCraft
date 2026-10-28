// Google Cloud Storage over the JSON API with OAuth2 tokens: resumable
// uploads for large files, server side rewrite for copies and V4 signed URLs
// (service account credentials only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../cloud/auth/gcp_auth.dart';
import '../../cloud/cloud_common.dart';
import 'object_storage.dart';

const _api = 'https://storage.googleapis.com';

StorageObject _gcsObject(String bucket, Map j) => StorageObject(
  bucket: bucket,
  key: j['name'] as String? ?? '',
  size: int.tryParse('${j['size']}') ?? -1,
  modified: DateTime.tryParse('${j['updated']}'),
  etag: j['etag'] as String?,
  contentType: j['contentType'] as String?,
  storageClass: j['storageClass'] as String?,
  metadata: {
    if (j['md5Hash'] != null) 'MD5': '${j['md5Hash']}',
    if (j['crc32c'] != null) 'CRC32C': '${j['crc32c']}',
    if (j['generation'] != null) 'Generazione': '${j['generation']}',
    if (j['timeCreated'] != null) 'Creato': '${j['timeCreated']}',
    ...((j['metadata'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
  },
);

/// objects.list response → folders, files and next page token.
StorageListPage parseGcsList(String json, String bucket) {
  final j = jsonDecode(json) as Map;
  final files = <StorageObject>[];
  for (final o in (j['items'] as List?) ?? const []) {
    final obj = _gcsObject(bucket, o as Map);
    if (obj.key.endsWith('/')) continue;
    files.add(obj);
  }
  final folders = [
    for (final p in (j['prefixes'] as List?) ?? const []) StorageObject(bucket: bucket, key: '$p', isFolder: true),
  ];
  return StorageListPage(folders: folders, files: files, continuation: j['nextPageToken'] as String?);
}

class GcsStorage extends ObjectStorage {
  GcsStorage({required this.credential, String? project})
    : _project = project == null || project.trim().isEmpty ? null : project.trim();

  final GcpCredential credential;
  String? _project;

  static const _resumableThreshold = 32 * 1024 * 1024;
  static const _chunk = 16 * 1024 * 1024; // multiple of 256 KiB

  @override
  StorageProvider get provider => StorageProvider.gcp;

  @override
  bool get canShare => credential.signer != null || credential is GcpDefaultCredential;

  Future<String> _projectId() async {
    final p = _project ?? await credential.projectId();
    if (p == null || p.isEmpty) throw CloudException('Indica il progetto Google Cloud dell\'account.');
    return _project = p;
  }

  Future<Map<String, String>> _headers([Map<String, String> extra = const {}]) async => {
    ...extra,
    'Authorization': 'Bearer ${(await credential.getToken()).token}',
  };

  String _o(String key) => uriEncode(key);

  Future<http.Response> _json(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    bool Function(int)? accept,
    String? operation,
  }) async {
    final uri = buildUri(_api, path, query);
    return cloudRequest(
      method,
      uri,
      headers: await _headers({if (body != null) 'Content-Type': 'application/json'}),
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      accept: accept,
      operation: operation,
    );
  }

  @override
  Future<List<StorageBucket>> listBuckets() async {
    final project = await _projectId();
    final out = <StorageBucket>[];
    String? token;
    do {
      final r = await _json(
        'GET',
        '/storage/v1/b',
        query: {'project': project, 'maxResults': '1000', 'pageToken': ?token},
        operation: 'Elenco bucket',
      );
      final j = jsonDecode(r.text) as Map;
      for (final b in (j['items'] as List?) ?? const []) {
        final m = b as Map;
        out.add(
          StorageBucket(
            m['name'] as String,
            region: (m['location'] as String?)?.toLowerCase(),
            created: DateTime.tryParse('${m['timeCreated']}'),
            storageClass: m['storageClass'] as String?,
          ),
        );
      }
      token = j['nextPageToken'] as String?;
    } while (token != null);
    return out;
  }

  @override
  Future<StorageListPage> list(
    String bucket, {
    String prefix = '',
    String? delimiter = '/',
    String? continuation,
    int maxResults = 1000,
  }) async {
    final r = await _json(
      'GET',
      '/storage/v1/b/${_o(bucket)}/o',
      query: {
        if (prefix.isNotEmpty) 'prefix': prefix,
        'delimiter': ?delimiter,
        'pageToken': ?continuation,
        'maxResults': '$maxResults',
      },
      operation: 'Elenco oggetti',
    );
    final page = parseGcsList(r.text, bucket);
    return StorageListPage(
      folders: page.folders.where((f) => f.key != prefix).toList(),
      files: page.files,
      continuation: page.continuation,
    );
  }

  @override
  Future<StorageObject> stat(String bucket, String key) async {
    final r = await _json('GET', '/storage/v1/b/${_o(bucket)}/o/${_o(key)}', operation: 'Proprietà oggetto');
    final o = _gcsObject(bucket, jsonDecode(r.text) as Map);
    return StorageObject(
      bucket: bucket,
      key: key,
      isFolder: key.endsWith('/'),
      size: o.size,
      modified: o.modified,
      etag: o.etag,
      contentType: o.contentType,
      storageClass: o.storageClass,
      metadata: o.metadata,
    );
  }

  @override
  Future<List<int>> readBytes(String bucket, String key, {int maxBytes = 1 << 20}) async {
    final uri = buildUri(_api, '/storage/v1/b/${_o(bucket)}/o/${_o(key)}', {'alt': 'media'});
    final r = await cloudRequest(
      'GET',
      uri,
      headers: await _headers({'Range': 'bytes=0-${maxBytes - 1}'}),
      accept: (s) => s == 200 || s == 206 || s == 416,
      operation: 'Lettura oggetto',
    );
    return r.statusCode == 416 ? const [] : r.bodyBytes;
  }

  @override
  Future<void> download(
    String bucket,
    String key,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final uri = buildUri(_api, '/storage/v1/b/${_o(bucket)}/o/${_o(key)}', {'alt': 'media'});
    final req = http.AbortableRequest('GET', uri, abortTrigger: cancel?.whenCancelled)
      ..headers.addAll(await _headers());
    final s = await sendRequest(req, cancel: cancel);
    if (s.statusCode != 200) await checkResponse(s, operation: 'Download');
    await saveResponse(s, target, onProgress: onProgress, cancel: cancel);
  }

  @override
  Future<void> putBytes(String bucket, String key, List<int> data, {String? contentType}) async {
    final uri = buildUri(_api, '/upload/storage/v1/b/${_o(bucket)}/o', {'uploadType': 'media', 'name': key});
    await cloudRequest(
      'POST',
      uri,
      headers: await _headers({'Content-Type': contentType ?? guessContentType(key)}),
      body: data,
      operation: 'Caricamento',
    );
  }

  @override
  Future<void> upload(
    String bucket,
    String key,
    File source, {
    String? contentType,
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final size = await source.length();
    final type = contentType ?? guessContentType(key);
    if (size <= _resumableThreshold) {
      final uri = buildUri(_api, '/upload/storage/v1/b/${_o(bucket)}/o', {'uploadType': 'media', 'name': key});
      final s = await sendFileRange(
        'POST',
        uri,
        await _headers({'Content-Type': type}),
        source,
        length: size,
        onProgress: onProgress,
        progressTotal: size,
        cancel: cancel,
      );
      await checkResponse(s, operation: 'Caricamento');
      return;
    }
    // Resumable session, uploaded in chunks.
    final init = await cloudRequest(
      'POST',
      buildUri(_api, '/upload/storage/v1/b/${_o(bucket)}/o', {'uploadType': 'resumable', 'name': key}),
      headers: await _headers({
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': type,
        'X-Upload-Content-Length': '$size',
      }),
      body: utf8.encode(jsonEncode({'name': key, 'contentType': type})),
      operation: 'Avvio caricamento',
    );
    final session = init.headers['location'];
    if (session == null) throw CloudException('Sessione di caricamento non disponibile.');
    try {
      for (var offset = 0; offset < size; offset += _chunk) {
        cancel?.throwIfCancelled();
        final len = min(_chunk, size - offset);
        final s = await sendFileRange(
          'PUT',
          Uri.parse(session),
          {'Content-Range': 'bytes $offset-${offset + len - 1}/$size'},
          source,
          start: offset,
          length: len,
          onProgress: onProgress,
          progressBase: offset,
          progressTotal: size,
          cancel: cancel,
        );
        final r = await http.Response.fromStream(s);
        if (r.statusCode == 308) continue;
        if (r.statusCode == 200 || r.statusCode == 201) return;
        throw responseError(r, r.text, operation: 'Caricamento');
      }
    } catch (_) {
      try {
        await cloudRequest('DELETE', Uri.parse(session), accept: (_) => true);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String bucket, String key) async {
    await _json(
      'DELETE',
      '/storage/v1/b/${_o(bucket)}/o/${_o(key)}',
      accept: (s) => s == 204 || s == 200 || s == 404,
      operation: 'Eliminazione',
    );
  }

  @override
  Future<void> copy(String bucket, String key, String destBucket, String destKey) async {
    String? token;
    do {
      final r = await _json(
        'POST',
        '/storage/v1/b/${_o(bucket)}/o/${_o(key)}/rewriteTo/b/${_o(destBucket)}/o/${_o(destKey)}',
        query: {'rewriteToken': ?token},
        body: const <String, Object?>{},
        operation: 'Copia',
      );
      final j = jsonDecode(r.text) as Map;
      token = j['done'] == true ? null : j['rewriteToken'] as String?;
    } while (token != null);
  }

  /// V4 signed URL (GOOG4-RSA-SHA256), exposed for tests.
  static Uri signedUrl(GcpServiceAccountCredential sa, String bucket, String key, Duration expires, {DateTime? now}) {
    final t = amzDate(now ?? DateTime.now());
    final date = t.substring(0, 8);
    final scope = '$date/auto/storage/goog4_request';
    final path = '/$bucket/${uriEncode(key, keepSlash: true)}';
    final secs = min(expires.inSeconds, 7 * 24 * 3600);
    final query = {
      'X-Goog-Algorithm': 'GOOG4-RSA-SHA256',
      'X-Goog-Credential': '${sa.clientEmail}/$scope',
      'X-Goog-Date': t,
      'X-Goog-Expires': '$secs',
      'X-Goog-SignedHeaders': 'host',
    };
    final canonical = [
      'GET',
      path,
      canonicalQuery(query),
      'host:storage.googleapis.com\n',
      'host',
      'UNSIGNED-PAYLOAD',
    ].join('\n');
    final sts = 'GOOG4-RSA-SHA256\n$t\n$scope\n${sha256Hex(utf8.encode(canonical))}';
    final sig = hexOf(rsaSha256Sign(sa.privateKey, utf8.encode(sts)));
    return buildUri(_api, path, {...query, 'X-Goog-Signature': sig});
  }

  @override
  Future<Uri> shareLink(String bucket, String key, Duration expires) async {
    if (credential is GcpDefaultCredential) await (credential as GcpDefaultCredential).resolve();
    final sa = credential.signer;
    if (sa == null) {
      throw CloudException(
        'I link firmati richiedono la chiave JSON di un service account: '
        'le credenziali utente (gcloud/ADC) non possono firmarli.',
      );
    }
    return signedUrl(sa, bucket, key, expires);
  }

  @override
  String uri(String bucket, String key) => 'gs://$bucket/$key';
}
