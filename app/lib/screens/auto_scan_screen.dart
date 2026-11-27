import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/project.dart';
import '../services/app_settings.dart';
import '../services/live_scan.dart';
import '../theme.dart';

/// Auto scan: just move around the object. The phone's depth builds the shape
/// live (shown with a light sweep), photos are taken automatically and paint
/// the real colours onto it. Red = not scanned yet, yellow = partly, green =
/// done, real colours = fully captured.
class AutoScanScreen extends StatefulWidget {
  final ScanProject project;

  /// Second scan of a flipped object (flip-and-merge).
  final bool bottomScan;

  const AutoScanScreen({super.key, required this.project, this.bottomScan = false});

  @override
  State<AutoScanScreen> createState() => _AutoScanScreenState();
}

class _AutoScanScreenState extends State<AutoScanScreen> {
  final AutoScan _auto = AutoScan();
  AutoScanState get _state => _auto.state;
  bool _ready = false;
  bool _finishing = false;
  bool _closed = false;
  String? _error;
  int _lastPhotos = 0;
  DateTime _flashAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.enable();
    _state.addListener(_onState);
    _start();
  }

  void _onState() {
    if (_state.photos > _lastPhotos) {
      _lastPhotos = _state.photos;
      _flashAt = DateTime.now();
    }
  }

  Future<void> _start() async {
    var a = await LiveScan.availability();
    if (a == 'install') {
      final r = await LiveScan.install();
      if (r == 'requested') {
        setState(() => _error = 'Google Play Services for AR is being installed. Open Auto scan again when it is done.');
        return;
      }
      a = await LiveScan.availability();
    }
    if (a != 'supported') {
      setState(() => _error = 'This phone does not support AR (ARCore), which Auto scan needs. '
          'Use "Scan with camera" or "Turntable" instead.');
      return;
    }
    if (!await LiveScan.cameraPermission()) {
      setState(() => _error = 'Camera access is needed for Auto scan. Allow it in the system settings.');
      return;
    }
    final keep = widget.bottomScan ? false : !AppSettings.instance.autoRemoveFloor;
    final status = await _auto.open(widget.project.dir, keepFloor: keep);
    if (!mounted) return;
    if (status == 'no_depth') {
      setState(() => _error = 'This phone cannot measure depth with AR, which Auto scan needs. '
          'Use Live Scan or Turntable instead.');
      return;
    }
    if (status != 'ok') {
      setState(() => _error = 'Auto scan could not start ($status).');
      return;
    }
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    if (!_closed) _auto.finish();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  Future<void> _done() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final (photos, rotation) = await _auto.finish();
    _closed = true;
    final p = widget.project;
    p.autoScan = true;
    p.photoRotation = rotation;
    await p.save();
    if (!mounted) return;
    Navigator.pop(context, photos);
  }

  Future<void> _restart() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start the live shape over?'),
        content: const Text('The live 3D shape is cleared. Photos already taken are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start over')),
        ],
      ),
    );
    if (ok == true) await _auto.restart();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null ? _errorView() : _scanView(),
    );
  }

  Widget _errorView() => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.blur_on_rounded, color: SfColors.accent, size: 56),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, height: 1.4)),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
          ]),
        ),
      );

  Widget _arView() {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return PlatformViewLink(
      viewType: 'scanforge/arview',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'scanforge/arview',
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }

  Widget _scanView() {
    return Stack(fit: StackFit.expand, children: [
      _arView(),
      // photo flash
      AnimatedBuilder(
        animation: _state,
        builder: (_, __) {
          final on = DateTime.now().difference(_flashAt).inMilliseconds < 150;
          return IgnorePointer(child: Container(color: on ? Colors.white24 : Colors.transparent));
        },
      ),
      SafeArea(
        child: AnimatedBuilder(
          animation: _state,
          builder: (_, __) => Column(children: [
            _topBar(),
            const SizedBox(height: 10),
            if (widget.bottomScan) ...[
              _bottomScanBanner(),
              const SizedBox(height: 8),
            ],
            _hintPill(),
            const Spacer(),
            _bottomPanel(),
          ]),
        ),
      ),
      if (_finishing)
        const ColoredBox(
          color: Color(0x99000000),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 14),
              Text('Saving photos…', style: TextStyle(color: Colors.white)),
            ]),
          ),
        ),
    ]);
  }

  Widget _glass({required Widget child, EdgeInsets padding = const EdgeInsets.all(12), double radius = 18}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0x8C0B0E12),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        Text(widget.bottomScan ? 'Auto scan · bottom' : 'Auto scan',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        _glass(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          radius: 20,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text('${_state.photos}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          ]),
        ),
      ]),
    );
  }

  Widget _bottomScanBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _glass(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: const Row(children: [
          Icon(Icons.flip_rounded, color: SfColors.accent, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text('Object turned over? Scan it again, especially the bottom. Both scans are combined '
                'into one model afterwards.',
                style: TextStyle(color: Colors.white, fontSize: 13, height: 1.3)),
          ),
        ]),
      ),
    );
  }

  Widget _hintPill() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _glass(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        radius: 22,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_state.tracking ? Icons.blur_on_rounded : Icons.sync_rounded,
              color: _state.tracking ? SfColors.accent : Colors.amber, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(_state.hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]);

  Widget _bottomPanel() {
    final pct = (_state.percent * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _glass(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        radius: 22,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CustomPaint(
                painter: _RingPainter(_state.percent),
                child: Center(
                  child: Text('$pct%',
                      style: const TextStyle(
                          fontFamily: 'Roboto', color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Scanned', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Wrap(spacing: 10, runSpacing: 4, children: [
                  _legendDot(const Color(0xFFFF4545), 'Not yet'),
                  _legendDot(const Color(0xFFFFCC33), 'Partly'),
                  _legendDot(const Color(0xFF33E673), 'Done'),
                  _legendDot(const Color(0xFFB0A090), 'Real colour'),
                ]),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.layers_clear_rounded, size: 18, color: _state.floorFound ? SfColors.accent : Colors.white54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _state.floorFound ? 'Remove the surface underneath' : 'Remove the surface underneath (not found yet)',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            Switch(
              value: _state.removeFloor,
              activeColor: SfColors.accent,
              onChanged: _finishing ? null : (v) => _auto.setRemoveFloor(v),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _finishing ? null : _restart,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Start over'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _finishing || _state.photos < 3 ? null : _done,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Done'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  _RingPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    final bg = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6;
    canvas.drawCircle(c, r, bg);
    final col = Color.lerp(const Color(0xFFFF4545), const Color(0xFF33E673), value.clamp(0, 1))!;
    final fg = Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 6;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * value.clamp(0, 1), false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}
