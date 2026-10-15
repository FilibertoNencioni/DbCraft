// Azure Blob Storage over the REST API: Shared Key signing, SAS tokens or
// Entra ID bearer tokens; block uploads for large files; SAS share links
// (service SAS with the account key, user delegation SAS with Entra ID).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../auth/azure_auth.dart';
import '../cloud_common.dart';
import 'cloud_storage.dart';

const azureStorageScope = 'https://storage.azure.com/.default';
const _msVersion = '2023-11-03';

String? _text(XmlElement e, String name) => e.getElement(name)?.innerText;

DateTime? _httpDate(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return HttpDate.parse(s);
  } catch (_) {
    return DateTime.tryParse(s);
  }
}

/// EnumerationResults of List Containers → containers and next marker.
(List<CloudBucket>, String?) parseAzureContainers(String xml) {
  final root = XmlDocument.parse(xml).rootElement;
  final list = [
    for (final c in root.findAllElements('Container'))
      CloudBucket(
        _text(c, 'Name') ?? '',
        created: _httpDate(c.getElement('Properties')?.getElement('Last-Modified')?.innerText),
      ),
  ];
  final next = _text(root, 'NextMarker');
  return (list, next == null || next.isEmpty ? null : next);
}

/// EnumerationResults of List Blobs → folders (BlobPrefix), files and marker.
CloudListPage parseAzureBlobs(String xml, String container) {
  final root = XmlDocument.parse(xml).rootElement;
  final prefix = _text(root, 'Prefix') ?? '';
  final blobs = root.getElement('Blobs');
  final files = <CloudObject>[];
  final folders = <CloudObject>[];
  if (blobs != null) {
    for (final b in blobs.findElements('Blob')) {
      final name = _text(b, 'Name') ?? '';
      if (name.endsWith('/')) {
        if (name != prefix) folders.add(CloudObject(bucket: container, key: name, isFolder: true));
        continue;
      }
      final p = b.getElement('Properties');
      String? prop(String n) => p == null ? null : _text(p, n);
      files.add(
        CloudObject(
          bucket: container,
          key: name,
          size: int.tryParse(prop('Content-Length') ?? '') ?? -1,
          modified: _httpDate(prop('Last-Modified')),
          etag: prop('Etag'),
          contentType: prop('Content-Type'),
          storageClass: prop('AccessTier'),
        ),
      );
    }
    for (final p in blobs.findElements('BlobPrefix')) {
      final name = _text(p, 'Name') ?? '';
      if (!folders.any((f) => f.key == name)) folders.add(CloudObject(bucket: container, key: name, isFolder: true));
    }
  }
  final next = _text(root, 'NextMarker');
  return CloudListPage(folders: folders, files: files, continuation: next == null || next.isEmpty ? null : next);
}

class AzureBlobStorage extends CloudStorage {
  AzureBlobStorage({required String endpoint, required this.accountName, this.sharedKey, String? sas, this.credential})
    : endpoint = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint,
      sas = sas == null || sas.trim().isEmpty
          ? null
          : (sas.trim().startsWith('?') ? sas.trim().substring(1) : sas.trim());

  /// From an account name (public cloud endpoint).
  factory AzureBlobStorage.forAccount(
    String account, {
    AzureSharedKey? sharedKey,
    String? sas,
    AzureCredential? credential,
    String suffix = 'core.windows.net',
  }) => AzureBlobStorage(
    endpoint: 'https://$account.blob.$suffix',
    accountName: account,
    sharedKey: sharedKey,
    sas: sas,
    credential: credential,
  );

  factory AzureBlobStorage.fromConnectionString(String cs) {
    final p = AzureConnectionString.parse(cs);
    final name = p.accountName ?? Uri.tryParse(p.blobEndpoint ?? '')?.host.split('.').first;
    final ep = p.blobEndpoint;
    if (name == null || ep == null) throw CloudException('Stringa di connessione Azure Storage non valida.');
    return AzureBlobStorage(
      endpoint: ep,
      accountName: name,
      sharedKey: p.accountKey == null ? null : AzureSharedKey(name, p.accountKey!),
      sas: p.sas,
    );
  }

  final String endpoint;
  final String accountName;
  final AzureSharedKey? sharedKey;
  final String? sas;
  final AzureCredential? credential;

  static const _blockThreshold = 64 * 1024 * 1024;
  static const _blockSize = 8 * 1024 * 1024;

  @override
  CloudProvider get provider => CloudProvider.azure;

  @override
  bool get canShare => sharedKey != null || credential != null || sas != null;

  String _path(String? container, String blob) =>
      container == null ? '/' : (blob.isEmpty ? '/$container' : '/$container/${uriEncode(blob, keepSlash: true)}');

