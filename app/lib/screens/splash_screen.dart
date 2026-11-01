import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/engine.dart';
import '../services/project_store.dart';
import '../theme.dart';
import 'home_screen.dart';

/// Animated start screen: a point cloud gathers into the ScanForge cube,
/// a scan line sweeps over it and the scan rings spin up, while a progress
/// bar shows the app getting ready.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..forward();
  late final AnimationController _loop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  double _work = 0; // real start-up work, 0..1
  String _status = 'Starting';
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _intro.addListener(_maybeFinish);
    _intro.addStatusListener((_) => _maybeFinish());
    _prepare();
  }

  Future<void> _prepare() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _step(0.25, 'Loading 3D engine');
    try {
      engineVersion();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _step(0.55, 'Opening your scans');
    try {
      await ProjectStore.instance.list();
    } catch (_) {}
    _step(0.85, 'Preparing the viewer');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _step(1.0, 'Ready');
  }

  void _step(double v, String s) {
    if (!mounted) return;
    setState(() {
      _work = v;
      _status = s;
    });
    _maybeFinish();
  }

  double get _progress => math.min(_work, Curves.easeInOut.transform(_intro.value));

  void _maybeFinish() {
    if (_leaving || !mounted) return;
    if (_work >= 1 && _intro.isCompleted) {
      _leaving = true;
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (_, __, ___) => const HomeScreen(),
          transitionsBuilder: (_, a, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween(begin: 1.04, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
              child: child,
            ),
          ),
        ));
      });
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SfColors.background,
      body: AnimatedBuilder(
        animation: Listenable.merge([_intro, _loop]),
        builder: (context, _) {
          final t = _intro.value;
          final title = Curves.easeOut.transform(((t - 0.55) / 0.35).clamp(0.0, 1.0));
          final pct = (_progress * 100).round();
          return Stack(fit: StackFit.expand, children: [
            CustomPaint(painter: _SplashPainter(t, _loop.value)),
            SafeArea(
              child: Column(children: [
                const Spacer(flex: 13),
                Opacity(
                  opacity: title,
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - title)),
                    child: Column(children: [
                      ShaderMask(
                        shaderCallback: (r) => const LinearGradient(
                          colors: [Color(0xFFFFC27A), SfColors.accent, Color(0xFFFF6A00)],
                        ).createShader(r),
                        child: const Text(
                          'ScanForge Pro',
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'PHOTOS  →  3D  →  PRINT',
                        style: TextStyle(color: SfColors.textDim, fontSize: 12, letterSpacing: 3),
                      ),
                    ]),
                  ),
                ),
                const Spacer(flex: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Column(children: [
                    _GlowBar(value: _progress, shimmer: _loop.value),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Text(_status,
                            style: const TextStyle(color: SfColors.textDim, fontSize: 12, letterSpacing: 0.4)),
                      ),
                      Text('$pct%',
                          style: const TextStyle(
                              color: SfColors.accent, fontSize: 13, fontWeight: FontWeight.w700,
                              fontFeatures: [ui.FontFeature.tabularFigures()])),
                    ]),
                  ]),
                ),
                const Spacer(flex: 2),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress bar with glow and a moving shimmer
// ---------------------------------------------------------------------------
class _GlowBar extends StatelessWidget {
  final double value;
  final double shimmer;
  const _GlowBar({required this.value, required this.shimmer});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: CustomPaint(painter: _BarPainter(value.clamp(0.0, 1.0), shimmer), size: Size.infinite),
    );
  }
}

