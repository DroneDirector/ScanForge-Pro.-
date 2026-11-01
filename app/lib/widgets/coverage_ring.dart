import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/orientation_tracker.dart';
import '../theme.dart';

/// Radar-style ring showing which sides/heights of the object are photographed.
class CoverageRing extends StatelessWidget {
  final Coverage coverage;
  final int? currentRing;
  final int? currentSegment;
  final double size;

  const CoverageRing({
    super.key,
    required this.coverage,
    this.currentRing,
    this.currentSegment,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RingPainter(coverage, currentRing, currentSegment)),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Coverage cov;
  final int? ring, seg;
  _RingPainter(this.cov, this.ring, this.seg);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    final bg = Paint()..color = const Color(0x99000000);
    canvas.drawCircle(c, maxR, bg);
    const n = Coverage.segments;
    final sweep = 2 * math.pi / n;
    for (var r = 0; r < Coverage.rings; r++) {
      // outer ring = low (camera level), inner = high (looking down)
      final outer = maxR * (0.96 - r * 0.27);
      final inner = outer - maxR * 0.22;
      final rr = (outer + inner) / 2;
      final w = outer - inner;
      for (var s = 0; s < n; s++) {
        final covered = cov.counts[r][s] > 0;
        final isCurrent = ring == r && seg == s;
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = isCurrent
              ? Colors.white
              : covered
                  ? SfColors.accent
                  : const Color(0x40FFFFFF);
        final start = -math.pi / 2 + s * sweep + sweep * 0.08;
        canvas.drawArc(Rect.fromCircle(center: c, radius: rr), start, sweep * 0.84, false, paint);
      }
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '${(cov.score * 100).round()}%',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => true;
}
