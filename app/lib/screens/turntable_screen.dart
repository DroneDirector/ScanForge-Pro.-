import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as pth;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/project.dart';
import '../services/live_scan.dart';
import '../services/project_store.dart';
import '../theme.dart';

/// Turntable scan: the phone stands still (stand or tripod) and the object
/// turns on a turntable or lazy Susan. Photos are taken at a steady pace;
/// up to three rounds at different heights.
class TurntableScreen extends StatefulWidget {
  final ScanProject project;
  final Widget? demoBackground;
  final TurntableDemo? demo;
  const TurntableScreen({super.key, required this.project, this.demoBackground, this.demo});

  @override
  State<TurntableScreen> createState() => _TurntableScreenState();
}

/// Fixed values for screenshots.
class TurntableDemo {
  final int round, inRound, perRound;
  final bool running;
  const TurntableDemo(this.round, this.inRound, this.perRound, this.running);
}

class _TurntableScreenState extends State<TurntableScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  String? _error;
  bool _running = false;
  bool _busy = false;
  int _round = 1;
  int _inRound = 0;
  int _perRound = 36;
  double _interval = 1.5;
  Timer? _timer;
  bool _finishing = false;
  String _finishText = '';
  bool _flash = false;

  bool get _isDemo => widget.demo != null;

  static const _roundHints = [
    'Round 1: phone at the height of the object, looking at it',
    'Round 2: raise the phone and tilt it down a little',
    'Round 3: from above, looking down at the top',
  ];

  @override
  void initState() {
    super.initState();
    final d = widget.demo;
    if (d != null) {
      _round = d.round;
      _inRound = d.inRound;
      _perRound = d.perRound;
      _running = d.running;
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.enable();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.max, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      await c.setFlashMode(FlashMode.off);
      if (!mounted) return c.dispose();
      setState(() => _cam = c);
    } catch (e) {
      setState(() => _error = 'Camera error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _pause();
  }

  @override
  void dispose() {
    if (!_isDemo) {
      WidgetsBinding.instance.removeObserver(this);
      _timer?.cancel();
      _cam?.dispose();
      WakelockPlus.disable();
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  Future<void> _start() async {
    final c = _cam;
    if (c == null) return;
    // focus and exposure once at the start of a round, then locked so all photos match
    try {
      await c.setFocusMode(FocusMode.auto);
      await c.setExposureMode(ExposureMode.auto);
      await c.setFocusPoint(const Offset(0.5, 0.5));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await c.setFocusMode(FocusMode.locked);
      await c.setExposureMode(ExposureMode.locked);
    } catch (_) {}
    setState(() => _running = true);
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: (_interval * 1000).round()), (_) => _shoot());
  }

  void _pause() {
    _timer?.cancel();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _shoot() async {
    final c = _cam;
    if (c == null || _busy || c.value.isTakingPicture) return;
    _busy = true;
    try {
      final f = await c.takePicture();
      await f.saveTo(ProjectStore.instance.nextPhotoPath(widget.project));
      HapticFeedback.selectionClick();
      setState(() {
        _inRound++;
        _flash = true;
      });
      Future.delayed(const Duration(milliseconds: 110), () {
        if (mounted) setState(() => _flash = false);
      });
      if (_inRound >= _perRound) {
        _pause();
        _roundDone();
      }
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  Future<void> _roundDone() async {
    if (!mounted) return;
    final more = _round < 3;
    final next = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Round $_round done'),
        content: Text(more
            ? '${_roundHints[_round]}.\n\nMore rounds from higher up give a better top. You can also finish now.'
            : 'All three rounds are done.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Finish')),
          if (more) FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Start round ${_round + 1}')),
        ],
      ),
    );
    if (next == true) {
      setState(() {
        _round++;
        _inRound = 0;
      });
      _start();
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    _pause();
    final n = widget.project.photos().length;
    if (n == 0) {
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _finishing = true;
      _finishText = 'Separating the object from the background…';
    });
    await File(pth.join(widget.project.dir, 'turntable.txt')).writeAsString('turntable\n');
    await LiveScan.segmentPhotos(widget.project.dir, (done, total) {
      if (mounted) setState(() => _finishText = 'Separating the object from the background… $done / $total');
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (widget.demoBackground != null)
          widget.demoBackground!
        else if (cam != null && cam.value.isInitialized)
          Center(child: CameraPreview(cam))
        else
          Center(
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.white))
                : const CircularProgressIndicator(),
          ),
        const IgnorePointer(child: CustomPaint(painter: _FramePainter())),
        if (_flash) Container(color: Colors.white24),
        SafeArea(
          child: Column(children: [
            _topBar(),
            const SizedBox(height: 10),
            _hint(),
            const Spacer(),
            _panel(),
          ]),
        ),
        if (_finishing)
          ColoredBox(
            color: const Color(0xCC000000),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text(_finishText, style: const TextStyle(color: Colors.white)),
              ]),
            ),
          ),
      ]),
    );
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

  Widget _topBar() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
          const Text('Turntable', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          const Spacer(),
          _glass(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            radius: 20,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text('${(_round - 1) * _perRound + _inRound}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      );

  Widget _hint() => _glass(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        radius: 24,
        child: Text(
          _running
              ? 'Turn the object slowly and evenly. Keep the phone still.'
              : 'Phone on a stand, object on a turntable or lazy Susan in the frame',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      );

  Widget _chip(String label, bool selected, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? SfColors.accent : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected ? Colors.black : Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _panel() {
    final locked = _running || _inRound > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _glass(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        radius: 22,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SizedBox(
              width: 74,
              height: 74,
              child: CustomPaint(painter: _RoundPainter(_inRound / _perRound, _round)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Round $_round of 3',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(_roundHints[_round - 1],
                    style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.3)),
                const SizedBox(height: 4),
                Text('$_inRound / $_perRound photos', style: const TextStyle(color: SfColors.accent, fontSize: 12)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const SizedBox(width: 74, child: Text('Every', style: TextStyle(color: Colors.white70, fontSize: 12))),
            for (final v in [1.0, 1.5, 2.0, 3.0]) ...[
              _chip('${v.toString().replaceAll('.0', '')} s', _interval == v,
                  locked ? null : () => setState(() => _interval = v)),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(width: 74, child: Text('Per round', style: TextStyle(color: Colors.white70, fontSize: 12))),
            for (final v in [24, 36, 48]) ...[
              _chip('$v', _perRound == v, locked ? null : () => setState(() => _perRound = v)),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton(
              onPressed: _isDemo || (_inRound == 0 && _round == 1) ? null : _finish,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              child: const Text('Finish'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _isDemo ? null : (_running ? _pause : _start),
                icon: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                label: Text(_running ? 'Pause' : (_inRound == 0 ? 'Start round $_round' : 'Continue')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _RoundPainter extends CustomPainter {
  final double v;
  final int round;
  _RoundPainter(this.v, this.round);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 5;
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = Colors.white.withValues(alpha: 0.15));
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        2 * math.pi * v.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round
          ..color = SfColors.accent);
    final tp = TextPainter(
      text: TextSpan(
          text: '${(v * 100).round()}%',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RoundPainter o) => o.v != v || o.round != round;
}

/// Frame guide: keep the object (and the turntable) inside.
class _FramePainter extends CustomPainter {
  const _FramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * 0.72, h = size.height * 0.36;
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.46), width: w, height: h);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = SfColors.accent;
    const l = 26.0;
    for (final corner in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      final dx = corner.dx == rect.left ? l : -l;
      final dy = corner.dy == rect.top ? l : -l;
      canvas.drawLine(corner, corner + Offset(dx, 0), p);
      canvas.drawLine(corner, corner + Offset(0, dy), p);
    }
    canvas.drawCircle(rect.center, 4, Paint()..color = SfColors.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
