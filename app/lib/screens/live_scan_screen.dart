import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/project.dart';
import '../services/live_scan.dart';
import '../theme.dart';
import '../widgets/hologram_painter.dart';

/// Live Scan: move around the object; photos are taken automatically and a
/// hologram shows how much of the object is captured.
class LiveScanScreen extends StatefulWidget {
  final ScanProject project;

  /// For previews / screenshots: a fixed background and state instead of AR.
  final Widget? demoBackground;
  final LiveScanState? demoState;

  const LiveScanScreen({super.key, required this.project, this.demoBackground, this.demoState});

  @override
  State<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends State<LiveScanScreen> with SingleTickerProviderStateMixin {
  final LiveScan _live = LiveScan();
  late final LiveScanState _state = widget.demoState ?? _live.state;
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  bool get _demo => widget.demoState != null;
  bool _ready = false;
  String? _error;
  bool _finishing = false;
  String? _shownMessage;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
    if (_demo) {
      _ready = true;
      if (widget.demoState != null) _anim.value = 0.32;
      _anim.stop();
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      WakelockPlus.enable();
      _start();
    }
  }

  void _onState() {
    final m = _state.message;
    if (m != null && m != _shownMessage && mounted) {
      _shownMessage = m;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _start() async {
    var a = await LiveScan.availability();
    if (a == 'install') {
      final r = await LiveScan.install();
      if (r == 'requested') {
        setState(() => _error = 'Google Play Services for AR is being installed. Open Live Scan again when it is done.');
        return;
      }
      a = await LiveScan.availability();
    }
    if (a != 'supported') {
      setState(() => _error = 'This phone does not support Live Scan (ARCore). Use "Scan with camera" instead.');
      return;
    }
    if (!await LiveScan.cameraPermission()) {
      setState(() => _error = 'Camera access is needed for Live Scan. Allow it in the system settings.');
      return;
    }
    final status = await _live.open(widget.project.dir);
    if (!mounted) return;
    if (!status.startsWith('ok')) {
      setState(() => _error = 'Live Scan could not start ($status).');
      return;
    }
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    _anim.dispose();
    if (!_demo) {
      if (!_finishing) _live.finish();
      WakelockPlus.disable();
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  Future<void> _done() async {
    if (_demo || _finishing) return;
    setState(() => _finishing = true);
    final (photos, rotation) = await _live.finish();
    widget.project.liveScan = true;
    widget.project.photoRotation = rotation;
    await widget.project.save();
    if (!mounted) return;
    Navigator.pop(context, photos);
  }

  void _onTapUp(TapUpDetails d) {
    if (_demo || _state.selected || _state.selecting) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    _live.tap(d.localPosition.dx * dpr, d.localPosition.dy * dpr);
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
            const Icon(Icons.view_in_ar_rounded, color: SfColors.accent, size: 56),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, height: 1.4)),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
          ]),
        ),
      );

  Widget _arView() {
    if (widget.demoBackground != null) return widget.demoBackground!;
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
      // hologram + taps
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: _onTapUp,
          child: AnimatedBuilder(
            animation: Listenable.merge([_anim, _state]),
            builder: (_, __) => CustomPaint(painter: HologramPainter(_state, _anim.value)),
          ),
        ),
      ),
      // photo flash
      AnimatedBuilder(
        animation: _state,
        builder: (_, __) {
          final t = _state.lastPhoto;
          final on = !_demo && t != null && DateTime.now().difference(t).inMilliseconds < 150;
          return IgnorePointer(child: Container(color: on ? Colors.white24 : Colors.transparent));
        },
      ),
      SafeArea(
        child: AnimatedBuilder(
          animation: _state,
          builder: (_, __) => Column(children: [
            _topBar(),
            const SizedBox(height: 10),
            _hintPill(),
            Expanded(child: _state.selected ? const SizedBox() : _reticle()),
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
        const Text('Live Scan', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        if (_state.selected && _state.aiSelection) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: holoCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: holoCyan.withValues(alpha: 0.7)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.auto_awesome_rounded, size: 13, color: holoCyan),
              SizedBox(width: 4),
              Text('AI object', style: TextStyle(color: holoCyan, fontSize: 11, fontWeight: FontWeight.w700)),
            ]),
          ),
        ],
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

  Widget _hintPill() {
    return _glass(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      radius: 24,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          _state.tracking ? Icons.navigation_rounded : Icons.sync_problem_rounded,
          size: 16,
          color: _state.tracking ? holoCyan : Colors.amber,
        ),
        const SizedBox(width: 8),
        Text(_state.hint, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _reticle() {
    return IgnorePointer(
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 120,
            height: 120,
            child: CustomPaint(painter: _ReticlePainter(_anim.value)),
          ),
          const SizedBox(height: 14),
          if (_state.selecting)
            const Text('Finding the object…', style: TextStyle(color: holoCyan, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _bottomPanel() {
    final cap = (_state.captured * 100).round();
    final det = (_state.detail * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _glass(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        radius: 22,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('$cap%',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1.0)),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 3),
                    child: Text('captured', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ]),
                const SizedBox(height: 8),
                _bar(_state.captured, const [Color(0xFF1EC8FF), holoGreen], 10),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('Detail', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: 8),
                  Expanded(child: _bar(_state.detail, const [Color(0xFFFF8A1F), Color(0xFFFFD23F)], 6)),
                  const SizedBox(width: 8),
                  Text('$det%', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            const SizedBox(width: 14),
            BinsRing(bins: _state.bins, size: 70),
          ]),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _roundButton(
              icon: Icons.motion_photos_auto_rounded,
              label: 'Auto',
              active: _state.auto,
              onTap: _demo
                  ? null
                  : () {
                      _live.setAuto(!_state.auto);
                    },
            ),
            _roundButton(
              icon: Icons.restart_alt_rounded,
              label: 'Reselect',
              active: false,
              onTap: _demo || !_state.selected ? null : () => _live.reset(),
            ),
            GestureDetector(
              onTap: _demo || !_state.selected ? null : () => _live.shutter(),
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                padding: const EdgeInsets.all(5),
                child: Container(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: SfColors.accent),
                ),
              ),
            ),
            _roundButton(
              icon: Icons.check_rounded,
              label: 'Done',
              active: _state.photos >= 8,
              onTap: _demo ? null : _done,
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _bar(double v, List<Color> colors, double h) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth * v.clamp(0.0, 1.0);
      return Stack(children: [
        Container(
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(h),
          ),
        ),
        Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(h),
            boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.6), blurRadius: 10)],
          ),
        ),
      ]);
    });
  }

  Widget _roundButton({required IconData icon, required String label, required bool active, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? SfColors.accent : Colors.white.withValues(alpha: 0.12),
          ),
          child: Icon(icon, color: active ? Colors.black : Colors.white, size: 24),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      ]),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  final double t;
  _ReticlePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = holoCyan;
    for (var i = 0; i < 4; i++) {
      final a = i * 3.14159265 / 2 + t * 3.14159265;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a + 0.25, 1.0, false, p);
    }
    canvas.drawCircle(c, 5, Paint()..color = holoCyan);
    canvas.drawCircle(
        c,
        r * 0.55,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) => old.t != t;
}
