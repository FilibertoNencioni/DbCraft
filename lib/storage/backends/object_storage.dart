// Provider independent view of an object store (Amazon S3, Azure Blob
// Storage, Google Cloud Storage): buckets/containers, "folders" emulated with
// the `/` delimiter, streaming transfers with progress and cancellation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../cloud/cloud_common.dart';

enum StorageProvider {
  aws('Amazon Web Services', 'Amazon S3', 'Bucket', 's3'),
  azure('Microsoft Azure', 'Azure Blob Storage', 'Container', 'https'),
  gcp('Google Cloud', 'Google Cloud Storage', 'Bucket', 'gs');

  const StorageProvider(this.label, this.storageLabel, this.bucketTerm, this.scheme);
  final String label;
  final String storageLabel;

  /// "Bucket" or "Container".
  final String bucketTerm;
  final String scheme;
}

class StorageBucket {
  const StorageBucket(this.name, {this.region, this.created, this.storageClass});
  final String name;

  /// Region / location (null when the provider does not expose it).
  final String? region;
  final DateTime? created;
  final String? storageClass;
}

/// A file or a "folder" (common prefix ending with `/`).
class StorageObject {
  const StorageObject({
    required this.bucket,
    required this.key,
    this.isFolder = false,
    this.size = -1,
    this.modified,
    this.etag,
    this.contentType,
    this.storageClass,
    this.metadata = const {},
  });

  final String bucket;
  final String key;
  final bool isFolder;
  final int size;
  final DateTime? modified;
  final String? etag;
  final String? contentType;
  final String? storageClass;
  final Map<String, String> metadata;

  /// Last path segment, without the trailing `/` of folders.
  String get name {
    final k = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
    final i = k.lastIndexOf('/');
    return i < 0 ? k : k.substring(i + 1);
  }

  /// Parent prefix (with trailing `/`, empty at the root).
  String get parent {
    final k = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
    final i = k.lastIndexOf('/');
    return i < 0 ? '' : k.substring(0, i + 1);
  }

  String get extension {
    final n = name;
    final i = n.lastIndexOf('.');
    return i <= 0 ? '' : n.substring(i + 1).toLowerCase();
  }
}

/// One page of a listing.
class StorageListPage {
  const StorageListPage({this.folders = const [], this.files = const [], this.continuation});
  final List<StorageObject> folders;
  final List<StorageObject> files;

  /// Token for the next page, null when the listing is complete.
  final String? continuation;
}

abstract class ObjectStorage {
  StorageProvider get provider;

  /// Lists buckets / containers (with their region when available).
  Future<List<StorageBucket>> listBuckets();

  /// Lists [prefix] with the `/` delimiter (one level) or recursively when
  /// [delimiter] is null.
  Future<StorageListPage> list(
    String bucket, {
    String prefix = '',
    String? delimiter = '/',
    String? continuation,
    int maxResults = 1000,
  });

  Future<StorageObject> stat(String bucket, String key);

  /// Streams the object to [target] (written to a `.part` file first).
  Future<void> download(String bucket, String key, File target, {ProgressCallback? onProgress, CancelToken? cancel});

  /// Uploads [source]; large files use multipart uploads / blocks /
  /// resumable sessions.
  Future<void> upload(
    String bucket,
    String key,
    File source, {
    String? contentType,
    ProgressCallback? onProgress,
    CancelToken? cancel,
  });

  /// Writes a small object from memory.
  Future<void> putBytes(String bucket, String key, List<int> data, {String? contentType});

  Future<void> delete(String bucket, String key);

  /// Server side copy.
  Future<void> copy(String bucket, String key, String destBucket, String destKey);

  /// Temporary read link (presigned URL / SAS / signed URL).
  Future<Uri> shareLink(String bucket, String key, Duration expires);

  /// Whether [shareLink] can work with the configured credential.
  bool get canShare => true;

  /// Native URI (s3://bucket/key, gs://bucket/key, https://account.blob…).
  String uri(String bucket, String key);

  /// First [maxBytes] of the object as bytes (ranged GET).
  Future<List<int>> readBytes(String bucket, String key, {int maxBytes = 1 << 20});

  // -------------------------------------------------------------------------
  // Derived operations
  // -------------------------------------------------------------------------

  Future<String> readText(String bucket, String key, {int maxBytes = 1 << 20}) async =>
      decodeUtf8Prefix(await readBytes(bucket, key, maxBytes: maxBytes));

  /// Every object under [prefix] (recursive).
  Future<List<StorageObject>> listAll(String bucket, String prefix, {CancelToken? cancel}) async {
    final out = <StorageObject>[];
    String? token;
    do {
      cancel?.throwIfCancelled();
      final page = await list(bucket, prefix: prefix, delimiter: null, continuation: token);
      out.addAll(page.files);
      token = page.continuation;
    } while (token != null);
    return out;
  }

  /// Zero-byte object whose key ends with `/` (console-style folder).
  Future<void> createFolder(String bucket, String prefix) =>
      putBytes(bucket, prefix.endsWith('/') ? prefix : '$prefix/', const [], contentType: 'application/x-directory');

