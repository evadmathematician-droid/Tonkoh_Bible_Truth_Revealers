import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Generates the branded preview image attached when sharing audio/video/
/// image content out of the app (see ShareService). Per the "static
/// thumbnail only" decision — no video pixel/frame watermarking, no new
/// image-processing dependency: this composites purely with dart:ui
/// (Canvas + PictureRecorder), which Flutter already ships.
class ShareBrandingService {
  ShareBrandingService._();

  static const String appName = 'Tonkoh Bible Truth Revealers';
  static const Color _brandColor = Color(0xFF102A72);

  static Uint8List? _iconBytesCache;

  static Future<Uint8List> _loadIconBytes() async {
    if (_iconBytesCache != null) return _iconBytesCache!;
    final data = await rootBundle.load('assets/icon/icon.jpeg');
    _iconBytesCache = data.buffer.asUint8List();
    return _iconBytesCache!;
  }

  static Future<ui.Image> _decodeImage(Uint8List bytes, {int? targetSize}) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetSize,
      targetHeight: targetSize,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Future<File> _saveImage(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/share_branded_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Overlays the app icon + app name as a header bar on top of an
  /// existing image (a sermon photo, or a Cloudinary-generated video
  /// thumbnail) — used for IMAGE and VIDEO content.
  static Future<File> buildBrandedOverlay(Uint8List baseImageBytes) async {
    final baseImage = await _decodeImage(baseImageBytes);
    final iconImage = await _loadIconBytes().then((b) => _decodeImage(b, targetSize: 128));

    final w = baseImage.width.toDouble();
    final h = baseImage.height.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    canvas.drawImage(baseImage, Offset.zero, Paint());

    // Semi-transparent header bar keeps the icon+name legible over any
    // photo/video-frame regardless of its own colors.
    final barHeight = (h * 0.14).clamp(48.0, 140.0);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, barHeight),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    final iconSize = barHeight * 0.66;
    final iconOffset = Offset(w * 0.03, (barHeight - iconSize) / 2);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(
      Rect.fromLTWH(iconOffset.dx, iconOffset.dy, iconSize, iconSize),
      Radius.circular(iconSize / 2),
    ));
    canvas.drawImageRect(
      iconImage,
      Rect.fromLTWH(0, 0, iconImage.width.toDouble(), iconImage.height.toDouble()),
      Rect.fromLTWH(iconOffset.dx, iconOffset.dy, iconSize, iconSize),
      Paint(),
    );
    canvas.restore();

    final textPainter = TextPainter(
      text: TextSpan(
        text: appName,
        style: TextStyle(
          color: Colors.white,
          fontSize: (barHeight * 0.28).clamp(12.0, 26.0),
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: w - iconOffset.dx - iconSize - (w * 0.06));
    textPainter.paint(
      canvas,
      Offset(iconOffset.dx + iconSize + (w * 0.03), (barHeight - textPainter.height) / 2),
    );

    final picture = recorder.endRecording();
    final composited = await picture.toImage(baseImage.width, baseImage.height);
    return _saveImage(composited);
  }

  /// Standalone branded card for content with no visual source (AUDIO):
  /// brand background + app icon + app name + track title.
  static Future<File> buildBrandedCard({required String title}) async {
    const size = 900.0;
    final iconImage = await _loadIconBytes().then((b) => _decodeImage(b, targetSize: 260));

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = _brandColor);

    const iconSize = 200.0;
    const iconRect = Rect.fromLTWH((size - iconSize) / 2, 160, iconSize, iconSize);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(iconRect, const Radius.circular(36)));
    canvas.drawImageRect(
      iconImage,
      Rect.fromLTWH(0, 0, iconImage.width.toDouble(), iconImage.height.toDouble()),
      iconRect,
      Paint(),
    );
    canvas.restore();

    void paintCenteredText(String text, double y, double fontSize, {FontWeight weight = FontWeight.normal}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 3,
        ellipsis: '…',
      )..layout(maxWidth: size - 100);
      tp.paint(canvas, Offset((size - tp.width) / 2, y));
    }

    paintCenteredText(appName, 400, 40, weight: FontWeight.bold);
    paintCenteredText(title.isEmpty ? 'Untitled' : title, 480, 26);
    paintCenteredText('🎧 Listen in the app', 720, 24);

    final picture = recorder.endRecording();
    final composited = await picture.toImage(size.toInt(), size.toInt());
    return _saveImage(composited);
  }
}
