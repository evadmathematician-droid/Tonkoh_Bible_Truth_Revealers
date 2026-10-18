import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../cloudinary/cloudinary_upload.dart';
import '../data/contacts_cache.dart';
import '../data/display_names.dart';
import '../screens/audio/audio_feed_provider.dart';
import '../screens/auth/auth_manager.dart';
import '../screens/components/profile_avatar.dart';
import 'incoming_share.dart';
import 'share_sender.dart';

const _kBrand = Color(0xFF102A72);

/// "Share to…" — where content shared in from another app goes: the audio
/// feed and/or any number of private chats, with an editable message.
class ShareTargetScreen extends StatefulWidget {
  final IncomingShare share;
  const ShareTargetScreen({super.key, required this.share});

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _Candidate {
  final String uid;
  final int lastTimestamp; // 0 = no chat yet, just a contact
  const _Candidate(this.uid, this.lastTimestamp);
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  late final TextEditingController _message;
  final _search = TextEditingController();
  final Set<String> _selected = {};
  List<_Candidate> _candidates = [];
  bool _toFeed = false;
  bool _sending = false;
  String _status = '';

  List<SharedFile> get _media =>
      widget.share.files.where((f) => f.isMedia).toList();
  int get _unsupported => widget.share.files.length - _media.length;

  @override
  void initState() {
    super.initState();
    _message = TextEditingController(text: widget.share.message);
    _loadCandidates();
  }

  @override
  void dispose() {
    _message.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Recent chats first (newest on top), then the rest of my contacts who
  /// are on the app.
  Future<void> _loadCandidates() async {
    final me = await AuthManager.getCachedProfile();
    if (me == null) return;
    final byUid = <String, _Candidate>{};
    try {
      final snap =
          await FirebaseDatabase.instance.ref('userChats/${me.uid}').get();
      final v = snap.value;
      if (v is Map) {
        for (final row in v.values) {
          if (row is! Map) continue;
          final uid = (row['otherUid'] ?? '') as String;
          if (uid.isEmpty || uid == me.uid) continue;
          final ts = (row['lastTimestamp'] as num?)?.toInt() ?? 0;
          final prev = byUid[uid];
          if (prev == null || ts > prev.lastTimestamp) {
            byUid[uid] = _Candidate(uid, ts);
          }
        }
      }
    } catch (e) {
      debugPrint('ShareTargetScreen: chat list read failed: $e');
    }
    for (final c in ContactsCache.instance.contacts) {
      final uid = c.uid;
      if (uid == null || uid.isEmpty || uid == me.uid) continue;
      byUid.putIfAbsent(uid, () => _Candidate(uid, 0));
    }
    final names = DisplayNames.instance;
    final list = byUid.values.toList()
      ..sort((a, b) {
        if (a.lastTimestamp != b.lastTimestamp) {
          return b.lastTimestamp.compareTo(a.lastTimestamp);
        }
        return names
            .nameFor(a.uid)
            .toLowerCase()
            .compareTo(names.nameFor(b.uid).toLowerCase());
      });
    if (mounted) setState(() => _candidates = list);
  }

  bool get _canSend =>
      !_sending &&
      (_toFeed || _selected.isNotEmpty) &&
      (_media.isNotEmpty || _message.text.trim().isNotEmpty);

  Future<void> _send() async {
    final me = await AuthManager.getCachedProfile();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (me == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Finishing sign-in — try again in a moment.')));
      return;
    }
    final text = _message.text.trim();
    final feed = context.read<AudioFeedProvider>();
    setState(() => _sending = true);

    try {
      final uploads = <UploadedShareFile>[];
      for (var i = 0; i < _media.length; i++) {
        setState(() => _status = 'Uploading ${i + 1} of ${_media.length}…');
        uploads.add(await ShareSender.upload(
          _media[i],
          folder: _toFeed
              ? CloudinaryConfig.audioFolder
              : CloudinaryConfig.chatMediaFolder,
          onProgress: (p) {
            if (mounted) {
              setState(() =>
                  _status = 'Uploading ${i + 1} of ${_media.length}… $p%');
            }
          },
        ));
      }

      if (_toFeed) {
        setState(() => _status = 'Posting to the feed…');
        if (uploads.isNotEmpty) {
          for (final u in uploads) {
            await ShareSender.postMediaToFeed(me: me, upload: u, caption: text);
          }
        } else if (text.isNotEmpty) {
          await feed.sendTextMessage(text);
          ShareSender.notifyFeedText(me, text);
        }
      }

      for (final uid in _selected) {
        setState(() => _status = 'Sending to ${DisplayNames.instance.nameFor(uid)}…');
        await ShareSender.sendToChat(
            me: me, otherUid: uid, text: text, files: uploads);
      }

      _cleanUp();
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(_doneMessage(uploads))));
    } catch (e) {
      debugPrint('ShareTargetScreen: send failed: $e');
      if (!mounted) return;
      setState(() {
        _sending = false;
        _status = '';
      });
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Sharing failed — check your connection and try again.')));
    }
  }

