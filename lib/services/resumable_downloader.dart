import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Status of a single media download.
enum DownloadStatus { idle, downloading, paused, completed, failed }

/// Immutable snapshot of one download's progress, handed to the UI.
class MediaDownload {
  final DownloadStatus status;
  final int received; // bytes on disk so far
  final int total; // -1 when the server didn't report a length
  final String? filePath; // set once status == completed

  const MediaDownload({
    this.status = DownloadStatus.idle,
    this.received = 0,
    this.total = -1,
    this.filePath,
  });

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  bool get isActive => status == DownloadStatus.downloading;
  bool get isComplete => status == DownloadStatus.completed;

  MediaDownload copyWith({
    DownloadStatus? status,
    int? received,
    int? total,
    String? filePath,
  }) {
    return MediaDownload(
      status: status ?? this.status,
      received: received ?? this.received,
      total: total ?? this.total,
      filePath: filePath ?? this.filePath,
    );
  }
}

/// Resumable, progressive HTTP downloader shared by the chat screen and
/// the audio screen.
///
/// Behaviour the app relies on:
///  * A download that is interrupted (screen closed, connection dropped,
///    data ran out) leaves a `<key><ext>.part` file on disk. The next
///    call to [start]/[resume] sends `Range: bytes=<partSize>-` and
///    appends — it never restarts from zero.
///  * The `.part` file *is* the persisted resume state, so a resume also
///    works after a full app restart.
///  * When the device regains connectivity, anything that stopped for a
///    network reason auto-resumes. A download the user explicitly paused
///    stays paused until they resume it.
///  * State per key is exposed as a [ValueListenable] so widgets can
///    rebuild on progress without the download being tied to any one
///    widget's lifecycle.
class ResumableDownloader {
  ResumableDownloader._();
  static final ResumableDownloader instance = ResumableDownloader._();

  final Dio _dio = Dio();
  final Map<String, ValueNotifier<MediaDownload>> _states = {};
  final Map<String, CancelToken> _tokens = {};
  final Map<String, String> _urls = {};
  final Map<String, String> _exts = {};
  final Set<String> _userPaused = {};

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// Live progress for [key]. Safe to call before the download starts —
  /// returns an idle snapshot that updates in place.
  ValueListenable<MediaDownload> watch(String key) => _stateOf(key);

  MediaDownload stateOf(String key) => _stateOf(key).value;

  ValueNotifier<MediaDownload> _stateOf(String key) =>
      _states.putIfAbsent(key, () => ValueNotifier(const MediaDownload()));

  Future<Directory> _mediaDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/media');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Final resting path for a completed download.
  Future<File> fileFor(String key, String ext) async =>
      File('${(await _mediaDir()).path}/$key$ext');

  Future<File> _partFor(String key, String ext) async =>
      File('${(await _mediaDir()).path}/$key$ext.part');

  /// Returns the fully-downloaded file for [key], or null if it isn't
  /// complete on disk yet.
  Future<File?> completedFile(String key, String ext) async {
    final f = await fileFor(key, ext);
    return await f.exists() ? f : null;
  }

  /// Get the completed file for [key], downloading it first if needed and
  /// waiting for an already-running download (e.g. one kicked off by
  /// playback) to finish rather than starting a second one. Returns null if
  /// the download fails. Used by "share this audio" so a tap that lands
  /// before the file is cached still ends with a real file to share.
  Future<File?> ensureComplete(String key, String url, {String ext = ''}) async {
    final existing = await completedFile(key, ext);
    if (existing != null) return existing;

    final notifier = _stateOf(key);
    if (notifier.value.status == DownloadStatus.downloading) {
      await _awaitSettled(notifier);
    } else {
      await start(key, url, ext: ext); // start() awaits the whole transfer
    }
    return completedFile(key, ext);
  }

  Future<void> _awaitSettled(ValueNotifier<MediaDownload> n) {
    bool done(DownloadStatus s) =>
        s == DownloadStatus.completed || s == DownloadStatus.failed;
    if (done(n.value.status)) return Future<void>.value();
    final completer = Completer<void>();
    void listener() {
      if (done(n.value.status)) {
        n.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      }
    }

    n.addListener(listener);
    return completer.future;
  }

