import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/project_store.dart';
import '../theme.dart';
import 'about_screen.dart';
import 'capture_screen.dart';
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

  void _showNewSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: SfColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('New scan', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            _SheetOption(
              icon: Icons.camera_alt_rounded,
              title: 'Scan with camera',
              subtitle: 'Guided capture: walk around the object',
              onTap: () {
                Navigator.pop(ctx);
                _newCapture();
              },
            ),
            const SizedBox(height: 10),
            _SheetOption(
              icon: Icons.photo_library_rounded,
              title: 'Import photos',
              subtitle: 'Use existing photos, e.g. from a drone or camera',
              onTap: () {
                Navigator.pop(ctx);
                _newImport();
              },
            ),
          ]),
        ),
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
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
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

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _SheetOption({required this.icon, required this.title, required this.subtitle, required this.onTap});

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
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
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
                : Image.file(File(thumb.path), fit: BoxFit.cover, cacheWidth: 400),
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
