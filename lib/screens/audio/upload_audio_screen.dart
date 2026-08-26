import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
// top of file
import 'package:flutter/foundation.dart' show kIsWeb;
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

// ⚠️ ASSUMPTION: I don't have the Kotlin generateTitle() implementation,
// so this is a simple stand-in — first ~40 chars of the description, or
// "Untitled" if blank. Paste generateTitle's real Kotlin source if you
// want an exact port instead.
String generateTitle(String description) {
  final trimmed = description.trim();
  if (trimmed.isEmpty) return 'Untitled';
  return trimmed.length > 40 ? '${trimmed.substring(0, 40)}...' : trimmed;
}

class UploadAudioScreen extends StatefulWidget {
  const UploadAudioScreen({super.key});

  @override
  State<UploadAudioScreen> createState() => _UploadAudioScreenState();
}

class _UploadAudioScreenState extends State<UploadAudioScreen> {
  final List<QueuedMedia> _queue = [];
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
        if (cached == null) return; // no profile yet — AuthGate handles that case elsewhere
        setState(() {
          _currentUid = cached.uid;
          _currentSenderName = cached.name;
          _currentSenderPhone = cached.phone;
        });
      },
      onError: (_) {},
    );
  }

  Future<void> _pick(MediaKind kind) async {
    FileType type;
    switch (kind) {
      case MediaKind.audio:
        type = FileType.audio;
        break;
      case MediaKind.image:
        type = FileType.image;
        break;
      case MediaKind.video:
        type = FileType.video;
        break;
    }

    // file_picker 12.x: FilePicker.platform singleton is gone — call the
    // static method directly. pickFiles() now returns List<PlatformFile>
    // directly instead of a nullable FilePickerResult wrapper.
    final result = await FilePicker.pickFiles(type: type);
    if (result.isEmpty) return;

    setState(() {
      for (final file in result) {
        _queue.add(QueuedMedia(file: file, kind: kind));
      }
    });
  }

  void _updateItem(String localId, void Function(QueuedMedia) transform) {
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

    // Native platforms: path is populated, bytes is null.
    // Web: bytes is populated, path is null (accessing .path on web throws).
    // file_picker 12.x removed the withData/.bytes shortcut — bytes are now
    // fetched on demand via PlatformFile.readAsBytes().
    final path = kIsWeb ? null : item.file.path;
    final bytes = kIsWeb ? await item.file.readAsBytes() : null;

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
          await FirebaseDatabase.instance
              .ref('sermons')
              .child('pending')
              .child(id)
              .set(data);
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
      _showSnack('Please enter description');
      return;
    }

    final toUpload = _queue
        .where((q) => q.status == UploadStatus.queued || q.status == UploadStatus.failed)
        .toList();
    if (toUpload.isEmpty) return;

    setState(() => _isUploading = true);

    for (final item in toUpload) {
      await _uploadOne(item);
    }

    setState(() => _isUploading = false);

    final failedCount = _queue.where((q) => q.status == UploadStatus.failed).length;
    if (failedCount == 0) {
      _showSnack('All submitted for approval ✅');
      setState(() {
        _queue.clear();
        _descriptionController.clear();
      });

    } else {
      _showSnack('$failedCount upload(s) failed — check your network and retry');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF3F7FF), Colors.white],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                elevation: 10,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Upload Sermon Media',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22, color: Color(0xFF2346A0)),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Share inspiring messages professionally',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isUploading ? null : () => _pick(MediaKind.audio),
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF365DDB)),
                              child: const Text('Audio', style: TextStyle(color: Colors.white)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isUploading ? null : () => _pick(MediaKind.image),
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF365DDB)),
                              child: const Text('Image', style: TextStyle(color: Colors.white)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isUploading ? null : () => _pick(MediaKind.video),
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF365DDB)),
                              child: const Text('Video', style: TextStyle(color: Colors.white)),
                            ),
                          ),
                        ],
                      ),
                      if (_queue.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: _queue.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
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
                                        Chip(label: Text(item.kind.name, style: const TextStyle(fontSize: 10))),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(item.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    if (item.status == UploadStatus.uploading) ...[
                                      LinearProgressIndicator(value: item.progress / 100),
                                      Text('${item.progress}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                    ] else if (item.status == UploadStatus.done)
                                      const Text('✔ Uploaded', style: TextStyle(fontSize: 12, color: Color(0xFF2E7D32)))
                                    else if (item.status == UploadStatus.failed)
                                        const Text('✖ Failed — will retry on Submit', style: TextStyle(fontSize: 12, color: Color(0xFFC62828)))
                                      else
                                        const Text('Waiting…', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      TextField(
                        controller: _descriptionController,
                        minLines: 6,
                        maxLines: null,
                        decoration: InputDecoration(
                          labelText: 'Sermon Description',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 58,
                        child: ElevatedButton(
                          onPressed: _isUploading
                              ? null
                              : () {
                            if (_queue.isEmpty) {
                              _showSnack('Please select a file');
                              return;
                            }
                            _startUploadQueue();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF9800),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          child: Text(
                            _isUploading
                                ? 'Uploading ${_queue.where((q) => q.status == UploadStatus.done).length}/${_queue.length}…'
                                : 'Submit Sermon(s)',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}