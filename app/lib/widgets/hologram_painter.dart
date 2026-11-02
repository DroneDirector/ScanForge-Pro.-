import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/live_scan.dart';

const holoCyan = Color(0xFF3FE3FF);
const holoGreen = Color(0xFF3FFFA0);
const holoYellow = Color(0xFFFFD23F);
const holoRed = Color(0xFFFF4D6D);

/// Draws the AR hologram on top of the camera view: the measured surface of
/// the object as glowing points (green = captured, yellow = one photo,
/// red = seen but not photographed yet), the AI outline of the selected
/// object and rings showing which angles are photographed.
class HologramPainter extends CustomPainter {
  final LiveScanState s;
  final double anim; // 0..1 repeating
  HologramPainter(this.s, this.anim) : super(repaint: s);

  Offset? _project(Size size, double x, double y, double z) {
    final m = _pv;
    final cx = m[0] * x + m[4] * y + m[8] * z + m[12];
    final cy = m[1] * x + m[5] * y + m[9] * z + m[13];
    final cw = m[3] * x + m[7] * y + m[11] * z + m[15];
    if (cw <= 1e-4) return null;
    return Offset((cx / cw + 1) * 0.5 * size.width, (1 - cy / cw) * 0.5 * size.height);
  }

  late Float64List _pv;

