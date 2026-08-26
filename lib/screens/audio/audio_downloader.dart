import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Equivalent of the Android downloadAudio() used in AudioScreen.kt's
/// handleAudioPlayPauseClick / handleVideoTap. Saves to "<audioId>.mp3"
/// in the app's local storage, matching the
/// `File(context.filesDir, "$audioId.mp3")` pattern used throughout
/// AudioScreen.kt for play and delete.
///
/// Note: context.filesDir is Android-internal, non-backed-up app storage.
/// The closest path_provider equivalent is getApplicationSupportDirectory()
/// rather than getApplicationDocumentsDirectory() (which is user-visible /
/// iCloud-backed on iOS). Using ApplicationSupport here — flag if you'd
/// rather match iOS Documents behavior instead.
class AudioDownloadHandle {
  final CancelToken _cancelToken;
  AudioDownloadHandle(this._cancelToken);

  void cancel() => _cancelToken.cancel('user_cancelled');
}

AudioDownloadHandle downloadAudio({
  required String audioId,
  required String url,
  required void Function(int percent) onProgress,
  required void Function(String path) onComplete,
  required void Function(Object error) onError,
  required void Function() onCancelled,
}) {
  final cancelToken = CancelToken();
  _run(audioId, url, cancelToken, onProgress, onComplete, onError, onCancelled);
  return AudioDownloadHandle(cancelToken);
}

/// Equivalent of `File(context.filesDir, "$id.mp3")` — used by the
/// downloader, the player, and delete logic, so it's centralized here
/// rather than reconstructed with a raw path join in three places.
Future<File> localAudioFile(String id) async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$id.mp3');
}

Future<void> _run(
    String audioId,
    String url,
    CancelToken cancelToken,
    void Function(int) onProgress,
    void Function(String) onComplete,
    void Function(Object) onError,
    void Function() onCancelled,
    ) async {
  try {
    final target = await localAudioFile(audioId);
    final tmpPath = '${target.path}.part'; // avoid a half-written file looking "done"

    await Dio().download(
      url,
      tmpPath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          onProgress(((received / total) * 100).round());
        }
      },
    );

    await File(tmpPath).rename(target.path);
    onComplete(target.path);
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) {
      onCancelled();
    } else {
      onError(e);
    }
  } catch (e) {
    onError(e);
  }
}