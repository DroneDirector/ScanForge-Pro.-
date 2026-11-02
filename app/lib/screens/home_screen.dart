import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/app_settings.dart';
import '../services/project_store.dart';
import '../services/updater.dart';
import '../widgets/update_dialog.dart';
import '../theme.dart';
import 'settings_screen.dart';
import 'capture_screen.dart';
import 'live_scan_screen.dart';
import 'turntable_screen.dart';
import 'project_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ScanProject> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUpdateCheck());
  }

  Future<void> _autoUpdateCheck() async {
    final st = AppSettings.instance;
    if (!Updater.supported || !st.autoCheckUpdates) return;
    final current = await Updater.currentVersion();
    final rel = await Updater.checkForUpdate();
    st.lastUpdateCheck = DateTime.now();
    await st.save();
    if (rel == null || rel.version == st.skippedVersion || !mounted) return;
    await showUpdateDialog(context, rel, current);
  }

  Future<void> _reload() async {
    final list = await ProjectStore.instance.list();
    if (!mounted) return;
    setState(() {
      _projects = list;
      _loading = false;
    });
  }

  Future<void> _newCapture() async {
    final proj = await ProjectStore.instance.create();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CaptureScreen(project: proj)));
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectScreen(project: proj)));
    _reload();
  }

  Future<void> _newImport() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
    );
    if (res == null || res.paths.isEmpty) return;
    final proj = await ProjectStore.instance.create();
    final n = await ProjectStore.instance.importPhotos(proj, res.paths.whereType<String>().toList());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $n photos')));
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectScreen(project: proj)));
    _reload();
  }

  Future<void> _newLiveScan() async {
    final proj = await ProjectStore.instance.create();
    if (!mounted) return;
    await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => LiveScanScreen(project: proj)));
    if (!mounted) return;
    if (proj.photos().isEmpty) {
      await ProjectStore.instance.delete(proj);
      _reload();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectScreen(project: proj)));
    _reload();
  }

  Future<void> _newTurntable() async {
    final proj = await ProjectStore.instance.create();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TurntableScreen(project: proj)));
    if (!mounted) return;
    if (proj.photos().isEmpty) {
      await ProjectStore.instance.delete(proj);
      _reload();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectScreen(project: proj)));
    _reload();
  }

  void _showNewSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: SfColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => NewScanSheet(
        onLiveScan: () {
          Navigator.pop(ctx);
          _newLiveScan();
        },
        onTurntable: () {
          Navigator.pop(ctx);
          _newTurntable();
        },
        onCamera: () {
          Navigator.pop(ctx);
          _newCapture();
        },
        onImport: () {
          Navigator.pop(ctx);
          _newImport();
        },
      ),
    );
  }

  Future<void> _confirmDelete(ScanProject p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete scan?'),
        content: Text('"${p.name}" with all its photos and models will be deleted from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await ProjectStore.instance.delete(p);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.view_in_ar_rounded, color: SfColors.accent),
          SizedBox(width: 10),
          Text('ScanForge Pro', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showNewSheet,
        backgroundColor: SfColors.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New scan', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? _EmptyState(onStart: _showNewSheet)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: LayoutBuilder(builder: (ctx, c) {
                    final cols = (c.maxWidth / 220).floor().clamp(2, 6);
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 100),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: _projects.length,
                      itemBuilder: (ctx, i) {
                        final p = _projects[i];
                        return _ProjectCard(
                          project: p,
                          onTap: () async {
                            await Navigator.of(context)
                                .push(MaterialPageRoute(builder: (_) => ProjectScreen(project: p)));
                            _reload();
                          },
                          onLongPress: () => _confirmDelete(p),
                        );
                      },
                    );
                  }),
                ),
    );
  }
}

/// The "New scan" choices (Live Scan, camera, import).
class NewScanSheet extends StatelessWidget {
  final VoidCallback onLiveScan, onTurntable, onCamera, onImport;
  const NewScanSheet(
      {super.key, required this.onLiveScan, required this.onTurntable, required this.onCamera, required this.onImport});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('New scan', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          _SheetOption(
            icon: Icons.view_in_ar_rounded,
            title: 'Live Scan',
            subtitle: 'AR: put a box around the object and walk around it. The dome shows what is captured; '
                'real size',
            badge: 'AR',
            onTap: onLiveScan,
          ),
          const SizedBox(height: 10),
          _SheetOption(
            icon: Icons.rotate_right_rounded,
            title: 'Turntable',
            subtitle: 'Phone on a stand, the object turns on a turntable or lazy Susan. Best for small objects',
            badge: 'NEW',
            onTap: onTurntable,
          ),
          const SizedBox(height: 10),
          _SheetOption(
            icon: Icons.camera_alt_rounded,
            title: 'Scan with camera',
            subtitle: 'Guided photos: walk around the object',
            onTap: onCamera,
          ),
          const SizedBox(height: 10),
          _SheetOption(
            icon: Icons.photo_library_rounded,
            title: 'Import photos',
            subtitle: 'Use existing photos, e.g. from a drone or camera',
            onTap: onImport,
          ),
        ]),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final String? badge;
  final VoidCallback onTap;
  const _SheetOption({required this.icon, required this.title, required this.subtitle, required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SfColors.surfaceHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: SfColors.accentSoft, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: SfColors.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  if (badge != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: SfColors.accent, borderRadius: BorderRadius.circular(6)),
                      child: Text(badge!,
                          style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: SfColors.textDim, fontSize: 13)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: SfColors.textDim),
          ]),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onStart;
  const _EmptyState({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.view_in_ar_rounded, size: 72, color: SfColors.accent),
          const SizedBox(height: 18),
          const Text('Scan your first object', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            'Walk around an object and take photos from every side. '
            'ScanForge Pro turns them into a 3D model you can view and print.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SfColors.textDim, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.add_rounded), label: const Text('New scan')),
        ]),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final ScanProject project;
  final VoidCallback onTap, onLongPress;
  const _ProjectCard({required this.project, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final photos = project.photos();
    final thumb = photos.isNotEmpty ? photos.first : null;
    final ready = project.hasModel;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: thumb == null
                ? Container(
                    color: SfColors.surfaceHigh,
                    child: const Icon(Icons.image_outlined, color: SfColors.textDim, size: 40),
                  )
                : RotatedBox(
                    quarterTurns: project.quarterTurnsFor(thumb.path),
                    child: Image.file(File(thumb.path), fit: BoxFit.cover, cacheWidth: 400),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(children: [
                Icon(ready ? Icons.check_circle_rounded : Icons.photo_camera_outlined,
                    size: 15, color: ready ? SfColors.good : SfColors.textDim),
                const SizedBox(width: 5),
                Text(ready ? '3D model ready' : '${photos.length} photos',
                    style: TextStyle(fontSize: 12, color: ready ? SfColors.good : SfColors.textDim)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
