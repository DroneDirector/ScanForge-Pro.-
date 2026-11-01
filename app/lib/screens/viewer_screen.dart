import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/project.dart';
import '../services/engine.dart';
import '../theme.dart';

class ViewerScreen extends StatefulWidget {
  final ScanProject project;
  const ViewerScreen({super.key, required this.project});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  ScanProject get p => widget.project;
  EngineMesh? _mesh;
  String? _error;
  bool _busy = false;
  double _yaw = 30, _pitch = 20, _zoom = 1, _panX = 0, _panY = 0;
  bool _clay = false;
  // gesture state
  double _startZoom = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _mesh?.dispose();
    _mesh = EngineMesh.load(p.meshPath);
    if (_mesh == null) _error = 'The 3D model could not be opened.';
    setState(() {});
  }

  @override
  void dispose() {
    _mesh?.dispose();
    super.dispose();
  }

  void _resetView() => setState(() {
        _yaw = 30;
        _pitch = 20;
        _zoom = 1;
        _panX = _panY = 0;
      });

  Printer get _printer => Printer.byId(p.printer);

  // ---------------------------------------------------------------- size
  Future<void> _setSize() async {
    final m = _mesh;
    if (m == null) return;
    final sizes = [m.sizeX, m.sizeY, m.sizeZ];
    var axis = 2;
    final ctrl = TextEditingController(text: (sizes[axis] * p.exportScale).toStringAsFixed(1));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('Real size'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Measure the real object and enter one dimension. The others follow.',
                style: TextStyle(color: SfColors.textDim, fontSize: 13)),
            const SizedBox(height: 14),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Width')),
                ButtonSegment(value: 1, label: Text('Depth')),
                ButtonSegment(value: 2, label: Text('Height')),
              ],
              selected: {axis},
              onSelectionChanged: (s) => setD(() {
                axis = s.first;
                ctrl.text = (sizes[axis] * p.exportScale).toStringAsFixed(1);
              }),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(suffixText: 'mm', border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final v = double.tryParse(ctrl.text.replaceAll(',', '.'));
                if (v == null || v <= 0 || sizes[axis] <= 0) return;
                Navigator.pop(ctx, v / sizes[axis]);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      }),
    );
    if (result != null) {
      p.exportScale = result;
      await p.save();
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- floor
  Future<void> _cutFloor() async {
    final m = _mesh;
    if (m == null) return;
    final h = m.sizeZ;
    var cut = 0.0;
    final res = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('Flat base'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Cut the bottom of the model flat so it sits on the print bed. '
                'Use this to remove leftovers of the table.',
                style: TextStyle(color: SfColors.textDim, fontSize: 13)),
            const SizedBox(height: 12),
            Text('${(cut * p.exportScale).toStringAsFixed(1)} mm', style: const TextStyle(fontSize: 22)),
            Slider(value: cut, min: 0, max: h * 0.4, onChanged: (v) => setD(() => cut = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, -1.0), child: const Text('Automatic')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, cut), child: const Text('Cut')),
          ],
        );
      }),
    );
    if (res == null) return;
    setState(() => _busy = true);
    final dir = p.dir;
    final code = await Isolate.run(() => remesh(dir, res));
    if (!mounted) return;
    setState(() => _busy = false);
    if (code != 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update the model ($code).')));
      return;
    }
    _load();
  }

  // ---------------------------------------------------------------- export
  Future<File?> _writeExport(ExportFormat f) async {
    final m = _mesh;
    if (m == null) return null;
    final tmp = await getTemporaryDirectory();
    final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_').trim();
    final path = pth.join(tmp.path, '${safe.isEmpty ? 'scan' : safe}.${f.extension}');
    final pr = _printer;
    final err = m.export(path, f, scale: p.exportScale, bedX: pr.bedX, bedY: pr.bedY, name: p.name);
    if (err != null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return null;
    }
    return File(path);
  }

  Future<void> _export(ExportFormat f, {required bool share}) async {
    setState(() => _busy = true);
    try {
      final file = await _writeExport(f);
      if (file == null) return;
      if (share) {
        await Share.shareXFiles([XFile(file.path)], subject: p.name);
      } else {
        final bytes = await file.readAsBytes();
        final saved = await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${f.extension.toUpperCase()}',
          fileName: pth.basename(file.path),
          bytes: bytes,
        );
        if (saved != null && Platform.isWindows) await file.copy(saved);
        if (mounted && saved != null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showExport() {
    var printerId = p.printer;
    showModalBottomSheet(
      context: context,
      backgroundColor: SfColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final m = _mesh!;
        final pr = Printer.byId(printerId);
        final sx = m.sizeX * p.exportScale, sy = m.sizeY * p.exportScale, sz = m.sizeZ * p.exportScale;
        final fits = sx <= pr.bedX && sy <= pr.bedY && sz <= pr.maxZ;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Export', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: printerId,
                decoration: const InputDecoration(labelText: 'Printer', border: OutlineInputBorder()),
                items: [for (final x in Printer.all) DropdownMenuItem(value: x.id, child: Text(x.name))],
                onChanged: (v) {
                  if (v == null) return;
                  setS(() => printerId = v);
                  p.printer = v;
                  p.save();
                },
              ),
              const SizedBox(height: 10),
              Row(children: [
                Icon(fits ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                    color: fits ? SfColors.good : Colors.amber, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${sx.toStringAsFixed(1)} × ${sy.toStringAsFixed(1)} × ${sz.toStringAsFixed(1)} mm'
                    '${fits ? ' fits the build plate' : ' is larger than the build plate'}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Text(m.watertight ? 'Closed (watertight) mesh, ready to slice.' : 'Mesh has open edges.',
                  style: const TextStyle(color: SfColors.textDim, fontSize: 12)),
              const SizedBox(height: 14),
              for (final f in ExportFormat.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(child: Text(f.label, style: const TextStyle(fontWeight: FontWeight.w600))),
                    IconButton(
                      tooltip: 'Save',
                      icon: const Icon(Icons.save_alt_rounded),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _export(f, share: false);
                      },
                    ),
                    IconButton(
                      tooltip: 'Share',
                      icon: const Icon(Icons.ios_share_rounded),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _export(f, share: true);
                      },
                    ),
                  ]),
                ),
              const Text(
                '3MF opens directly in Bambu Studio and Bambu Handy with the size in millimetres. '
                'Colours are kept in PLY and OBJ.',
                style: TextStyle(color: SfColors.textDim, fontSize: 12, height: 1.35),
              ),
            ]),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = _mesh;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            tooltip: _clay ? 'Show colours' : 'Show shape only',
            icon: Icon(_clay ? Icons.palette_rounded : Icons.texture_rounded),
            onPressed: () => setState(() => _clay = !_clay),
          ),
          IconButton(tooltip: 'Reset view', icon: const Icon(Icons.center_focus_strong_rounded), onPressed: _resetView),
        ],
      ),
      body: m == null
          ? Center(child: Text(_error ?? 'Loading…'))
          : Column(children: [
              Expanded(
                child: Stack(children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onScaleStart: (d) => _startZoom = _zoom,
                      onScaleUpdate: (d) {
                        setState(() {
                          if (d.pointerCount >= 2) {
                            _zoom = (_startZoom * d.scale).clamp(0.3, 8.0);
                            _panX += d.focalPointDelta.dx;
                            _panY += d.focalPointDelta.dy;
                          } else {
                            _yaw -= d.focalPointDelta.dx * 0.4;
                            _pitch = (_pitch + d.focalPointDelta.dy * 0.4).clamp(-89.0, 89.0);
                          }
                        });
                      },
                      onDoubleTap: _resetView,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            colors: [Color(0xFF2A313B), SfColors.background],
                            radius: 1.0,
                          ),
                        ),
                        child: CustomPaint(
                          painter: _MeshPainter(m, _yaw, _pitch, _zoom, _panX, _panY, _clay),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  ),
                  if (_busy) const Positioned.fill(child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator()))),
                  Positioned(
                    left: 14,
                    top: 10,
                    child: _InfoChip(
                      text: '${(m.sizeX * p.exportScale).toStringAsFixed(1)} × '
                          '${(m.sizeY * p.exportScale).toStringAsFixed(1)} × '
                          '${(m.sizeZ * p.exportScale).toStringAsFixed(1)} mm',
                    ),
                  ),
                  Positioned(
                    left: 14,
                    top: 46,
                    child: _InfoChip(text: '${_fmtInt(m.triangles)} triangles${m.watertight ? ' · watertight' : ''}'),
                  ),
                ]),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(children: [
                    Expanded(child: _ToolButton(icon: Icons.straighten_rounded, label: 'Size', onTap: _setSize)),
                    Expanded(child: _ToolButton(icon: Icons.content_cut_rounded, label: 'Flat base', onTap: _cutFloor)),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _showExport,
                        icon: const Icon(Icons.print_rounded),
                        label: const Text('Export STL / 3MF'),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }

  static String _fmtInt(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }
}

class _MeshPainter extends CustomPainter {
  final EngineMesh mesh;
  final double yaw, pitch, zoom, panX, panY;
  final bool clay;
  _MeshPainter(this.mesh, this.yaw, this.pitch, this.zoom, this.panX, this.panY, this.clay);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || size.height < 2) return;
    final r = mesh.render(
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      panX: panX,
      panY: panY,
      width: size.width.round(),
      height: size.height.round(),
      clay: clay,
    );
    if (r == null || r.positions.isEmpty) return;
    final v = ui.Vertices.raw(ui.VertexMode.triangles, r.positions, colors: r.colors);
    canvas.drawVertices(v, BlendMode.modulate, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _MeshPainter o) =>
      o.yaw != yaw || o.pitch != pitch || o.zoom != zoom || o.panX != panX || o.panY != panY || o.clay != clay ||
      o.mesh != mesh;
}

class _InfoChip extends StatelessWidget {
  final String text;
  const _InfoChip({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
      );
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: SfColors.accent),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );
}
