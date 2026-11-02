import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/engine.dart';
import '../services/job_manager.dart';
import '../services/project_store.dart';
import '../theme.dart';
import 'capture_screen.dart';
import 'live_scan_screen.dart';
import 'viewer_screen.dart';

class ProjectScreen extends StatefulWidget {
  final ScanProject project;
  const ProjectScreen({super.key, required this.project});

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  ScanProject get p => widget.project;
  final jobs = JobManager.instance;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    jobs.addListener(_onJob);
    _wasRunning = jobs.isRunning(p.id);
  }

  @override
  void dispose() {
    jobs.removeListener(_onJob);
    super.dispose();
  }

  bool _asking = false;
  DateTime _answeredAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _askIfNeeded() async {
    final snap = jobs.snapshot(p.id);
    if (_asking || snap == null || snap.state != JobState.confirm || !mounted) return;
    // the status is polled, so ignore the question briefly after it was answered
    if (DateTime.now().difference(_answeredAt).inMilliseconds < 1500) return;
    _asking = true;
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber),
          SizedBox(width: 10),
          Expanded(child: Text('Too few overlapping photos')),
        ]),
        content: Text(snap.message, style: const TextStyle(height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stop')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Proceed')),
        ],
      ),
    );
    if (go != null) jobs.confirm(p.id, go);
    _answeredAt = DateTime.now();
    _asking = false;
  }

  void _onJob() {
    if (!mounted) return;
    if (jobs.snapshot(p.id)?.state == JobState.confirm) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askIfNeeded());
    }
    final running = jobs.isRunning(p.id);
    if (_wasRunning && !running) {
      final s = jobs.snapshot(p.id);
      if (s?.state == JobState.done) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openViewer());
      } else if (s?.state == JobState.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Stopped. Add more photos with Camera or Import, then build again.'),
        ));
      }
    }
    _wasRunning = running;
    setState(() {});
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename scan'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      p.name = name;
      await p.save();
      setState(() {});
    }
  }

  Future<void> _addFromCamera() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CaptureScreen(project: p)));
    setState(() {});
  }

  Future<void> _addFromLiveScan() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveScanScreen(project: p)));
    setState(() {});
  }

  Future<void> _addFromFiles() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
    );
    if (res == null) return;
    await ProjectStore.instance.importPhotos(p, res.paths.whereType<String>().toList());
    setState(() {});
  }

  Future<void> _build() async {
    final n = p.photos().length;
    if (n < 3) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not enough photos'),
          content: Text('This scan has $n photo${n == 1 ? '' : 's'}. A 3D model needs at least 3 overlapping '
              'photos, and 30-60 give the best results.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (n < 20) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Too few photos'),
          content: Text('This scan has only $n photos, so there may not be enough overlap. The model may '
              'fail, miss parts or look like a block.\n\nFor good results take 30-60 photos all the way around, '
              'plus a round from higher up.\n\nDo you still want to proceed?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Take more photos')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Proceed')),
          ],
        ),
      );
      if (go != true) {
        if (go == false && mounted) await _addFromCamera();
        return;
      }
    }
    if (!mounted) return;
    if (!jobs.start(p)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not start processing.')));
    }
    setState(() {});
  }

  void _openViewer() {
    if (!p.hasModel || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewerScreen(project: p)));
  }

  void _showLog() {
    final f = File(p.logPath);
    final live = File('${p.dir}/live_log.txt');
    var text = f.existsSync() ? f.readAsStringSync() : 'No 3D build log yet.';
    if (live.existsSync()) {
      final lines = live.readAsLinesSync();
      final last = lines.length > 60 ? lines.sublist(lines.length - 60) : lines;
      text += '\n\n--- Live Scan ---\n${last.join('\n')}';
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SfColors.surface,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, sc) => SingleChildScrollView(
          controller: sc,
          padding: const EdgeInsets.all(18),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = p.photos();
    final running = jobs.isRunning(p.id);
    final snap = jobs.snapshot(p.id);
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: _rename, child: Text(p.name)),
        actions: [
          IconButton(icon: const Icon(Icons.edit_rounded), onPressed: _rename, tooltip: 'Rename'),
          IconButton(icon: const Icon(Icons.receipt_long_rounded), onPressed: _showLog, tooltip: 'Processing log'),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        if (p.hasModel && !running)
          Card(
            color: SfColors.surfaceHigh,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: const Icon(Icons.view_in_ar_rounded, color: SfColors.good, size: 34),
              title: const Text('3D model ready', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('View, scale and export for printing'),
              trailing: FilledButton(onPressed: _openViewer, child: const Text('Open')),
            ),
          ),
        if (File('${p.dir}/turntable.txt').existsSync())
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Row(children: [
              Icon(Icons.rotate_right_rounded, size: 16, color: SfColors.good),
              SizedBox(width: 6),
              Expanded(
                child: Text('Turntable scan · background removed by AI',
                    style: TextStyle(color: SfColors.good, fontSize: 13)),
              ),
            ]),
          ),
        if (p.hasCameraPositions)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Row(children: const [
              Icon(Icons.view_in_ar_rounded, size: 16, color: SfColors.good),
              SizedBox(width: 6),
              Expanded(
                child: Text('Live Scan · camera positions and real size are known',
                    style: TextStyle(color: SfColors.good, fontSize: 13)),
              ),
            ]),
          ),
        const SizedBox(height: 8),
        // ---- photos
        Text('Photos (${photos.length})', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Wrap(spacing: 4, children: [
          if (p.liveScan)
            TextButton.icon(
                onPressed: running ? null : _addFromLiveScan,
                icon: const Icon(Icons.view_in_ar_rounded),
                label: const Text('Live')),
          TextButton.icon(
              onPressed: running ? null : _addFromCamera,
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text('Camera')),
          TextButton.icon(
              onPressed: running ? null : _addFromFiles,
              icon: const Icon(Icons.add_photo_alternate_rounded),
              label: const Text('Import')),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 96,
          child: photos.isEmpty
              ? const Center(child: Text('No photos yet', style: TextStyle(color: SfColors.textDim)))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (ctx, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RotatedBox(
                      quarterTurns: p.quarterTurnsFor(photos[i].path),
                      child: Image.file(photos[i], width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 200),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 22),
        // ---- quality
        const Text('Quality', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (var q = 0; q < 4; q++) ButtonSegment(value: q, label: Text(Quality.names[q])),
          ],
          selected: {p.quality},
          onSelectionChanged: running
              ? null
              : (s) {
                  setState(() => p.quality = s.first);
                  p.save();
                },
        ),
        const SizedBox(height: 8),
        Text(_qualityHint(p.quality), style: const TextStyle(color: SfColors.textDim, fontSize: 13, height: 1.35)),
        const SizedBox(height: 24),
        // ---- processing
        if (running)
          _ProgressCard(
            snapshot: snap,
            onCancel: () => jobs.cancel(p.id),
            onAnswer: (go) {
              _answeredAt = DateTime.now();
              jobs.confirm(p.id, go);
            },
          ),
        if (!running) ...[
          if (p.lastError != null)
            Card(
              color: const Color(0xFF3A1E1E),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFFF7A7A)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.lastError!, style: const TextStyle(height: 1.35)),
                      if (p.lastError!.contains('photos'))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: _addFromCamera,
                            icon: const Icon(Icons.camera_alt_rounded),
                            label: const Text('Take more photos'),
                          ),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: photos.isEmpty ? null : _build,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(p.hasModel ? 'Rebuild 3D model' : 'Build 3D model'),
          ),
        ],
        const SizedBox(height: 26),
        const _Tips(),
      ]),
    );
  }

  String _qualityHint(int q) {
    switch (q) {
      case 0:
        return 'Quick preview. Good for checking a scan, a few minutes on a phone.';
      case 2:
        return 'More detail. Takes noticeably longer on a phone and uses more memory.';
      case 3:
        return 'Maximum detail. Best on a PC; on a phone it can take a long time.';
      default:
        return 'Balanced detail and speed. Recommended for most scans.';
    }
  }
}

