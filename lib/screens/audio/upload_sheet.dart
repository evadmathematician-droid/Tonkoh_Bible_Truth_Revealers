import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_manager.dart';
import '../../cloudinary/cloudinary_upload.dart';

enum MediaKind { audio, image, video }
enum UploadStatus { queued, uploading, done, failed }

class QueuedMedia {
  final String localId;
  final PlatformFile file;
  final MediaKind kind;
  int progress;
  UploadStatus status;

  QueuedMedia({
    required this.file,
    required this.kind,
    this.progress = 0,
    this.status = UploadStatus.queued,
  }) : localId = const Uuid().v4();
}

String generateTitle(String description) {
  final trimmed = description.trim();
  if (trimmed.isEmpty) return 'Untitled';
  return trimmed.length > 40 ? '${trimmed.substring(0, 40)}...' : trimmed;
}

/// Quick pick menu — tapping the upload button shows this directly instead
/// of navigating to a whole separate screen with its own three buttons.
/// Each option opens the system file picker for that kind immediately.
Future<void> showUploadPickMenu(BuildContext screenContext) async {
  await showModalBottomSheet(
    context: screenContext,
    builder: (sheetContext) {
      Widget option(IconData icon, String label, MediaKind kind) {
        return InkWell(
          onTap: () async {
            // Close the pick menu, then run the picker + confirm sheet on the
            // SCREEN's context — not this sheet's. The old code used the
            // (now-popped) sheet context, so after the file picker returned
            // `context.mounted` was already false and the confirm sheet was
            // silently never shown: picked files just vanished.
            Navigator.pop(sheetContext);
            if (!screenContext.mounted) return;
            await _pickAndShowConfirm(screenContext, kind);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(radius: 28, backgroundColor: const Color(0xFF365DDB), child: Icon(icon, color: Colors.white)),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        );
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              option(Icons.audiotrack_outlined, 'Audio', MediaKind.audio),
              option(Icons.image_outlined, 'Image', MediaKind.image),
              option(Icons.videocam_outlined, 'Video', MediaKind.video),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _pickAndShowConfirm(BuildContext context, MediaKind kind) async {
  final type = switch (kind) {
    MediaKind.audio => FileType.audio,
    MediaKind.image => FileType.image,
    MediaKind.video => FileType.video,
  };

  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      type: type,
      allowMultiple: true,
      // Native gives a real file path (streamed to Cloudinary in _uploadOne);
      // only web needs the bytes loaded.
      withData: kIsWeb,
    );
  } catch (e) {
    debugPrint('upload picker failed: $e');
    if (context.mounted) {
      _snack(context,
          "Couldn't open the file picker — check storage permission and try again.");
    }
    return;
  }

  // User backed out without choosing anything — not an error.
  if (result == null) return;

  // Keep only files we can actually upload (has a path, or bytes on web).
  final usable = result.files
      .where((f) => kIsWeb ? f.bytes != null : (f.path?.isNotEmpty ?? false))
      .toList();

  if (usable.isEmpty) {
    if (context.mounted) {
      _snack(
          context,
          result.files.isEmpty
              ? 'No file selected.'
              : "Couldn't read the selected file(s) — try picking from a different folder.");
    }
    return;
  }

  final queue = usable.map((f) => QueuedMedia(file: f, kind: kind)).toList();
  if (!context.mounted) return;
  await showUploadConfirmSheet(context, initialQueue: queue);
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Description-required confirmation sheet, shown right after file(s) are
/// picked. Same validation (description required, at least one file) and
/// same destination (sermons/pending/{id}, status "pending" — the admin
/// approval screen reads from there already) as the old full-screen
/// UploadAudioScreen, just presented as a bottom sheet instead of a
/// screen transition.
Future<void> showUploadConfirmSheet(BuildContext context, {required List<QueuedMedia> initialQueue}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _UploadConfirmSheet(initialQueue: initialQueue),
  );
}

class _UploadConfirmSheet extends StatefulWidget {
  final List<QueuedMedia> initialQueue;
  const _UploadConfirmSheet({required this.initialQueue});

  @override
  State<_UploadConfirmSheet> createState() => _UploadConfirmSheetState();
}

class _UploadConfirmSheetState extends State<_UploadConfirmSheet> {
  late final List<QueuedMedia> _queue = List.of(widget.initialQueue);
  final _descriptionController = TextEditingController();
  bool _isUploading = false;

  String? _currentUid;
  String _currentSenderName = '';
  String _currentSenderPhone = '';

  @override
  void initState() {
    super.initState();
    _loadSenderProfile();
  }

  Future<void> _loadSenderProfile() async {
    await AuthManager.ensureSignedIn(
      onReady: () async {
        final cached = await AuthManager.getCachedProfile();
        if (cached == null) return;
        if (!mounted) return;
        setState(() {
          _currentUid = cached.uid;
          _currentSenderName = cached.name;
          _currentSenderPhone = cached.phone;
        });
      },
      onError: (_) {},
    );
  }

  void _updateItem(String localId, void Function(QueuedMedia) transform) {
    if (!mounted) return;
    setState(() {
      final item = _queue.firstWhere((q) => q.localId == localId);
      transform(item);
    });
  }

  Future<void> _uploadOne(QueuedMedia item) async {
    _updateItem(item.localId, (q) {
      q.status = UploadStatus.uploading;
      q.progress = 0;
    });

    final resourceType = cloudinaryResourceType(item.kind.name.toUpperCase());
    final path = kIsWeb ? null : item.file.path;
    final bytes = kIsWeb ? item.file.bytes : null;

    if (path == null && bytes == null) {
      _updateItem(item.localId, (q) => q.status = UploadStatus.failed);
      return;
    }

    final completer = Completer<void>();

    await uploadAudioToCloudinary(
      filePath: path,
      fileBytes: bytes,
      fileName: item.file.name,
      resourceType: resourceType,
      onProgress: (percent) {
        _updateItem(item.localId, (q) => q.progress = percent);
      },
      onSuccess: (url) async {
        final id = const Uuid().v4();
        final data = {
          'id': id,
          'title': generateTitle(_descriptionController.text),
          'description': _descriptionController.text,
          'audioUrl': url,
          'mediaType': item.kind.name.toUpperCase(),
          'uploadedBy': _currentSenderName.isEmpty ? 'user' : _currentSenderName,
          'status': 'pending',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'senderId': _currentUid ?? '',
          'senderName': _currentSenderName,
          'senderPhone': _currentSenderPhone,
        };

        try {
          await FirebaseDatabase.instance.ref('sermons').child('pending').child(id).set(data);
          _updateItem(item.localId, (q) {
            q.status = UploadStatus.done;
            q.progress = 100;
          });
        } catch (_) {
          _updateItem(item.localId, (q) => q.status = UploadStatus.failed);
        }
        completer.complete();
      },
      onError: (_) {
        _updateItem(item.localId, (q) => q.status = UploadStatus.failed);
        completer.complete();
      },
    );

    return completer.future;
  }

  Future<void> _startUploadQueue() async {
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      _showSnack('No internet connection. Please check your network and try again.');
      return;
    }

    if (_descriptionController.text.trim().isEmpty) {
      _showSnack('Please enter a description');
      return;
    }

    final toUpload = _queue.where((q) => q.status == UploadStatus.queued || q.status == UploadStatus.failed).toList();
    if (toUpload.isEmpty) return;

    setState(() => _isUploading = true);

    for (final item in toUpload) {
      await _uploadOne(item);
    }

    if (!mounted) return;
    setState(() => _isUploading = false);

    final failedCount = _queue.where((q) => q.status == UploadStatus.failed).length;
    if (failedCount == 0) {
      _showSnack('Submitted for approval ✅');
      Navigator.of(context).pop();
    } else {
      _showSnack('$failedCount upload(s) failed — check your network and retry');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              const Text(
                'Add a description',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF2346A0)),
              ),
              const SizedBox(height: 12),
              if (_queue.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _queue.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = _queue[index];
                      Color bg;
                      switch (item.status) {
                        case UploadStatus.done:
                          bg = const Color(0xFFE8F5E9);
                          break;
                        case UploadStatus.failed:
                          bg = const Color(0xFFFFEBEE);
                          break;
                        default:
                          bg = const Color(0xFFF0F3FF);
                      }
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Chip(label: Text(item.kind.name, style: const TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact),
                                const SizedBox(width: 6),
                                Expanded(child: Text(item.file.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                if (item.status == UploadStatus.queued)
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 16),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                    onPressed: () => setState(() => _queue.removeAt(index)),
                                  ),
                              ],
                            ),
                            if (item.status == UploadStatus.uploading)
                              LinearProgressIndicator(value: item.progress / 100)
                            else if (item.status == UploadStatus.done)
                              const Text('✔ Uploaded', style: TextStyle(fontSize: 12, color: Color(0xFF2E7D32)))
                            else if (item.status == UploadStatus.failed)
                              const Text('✖ Failed — will retry on Submit', style: TextStyle(fontSize: 12, color: Color(0xFFC62828)))
                            else
                              const Text('Ready', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                minLines: 4,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: 'Description (required)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _isUploading || _queue.isEmpty ? null : _startUploadQueue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF9800),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(
                    _isUploading
                        ? 'Uploading ${_queue.where((q) => q.status == UploadStatus.done).length}/${_queue.length}…'
                        : 'Submit for approval',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
