import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// How hard to shrink a photo before sending it.
enum ImageQuality {
  /// Longest side 1600 px, JPEG 80 — a few hundred KB.
  standard(1600, 80),

  /// Longest side 2560 px, JPEG 90.
  hd(2560, 90);

  const ImageQuality(this.maxSide, this.jpegQuality);
  final int maxSide;
  final int jpegQuality;
}

/// The width/height to pass to flutter_image_compress so the image's
/// LONGEST side ends up at most [maxSide], keeping its shape.
///
/// The plugin scales by `min(width / minWidth, height / minHeight)` and
/// never enlarges, so asking for exactly the target size of each side does
/// it. Returns null when the image is already small enough.
@visibleForTesting
({int minWidth, int minHeight})? shrinkTarget(int width, int height, int maxSide) {
  final longest = math.max(width, height);
  if (width <= 0 || height <= 0 || longest <= maxSide) return null;
  final scale = maxSide / longest;
  return (
    minWidth: math.max(1, (width * scale).round()),
    minHeight: math.max(1, (height * scale).round()),
  );
}

/// Resizes and re-encodes photos with the platform's native encoder (off the
/// UI thread), into the app's own storage so the file survives until the
/// upload is done.
class ImageShrink {
  ImageShrink._();

  static final Map<String, Future<File?>> _memo = {};

  /// A JPEG of [path] at [quality], or null if it couldn't be made (the
  /// caller then sends the original). The same (path, quality) is only
  /// worked out once — the preview's size estimate is reused by Send.
  static Future<File?> shrink(String path, ImageQuality quality) =>
      _memo.putIfAbsent('$path|${quality.name}', () => _shrink(path, quality));

  static Future<File?> _shrink(String path, ImageQuality quality) async {
    try {
      final size = await _imageSize(path);
      final target = size == null
          ? (minWidth: quality.maxSide, minHeight: quality.maxSide)
          : shrinkTarget(size.width, size.height, quality.maxSide) ??
              (minWidth: size.width, minHeight: size.height);

      final dir = Directory(p.join(
          (await getApplicationSupportDirectory()).path, 'media_outbox'));
      await dir.create(recursive: true);
      final out = p.join(dir.path,
          '${DateTime.now().microsecondsSinceEpoch}_${quality.name}.jpg');

      final result = await FlutterImageCompress.compressAndGetFile(
        path,
        out,
        minWidth: target.minWidth,
        minHeight: target.minHeight,
        quality: quality.jpegQuality,
        format: CompressFormat.jpeg,
      );
      if (result == null) return null;
      final file = File(result.path);
      // Already-compressed small photos can come out bigger; keep the
      // original then.
      final original = await File(path).length();
      if (await file.length() >= original && p.extension(path).toLowerCase() != '.heic') {
        await file.delete();
        return File(path);
      }
      return file;
    } catch (e) {
      debugPrint('ImageShrink: $path failed: $e');
      _memo.remove('$path|${quality.name}');
      return null;
    }
  }

  /// Width/height from the file header, without decoding the pixels.
  static Future<({int width, int height})?> _imageSize(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (width: descriptor.width, height: descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null; // e.g. HEIC on some phones — let the plugin decide
    }
  }

  /// Forget cached results for [path] (after it was cropped into a new file).
  static void forget(String path) =>
      _memo.removeWhere((key, _) => key.startsWith('$path|'));
}

/// "3.4 MB", "280 KB".
String formatBytes(int bytes) {
  if (bytes >= 1000 * 1000) {
    return '${(bytes / (1000 * 1000)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1000) return '${(bytes / 1000).round()} KB';
  return '$bytes B';
}