class _ProgressCard extends StatelessWidget {
  final JobSnapshot? snapshot;
  final VoidCallback onCancel;
  final void Function(bool) onAnswer;
  const _ProgressCard({required this.snapshot, required this.onCancel, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    if (s != null && s.state == JobState.confirm) {
      return Card(
        color: const Color(0xFF3A3018),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text('Too few overlapping photos', style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            Text(s.message, style: const TextStyle(height: 1.4)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => onAnswer(false), child: const Text('Stop')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => onAnswer(true), child: const Text('Proceed')),
            ]),
          ]),
        ),
      );
    }
    final pct = ((s?.progress ?? 0) * 100).clamp(0, 100).round();
    final stage = s == null ? 'Starting' : stageNames[s.stage.clamp(0, stageNames.length - 1)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('$pct%', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: SfColors.accent)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(stage, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (s != null && s.message.isNotEmpty)
                  Text(s.message, style: const TextStyle(color: SfColors.textDim, fontSize: 12)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (s?.progress ?? 0).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: SfColors.surfaceHigh,
            ),
          ),
          const SizedBox(height: 12),
          const Text('Keep the app open. The screen stays on while the model is built.',
              style: TextStyle(color: SfColors.textDim, fontSize: 12)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ),
        ]),
      ),
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    const tips = [
      'Walk all the way around the object. Take a photo every step (about every 15°).',
      'Do a second round from higher up, looking down at the object.',
      'Each photo should overlap the previous one by about two thirds.',
      'Even light, no harsh shadows. Matt objects with texture scan best.',
      'Shiny, see-through or plain single-colour objects are hard to scan. Place them on a newspaper or patterned cloth.',
      'Keep the object still; move yourself, not the object.',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.lightbulb_outline_rounded, color: SfColors.accent),
            SizedBox(width: 8),
            Text('Tips for a good scan', style: TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          for (final t in tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  ', style: TextStyle(color: SfColors.accent)),
                Expanded(child: Text(t, style: const TextStyle(color: SfColors.textDim, height: 1.35))),
              ]),
            ),
        ]),
      ),
    );
  }
}