  /// Deletes an object, or every object under a folder prefix.
  Future<int> deleteRecursive(String bucket, String key, {CancelToken? cancel}) async {
    if (!key.endsWith('/')) {
      await delete(bucket, key);
      return 1;
    }
    final all = await listAll(bucket, key, cancel: cancel);
    var n = 0;
    for (final o in all) {
      cancel?.throwIfCancelled();
      await delete(bucket, o.key);
      n++;
    }
    // The folder marker may not be returned by some listings.
    if (!all.any((o) => o.key == key)) {
      try {
        await delete(bucket, key);
      } catch (_) {}
    }
    return n;
  }

  /// Copy + delete (object stores have no rename). Folders move every object.
  Future<void> rename(String bucket, String key, String newKey, {CancelToken? cancel}) async {
    if (!key.endsWith('/')) {
      await copy(bucket, key, bucket, newKey);
      await delete(bucket, key);
      return;
    }
    final dest = newKey.endsWith('/') ? newKey : '$newKey/';
    for (final o in await listAll(bucket, key, cancel: cancel)) {
      cancel?.throwIfCancelled();
      final target = dest + o.key.substring(key.length);
      await copy(bucket, o.key, bucket, target);
      await delete(bucket, o.key);
    }
  }

  void close() {}
}

/// UTF-8 decoding tolerant to a multi-byte character cut by a ranged read.
String decodeUtf8Prefix(List<int> bytes) {
  var end = bytes.length;
  for (var i = bytes.length - 1; i >= 0 && i >= bytes.length - 4; i--) {
    final b = bytes[i];
    if (b & 0xC0 == 0x80) continue;
    final need = b >= 0xF0
        ? 4
        : b >= 0xE0
        ? 3
        : b >= 0xC0
        ? 2
        : 1;
    if (bytes.length - i < need) end = i;
    break;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

// ---------------------------------------------------------------------------
// Transfer helpers shared by the implementations
// ---------------------------------------------------------------------------

/// Writes a streamed response to [target] through a temporary `.part` file.
Future<void> saveResponse(
  http.StreamedResponse r,
  File target, {
  ProgressCallback? onProgress,
  CancelToken? cancel,
}) async {
  final total = r.contentLength ?? -1;
  final part = File('${target.path}.part');
  await part.parent.create(recursive: true);
  final sink = part.openWrite();
  var done = 0;
  try {
    await for (final chunk in r.stream) {
      if (cancel?.isCancelled ?? false) throw CancelledException();
      sink.add(chunk);
      done += chunk.length;
      onProgress?.call(done, total);
    }
    await sink.flush();
    await sink.close();
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  } on http.RequestAbortedException {
    await sink.close();
    if (await part.exists()) await part.delete();
    throw CancelledException();
  } catch (_) {
    await sink.close();
    if (await part.exists()) await part.delete();
    rethrow;
  }
}

/// Sends [length] bytes of [file] from [start] as the request body.
Future<http.StreamedResponse> sendFileRange(
  String method,
  Uri url,
  Map<String, String> headers,
  File file, {
  int start = 0,
  required int length,
  ProgressCallback? onProgress,
  int progressBase = 0,
  int progressTotal = -1,
  CancelToken? cancel,
}) async {
  final req = http.AbortableStreamedRequest(method, url, abortTrigger: cancel?.whenCancelled);
  req.headers.addAll(headers);
  req.contentLength = length;
  final responseF = sendRequest(req, cancel: cancel);
  var sent = 0;
  unawaited(() async {
    try {
      await for (final chunk in file.openRead(start, start + length)) {
        if (cancel?.isCancelled ?? false) break;
        req.sink.add(chunk);
        sent += chunk.length;
        onProgress?.call(progressBase + sent, progressTotal);
      }
    } catch (e) {
      req.sink.addError(e);
    } finally {
      await req.sink.close();
    }
  }());
  return responseF;
}

/// Reads a whole response body and throws a [CloudException] on errors.
Future<http.Response> checkResponse(http.StreamedResponse s, {String? operation}) async {
  final r = await http.Response.fromStream(s);
  if (r.statusCode < 200 || r.statusCode >= 300) throw responseError(r, r.text, operation: operation);
  return r;
}

/// Content type from the file extension.
String guessContentType(String name) {
  final i = name.lastIndexOf('.');
  final ext = i < 0 ? '' : name.substring(i + 1).toLowerCase();
  return switch (ext) {
    'csv' => 'text/csv',
    'tsv' => 'text/tab-separated-values',
    'txt' || 'log' => 'text/plain',
    'sql' => 'application/sql',
    'json' => 'application/json',
    'jsonl' || 'ndjson' => 'application/x-ndjson',
    'xml' => 'application/xml',
    'html' || 'htm' => 'text/html',
    'md' => 'text/markdown',
    'yaml' || 'yml' => 'application/yaml',
    'parquet' => 'application/vnd.apache.parquet',
    'avro' => 'application/avro',
    'gz' => 'application/gzip',
    'zip' => 'application/zip',
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'svg' => 'image/svg+xml',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    _ => 'application/octet-stream',
  };
}
