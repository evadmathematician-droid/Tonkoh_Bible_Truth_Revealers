import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../chat_media/chat_media_sender.dart';
import '../../util/image_shrink.dart';

/// Most photos / videos sent together.
const chatMaxMediaPerSend = 10;

bool isVideoPath(String path) => const {
      '.mp4', '.mov', '.mkv', '.3gp', '.webm', '.m4v'
    }.contains(p.extension(path).toLowerCase());

class _Item {
  _Item(this.path) : isVideo = isVideoPath(path);
  String path;
  final bool isVideo;
  final caption = TextEditingController();
}

/// WhatsApp-style "check before you send": large preview, a strip of
/// everything picked (remove, add more), crop & rotate, Standard / HD with
/// the size it will be, and a caption per item. Nothing is sent until
/// Send; closing asks before throwing the selection away.
///
/// Pops with the [OutgoingMedia] to send, or null.
class MediaPreviewScreen extends StatefulWidget {
  const MediaPreviewScreen({super.key, required this.paths, this.recipient = ''});

  final List<String> paths;

  /// Shown in the caption hint ("Add a caption for …").
  final String recipient;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  late final List<_Item> _items = [for (final path in widget.paths) _Item(path)];
  final _pages = PageController();
  int _current = 0;
  ImageQuality _quality = ImageQuality.standard;
  String? _estimate;
  int _estimateToken = 0;

