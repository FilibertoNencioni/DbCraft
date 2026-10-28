// Amazon S3 and S3-compatible stores (MinIO, Cloudflare R2, Wasabi, …) over
// the REST API with SigV4: any region (bucket region discovery through
// `x-amz-bucket-region` and redirects), virtual-hosted or path style
// addressing, multipart uploads for large files and presigned links.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../auth/aws_auth.dart';
import '../cloud_common.dart';
import 'cloud_storage.dart';

// ---------------------------------------------------------------------------
// XML parsing (pure, unit tested)
// ---------------------------------------------------------------------------

String? _text(XmlElement e, String name) => e.getElement(name)?.innerText;

DateTime? _date(String? s) => s == null ? null : DateTime.tryParse(s);

String? _unquote(String? etag) =>
    etag == null ? null : (etag.startsWith('"') && etag.endsWith('"') ? etag.substring(1, etag.length - 1) : etag);

/// ListAllMyBucketsResult → buckets and continuation token.
(List<CloudBucket>, String?) parseS3Buckets(String xml) {
  final doc = XmlDocument.parse(xml);
  final buckets = [
    for (final b in doc.findAllElements('Bucket'))
      CloudBucket(_text(b, 'Name') ?? '', region: _text(b, 'BucketRegion'), created: _date(_text(b, 'CreationDate'))),
  ];
  final token = doc.findAllElements('ContinuationToken').firstOrNull?.innerText;
  return (buckets, token == null || token.isEmpty ? null : token);
}

/// ListBucketResult (ListObjectsV2) → folders, files and next token.
CloudListPage parseS3ListObjects(String xml, String bucket) {
  final doc = XmlDocument.parse(xml);
  final root = doc.rootElement;
  final prefix = _text(root, 'Prefix') ?? '';
  final files = <CloudObject>[];
  for (final c in root.findElements('Contents')) {
    final key = _text(c, 'Key') ?? '';
    // The folder marker itself is not shown inside the folder.
    if (key == prefix && key.endsWith('/')) continue;
    files.add(
      CloudObject(
        bucket: bucket,
        key: key,
        isFolder: key.endsWith('/'),
        size: int.tryParse(_text(c, 'Size') ?? '') ?? -1,
        modified: _date(_text(c, 'LastModified')),
        etag: _unquote(_text(c, 'ETag')),
        storageClass: _text(c, 'StorageClass'),
      ),
    );
  }
  final folders = [
    for (final p in root.findElements('CommonPrefixes'))
      CloudObject(bucket: bucket, key: _text(p, 'Prefix') ?? '', isFolder: true),
  ];
  final truncated = _text(root, 'IsTruncated') == 'true';
  final next = _text(root, 'NextContinuationToken');
  return CloudListPage(
    folders: folders,
    files: files.where((f) => !f.isFolder).toList(),
    continuation: truncated && next != null && next.isNotEmpty ? next : null,
  );
}

// ---------------------------------------------------------------------------

class S3Storage extends CloudStorage {
  S3Storage({required this.auth, String? region, String? endpoint, this.pathStyle = false})
    : _region = region == null || region.trim().isEmpty ? null : region.trim(),
      endpoint = endpoint == null || endpoint.trim().isEmpty ? null : _normalizeEndpoint(endpoint.trim());

  final AwsAuth auth;

  /// Custom endpoint for S3-compatible services (https://minio.local:9000).
  final String? endpoint;

  /// Path style addressing (required by most S3-compatible services).
  final bool pathStyle;
  String? _region;
  final Map<String, String> _bucketRegions = {};

  static const _multipartThreshold = 64 * 1024 * 1024;
  static const _minPart = 16 * 1024 * 1024;