  void _computePV() {
    final p = s.proj, v = s.view;
    final r = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var row = 0; row < 4; row++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += p[k * 4 + row] * v[c * 4 + k];
        }
        r[c * 4 + row] = sum;
      }
    }
    _pv = r;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // what is captured stays visible, also while tracking is briefly lost
    if (s.proj.every((e) => e == 0)) return;
    _computePV();
    if (!s.tracking) canvas.saveLayer(Offset.zero & size, Paint()..color = const Color(0x88FFFFFF));
    if (s.box != null) _box(canvas, size, s.box!);
    if (s.selected && (s.box == null || s.scanning)) _rings(canvas, size);
    if (s.box == null || s.showDots) _points(canvas, size);
    if (s.selected && s.outline.isNotEmpty && s.photos < 3) _outline(canvas, size);
    if (!s.tracking) canvas.restore();
  }

  void _points(Canvas canvas, Size size) {
    final pts = s.points;
    if (pts.isEmpty) return;
    final buckets = [<double>[], <double>[], <double>[]];
    for (var i = 0; i + 3 < pts.length; i += 4) {
      final o = _project(size, pts[i], pts[i + 1], pts[i + 2]);
      if (o == null) continue;
      if (o.dx < -10 || o.dy < -10 || o.dx > size.width + 10 || o.dy > size.height + 10) continue;
      final st = pts[i + 3].round().clamp(0, 2);
      buckets[st]
        ..add(o.dx)
        ..add(o.dy);
    }
    const colors = [holoRed, holoYellow, holoGreen];
    for (var st = 0; st < 3; st++) {
      if (buckets[st].isEmpty) continue;
      final raw = Float32List.fromList(buckets[st]);
      final c = colors[st];
      // soft glow, then bright core
      canvas.drawRawPoints(
        ui.PointMode.points,
        raw,
        Paint()
          ..color = c.withValues(alpha: 0.22)
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.plus,
      );
      canvas.drawRawPoints(
        ui.PointMode.points,
        raw,
        Paint()
          ..color = Color.lerp(c, Colors.white, 0.35)!.withValues(alpha: 0.95)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _outline(Canvas canvas, Size size) {
    final o = s.outline;
    final pulse = 0.55 + 0.45 * math.sin(anim * 2 * math.pi);
    final list = <double>[];
    for (var i = 0; i + 2 < o.length; i += 3) {
      final p = _project(size, o[i], o[i + 1], o[i + 2]);
      if (p == null) continue;
      list
        ..add(p.dx)
        ..add(p.dy);
    }
    if (list.isEmpty) return;
    final raw = Float32List.fromList(list);
    canvas.drawRawPoints(
      ui.PointMode.points,
      raw,
      Paint()
        ..color = holoCyan.withValues(alpha: 0.25 * pulse)
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..blendMode = BlendMode.plus,
    );
    canvas.drawRawPoints(
      ui.PointMode.points,
      raw,
      Paint()
        ..color = holoCyan.withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Corners of the scan box (same convention as the engine's box.txt).
  static List<List<double>> boxCorners(List<double> b) {
    final cy = math.cos(b[3]), sy = math.sin(b[3]);
    final out = <List<double>>[];
    for (var k = 0; k < 8; k++) {
      final lx = (k & 1 != 0 ? 0.5 : -0.5) * b[4];
      final lz = (k & 2 != 0 ? 0.5 : -0.5) * b[5];
      final lh = k & 4 != 0 ? b[6] : 0.0;
      out.add([b[0] + cy * lx + sy * lz, b[1] + lh, b[2] - sy * lx + cy * lz]);
    }
    return out;
  }

  void _box(Canvas canvas, Size size, List<double> b) {
    final cs = boxCorners(b).map((c) => _project(size, c[0], c[1], c[2])).toList();
    const edges = [
      [0, 1], [1, 3], [3, 2], [2, 0], // bottom
      [4, 5], [5, 7], [7, 6], [6, 4], // top
      [0, 4], [1, 5], [2, 6], [3, 7], // sides
    ];
    final adjusting = !s.scanning;
    final pulse = 0.6 + 0.4 * math.sin(anim * 2 * math.pi);
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = adjusting ? 10 : 6
      ..strokeCap = StrokeCap.round
      ..color = holoCyan.withValues(alpha: (adjusting ? 0.28 * pulse : 0.12))
      ..blendMode = BlendMode.plus;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = adjusting ? 2.4 : 1.4
      ..strokeCap = StrokeCap.round
      ..color = adjusting ? holoCyan : Colors.white.withValues(alpha: 0.55);
    // faint bottom face so the footprint is easy to see
    if (cs[0] != null && cs[1] != null && cs[3] != null && cs[2] != null) {
      final face = Path()
        ..moveTo(cs[0]!.dx, cs[0]!.dy)
        ..lineTo(cs[1]!.dx, cs[1]!.dy)
        ..lineTo(cs[3]!.dx, cs[3]!.dy)
        ..lineTo(cs[2]!.dx, cs[2]!.dy)
        ..close();
      canvas.drawPath(face, Paint()..color = holoCyan.withValues(alpha: adjusting ? 0.16 : 0.07));
    }
    for (final e in edges) {
      final a = cs[e[0]], c = cs[e[1]];
      if (a == null || c == null) continue;
      canvas.drawLine(a, c, glow);
      canvas.drawLine(a, c, line);
    }
    if (adjusting) {
      for (final p in cs) {
        if (p == null) continue;
        canvas.drawCircle(p, 5, Paint()..color = Colors.white);
        canvas.drawCircle(p, 3, Paint()..color = holoCyan);
      }
    }
  }

  /// Three rings (low, middle, high viewing angles) around the object, split in
  /// 24 segments; photographed directions light up green. A scan ring sweeps
  /// up and down the object.
  void _rings(Canvas canvas, Size size) {
    final b = s.box;
    final c = s.baseCenter;
    if (c == null && b == null) return;
    final double cx, cz, r, bottom, objTop;
    if (b != null) {
      // dome around the scan box
      cx = b[0];
      cz = b[2];
      r = 0.5 * math.sqrt(b[4] * b[4] + b[5] * b[5]) * 1.25;
      bottom = b[1];
      objTop = b[1] + b[6];
    } else {
      cx = c![0];
      cz = c[2];
      // rings hug the object itself, not the padded scan region
      r = math.max(s.radius * 0.6, (s.radius - 0.015) / 1.4 * 1.3);
      bottom = s.bottom;
      objTop = s.objectTop ?? s.top;
    }
    final h = objTop - bottom;
    final heights = [bottom + 0.02 * h, bottom + 0.5 * h, objTop + 0.15 * h];
    for (var band = 0; band < 3; band++) {
      final y = heights[band];
      final rr = r * (band == 2 ? 0.8 : 1.0);
      for (var seg = 0; seg < 24; seg++) {
        final on = s.bins.length == 72 && s.bins[band * 24 + seg] > 0;
        final path = Path();
        var first = true;
        for (var k = 0; k <= 6; k++) {
          final a = (seg + 0.08 + 0.84 * k / 6) / 24 * 2 * math.pi;
          final p = _project(size, cx + rr * math.sin(a), y, cz + rr * math.cos(a));
          if (p == null) {
            first = true;
            continue;
          }
          if (first) {
            path.moveTo(p.dx, p.dy);
            first = false;
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        if (on) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 10
              ..strokeCap = StrokeCap.round
              ..color = holoGreen.withValues(alpha: 0.25)
              ..blendMode = BlendMode.plus,
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = on ? 3.5 : 2
            ..strokeCap = StrokeCap.round
            ..color = on ? holoGreen : Colors.white.withValues(alpha: 0.28),
        );
      }
    }
    // sweeping scan ring
    final sweep = 0.5 - 0.5 * math.cos(anim * 2 * math.pi);
    final y = bottom + sweep * h;
    final path = Path();
    var first = true;
    for (var k = 0; k <= 72; k++) {
      final a = k / 72 * 2 * math.pi;
      final p = _project(size, cx + r * 0.97 * math.sin(a), y, cz + r * 0.97 * math.cos(a));
      if (p == null) {
        first = true;
        continue;
      }
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = holoCyan.withValues(alpha: 0.16)
        ..blendMode = BlendMode.plus,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = holoCyan.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant HologramPainter old) => old.anim != anim || old.s != s;
}

/// Small flat version of the angle rings for the bottom panel.
class BinsRing extends StatelessWidget {
  final Uint8List bins;
  final double size;
  const BinsRing({super.key, required this.bins, this.size = 64});

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _BinsPainter(bins)));
}

class _BinsPainter extends CustomPainter {
  final Uint8List bins;
  _BinsPainter(this.bins);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    const sweep = 2 * math.pi / 24;
    for (var band = 0; band < 3; band++) {
      final rr = maxR * (0.88 - band * 0.28);
      for (var seg = 0; seg < 24; seg++) {
        final on = bins.length == 72 && bins[band * 24 + seg] > 0;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: rr),
          -math.pi / 2 + seg * sweep + sweep * 0.1,
          sweep * 0.8,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = maxR * 0.18
            ..color = on ? holoGreen : Colors.white.withValues(alpha: 0.18),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BinsPainter old) => true;
}
