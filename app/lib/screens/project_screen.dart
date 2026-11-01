import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/engine.dart';
import '../services/job_manager.dart';
import '../services/project_store.dart';
import '../theme.dart';
import 'capture_screen.dart';
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

  void _onJob() {
    if (!mounted) return;
    final running = jobs.isRunning(p.id);
    if (_wasRunning && !running) {
      final s = jobs.snapshot(p.id);
      if (s?.state == JobState.done) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openViewer());
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
    if (n < 8) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not enough photos'),
          content: Text('This scan has $n photos. At least 8 are needed to build a model, '
              'and 30-60 give the best results.\n\nWalk all the way around the object, then do a second '
              'round from higher up.'),
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
          title: const Text('Only a few photos'),
          content: Text('This scan has $n photos. With so few, the model will probably fail or miss parts '
              'of the object.\n\nFor good results take 30-60 photos all the way around, plus a round from '
              'higher up.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Take more photos')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Build anyway')),
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
    final text = f.existsSync() ? f.readAsStringSync() : 'No log yet.';
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
        const SizedBox(height: 8),
        // ---- photos
        Row(children: [
          Text('Photos (${photos.length})', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const Spacer(),
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
                    child: Image.file(photos[i], width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 200),
                  ),
                ),
        ),
        const SizedBox(height: 22),
        // ---- quality
        const Text('Quality', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        SegmentedButton<int>(
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
        if (running) _ProgressCard(snapshot: snap, onCancel: () => jobs.cancel(p.id)),
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
                      if (p.lastError!.startsWith('Not enough photos'))
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
  const _ProgressCard({required this.snapshot, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
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