  Uri _uri(String? container, String blob, [Map<String, String> query = const {}]) {
    final base = Uri.parse(endpoint);
    // Emulator / custom endpoints carry the account name in the path.
    final prefix = base.path == '/' ? '' : base.path;
    final u = buildUri('${base.scheme}://${base.authority}', '$prefix${_path(container, blob)}', query);
    if (sas == null || sharedKey != null || credential != null) return u;
    return Uri.parse(u.hasQuery ? '$u&$sas' : '$u?$sas');
  }

  Future<Map<String, String>> _auth(String method, Uri uri, Map<String, String> headers, int contentLength) async {
    final h = <String, String>{...headers, 'x-ms-date': httpDate(DateTime.now()), 'x-ms-version': _msVersion};
    if (sharedKey != null) {
      final forSign = {...h, if (contentLength > 0) 'Content-Length': '$contentLength'};
      h['Authorization'] = sharedKey!.authorization(method, uri, forSign);
    } else if (credential != null) {
      h['Authorization'] = 'Bearer ${(await credential!.getToken(azureStorageScope)).token}';
    }
    return h;
  }

  Future<http.Response> _request(
    String method,
    String? container,
    String blob, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int>? body,
    bool Function(int)? accept,
    String? operation,
  }) async {
    final uri = _uri(container, blob, query);
    final h = await _auth(method, uri, headers, body?.length ?? 0);
    return cloudRequest(
      method,
      uri,
      headers: h,
      body: body ?? (method == 'PUT' ? const [] : null),
      accept: accept,
      operation: operation,
    );
  }

  @override
  Future<List<CloudBucket>> listBuckets() async {
    final out = <CloudBucket>[];
    String? marker;
    do {
      final r = await _request(
        'GET',
        null,
        '',
        query: {'comp': 'list', 'marker': ?marker},
        operation: 'Elenco container',
      );
      final (list, next) = parseAzureContainers(r.body);
      out.addAll(list);
      marker = next;
    } while (marker != null);
    return out;
  }

  @override
  Future<CloudListPage> list(
    String bucket, {
    String prefix = '',
    String? delimiter = '/',
    String? continuation,
    int maxResults = 1000,
  }) async {
    final r = await _request(
      'GET',
      bucket,
      '',
      query: {
        'restype': 'container',
        'comp': 'list',
        if (prefix.isNotEmpty) 'prefix': prefix,
        'delimiter': ?delimiter,
        'marker': ?continuation,
        'maxresults': '$maxResults',
      },
      operation: 'Elenco blob',
    );
    return parseAzureBlobs(r.body, bucket);
  }

  @override
  Future<CloudObject> stat(String bucket, String key) async {
    final r = await _request('HEAD', bucket, key, operation: 'Proprietà blob');
    final h = r.headers;
    return CloudObject(
      bucket: bucket,
      key: key,
      isFolder: key.endsWith('/'),
      size: int.tryParse(h['content-length'] ?? '') ?? -1,
      modified: _httpDate(h['last-modified']),
      etag: h['etag'],
      contentType: h['content-type'],
      storageClass: h['x-ms-access-tier'],
      metadata: {
        for (final e in h.entries)
          if (e.key.startsWith('x-ms-meta-')) e.key.substring(10): e.value,
        if (h['x-ms-blob-type'] != null) 'Tipo blob': h['x-ms-blob-type']!,
        if (h['x-ms-server-encrypted'] != null) 'Cifrato': h['x-ms-server-encrypted']!,
        if (h['x-ms-lease-state'] != null) 'Lease': h['x-ms-lease-state']!,
      },
    );
  }

  @override
  Future<List<int>> readBytes(String bucket, String key, {int maxBytes = 1 << 20}) async {
    final r = await _request(
      'GET',
      bucket,
      key,
      headers: {'x-ms-range': 'bytes=0-${maxBytes - 1}'},
      accept: (s) => s == 200 || s == 206 || s == 416,
      operation: 'Lettura blob',
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
    final uri = _uri(bucket, key);
    final req = http.AbortableRequest('GET', uri, abortTrigger: cancel?.whenCancelled)
      ..headers.addAll(await _auth('GET', uri, const {}, 0));
    final s = await sendRequest(req, cancel: cancel);
    if (s.statusCode != 200) await checkResponse(s, operation: 'Download blob');
    await saveResponse(s, target, onProgress: onProgress, cancel: cancel);
  }

  @override
  Future<void> putBytes(String bucket, String key, List<int> data, {String? contentType}) async {
    await _request(
      'PUT',
      bucket,
      key,
      body: data,
      headers: {'x-ms-blob-type': 'BlockBlob', 'Content-Type': contentType ?? guessContentType(key)},
      operation: 'Caricamento blob',
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
    if (size <= _blockThreshold) {
      final uri = _uri(bucket, key);
      final h = await _auth('PUT', uri, {'x-ms-blob-type': 'BlockBlob', 'Content-Type': type}, size);
      final s = await sendFileRange(
        'PUT',
        uri,
        h,
        source,
        length: size,
        onProgress: onProgress,
        progressTotal: size,
        cancel: cancel,
      );
      await checkResponse(s, operation: 'Caricamento blob');
      return;
    }
    final blockSize = max(_blockSize, (size / 49000).ceil());
    final ids = <String>[];
    for (var offset = 0, n = 0; offset < size; offset += blockSize, n++) {
      cancel?.throwIfCancelled();
      final id = base64Encode(utf8.encode('block-${n.toString().padLeft(6, '0')}'));
      ids.add(id);
      final len = min(blockSize, size - offset);
      final uri = _uri(bucket, key, {'comp': 'block', 'blockid': id});
      final h = await _auth('PUT', uri, const {}, len);
      final s = await sendFileRange(
        'PUT',
        uri,
        h,
        source,
        start: offset,
        length: len,
        onProgress: onProgress,
        progressBase: offset,
        progressTotal: size,
        cancel: cancel,
      );
      await checkResponse(s, operation: 'Put Block');
    }
    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?><BlockList>');
    for (final id in ids) {
      xml.write('<Latest>$id</Latest>');
    }
    xml.write('</BlockList>');
    await _request(
      'PUT',
      bucket,
      key,
      query: {'comp': 'blocklist'},
      body: utf8.encode(xml.toString()),
      headers: {'Content-Type': 'application/xml', 'x-ms-blob-content-type': type},
      operation: 'Put Block List',
    );
  }

  @override
  Future<void> delete(String bucket, String key) async {
    await _request(
      'DELETE',
      bucket,
      key,
      accept: (s) => s == 202 || s == 200 || s == 404,
      operation: 'Eliminazione blob',
    );
  }

  @override
  Future<void> copy(String bucket, String key, String destBucket, String destKey) async {
    var source = _uri(bucket, key).toString();
    final headers = <String, String>{};
    if (sharedKey == null && credential == null && sas != null && !source.contains('sig=')) {
      source = '$source?$sas';
    }
    if (credential != null) {
      headers['x-ms-copy-source-authorization'] = 'Bearer ${(await credential!.getToken(azureStorageScope)).token}';
    }
    headers['x-ms-copy-source'] = source;
    final r = await _request('PUT', destBucket, destKey, headers: headers, operation: 'Copia blob');
    // Copy Blob may complete asynchronously: wait for it (same account
    // copies are normally immediate).
    var status = r.headers['x-ms-copy-status'];
    var tries = 0;
    while (status == 'pending' && tries++ < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final h = await _request('HEAD', destBucket, destKey);
      status = h.headers['x-ms-copy-status'];
      if (status == 'failed' || status == 'aborted') {
        throw CloudException('Copia non riuscita: ${h.headers['x-ms-copy-status-description'] ?? status}');
      }
    }
  }

  @override
  Future<Uri> shareLink(String bucket, String key, Duration expires) async {
    final blobUri = _uri(bucket, key);
    final expiry = DateTime.now().toUtc().add(expires);
    if (sharedKey != null) {
      return Uri.parse('$blobUri?${sharedKey!.blobSas(container: bucket, blob: key, expiry: expiry)}');
    }
    if (credential != null) {
      final start = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final body =
          '<?xml version="1.0" encoding="utf-8"?><KeyInfo><Start>${isoSeconds(start)}</Start>'
          '<Expiry>${isoSeconds(expiry)}</Expiry></KeyInfo>';
      final r = await _request(
        'POST',
        null,
        '',
        query: {'restype': 'service', 'comp': 'userdelegationkey'},
        body: utf8.encode(body),
        headers: {'Content-Type': 'application/xml'},
        operation: 'User delegation key',
      );
      final k = XmlDocument.parse(r.body).rootElement;
      final key0 = AzureUserDelegationKey(
        oid: _text(k, 'SignedOid') ?? '',
        tid: _text(k, 'SignedTid') ?? '',
        start: _text(k, 'SignedStart') ?? '',
        expiry: _text(k, 'SignedExpiry') ?? '',
        service: _text(k, 'SignedService') ?? 'b',
        version: _text(k, 'SignedVersion') ?? _msVersion,
        value: _text(k, 'Value') ?? '',
      );
      return Uri.parse('$blobUri?${key0.blobSas(account: accountName, container: bucket, blob: key, expiry: expiry)}');
    }
    if (sas != null) return blobUri; // already carries the account SAS (its own expiry)
    throw CloudException('Le credenziali dell\'account non permettono di creare link di condivisione.');
  }

  @override
  String uri(String bucket, String key) => '$endpoint/$bucket/${uriEncode(key, keepSlash: true)}';
}
