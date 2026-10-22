import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../uploads/feed_upload_service.dart';
import '../../util/image_shrink.dart' show formatBytes;
import 'upload_sheet.dart' show pickFeedFiles;

const _kBlue = Color(0xFF2346A0);

/// "Upload files": review picked files before anything is uploaded —
/// numbered, reorderable, removable, one shared title and description —
/// then follow each file's progress. Closing it doesn't stop the uploads
/// ([FeedUploadService] runs them); the Audio screen's banner reopens it.
class UploadReviewScreen extends StatefulWidget {
  const UploadReviewScreen({super.key, this.initialFiles = const [], this.batch});

  /// Review mode.
  final List<FeedUploadFile> initialFiles;

  /// Progress mode for an upload already running.
  final FeedUploadBatch? batch;

  @override
  State<UploadReviewScreen> createState() => _UploadReviewScreenState();
}

class _UploadReviewScreenState extends State<UploadReviewScreen> {
  late final List<FeedUploadFile> _files = List.of(widget.initialFiles);
  final _title = TextEditingController();
  final _description = TextEditingController();
  late FeedUploadBatch? _batch = widget.batch;
  AudioPlayer? _probe;

  @override
  void initState() {
    super.initState();
    _probeDurations();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _probe?.dispose();
    super.dispose();
  }

  /// Audio / video lengths, one file at a time (cheap: metadata only).
  Future<void> _probeDurations() async {
    for (final f in List.of(_files)) {
      if (!mounted) return;
      if (f.kind == FeedMediaKind.image || f.duration != null) continue;
      try {
        _probe ??= AudioPlayer();
        f.duration = await _probe!
            .setFilePath(f.path, preload: true)
            .timeout(const Duration(seconds: 5));
        if (mounted) setState(() {});
      } catch (_) {
        // Unknown length is fine; it just isn't shown.
      }
    }
    await _probe?.stop();
  }

  Future<void> _addMore() async {
    final more = await pickFeedFiles(context, alreadyChosen: _files.length);
    if (more == null || more.isEmpty || !mounted) return;
    setState(() => _files.addAll(more));
    _probeDurations();
  }

