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
  if (filePath == null && fileBytes == null) {
    onError('No file data provided (neither filePath nor fileBytes)');
    return;
  }

  try {
    final dio = Dio();
    final url =
        'https://api.cloudinary.com/v1_1/${CloudinaryConfig.cloudName}/$resourceType/upload';

    final multipartFile = filePath != null
        ? await MultipartFile.fromFile(filePath, filename: fileName)
        : MultipartFile.fromBytes(fileBytes!, filename: fileName);

    final formData = FormData.fromMap({
      'upload_preset': CloudinaryConfig.uploadPreset,
      'folder': folder,
      'file': multipartFile,
    });

    final response = await dio.post(
      url,
      data: formData,
      onSendProgress: (sent, total) {
        if (total > 0 && onProgress != null) {
          final percent = ((sent * 100) / total).clamp(0, 100).toInt();
          onProgress(percent);
        }
      },
    );

    final secureUrl = response.data['secure_url'] as String?;
    if (secureUrl == null || secureUrl.isEmpty) {
      onError('Upload succeeded but URL missing');
      return;
    }
    onSuccess(secureUrl);
  } catch (e) {
    onError(e.toString());
  }
}
