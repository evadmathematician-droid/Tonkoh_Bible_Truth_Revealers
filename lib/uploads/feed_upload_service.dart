import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../cloudinary/cloudinary_upload.dart';
import '../screens/auth/auth_manager.dart';
import '../util/image_shrink.dart';

enum FeedMediaKind { audio, video, image }

const feedAudioExtensions = ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus'];
const feedVideoExtensions = ['mp4', 'mov', 'mkv', '3gp'];
const feedImageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'heic'];
const feedAllExtensions = [
  ...feedAudioExtensions,
  ...feedVideoExtensions,
  ...feedImageExtensions,
];

/// Most files in one upload batch.
const feedMaxFilesPerBatch = 20;

FeedMediaKind? feedKindForName(String name) {
  final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
  if (feedAudioExtensions.contains(ext)) return FeedMediaKind.audio;
  if (feedVideoExtensions.contains(ext)) return FeedMediaKind.video;
  if (feedImageExtensions.contains(ext)) return FeedMediaKind.image;
  return null;
}

/// The title and description saved for part [part] of [total], from the
/// one title / description typed for the whole batch:
///  - title "Sermon — Part 2", description "2. About grace";
///  - a single file gets them unnumbered;
///  - no title: the file name without its extension (not numbered — it is
///    already different per file).
({String title, String description}) feedPartText({
  required String title,
  required String description,
  required String fileName,
  required int part,
  required int total,
}) {
  final t = title.trim();
  final d = description.trim();
  final numbered = total > 1;
  return (
    title: t.isEmpty
        ? p.basenameWithoutExtension(fileName)
        : (numbered ? '$t — Part $part' : t),
    description: d.isEmpty ? '' : (numbered ? '$part. $d' : d),
  );
}

/// One picked file, before upload.
class FeedUploadFile {
  FeedUploadFile({
    required this.path,
    required this.name,
    required this.size,
    required this.kind,
  }) : id = const Uuid().v4();

  final String id;
  final String path;
  final String name;
  final int size;
  final FeedMediaKind kind;

  /// Audio / video length, once known.
  Duration? duration;
}

enum FeedUploadState { queued, preparing, uploading, done, failed }

class FeedUploadJob {
  FeedUploadJob({required this.file, required this.part, required this.total});

  final FeedUploadFile file;
  final int part;
  final int total;
  FeedUploadState state = FeedUploadState.queued;
  double progress = 0;
  String? error;
}

class FeedUploadBatch {
  FeedUploadBatch({
    required this.id,
    required this.title,
    required this.description,
    required this.jobs,
  });

  final String id;
  final String title;
  final String description;
  final List<FeedUploadJob> jobs;

  int get doneCount => jobs.where((j) => j.state == FeedUploadState.done).length;
  int get failedCount =>
      jobs.where((j) => j.state == FeedUploadState.failed).length;
  bool get isFinished => jobs.every((j) =>
      j.state == FeedUploadState.done || j.state == FeedUploadState.failed);
}

/// Uploads Audio-screen batches in the background — independent of any
/// screen, so leaving the review screen (or the app) doesn't stop them.
///
/// At most [maxParallel] files at a time, so weak networks and low-memory
/// phones aren't swamped. Audio and video stream from their file path;
/// photos are first shrunk to 1600 px / JPEG 80. Each finished file goes
/// to `sermons/pending/{id}` (the admin approval queue) with `batchId`,
/// `partNumber` and `totalParts`.
class FeedUploadService extends ChangeNotifier {
  FeedUploadService._();
  static final FeedUploadService instance = FeedUploadService._();

  static const int maxParallel = 2;
  static const int _notificationId = 4270;

  final List<FeedUploadBatch> batches = [];
  int _running = 0;
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive => batches.any((b) => !b.isFinished);

  /// The batch the user is most likely watching.
  FeedUploadBatch? get latest => batches.isEmpty ? null : batches.last;

  /// Queues [files] (in this order) as one batch and starts uploading.
  FeedUploadBatch start(
    List<FeedUploadFile> files, {
    required String title,
    required String description,
  }) {
    final batch = FeedUploadBatch(
      id: const Uuid().v4(),
      title: title,
      description: description,
      jobs: [
        for (var i = 0; i < files.length; i++)
          FeedUploadJob(file: files[i], part: i + 1, total: files.length),
      ],
    );
    batches.add(batch);
    notifyListeners();
    _pump();
    return batch;
  }

  void retry(FeedUploadJob job) {
    if (job.state != FeedUploadState.failed) return;
    job
      ..state = FeedUploadState.queued
      ..progress = 0
      ..error = null;
    notifyListeners();
    _pump();
  }

