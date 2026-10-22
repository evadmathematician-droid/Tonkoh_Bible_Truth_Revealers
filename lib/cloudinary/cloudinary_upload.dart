import 'dart:async';

import 'package:dio/dio.dart';

class CloudinaryConfig {
  static const cloudName = 'dxg9gkeks';
  static const uploadPreset = 'tonkoh';
  static const audioFolder = 'sermons_audio';
  static const chatMediaFolder = 'chat_media';
}

/// Cloudinary resource-type segment for a chat attachment MIME type.
/// Cloudinary lumps audio in with "video".
String cloudinaryResourceTypeForMime(String mime) {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/') || mime.startsWith('audio/')) return 'video';
  return 'raw';
}

/// Derives a poster-frame image URL for a Cloudinary-hosted video, so the
/// feed can show a real thumbnail (like YouTube) instead of a blank tile.
///
/// Cloudinary generates a still from any video by inserting a transformation
/// right after `/upload/` and requesting an image extension. `so_0` grabs
/// the first frame; `c_fill,w_640,h_360` gives a consistent 16:9 crop.
/// Returns the input unchanged if it doesn't look like a Cloudinary URL.
String cloudinaryVideoThumbnail(String videoUrl) {
  const marker = '/upload/';
  final idx = videoUrl.indexOf(marker);
  if (idx == -1) return videoUrl;

  final head = videoUrl.substring(0, idx + marker.length);
  var tail = videoUrl.substring(idx + marker.length);

  // Swap the video extension (.mp4/.mov/.webm/...) for .jpg.
  final lastSlash = tail.lastIndexOf('/');
  final lastDot = tail.lastIndexOf('.');
  if (lastDot > lastSlash) tail = tail.substring(0, lastDot);

  return '${head}so_0,c_fill,w_640,h_360/$tail.jpg';
}

String cloudinaryResourceType(String mediaKind) {
  switch (mediaKind) {
    case 'IMAGE':
      return 'image';
    case 'AUDIO':
    case 'VIDEO':
    default:
      return 'video';
  }
}

/// Either [filePath] (native platforms) or [fileBytes] (web) must be
/// provided — exactly one, not both. Web can't expose real filesystem
/// paths to Dart (browser security restriction), so file_picker gives
/// bytes there instead of a path.
Future<void> uploadAudioToCloudinary({
  String? filePath,
  List<int>? fileBytes,
  required String fileName,
  required String resourceType, // "video" (covers audio+video) or "image"
  void Function(int percent)? onProgress,
  required void Function(String secureUrl) onSuccess,
  required void Function(String message) onError,
}) =>
    uploadToCloudinary(
      filePath: filePath,
      fileBytes: fileBytes,
      fileName: fileName,
      resourceType: resourceType,
      folder: CloudinaryConfig.audioFolder,
      onProgress: onProgress,
      onSuccess: onSuccess,
      onError: onError,
    );

/// Generic unsigned Cloudinary upload. Either [filePath] (native) or
/// [fileBytes] (web) must be provided.
Future<void> uploadToCloudinary({
  String? filePath,
  List<int>? fileBytes,
  required String fileName,
  required String resourceType, // "image" | "video" | "raw"
  String folder = CloudinaryConfig.audioFolder,
  void Function(int percent)? onProgress,
  required void Function(String secureUrl) onSuccess,
  required void Function(String message) onError,
}) async {
  try {
    onSuccess(await cloudinaryUpload(
      filePath: filePath,
      fileBytes: fileBytes,
      fileName: fileName,
      resourceType: resourceType,
      folder: folder,
      onProgress: onProgress == null ? null : (f) => onProgress((f * 100).toInt()),
    ));
  } catch (e) {
    onError(e.toString());
  }
}

/// Why a [cloudinaryUpload] failed, in words a user can act on.
class CloudinaryUploadException implements Exception {
  CloudinaryUploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uploads one file to Cloudinary and returns its `secure_url`.
///
/// The file is streamed from [filePath] (never loaded whole into memory);
/// [fileBytes] is for web only. [onProgress] gets 0.0–1.0.
///
/// Never hangs: it fails when nothing has been sent for [stallTimeout]
/// (a dead or stuck connection), or — when given — once [totalTimeout]
/// passes. [cancel] stops it early.
Future<String> cloudinaryUpload({
  String? filePath,
  List<int>? fileBytes,
  required String fileName,
  required String resourceType, // "image" | "video" | "raw"
  String folder = CloudinaryConfig.audioFolder,
  void Function(double fraction)? onProgress,
  Duration stallTimeout = const Duration(seconds: 60),
  Duration? totalTimeout,
  CancelToken? cancel,
}) async {
  if (filePath == null && fileBytes == null) {
    throw CloudinaryUploadException('No file to upload.');
  }
  final token = cancel ?? CancelToken();
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    // The server answers once the whole file is in; give it time to
    // process a large video.
    receiveTimeout: const Duration(minutes: 3),
  ));

  String? timedOut;
  Timer? stall;
  void armStall() {
    stall?.cancel();
    stall = Timer(stallTimeout, () {
      timedOut = 'The connection stopped — check your internet and retry.';
      token.cancel('stalled');
    });
  }

  final total = totalTimeout == null
      ? null
      : Timer(totalTimeout, () {
          timedOut = 'Upload took too long — check your internet and retry.';
          token.cancel('timeout');
        });

  try {
    final multipartFile = filePath != null
        ? await MultipartFile.fromFile(filePath, filename: fileName)
        : MultipartFile.fromBytes(fileBytes!, filename: fileName);
    final formData = FormData.fromMap({
      'upload_preset': CloudinaryConfig.uploadPreset,
      'folder': folder,
      'file': multipartFile,
    });

    armStall();
    final response = await dio.post(
      'https://api.cloudinary.com/v1_1/${CloudinaryConfig.cloudName}/$resourceType/upload',
      data: formData,
      cancelToken: token,
      onSendProgress: (sent, size) {
        // Everything sent: now waiting for the server, not stalled.
        if (size > 0 && sent >= size) {
          stall?.cancel();
        } else {
          armStall();
        }
        if (size > 0 && onProgress != null) {
          onProgress((sent / size).clamp(0.0, 1.0));
        }
      },
    );

    final secureUrl = response.data['secure_url'] as String?;
    if (secureUrl == null || secureUrl.isEmpty) {
      throw CloudinaryUploadException('Upload finished but no link came back.');
    }
    return secureUrl;
  } on DioException catch (e) {
    if (timedOut != null) throw CloudinaryUploadException(timedOut!);
    if (CancelToken.isCancel(e)) throw CloudinaryUploadException('Cancelled.');
    final status = e.response?.statusCode;
    final serverMsg = e.response?.data is Map
        ? (e.response!.data['error']?['message'] as String?)
        : null;
    throw CloudinaryUploadException(switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout =>
        'No internet connection.',
      _ when serverMsg != null => serverMsg,
      _ when status != null => 'Upload failed (error $status).',
      _ => 'Upload failed — check your internet and retry.',
    });
  } finally {
    stall?.cancel();
    total?.cancel();
  }
}

/// A Cloudinary image URL with [transformation] applied (e.g.
/// `c_limit,w_720`), for a smaller download than the original. Returns
/// [url] unchanged when it isn't a Cloudinary upload URL.
String cloudinaryImageVariant(String url, String transformation) {
  const marker = '/image/upload/';
  final idx = url.indexOf(marker);
  if (idx == -1) return url;
  final head = url.substring(0, idx + marker.length);
  return '$head$transformation/${url.substring(idx + marker.length)}';
}