  void _upload() {
    if (_files.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _batch = FeedUploadService.instance.start(
        List.of(_files),
        title: _title.text,
        description: _description.text,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final batch = _batch;
    return Scaffold(
      appBar: AppBar(
        foregroundColor: _kBlue,
        title: Text(batch == null ? 'Upload files' : 'Uploading'),
        actions: [
          if (batch == null)
            TextButton.icon(
              onPressed: _files.length >= feedMaxFilesPerBatch ? null : _addMore,
              icon: const Icon(Icons.add),
              label: const Text('Add more'),
            ),
        ],
      ),
      body: SafeArea(child: batch == null ? _review() : _progress(batch)),
    );
  }

  // ── review ───────────────────────────────────────────────────────────

  Widget _review() {
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            header: _sharedFields(),
            itemCount: _files.length,
            onReorderItem: (from, to) =>
                setState(() => _files.insert(to, _files.removeAt(from))),
            itemBuilder: (context, i) {
              final f = _files[i];
              return _FileRow(
                key: ValueKey(f.id),
                index: i,
                file: f,
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _files.removeAt(i)),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _files.isEmpty ? null : _upload,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text('Upload all (${_files.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sharedFields() {
    final many = _files.length > 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Title (for all files)',
              helperText: many
                  ? 'Saved as "${_title.text.trim().isEmpty ? 'Title' : _title.text.trim()} — Part 1", "— Part 2", …'
                  : 'Leave empty to use the file name',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Description (for all files)',
              helperText: many ? 'Numbered "1.", "2.", … per file' : null,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _files.isEmpty
                ? 'No files. Tap "Add more".'
                : many
                    ? '${_files.length} files — hold and drag ≡ to change the order'
                    : '1 file',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── progress ─────────────────────────────────────────────────────────

  Widget _progress(FeedUploadBatch batch) {
    return ListenableBuilder(
      listenable: FeedUploadService.instance,
      builder: (context, _) {
        final total = batch.jobs.length;
        final finished = batch.isFinished;
        return Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: finished && batch.failedCount == 0
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFF0F3FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    finished && batch.failedCount == 0
                        ? (total == 1 ? '1 file uploaded' : '$total files uploaded')
                        : '${batch.doneCount} of $total uploaded',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16, color: _kBlue),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    finished
                        ? (batch.failedCount == 0
                            ? 'They appear on the Audio screen once an admin approves them.'
                            : '${batch.failedCount} failed — tap Retry.')
                        : 'You can leave this screen — uploads continue.',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: total,
                itemBuilder: (context, i) => _JobCard(job: batch.jobs[i]),
              ),
            ),
            if (finished)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.index,
    required this.file,
    required this.trailing,
  });

  final int index;
  final FeedUploadFile file;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final details = [
      formatBytes(file.size),
      if (file.duration != null) _clock(file.duration!),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text('${index + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: _kBlue, fontSize: 16)),
            ),
            _Thumb(file: file),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(details,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            trailing,
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.drag_handle, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});
  final FeedUploadFile file;

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    if (file.kind == FeedMediaKind.image) {
      final px = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(file.path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: px,
          errorBuilder: (_, __, ___) => _icon(Icons.image_outlined),
        ),
      );
    }
    return _icon(file.kind == FeedMediaKind.video
        ? Icons.movie_outlined
        : Icons.audiotrack_outlined);
  }

  static Widget _icon(IconData icon) => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFFE8EDFB),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: _kBlue),
      );
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job});
  final FeedUploadJob job;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (job.state) {
      FeedUploadState.queued => ('Waiting…', Colors.grey.shade600),
      FeedUploadState.preparing => ('Preparing…', Colors.grey.shade600),
      FeedUploadState.uploading =>
        ('${(job.progress * 100).round()}%', _kBlue),
      FeedUploadState.done => ('Uploaded', const Color(0xFF2E7D32)),
      FeedUploadState.failed => ('Failed', const Color(0xFFC62828)),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${job.part}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: _kBlue)),
                const SizedBox(width: 10),
                _Thumb(file: job.file),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(job.file.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (job.state == FeedUploadState.done)
                  const Icon(Icons.check_circle, color: Color(0xFF2E7D32))
                else if (job.state == FeedUploadState.failed)
                  TextButton.icon(
                    onPressed: () => FeedUploadService.instance.retry(job),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(label, style: TextStyle(color: color)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (job.state == FeedUploadState.failed)
              Text('Failed — ${job.error ?? 'retry'}',
                  style: TextStyle(color: color, fontSize: 12))
            else
              LinearProgressIndicator(
                value: switch (job.state) {
                  FeedUploadState.done => 1,
                  FeedUploadState.uploading => job.progress,
                  FeedUploadState.preparing => null,
                  _ => 0,
                },
                color: job.state == FeedUploadState.done
                    ? const Color(0xFF2E7D32)
                    : _kBlue,
                backgroundColor: const Color(0xFFE8EDFB),
              ),
          ],
        ),
      ),
    );
  }
}

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A slim strip on the Audio screen while uploads run (or just finished);
/// tap to see each file's progress.
class FeedUploadBanner extends StatelessWidget {
  const FeedUploadBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = FeedUploadService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final batch = service.latest;
        if (batch == null) return const SizedBox.shrink();
        final total = batch.jobs.length;
        final finished = batch.isFinished;
        final text = !finished
            ? 'Uploading ${batch.doneCount} of $total…'
            : batch.failedCount > 0
                ? '${batch.failedCount} upload(s) failed — tap to retry'
                : '${total == 1 ? '1 file' : '$total files'} uploaded · '
                    'waiting for approval';
        return Material(
          color: batch.failedCount > 0 && finished
              ? const Color(0xFFFFEBEE)
              : Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => UploadReviewScreen(batch: batch))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  finished
                      ? Icon(
                          batch.failedCount > 0
                              ? Icons.error_outline
                              : Icons.check_circle,
                          size: 18,
                          color: batch.failedCount > 0
                              ? const Color(0xFFC62828)
                              : const Color(0xFF2E7D32))
                      : const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(text,
                        style: const TextStyle(fontSize: 13, color: _kBlue)),
                  ),
                  if (finished)
                    IconButton(
                      tooltip: 'Dismiss',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: service.clearFinished,
                    )
                  else
                    const Icon(Icons.chevron_right, color: _kBlue),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