  @override
  void initState() {
    super.initState();
    _updateEstimate();
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final i in _items) {
      i.caption.dispose();
    }
    super.dispose();
  }

  _Item get _item => _items[_current];

  Future<void> _updateEstimate() async {
    final token = ++_estimateToken;
    if (_items.isEmpty) return;
    final item = _item;
    setState(() => _estimate = null);
    final original = await File(item.path).length().catchError((_) => 0);
    if (item.isVideo) {
      if (mounted && token == _estimateToken) {
        setState(() => _estimate = formatBytes(original));
      }
      return;
    }
    final small = await ImageShrink.shrink(item.path, _quality);
    final after = small == null ? original : await small.length();
    if (!mounted || token != _estimateToken) return;
    setState(() => _estimate = '${formatBytes(original)} → ${formatBytes(after)}');
  }

  void _select(int index) {
    if (index == _current) return;
    setState(() => _current = index);
    _pages.jumpToPage(index);
    _updateEstimate();
  }

  void _remove(int index) {
    final removed = _items.removeAt(index);
    removed.caption.dispose();
    if (_items.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _current = _current.clamp(0, _items.length - 1));
    _pages.jumpToPage(_current);
    _updateEstimate();
  }

  Future<void> _addMore() async {
    final room = chatMaxMediaPerSend - _items.length;
    if (room <= 0) {
      _snack('You can send up to $chatMaxMediaPerSend at a time.');
      return;
    }
    try {
      final picker = ImagePicker();
      final picked = room == 1
          ? [if (await picker.pickMedia() case final f?) f]
          : await picker.pickMultipleMedia(limit: room);
      if (!mounted || picked.isEmpty) return;
      setState(() => _items.addAll(picked.take(room).map((f) => _Item(f.path))));
      if (picked.length > room) {
        _snack('You can send up to $chatMaxMediaPerSend at a time.');
      }
    } catch (e) {
      _snack("Couldn't open your gallery: $e");
    }
  }

  Future<void> _crop() async {
    final item = _item;
    if (item.isVideo) return;
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: item.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 95,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop & rotate',
            toolbarColor: Colors.black,
            toolbarWidgetColor: Colors.white,
            statusBarLight: false,
            backgroundColor: Colors.black,
            activeControlsWidgetColor: const Color(0xFF25D366),
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
            aspectRatioPresets: const [
              CropAspectRatioPreset.original,
              CropAspectRatioPreset.square,
              CropAspectRatioPreset.ratio4x3,
              CropAspectRatioPreset.ratio16x9,
            ],
          ),
          IOSUiSettings(title: 'Crop & rotate'),
        ],
      );
      if (cropped == null || !mounted) return;
      ImageShrink.forget(item.path);
      setState(() => item.path = cropped.path);
      _updateEstimate();
    } catch (e) {
      _snack("Couldn't open the editor: $e");
    }
  }

  void _send() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop([
      for (final i in _items)
        OutgoingMedia(
          path: i.path,
          isVideo: i.isVideo,
          caption: i.caption.text,
          quality: _quality,
        ),
    ]);
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(_items.length == 1
            ? 'Discard selected media?'
            : 'Discard ${_items.length} selected items?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return discard == true;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final item = _item;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: IconButton(
            tooltip: 'Discard',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.maybePop(context),
          ),
          actions: [
            if (!item.isVideo)
              IconButton(
                tooltip: 'Crop & rotate',
                icon: const Icon(Icons.crop_rotate),
                onPressed: _crop,
              ),
            PopupMenuButton<ImageQuality>(
              tooltip: 'Quality',
              initialValue: _quality,
              onSelected: (q) {
                setState(() => _quality = q);
                _updateEstimate();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: ImageQuality.standard,
                    child: Text('Standard (recommended)')),
                PopupMenuItem(value: ImageQuality.hd, child: Text('HD')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Icon(_quality == ImageQuality.hd ? Icons.hd : Icons.sd,
                      color: Colors.white),
                  const Icon(Icons.arrow_drop_down, color: Colors.white),
                ]),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _estimate == null
                    ? (item.isVideo ? '' : 'Working out the size…')
                    : item.isVideo
                        ? 'Video · $_estimate'
                        : '${_quality == ImageQuality.hd ? 'HD' : 'Standard'} · $_estimate',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: _items.length,
                onPageChanged: (i) {
                  setState(() => _current = i);
                  _updateEstimate();
                },
                itemBuilder: (context, i) {
                  final it = _items[i];
                  return it.isVideo
                      ? _VideoFrame(key: ValueKey(it.path), path: it.path)
                      : Image.file(
                          File(it.path),
                          key: ValueKey(it.path),
                          fit: BoxFit.contain,
                          cacheWidth: (MediaQuery.sizeOf(context).width *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round(),
                          errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image,
                                  color: Colors.white54, size: 48)),
                        );
                },
              ),
            ),
            _strip(),
            _captionBar(item),
          ],
        ),
      ),
    );
  }

  Widget _strip() {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                onTap: _addMore,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 60,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white38),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add_photo_alternate_outlined,
                      color: Colors.white),
                ),
              ),
            );
          }
          final it = _items[i];
          final selected = i == _current;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => _select(i),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 60,
                    height: 64,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: selected ? const Color(0xFF25D366) : Colors.transparent,
                          width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: it.isVideo
                          ? Container(
                              color: Colors.white12,
                              child: const Icon(Icons.videocam, color: Colors.white),
                            )
                          : Image.file(File(it.path),
                              key: ValueKey(it.path),
                              fit: BoxFit.cover,
                              cacheWidth: 180,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image, color: Colors.white54)),
                    ),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: GestureDetector(
                      onTap: () => _remove(i),
                      child: const CircleAvatar(
                        radius: 11,
                        backgroundColor: Colors.black87,
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _captionBar(_Item item) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('caption-${item.path}'),
                controller: item.caption,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Add a caption…',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white12,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton(
              heroTag: 'media-send',
              backgroundColor: const Color(0xFF25D366),
              onPressed: _send,
              child: Badge(
                isLabelVisible: _items.length > 1,
                label: Text('${_items.length}'),
                child: const Icon(Icons.send, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A video's first frame with a play badge (no playback here).
class _VideoFrame extends StatefulWidget {
  const _VideoFrame({super.key, required this.path});
  final String path;

  @override
  State<_VideoFrame> createState() => _VideoFrameState();
}

class _VideoFrameState extends State<_VideoFrame> {
  late final VideoPlayerController _controller =
      VideoPlayerController.file(File(widget.path));
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_ready)
            AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: VideoPlayer(_controller),
            )
          else
            const Icon(Icons.videocam, color: Colors.white38, size: 64),
          const CircleAvatar(
            radius: 28,
            backgroundColor: Colors.black54,
            child: Icon(Icons.play_arrow, color: Colors.white, size: 32),
          ),
        ],
      ),
    );
  }
}