class _BarPainter extends CustomPainter {
  final double v, s;
  _BarPainter(this.v, this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(track, Paint()..color = const Color(0xFF232A33));
    if (v <= 0) return;
    final w = math.max(size.height, size.width * v);
    final fill = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), r);
    // glow
    canvas.drawRRect(
      fill,
      Paint()
        ..color = SfColors.accent.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(
      fill,
      Paint()
        ..shader = const LinearGradient(colors: [Color(0xFFFF6A00), SfColors.accent, Color(0xFFFFC27A)])
            .createShader(Rect.fromLTWH(0, 0, w, size.height)),
    );
    // shimmer
    canvas.save();
    canvas.clipRRect(fill);
    final x = (s * 1.6 - 0.3) * size.width;
    canvas.drawRect(
      Rect.fromLTWH(x - 40, 0, 80, size.height),
      Paint()
        ..shader = LinearGradient(colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0),
        ]).createShader(Rect.fromLTWH(x - 40, 0, 80, size.height)),
    );
    canvas.restore();
    // bright head
    canvas.drawCircle(Offset(w - size.height / 2, size.height / 2), size.height * 0.9,
        Paint()
          ..color = const Color(0xFFFFD9A8).withValues(alpha: 0.8)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
  }

  @override
  bool shouldRepaint(covariant _BarPainter o) => o.v != v || o.s != s;
}

// ---------------------------------------------------------------------------
// The animated cube (same design as the app icon)
// ---------------------------------------------------------------------------
class _SplashPainter extends CustomPainter {
  final double t; // intro 0..1
  final double loop; // repeating 0..1
  _SplashPainter(this.t, this.loop);

  static final List<Offset> _seeds = () {
    final rnd = math.Random(11);
    return List.generate(90, (_) => Offset(rnd.nextDouble() * 2 - 1, rnd.nextDouble() * 2 - 1));
  }();