  static String _normalizeEndpoint(String e) {
    var s = e.contains('://') ? e : 'https://$e';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  @override
  CloudProvider get provider => CloudProvider.aws;

  Future<String> _defaultRegion() async => _region ??= await auth.profileRegion() ?? 'us-east-1';

  static String _awsHost(String region) =>
      region.startsWith('cn-') ? 's3.$region.amazonaws.com.cn' : 's3.$region.amazonaws.com';

  /// Base URL and encoded path for [bucket]/[key].
  (String, String) _target(String? bucket, String key, String region) {
    final encKey = uriEncode(key, keepSlash: true);
    if (bucket == null) return (endpoint ?? 'https://${_awsHost(region)}', '/');
    final virtual = !pathStyle && !bucket.contains('.');
    if (endpoint != null) {
      if (!virtual) return (endpoint!, '/$bucket/$encKey');
      final u = Uri.parse(endpoint!);
      return ('${u.scheme}://$bucket.${u.host}${u.hasPort ? ':${u.port}' : ''}', '/$encKey');
    }
    if (!virtual) return ('https://${_awsHost(region)}', '/$bucket/$encKey');
    return ('https://$bucket.${_awsHost(region)}', '/$encKey');
  }

  /// Region of [bucket]: `x-amz-bucket-region` of a HEAD request (returned
  /// also with 301/403), then GetBucketLocation.
  Future<String> regionOf(String bucket) async {
    final cached = _bucketRegions[bucket];
    if (cached != null) return cached;
    if (endpoint != null) return _bucketRegions[bucket] = await _defaultRegion();
    final creds = await auth.credentials();
    final uri = buildUri('https://s3.amazonaws.com', '/$bucket');
    final signer = SigV4Signer(credentials: creds, region: 'us-east-1', service: 's3');
    try {
      final r = await cloudRequest(
        'HEAD',
        uri,
        headers: signer.sign(method: 'HEAD', uri: uri, payloadHash: emptySha256),
        accept: (_) => true,
      );
      final reg = r.headers['x-amz-bucket-region'];
      if (reg != null && reg.isNotEmpty) return _bucketRegions[bucket] = reg;
      if (r.statusCode == 404) throw CloudException('Il bucket "$bucket" non esiste.', statusCode: 404);
    } on CloudException catch (e) {
      if (e.statusCode == 404) rethrow;
    }
    final def = await _defaultRegion();
    final loc = await _request('GET', bucket, '', query: {'location': ''}, region: def, operation: 'GetBucketLocation');
    final txt = XmlDocument.parse(loc.text).rootElement.innerText.trim();
    return _bucketRegions[bucket] = txt.isEmpty ? 'us-east-1' : (txt == 'EU' ? 'eu-west-1' : txt);
  }

  Future<Map<String, String>> _sign(
    String method,
    Uri uri,
    String region, {
    Map<String, String> headers = const {},
    String payloadHash = SigV4Signer.unsignedPayload,
  }) async {
    final signer = SigV4Signer(credentials: await auth.credentials(), region: region, service: 's3');
    return signer.sign(method: method, uri: uri, headers: headers, payloadHash: payloadHash);
  }

  /// In-memory request with one retry on a wrong-region answer.
  Future<http.Response> _request(
    String method,
    String? bucket,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int>? body,
    String? region,
    bool Function(int)? accept,
    String? operation,
  }) async {
    var reg = region ?? (bucket == null ? await _defaultRegion() : await regionOf(bucket));
    for (var attempt = 0; ; attempt++) {
      final (base, path) = _target(bucket, key, reg);
      final uri = buildUri(base, path, query);
      final hash = sha256Hex(body ?? const []);
      final signed = await _sign(method, uri, reg, headers: headers, payloadHash: hash);
      final r = await cloudRequest(method, uri, headers: signed, body: body, accept: (_) => true);
      final redirect = r.headers['x-amz-bucket-region'];
      final wrongRegion =
          (r.statusCode == 301 || r.statusCode == 307 || r.statusCode == 400) &&
          redirect != null &&
          redirect.isNotEmpty &&
          redirect != reg;
      if (wrongRegion && attempt == 0 && bucket != null) {
        reg = _bucketRegions[bucket] = redirect;
        continue;
      }
      if (r.statusCode == 403 && attempt == 0) auth.invalidate();
      final ok = accept?.call(r.statusCode) ?? (r.statusCode >= 200 && r.statusCode < 300);
      if (!ok) throw responseError(r, r.text, operation: operation);
      return r;
    }
  }

