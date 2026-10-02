import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

/// Pan / zoom-to-square crop step, pure Flutter (no crop plugin).
///
/// The picked image fills a square viewport (`BoxFit.cover`) inside an
/// [InteractiveViewer]; the user drags / pinches to frame it, and
/// "Use photo" rasterises exactly what's inside the square to a PNG file
/// which the caller then hands to `AuthManager.saveProfileWithPhoto`.
///
/// Push it with `Navigator.push<String>(...)`; it pops the cropped file
/// path, or null if the user backs out.
class SquareCropScreen extends StatefulWidget {
  final String imagePath;

  const SquareCropScreen({super.key, required this.imagePath});

  @override
  State<SquareCropScreen> createState() => _SquareCropScreenState();
}

class _SquareCropScreenState extends State<SquareCropScreen> {
  static const _accent = Color(0xFF102A72);

  // Longest edge of the exported crop. Kept modest so the resulting Base64
  // stays under AuthManager's 600 KB cap.
  static const double _outputPx = 400;

  final _boundaryKey = GlobalKey();
  final _controller = TransformationController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _usephoto() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final pixelRatio =
          (_outputPx / boundary.size.width).clamp(1.0, 4.0).toDouble();
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) throw StateError('Could not encode the crop');

      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/profile_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());

      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Crop failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Move and scale'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = constraints.biggest.shortestSide - 32;
                  return RepaintBoundary(
                    key: _boundaryKey,
                    child: ClipRect(
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: InteractiveViewer(
                          transformationController: _controller,
                          minScale: 1,
                          maxScale: 5,
                          clipBehavior: Clip.hardEdge,
                          child: Image.file(
                            File(widget.imagePath),
                            width: side,
                            height: side,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _usephoto,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