  double _seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    // background glow
    final center = Offset(size.width / 2, size.height * 0.40);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: const [Color(0xFF262C35), SfColors.background],
          radius: 0.8,
        ).createShader(Rect.fromCircle(center: center, radius: size.shortestSide)),
    );

    final a = size.shortestSide * 0.20;
    final bob = math.sin(loop * 2 * math.pi) * a * 0.025 * _seg(0.6, 1.0);
    final c = center + Offset(0, bob);
    final p = <String, Offset>{
      't': c + Offset(0, -a),
      'tl': c + Offset(-a * 0.87, -a * 0.5),
      'tr': c + Offset(a * 0.87, -a * 0.5),
      'm': c,
      'bl': c + Offset(-a * 0.87, a * 0.5),
      'br': c + Offset(a * 0.87, a * 0.5),
      'b': c + Offset(0, a),
    };

    // ---- back half of the scan rings (behind the cube)
    _rings(canvas, c, a, back: true);

    // ---- pulsing glow behind the cube
    final glow = _seg(0.35, 0.7) * (0.75 + 0.25 * math.sin(loop * 2 * math.pi));
    canvas.drawCircle(
      c,
      a * 1.25,
      Paint()
        ..color = SfColors.accent.withValues(alpha: 0.22 * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, a * 0.5),
    );

    // ---- point cloud gathering into the cube outline
    final gather = Curves.easeInOutCubic.transform(_seg(0.0, 0.45));
    final cloudFade = 1 - _seg(0.42, 0.6);
    if (cloudFade > 0) {
      final edges = _edges(p);
      final dot = Paint()..color = SfColors.accent.withValues(alpha: 0.9 * cloudFade);
      for (var i = 0; i < _seeds.length; i++) {
        final e = edges[i % edges.length];
        final f = (i * 0.618) % 1.0;
        final target = Offset.lerp(e.$1, e.$2, f)!;
        final start = c + Offset(_seeds[i].dx * size.width * 0.6, _seeds[i].dy * size.height * 0.45);
        final pos = Offset.lerp(start, target, gather)!;
        canvas.drawCircle(pos, 1.6 + 1.2 * (1 - gather), dot);
      }
    }

    // ---- faces, revealed top-down by the scan line
    final reveal = Curves.easeInOut.transform(_seg(0.35, 0.7));
    final scanY = (c.dy - a * 1.1) + reveal * a * 2.2;
    if (reveal > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, size.width, scanY));
      _face(canvas, [p['t']!, p['tr']!, p['m']!, p['tl']!], const Color(0xFFFFA03C), const Color(0xFFFF8A1F));
      _face(canvas, [p['tl']!, p['m']!, p['b']!, p['bl']!], const Color(0xFFE6701A), const Color(0xFFCC5E12));
      _face(canvas, [p['m']!, p['tr']!, p['br']!, p['b']!], const Color(0xFFC0520A), const Color(0xFF9E4108));
      canvas.restore();
    }

    // ---- edges drawn progressively
    final draw = Curves.easeOut.transform(_seg(0.2, 0.55));
    if (draw > 0) {
      final edge = Paint()
        ..color = const Color(0xFFFFF0E2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = a * 0.045
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final e in _edges(p)) {
        canvas.drawLine(e.$1, Offset.lerp(e.$1, e.$2, draw)!, edge);
      }
    }

    // ---- scan line
    if (reveal > 0 && reveal < 1) {
      final w = a * 1.4;
      final line = Rect.fromLTWH(c.dx - w, scanY - 1.5, w * 2, 3);
      canvas.drawRect(
        line.inflate(6),
        Paint()
          ..color = SfColors.accent.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawRect(
        line,
        Paint()
          ..shader = LinearGradient(colors: [
            SfColors.accent.withValues(alpha: 0),
            const Color(0xFFFFE0B8),
            SfColors.accent.withValues(alpha: 0),
          ]).createShader(line),
      );
    }

    // ---- front half of the scan rings (over the cube, like the icon)
    _rings(canvas, c, a, back: false);
  }

  List<(Offset, Offset)> _edges(Map<String, Offset> p) => [
        (p['t']!, p['tr']!),
        (p['tr']!, p['m']!),
        (p['m']!, p['tl']!),
        (p['tl']!, p['t']!),
        (p['tl']!, p['bl']!),
        (p['bl']!, p['b']!),
        (p['b']!, p['br']!),
        (p['br']!, p['tr']!),
        (p['m']!, p['b']!),
      ];

  void _face(Canvas canvas, List<Offset> pts, Color c1, Color c2) {
    final path = Path()..addPolygon(pts, true);
    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()..shader = LinearGradient(colors: [c1, c2], begin: Alignment.topLeft, end: Alignment.bottomRight)
          .createShader(bounds),
    );
  }

  void _rings(Canvas canvas, Offset c, double a, {required bool back}) {
    final grow = Curves.easeOutBack.transform(_seg(0.45, 0.8));
    if (grow <= 0) return;
    final rc = c + Offset(0, a * 0.35);
    for (var k = 0; k < 2; k++) {
      final rx = a * (1.55 + 0.22 * k) * grow;
      final ry = rx * 0.42;
      final rect = Rect.fromCenter(center: rc, width: rx * 2, height: ry * 2);
      final base = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = a * (k == 0 ? 0.085 : 0.055)
        ..color = SfColors.accent.withValues(alpha: back ? 0.22 : 0.95);
      // back half = upper arc (behind the cube), front half = lower arc
      final start = back ? math.pi + 0.26 : 0.26;
      const sweep = math.pi - 0.52;
      canvas.drawArc(rect, start, sweep, false, base);
      if (!back) {
        // bright comet travelling around the ring
        final ang = (loop + k * 0.5) * 2 * math.pi;
        final pos = Offset(rc.dx + math.cos(ang) * rx, rc.dy + math.sin(ang) * ry);
        final inFront = math.sin(ang) > 0;
        canvas.drawCircle(
          pos,
          a * (inFront ? 0.075 : 0.05),
          Paint()
            ..color = const Color(0xFFFFE6C8).withValues(alpha: inFront ? 0.95 : 0.35)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, a * 0.05),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SplashPainter o) => o.t != t || o.loop != loop;
}
