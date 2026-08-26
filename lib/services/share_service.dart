import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:share_plus/share_plus.dart';

import '../cloudinary/cloudinary_upload.dart' show cloudinaryVideoThumbnailUrl;
import '../data/sermon_audio.dart';
import 'share_branding_service.dart';

/// Wires the OS share sheet (ACTION_SEND, via share_plus — already the
/// project's share dependency) to audio/video/image sermon content.
///
/// Scope note: there is no working deep-link infrastructure in this app
/// (Firebase Dynamic Links, the originally-suggested option, was shut
/// down by Google in Aug 2025; building App Links + a hosted landing
/// page + deferred install-referrer linking was explicitly declined in
/// favor of a simpler flow). So this shares a BRANDED PREVIEW IMAGE +
/// caption text with a generic Play Store link — not a link to this
/// specific piece of content, and not the raw media file for video/audio
/// (see class doc on each build method below for why).
class ShareService {
  ShareService._();

  static const String playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.tbtrapp';

  static final Dio _dio = Dio();

  static Future<Uint8List> _fetchBytes(String url) async {
    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data!);
  }

  static String _caption(SermonAudio sermon) {
    final title = sermon.title.isEmpty ? 'Untitled' : sermon.title;
    return '$title\n\nShared from ${ShareBrandingService.appName} 🙏\n'
        'Get the app: $playStoreUrl';
  }

  /// Shares [sermon] via the OS share sheet, attaching a branded preview
  /// image appropriate to its type:
  ///  - IMAGE: the actual sermon image, with the app icon+name overlaid —
  ///    this genuinely is the shared content, branded.
  ///  - VIDEO: a branded still frame (Cloudinary already generates a JPG
  ///    thumbnail on the fly from the hosted video URL — see
  ///    cloudinaryVideoThumbnailUrl — with the same icon+name overlay).
  ///    The raw video file itself is NOT attached: sermon videos can run
  ///    into the hundreds of MB, and this app already has a separate,
  ///    explicit "Download" action for that; bundling a full video into
  ///    a share-sheet payload would be slow and easy to fail silently.
  ///  - AUDIO: a standalone branded card (icon + app name + track title)
  ///    — audio has no visual to overlay onto, and for the same file-size
  ///    reason as video, the raw audio file isn't attached either.
  static Future<void> shareSermon(SermonAudio sermon) async {
    final caption = _caption(sermon);
    final title = sermon.title.isEmpty ? 'Untitled' : sermon.title;

    try {
      File brandedFile;
      switch (sermon.mediaType) {
        case 'IMAGE':
          final bytes = await _fetchBytes(sermon.audioUrl);
          brandedFile = await ShareBrandingService.buildBrandedOverlay(bytes);
          break;
        case 'VIDEO':
          final thumbUrl = cloudinaryVideoThumbnailUrl(sermon.audioUrl) ?? sermon.audioUrl;
          final bytes = await _fetchBytes(thumbUrl);
          brandedFile = await ShareBrandingService.buildBrandedOverlay(bytes);
          break;
        default: // AUDIO
          brandedFile = await ShareBrandingService.buildBrandedCard(title: title);
      }

      await SharePlus.instance.share(ShareParams(
        files: [XFile(brandedFile.path)],
        text: caption,
        subject: title,
      ));
    } catch (e) {
      // Network fetch or compositing failed (offline, bad URL, etc.) —
      // fall back to a text-only share so the action never silently does
      // nothing.
      debugPrint('ShareService: branded share failed, falling back to text: $e');
      await SharePlus.instance.share(ShareParams(text: caption, subject: title));
    }
  }
}