  String _doneMessage(List<UploadedShareFile> uploads) {
    final parts = <String>[];
    if (_toFeed) {
      parts.add(uploads.isNotEmpty
          ? 'sent to the admins for the feed'
          : 'posted to the feed');
    }
    if (_selected.isNotEmpty) {
      parts.add(_selected.length == 1
          ? 'sent to ${DisplayNames.instance.nameFor(_selected.first)}'
          : 'sent to ${_selected.length} chats');
    }
    final s = parts.join(' and ');
    return '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// The copies ShareReceiverActivity made — not needed once uploaded.
  void _cleanUp() {
    for (final f in widget.share.files) {
      try {
        File(f.path).deleteSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = context.watch<DisplayNames>();
    final q = _search.text.trim().toLowerCase();
    final visible = _candidates.where((c) {
      if (q.isEmpty) return true;
      return names.nameFor(c.uid).toLowerCase().contains(q) ||
          c.uid.contains(q.replaceAll(' ', ''));
    }).toList();
    final hasFiles = _media.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Share to…'),
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  _Preview(share: widget.share, media: _media),
                  if (_unsupported > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '$_unsupported file(s) skipped — only photos, videos '
                        'and audio can be shared here.',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      controller: _message,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: hasFiles ? 'Add a caption' : 'Message',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  CheckboxListTile(
                    value: _toFeed,
                    onChanged:
                        _sending ? null : (v) => setState(() => _toFeed = v!),
                    secondary: const Icon(Icons.campaign, color: _kBrand),
                    title: const Text('Post to the Audio feed'),
                    subtitle: Text(hasFiles
                        ? 'Admins approve it before everyone sees it'
                        : 'Everyone in the feed will see it'),
                  ),
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Send privately to',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: _kBrand)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search name or number',
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No chats or contacts on the app yet.',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  for (final c in visible)
                    CheckboxListTile(
                      value: _selected.contains(c.uid),
                      onChanged: _sending
                          ? null
                          : (v) => setState(() =>
                              v! ? _selected.add(c.uid) : _selected.remove(c.uid)),
                      secondary: CachedProfileAvatar(
                          uid: c.uid, name: names.nameFor(c.uid), size: 40),
                      title: Text(names.nameFor(c.uid),
                          overflow: TextOverflow.ellipsis),
                      subtitle: names.isSaved(c.uid)
                          ? Text(formatPhoneForDisplay(c.uid))
                          : null,
                    ),
                ],
              ),
            ),
            if (_sending)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 6),
                    Text(_status, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _kBrand),
                  onPressed: _canSend ? _send : null,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What's being shared: thumbnails for photos, a row per video/audio file,
/// or the text with its link called out.
class _Preview extends StatelessWidget {
  final IncomingShare share;
  final List<SharedFile> media;
  const _Preview({required this.share, required this.media});

  @override
  Widget build(BuildContext context) {
    final link = share.link;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (media.isNotEmpty)
              SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: media.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _thumb(media[i]),
                ),
              ),
            if (media.isEmpty && link != null)
              Row(
                children: [
                  const Icon(Icons.link, color: _kBrand),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(link,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: _kBrand,
                            decoration: TextDecoration.underline)),
                  ),
                ],
              ),
            if (media.isEmpty && link == null)
              Text(share.message,
                  maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _thumb(SharedFile f) {
    if (f.kind == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(f.path),
            width: 96,
            height: 96,
            fit: BoxFit.cover,
            cacheWidth: 192,
            errorBuilder: (_, __, ___) => _iconTile(Icons.broken_image, f.name)),
      );
    }
    return _iconTile(
        f.kind == 'video' ? Icons.movie : Icons.audiotrack, f.name);
  }

  Widget _iconTile(IconData icon, String name) => Container(
        width: 96,
        height: 96,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFFECEFF3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _kBrand, size: 32),
            const SizedBox(height: 4),
            Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10)),
          ],
        ),
      );
}
