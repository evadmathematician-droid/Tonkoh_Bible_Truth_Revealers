import 'package:dio/dio.dart';

class CloudinaryConfig {
  static const cloudName = 'dxg9gkeks';
  static const uploadPreset = 'tonkoh';
  static const audioFolder = 'sermons_audio';
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
      'folder': CloudinaryConfig.audioFolder,
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

/// Derives a JPG thumbnail URL from a Cloudinary-hosted video, taken at
/// [offsetSeconds] into the clip — Cloudinary generates this on the fly via
/// URL transformation, so no local video-thumbnail plugin or download is
/// needed and it works identically on web/Android/iOS. Clips shorter than
/// [offsetSeconds] just get clamped to their last frame by Cloudinary.
/// Returns null if [videoUrl] isn't a Cloudinary "/upload/" URL.
String? cloudinaryVideoThumbnailUrl(String videoUrl, {int offsetSeconds = 3}) {
  const marker = '/upload/';
  final markerIndex = videoUrl.indexOf(marker);
  if (markerIndex == -1) return null;

  final insertAt = markerIndex + marker.length;
  final withOffset =
      '${videoUrl.substring(0, insertAt)}so_$offsetSeconds/${videoUrl.substring(insertAt)}';

  final dotIndex = withOffset.lastIndexOf('.');
  if (dotIndex < insertAt) return '$withOffset.jpg';
  return '${withOffset.substring(0, dotIndex)}.jpg';
}