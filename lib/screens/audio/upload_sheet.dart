import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../uploads/feed_upload_service.dart';
import 'upload_review_screen.dart';

String generateTitle(String description) {
  final trimmed = description.trim();
  if (trimmed.isEmpty) return 'Untitled';
  return trimmed.length > 40 ? '${trimmed.substring(0, 40)}...' : trimmed;
}

/// The Audio screen's upload button: pick any mix of audio, video and
/// photos, then review them before anything is uploaded.
Future<void> showUploadPickMenu(BuildContext context) async {
  final files = await pickFeedFiles(context, alreadyChosen: 0);
  if (files == null || files.isEmpty || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => UploadReviewScreen(initialFiles: files),
  ));
}

/// Opens the system file picker for up to [feedMaxFilesPerBatch] files
/// (minus [alreadyChosen]). Returns null when the user cancelled.
///
/// `FileType.custom` with extensions always opens Android's document
/// picker, which handles selecting several files of any type reliably.
/// (`FileType.image` went to the phone's gallery app via ACTION_PICK,
/// where many galleries drop a multi-selection.) Paths only: nothing is
/// loaded into memory.
Future<List<FeedUploadFile>?> pickFeedFiles(
  BuildContext context, {
  required int alreadyChosen,
}) async {
  final room = feedMaxFilesPerBatch - alreadyChosen;
  if (room <= 0) {
    _snack(context, 'You can upload up to $feedMaxFilesPerBatch files at a time.');
    return null;
  }
  if (kIsWeb) {
    _snack(context, 'Uploading files is available in the phone app.');
    return null;
  }

  // file_picker copies each picked file into the app's cache before it
  // returns — seconds for big videos. Say so instead of looking frozen.
  var preparingShown = false;
  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: feedAllExtensions,
      allowMultiple: true,
      withData: false,
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking &&
            !preparingShown &&
            context.mounted) {
          preparingShown = true;
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const PopScope(
              canPop: false,
              child: AlertDialog(
                content: Row(children: [
                  SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                  SizedBox(width: 16),
                  Expanded(child: Text('Preparing files…')),
                ]),
              ),
            ),
          );
        }
      },
    );
  } catch (e) {
    debugPrint('pickFeedFiles failed: $e');
    if (context.mounted) {
      _snack(context, "Couldn't open your files: $e");
    }
    return null;
  } finally {
    if (preparingShown && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  if (result == null) return null; // cancelled

  final files = <FeedUploadFile>[];
  var skipped = 0;
  for (final f in result.files) {
    final path = f.path;
    final kind = feedKindForName(f.name);
    if (path == null || path.isEmpty || kind == null) {
      skipped++;
      continue;
    }
    files.add(FeedUploadFile(path: path, name: f.name, size: f.size, kind: kind));
  }

  final messages = <String>[];
  if (files.length > room) {
    files.removeRange(room, files.length);
    messages.add('You can upload up to $feedMaxFilesPerBatch files at a time — '
        'the first $room were added.');
  }
  if (skipped > 0) {
    messages.add(skipped == 1
        ? "1 file couldn't be used (not audio, video or a photo)."
        : "$skipped files couldn't be used (not audio, video or photos).");
  }
  if (files.isEmpty && messages.isEmpty) messages.add('No file selected.');
  if (messages.isNotEmpty && context.mounted) _snack(context, messages.join('\n'));
  return files;
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