  /// Drops finished batches from the list (the banner hides).
  void clearFinished() {
    batches.removeWhere((b) => b.isFinished);
    notifyListeners();
  }

  void _pump() {
    for (final batch in batches) {
      for (final job in batch.jobs) {
        if (_running >= maxParallel) return;
        if (job.state != FeedUploadState.queued) continue;
        _running++;
        job.state = FeedUploadState.preparing;
        unawaited(_run(batch, job).whenComplete(() {
          _running--;
          _changed(force: true);
          _pump();
        }));
      }
    }
  }

  Future<void> _run(FeedUploadBatch batch, FeedUploadJob job) async {
    final file = job.file;
    try {
      final me = AuthManager.lastKnownProfile ?? await AuthManager.getCachedProfile();
      if (me == null) throw CloudinaryUploadException('Not signed in.');

      var path = file.path;
      var name = file.name;
      if (file.kind == FeedMediaKind.image) {
        final small = await ImageShrink.shrink(path, ImageQuality.standard);
        if (small != null && small.path != path) {
          path = small.path;
          name = '${p.basenameWithoutExtension(file.name)}.jpg';
        }
      }
      if (!await File(path).exists()) {
        throw CloudinaryUploadException('The file is no longer on this phone.');
      }

      job.state = FeedUploadState.uploading;
      _changed(force: true);
      final url = await cloudinaryUpload(
        filePath: path,
        fileName: name,
        resourceType:
            file.kind == FeedMediaKind.image ? 'image' : 'video',
        folder: CloudinaryConfig.audioFolder,
        onProgress: (f) {
          job.progress = f;
          _changed();
        },
      );

      final text = feedPartText(
        title: batch.title,
        description: batch.description,
        fileName: file.name,
        part: job.part,
        total: job.total,
      );
      final id = const Uuid().v4();
      await FirebaseDatabase.instance.ref('sermons/pending/$id').set({
        'id': id,
        'title': text.title,
        'description': text.description,
        'audioUrl': url,
        'mediaType': file.kind.name.toUpperCase(),
        'uploadedBy': me.name.isEmpty ? 'user' : me.name,
        'status': 'pending',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'senderId': me.uid,
        'senderName': me.name,
        'senderPhone': me.phone,
        'batchId': batch.id,
        'partNumber': job.part,
        'totalParts': job.total,
        if (file.duration != null) 'duration': file.duration!.inSeconds,
      }).timeout(const Duration(seconds: 30), onTimeout: () {
        throw CloudinaryUploadException(
            'Uploaded, but saving it timed out — retry.');
      });
      job
        ..state = FeedUploadState.done
        ..progress = 1;
    } catch (e) {
      debugPrint('FeedUpload: ${file.name} failed: $e');
      job
        ..state = FeedUploadState.failed
        ..error = e is CloudinaryUploadException
            ? e.message
            : 'Upload failed — check your internet and retry.';
    }
  }

  /// Rebuilds listeners; the notification at most twice a second.
  void _changed({bool force = false}) {
    notifyListeners();
    final now = DateTime.now();
    if (!force && now.difference(_lastNotified) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastNotified = now;
    unawaited(_updateNotification());
  }

  Future<void> _updateNotification() async {
    if (kIsWeb) return;
    final jobs = [for (final b in batches) ...b.jobs];
    if (jobs.isEmpty) return;
    final done = jobs.where((j) => j.state == FeedUploadState.done).length;
    final failed = jobs.where((j) => j.state == FeedUploadState.failed).length;
    final active = jobs.any((j) =>
        j.state != FeedUploadState.done && j.state != FeedUploadState.failed);
    final plugin = FlutterLocalNotificationsPlugin();

    final percent = (jobs.fold<double>(
                0,
                (sum, j) =>
                    sum + (j.state == FeedUploadState.done ? 1 : j.progress)) *
            100 /
            jobs.length)
        .round();

    final String title;
    final String body;
    if (active) {
      title = 'Uploading files';
      body = '$done of ${jobs.length} uploaded';
    } else if (failed == 0) {
      title = done == 1 ? '1 file uploaded' : '$done files uploaded';
      body = 'Waiting for admin approval before it appears.';
    } else {
      title = '$failed of ${jobs.length} uploads failed';
      body = 'Open TBTR to retry.';
    }

    try {
      await plugin.show(
        _notificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'feed_uploads',
            'Uploads',
            channelDescription: 'Progress of files you upload',
            importance: Importance.low,
            priority: Priority.low,
            onlyAlertOnce: true,
            ongoing: active,
            autoCancel: !active,
            showProgress: active,
            maxProgress: 100,
            progress: percent,
          ),
        ),
      );
    } catch (e) {
      debugPrint('FeedUpload: notification failed: $e');
    }
  }
}