  /// Begin (or continue) downloading [url] for [key]. [ext] should include
  /// the leading dot, e.g. `.mp4` / `.mp3` / `.m4a`.
  Future<void> start(String key, String url, {String ext = ''}) async {
    _urls[key] = url;
    _exts[key] = ext;
    _userPaused.remove(key);

    final notifier = _stateOf(key);
    if (notifier.value.status == DownloadStatus.downloading) return;

    _ensureConnListener();

    final finalFile = await fileFor(key, ext);
    if (await finalFile.exists()) {
      final len = await finalFile.length();
      notifier.value = MediaDownload(
        status: DownloadStatus.completed,
        received: len,
        total: len,
        filePath: finalFile.path,
      );
      return;
    }

    final part = await _partFor(key, ext);
    int existing = await part.exists() ? await part.length() : 0;

    final token = CancelToken();
    _tokens[key] = token;
    notifier.value = notifier.value.copyWith(
      status: DownloadStatus.downloading,
      received: existing,
    );

    RandomAccessFile? raf;
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: existing > 0 ? {'range': 'bytes=$existing-'} : null,
          followRedirects: true,
          validateStatus: (s) => s != null && s < 400,
        ),
        cancelToken: token,
      );

      final statusCode = response.statusCode ?? 200;
      // Asked for a range but the server ignored it (sent a fresh 200) —
      // discard the partial and start over so bytes don't get spliced.
      if (existing > 0 && statusCode == 200) {
        existing = 0;
        if (await part.exists()) await part.delete();
      }

      int total = -1;
      final contentRange = response.headers.value('content-range');
      final contentLength = int.tryParse(
              response.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
          -1;
      if (contentRange != null && contentRange.contains('/')) {
        total = int.tryParse(contentRange.split('/').last.trim()) ?? -1;
      } else if (contentLength > 0) {
        total = existing + contentLength;
      }
      notifier.value =
          notifier.value.copyWith(received: existing, total: total);

      raf = await part.open(
        mode: existing > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      int received = existing;

      await for (final chunk in response.data!.stream) {
        if (token.isCancelled) break;
        await raf.writeFrom(chunk);
        received += chunk.length;
        notifier.value =
            notifier.value.copyWith(received: received, total: total);
      }
      await _closeQuietly(raf);
      raf = null;

      if (token.isCancelled) {
        notifier.value = notifier.value.copyWith(status: DownloadStatus.paused);
        return;
      }

      await part.rename(finalFile.path);
      notifier.value = MediaDownload(
        status: DownloadStatus.completed,
        received: received,
        total: received,
        filePath: finalFile.path,
      );
    } on DioException catch (e) {
      await _closeQuietly(raf);
      if (CancelToken.isCancel(e)) {
        notifier.value = notifier.value.copyWith(status: DownloadStatus.paused);
      } else {
        notifier.value = notifier.value.copyWith(status: DownloadStatus.failed);
      }
    } catch (e) {
      await _closeQuietly(raf);
      debugPrint('ResumableDownloader[$key] failed: $e');
      notifier.value = notifier.value.copyWith(status: DownloadStatus.failed);
    } finally {
      _tokens.remove(key);
    }
  }

  Future<void> _closeQuietly(RandomAccessFile? raf) async {
    try {
      await raf?.close();
    } catch (_) {}
  }

  /// User-initiated pause — will NOT auto-resume on reconnect.
  void pause(String key) {
    _userPaused.add(key);
    _tokens[key]?.cancel('user_paused');
    _tokens.remove(key);
    final n = _states[key];
    if (n != null && n.value.status == DownloadStatus.downloading) {
      n.value = n.value.copyWith(status: DownloadStatus.paused);
    }
  }

  Future<void> resume(String key) async {
    final url = _urls[key];
    if (url == null) return;
    await start(key, url, ext: _exts[key] ?? '');
  }

  /// Drop a partially-downloaded file (e.g. the user deleted the message).
  Future<void> discard(String key) async {
    _tokens[key]?.cancel('discarded');
    _tokens.remove(key);
    final ext = _exts[key] ?? '';
    for (final f in [await _partFor(key, ext), await fileFor(key, ext)]) {
      if (await f.exists()) await f.delete();
    }
    _states.remove(key)?.dispose();
    _urls.remove(key);
    _exts.remove(key);
    _userPaused.remove(key);
  }

  void _ensureConnListener() {
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (!online) return;
      for (final entry in _states.entries.toList()) {
        final status = entry.value.value.status;
        final stalled =
            status == DownloadStatus.paused || status == DownloadStatus.failed;
        if (stalled && !_userPaused.contains(entry.key)) {
          resume(entry.key);
        }
      }
    });
  }
}
