import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'resumable_downloader.dart';

/// Play Store listing for the app (package id `com.tbtrapp`). A recipient
/// who doesn't have the app lands here.
const String kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.tbtrapp';

const String kShareTagline =
    "Shared from Tonkoh Bible Truth Revealers.\n"
    "Don't have the app? Get it here: $kPlayStoreUrl";

/// Central place for "share to WhatsApp / social" actions.
class ShareService {
  ShareService._();
  static final ShareService instance = ShareService._();

  /// share_plus silently no-ops (or throws) if `share()` is called again
  /// while a previous sheet is still resolving — a fast double-tap on a
  /// share icon then feels "dead". This gate drops the second call.
  bool _sharing = false;

  Future<T?> _guard<T>(Future<T> Function() body) async {
    if (_sharing) return null;
    _sharing = true;
    try {
      return await body();
    } catch (e) {
      // A thrown share (no activity, user backgrounded mid-open, etc.) must
      // not crash the caller — just log it.
      // ignore: avoid_print
      print('ShareService: share failed: $e');
      return null;
    } finally {
      _sharing = false;
    }
  }

  Future<File> _tmp(String name) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/tbtr_share_$name');
  }

  /// The app icon written to a temp file — prepared once per process, then
  /// reused so a share doesn't re-load the asset and re-write the file on
  /// every tap.
  XFile? _cachedIconFile;

  Future<XFile?> _appIconFile() async {
    if (_cachedIconFile != null && await File(_cachedIconFile!.path).exists()) {
      return _cachedIconFile;
    }
    try {
      final bytes = await rootBundle.load('assets/icon/icon.png');
      final f = await _tmp('app_icon.png');
      await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return _cachedIconFile = XFile(f.path, mimeType: 'image/png');
    } catch (_) {
      return null;
    }
  }

  /// Small best-effort fetch (thumbnails, legacy image URLs) streamed to a
  /// temp file. [timeout] caps how long a share is willing to wait on it —
  /// a slow thumbnail must never hold up the share sheet.
  Future<File?> _download(
    String url,
    String filename, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final f = await _tmp(filename);
      await Dio().download(url, f.path).timeout(timeout);
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// Share a video.
  ///
  /// Speed is the whole point here: the previous version re-downloaded the
  /// entire video into memory (`ResponseType.bytes`) on every tap, even when
  /// the exact file was already cached on disk, with no on-screen feedback —
  /// so a big video felt frozen for a long time. Now:
  ///  * an already-cached copy (played / downloaded before, keyed by
  ///    [cacheKey]) is shared immediately;
  ///  * otherwise the shared download is streamed to disk and **resumable**,
  ///    and reuses an in-flight download rather than starting a second one
  ///    (`ResumableDownloader.ensureComplete`);
  ///  * the poster-frame thumbnail is best-effort with a short timeout — it
  ///    never blocks the sheet;
  ///  * if no file can be prepared, it falls back to the app link instead of
  ///    opening an empty sheet.
  ///
  /// Callers that have a Scaffold should still show their own "Preparing…"
  /// feedback before calling this for an uncached video.
  Future<void> shareVideo({
    required String title,
    String? cacheKey,
    String? localFilePath,
    String? remoteUrl,
    String? thumbnailUrl,
  }) async {
    await _guard(() async {
      File? video;

      if (localFilePath != null && await File(localFilePath).exists()) {
        video = File(localFilePath);
      } else if (cacheKey != null && cacheKey.isNotEmpty) {
        video =
            await ResumableDownloader.instance.completedFile(cacheKey, '.mp4');
        if (video == null &&
            remoteUrl != null &&
            remoteUrl.startsWith('http')) {
          video = await ResumableDownloader.instance
              .ensureComplete(cacheKey, remoteUrl, ext: '.mp4');
        }
      } else if (remoteUrl != null && remoteUrl.startsWith('http')) {
        video = await _download(remoteUrl, 'video.mp4',
            timeout: const Duration(minutes: 5));
      }

      if (video == null) {
        // Couldn't get the file — share the app link rather than nothing.
        final icon = await _appIconFile();
        await SharePlus.instance.share(ShareParams(
          text: title.isEmpty ? kShareTagline : '$title\n\n$kShareTagline',
          subject: title.isEmpty ? 'Tonkoh Bible Truth Revealers' : title,
          files: icon == null ? null : [icon],
        ));
        return;
      }

      XFile? thumb;
      if (thumbnailUrl != null && thumbnailUrl.startsWith('http')) {
        final t = await _download(thumbnailUrl, 'thumb.jpg',
            timeout: const Duration(seconds: 3));
        if (t != null) thumb = XFile(t.path, mimeType: 'image/jpeg');
      }

      await SharePlus.instance.share(ShareParams(
        text: title.isEmpty ? kShareTagline : '$title\n\n$kShareTagline',
        subject: title.isEmpty ? 'Tonkoh Bible Truth Revealers' : title,
        files: [XFile(video.path, mimeType: 'video/mp4')],
        previewThumbnail: thumb,
      ));
    });
  }

  /// Share the app itself — icon image + Play Store link. Used as the
  /// fallback when an audio file can't be prepared.
  Future<void> shareApp({String? message}) async {
    await _guard(() async {
      final icon = await _appIconFile();
      final text = message == null || message.isEmpty
          ? kShareTagline
          : '$message\n\n$kShareTagline';

      await SharePlus.instance.share(ShareParams(
        text: text,
        subject: 'Tonkoh Bible Truth Revealers',
        files: icon == null ? null : [icon],
        previewThumbnail: icon,
      ));
    });
  }

  /// Share an already-downloaded audio file (the sermon mp3 on disk) plus
  /// the app link. The file path must be a completed local copy — callers
  /// are responsible for the on-demand download + user feedback before
  /// getting here.
  Future<void> shareAudioFile({
    required String filePath,
    String? title,
  }) async {
    await _guard(() async {
      final f = File(filePath);
      if (!await f.exists()) {
        // Shouldn't happen, but never open an empty share sheet.
        final icon = await _appIconFile();
        await SharePlus.instance.share(ShareParams(
          text: (title == null || title.isEmpty)
              ? kShareTagline
              : '$title\n\n$kShareTagline',
          files: icon == null ? null : [icon],
        ));
        return;
      }
      await SharePlus.instance.share(ShareParams(
        text: (title == null || title.isEmpty)
            ? kShareTagline
            : '$title\n\n$kShareTagline',
        subject: title ?? 'Tonkoh Bible Truth Revealers',
        files: [XFile(f.path, mimeType: 'audio/mpeg')],
      ));
    });
  }

  /// Share an image — the file itself when it can be fetched, plus the
  /// app link.
  Future<void> shareImage({String? url, List<int>? bytes}) async {
    XFile? file;
    if (bytes != null) {
      final f = await _tmp('image.jpg');
      await f.writeAsBytes(bytes, flush: true);
      file = XFile(f.path, mimeType: 'image/jpeg');
    } else if (url != null && url.startsWith('http')) {
      final f = await _download(url, 'image.jpg');
      if (f != null) file = XFile(f.path, mimeType: 'image/jpeg');
    }
    await SharePlus.instance.share(ShareParams(
      text: kShareTagline,
      files: file == null ? null : [file],
      previewThumbnail: file,
    ));
  }

  /// Plain text/link share (used for legacy items with no media file).
  Future<void> shareText(String text) => SharePlus.instance.share(
      ShareParams(text: '$text\n\n$kShareTagline'));

  /// Invite a device contact who isn't on the app yet — opens the native
  /// share sheet (SMS, WhatsApp, etc.) pre-filled with an invite + the
  /// Play Store link.
  Future<void> inviteToApp({String? name}) async {
    final greeting =
        (name != null && name.trim().isNotEmpty) ? 'Hi ${name.trim()}, ' : '';
    await SharePlus.instance.share(ShareParams(
      text: "${greeting}join me on Tonkoh Bible Truth Revealers — Gospel "
          "audio, discussions and calls.\n\nGet it here: $kPlayStoreUrl",
      subject: 'Join me on Tonkoh Bible Truth Revealers',
    ));
  }
}