  @override
  Future<List<CloudBucket>> listBuckets() async {
    final region = await _defaultRegion();
    final out = <CloudBucket>[];
    String? token;
    do {
      final r = await _request(
        'GET',
        null,
        '',
        region: region,
        query: {if (endpoint == null) 'max-buckets': '1000', 'continuation-token': ?token},
        operation: 'ListBuckets',
      );
      final (list, next) = parseS3Buckets(r.text);
      out.addAll(list);
      token = next;
    } while (token != null);
    for (final b in out) {
      if (b.region != null) _bucketRegions[b.name] = b.region!;
    }
    if (endpoint != null) {
      return [for (final b in out) CloudBucket(b.name, region: b.region ?? region, created: b.created)];
    }
    // Older responses carry no region: discover it (in parallel, best effort).
    final missing = out.where((b) => b.region == null).toList();
    if (missing.isNotEmpty) {
      await Future.wait(missing.map((b) => regionOf(b.name).then((_) {}, onError: (_) {})));
    }
    return [for (final b in out) CloudBucket(b.name, region: _bucketRegions[b.name], created: b.created)];
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
        'list-type': '2',
        'prefix': prefix,
        'delimiter': ?delimiter,
        'continuation-token': ?continuation,
        'max-keys': '$maxResults',
      },
      operation: 'ListObjects',
    );
    return parseS3ListObjects(r.text, bucket);
  }

  @override
  Future<CloudObject> stat(String bucket, String key) async {
    final r = await _request('HEAD', bucket, key, operation: 'HeadObject');
    final h = r.headers;
    return CloudObject(
      bucket: bucket,
      key: key,
      isFolder: key.endsWith('/'),
      size: int.tryParse(h['content-length'] ?? '') ?? -1,
      modified: h['last-modified'] == null ? null : HttpDate.parse(h['last-modified']!),
      etag: _unquote(h['etag']),
      contentType: h['content-type'],
      storageClass: h['x-amz-storage-class'] ?? 'STANDARD',
      metadata: {
        for (final e in h.entries)
          if (e.key.startsWith('x-amz-meta-')) e.key.substring(11): e.value,
        if (h['x-amz-server-side-encryption'] != null) 'Cifratura': h['x-amz-server-side-encryption']!,
        if (h['x-amz-version-id'] != null) 'Versione': h['x-amz-version-id']!,
      },
    );
  }

  @override
  Future<List<int>> readBytes(String bucket, String key, {int maxBytes = 1 << 20}) async {
    final r = await _request(
      'GET',
      bucket,
      key,
      headers: {'Range': 'bytes=0-${maxBytes - 1}'},
      accept: (s) => s == 200 || s == 206 || s == 416,
      operation: 'GetObject',
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
    final region = await regionOf(bucket);
    final (base, path) = _target(bucket, key, region);
    final uri = buildUri(base, path);
    final req = http.AbortableRequest('GET', uri, abortTrigger: cancel?.whenCancelled)
      ..headers.addAll(await _sign('GET', uri, region, payloadHash: emptySha256));
    final s = await sendRequest(req, cancel: cancel);
    if (s.statusCode != 200) await checkResponse(s, operation: 'GetObject');
    await saveResponse(s, target, onProgress: onProgress, cancel: cancel);
  }

  @override
  Future<void> putBytes(String bucket, String key, List<int> data, {String? contentType}) async {
    await _request(
      'PUT',
      bucket,
      key,
      body: data,
      headers: {'Content-Type': contentType ?? guessContentType(key)},
      operation: 'PutObject',
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
    final region = await regionOf(bucket);
    if (size <= _multipartThreshold) {
      final (base, path) = _target(bucket, key, region);
      final uri = buildUri(base, path);
      final headers = await _sign('PUT', uri, region, headers: {'Content-Type': type});
      final s = await sendFileRange(
        'PUT',
        uri,
        headers,
        source,
        length: size,
        onProgress: onProgress,
        progressTotal: size,
        cancel: cancel,
      );
      await checkResponse(s, operation: 'PutObject');
      return;
    }
    // Multipart upload (parts of at least 16 MB, at most 10000 parts).
    final partSize = max(_minPart, (size / 9000).ceil());
    final init = await _request(
      'POST',
      bucket,
      key,
      query: {'uploads': ''},
      headers: {'Content-Type': type},
      region: region,
      operation: 'CreateMultipartUpload',
    );
    final uploadId = XmlDocument.parse(init.text).findAllElements('UploadId').first.innerText;
    final etags = <int, String>{};
    try {
      var part = 1;
      for (var offset = 0; offset < size; offset += partSize, part++) {
        cancel?.throwIfCancelled();
        final len = min(partSize, size - offset);
        final (base, path) = _target(bucket, key, region);
        final uri = buildUri(base, path, {'partNumber': '$part', 'uploadId': uploadId});
        final headers = await _sign('PUT', uri, region);
        final s = await sendFileRange(
          'PUT',
          uri,
          headers,
          source,
          start: offset,
          length: len,
          onProgress: onProgress,
          progressBase: offset,
          progressTotal: size,
          cancel: cancel,
        );
        final r = await checkResponse(s, operation: 'UploadPart $part');
        etags[part] = r.headers['etag'] ?? '';
      }
      final xml = StringBuffer('<CompleteMultipartUpload>');
      for (final e in etags.entries) {
        xml.write('<Part><PartNumber>${e.key}</PartNumber><ETag>${const HtmlEscape().convert(e.value)}</ETag></Part>');
      }
      xml.write('</CompleteMultipartUpload>');
      final done = await _request(
        'POST',
        bucket,
        key,
        query: {'uploadId': uploadId},
        body: utf8.encode(xml.toString()),
        headers: {'Content-Type': 'application/xml'},
        region: region,
        operation: 'CompleteMultipartUpload',
      );
      // Errors can come with status 200 in the body.
      if (done.text.contains('<Error>')) throw responseError(done, done.text, operation: 'CompleteMultipartUpload');
    } catch (_) {
      try {
        await _request('DELETE', bucket, key, query: {'uploadId': uploadId}, region: region);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String bucket, String key) async {
    await _request('DELETE', bucket, key, operation: 'DeleteObject');
  }

  /// Batch delete (DeleteObjects, 1000 keys per request).
  @override
  Future<int> deleteRecursive(String bucket, String key, {CancelToken? cancel}) async {
    if (!key.endsWith('/')) return super.deleteRecursive(bucket, key, cancel: cancel);
    final keys = (await listAll(bucket, key, cancel: cancel)).map((o) => o.key).toSet()..add(key);
    final all = keys.toList();
    for (var i = 0; i < all.length; i += 1000) {
      cancel?.throwIfCancelled();
      final chunk = all.sublist(i, min(i + 1000, all.length));
      final xml = StringBuffer('<Delete><Quiet>true</Quiet>');
      for (final k in chunk) {
        xml.write('<Object><Key>${const HtmlEscape(HtmlEscapeMode.element).convert(k)}</Key></Object>');
      }
      xml.write('</Delete>');
      final body = utf8.encode(xml.toString());
      final r = await _request(
        'POST',
        bucket,
        '',
        query: {'delete': ''},
        body: body,
        headers: {'Content-Type': 'application/xml', 'Content-MD5': base64Encode(md5.convert(body).bytes)},
        operation: 'DeleteObjects',
      );
      final errors = XmlDocument.parse(r.text).findAllElements('Error').toList();
      if (errors.isNotEmpty) {
        final e = errors.first;
        throw CloudException(
          'Eliminazione di ${errors.length} oggetti non riuscita: '
          '${_text(e, 'Key')}: ${_text(e, 'Message') ?? _text(e, 'Code')}',
        );
      }
    }
    return all.length - 1;
  }

  @override
  Future<void> copy(String bucket, String key, String destBucket, String destKey) async {
    final r = await _request(
      'PUT',
      destBucket,
      destKey,
      headers: {'x-amz-copy-source': '/$bucket/${uriEncode(key, keepSlash: true)}'},
      operation: 'CopyObject',
    );
    if (r.text.contains('<Error>')) throw responseError(r, r.text, operation: 'CopyObject');
  }

  @override
  Future<Uri> shareLink(String bucket, String key, Duration expires) async {
    final region = await regionOf(bucket);
    final (base, path) = _target(bucket, key, region);
    final signer = SigV4Signer(credentials: await auth.credentials(), region: region, service: 's3');
    final e = expires > const Duration(days: 7) ? const Duration(days: 7) : expires;
    return signer.presign(method: 'GET', uri: buildUri(base, path), expires: e);
  }

  @override
  String uri(String bucket, String key) => 's3://$bucket/$key';
}
