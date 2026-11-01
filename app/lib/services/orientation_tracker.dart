import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// Tracks which way the phone camera points (compass heading + tilt) and
/// whether the phone is held steady. Used for the guided capture ring.
class OrientationTracker {
  final _subs = <StreamSubscription>[];
  List<double> _acc = [0, 0, 9.8];
  List<double> _mag = [0, 30, -30];
  double _motion = 0;
  double? _heading; // filtered, degrees 0..360
  double _down = 0; // degrees the camera points below the horizon

  /// Heading of the camera view in degrees (0..360), null until known.
  double? get heading => _heading;

  /// Degrees below the horizon (positive = looking down).
  double get downAngle => _down;

  /// True when the phone is held still enough for a sharp photo.
  bool get steady => _motion < 0.5;

  void start() {
    const period = Duration(milliseconds: 40);
    _subs.add(accelerometerEventStream(samplingPeriod: period).listen((e) {
      _acc = [e.x, e.y, e.z];
      _update();
    }, onError: (_) {}));
    _subs.add(magnetometerEventStream(samplingPeriod: period).listen((e) {
      _mag = [e.x, e.y, e.z];
    }, onError: (_) {}));
    _subs.add(userAccelerometerEventStream(samplingPeriod: period).listen((e) {
      final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      _motion = _motion * 0.8 + m * 0.2;
    }, onError: (_) {}));
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  static List<double> _cross(List<double> a, List<double> b) =>
      [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

  static List<double>? _norm(List<double> v) {
    final n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (n < 1e-6) return null;
    return [v[0] / n, v[1] / n, v[2] / n];
  }

  void _update() {
    final a = _norm(_acc);
    if (a == null) return;
    final h = _norm(_cross(_mag, a)); // east
    if (h == null) return;
    final m = _cross(a, h); // north
    // back camera looks along -z of the device
    final east = -h[2], north = -m[2], up = -a[2];
    _down = -math.asin(up.clamp(-1.0, 1.0)) * 180 / math.pi;
    var hd = math.atan2(east, north) * 180 / math.pi;
    if (hd < 0) hd += 360;
    if (_heading == null) {
      _heading = hd;
    } else {
      var d = hd - _heading!;
      if (d > 180) d -= 360;
      if (d < -180) d += 360;
      _heading = (_heading! + d * 0.15) % 360;
      if (_heading! < 0) _heading = _heading! + 360;
    }
  }
}

/// Coverage of viewing directions: rings (heights) x segments (around).
class Coverage {
  static const segments = 24;
  static const rings = 3; // low, middle, high
  final List<List<int>> counts = List.generate(rings, (_) => List.filled(segments, 0));
  double? reference; // heading of the first photo

  int ringFor(double downAngle) {
    if (downAngle < 15) return 0;
    if (downAngle < 40) return 1;
    return 2;
  }

  /// Segment index relative to the first photo. Moving around the object to
  /// the right turns the camera heading the other way, so it is mirrored to
  /// make the ring fill up in the direction the user walks.
  int segmentFor(double heading) {
    final ref = reference ?? heading;
    var rel = (ref - heading) % 360;
    if (rel < 0) rel += 360;
    return (rel / (360 / segments)).floor() % segments;
  }

  void add(double? heading, double downAngle) {
    if (heading == null) return;
    reference ??= heading;
    counts[ringFor(downAngle)][segmentFor(heading)]++;
  }

  bool isCovered(double? heading, double downAngle) {
    if (heading == null) return false;
    return counts[ringFor(downAngle)][segmentFor(heading)] > 0;
  }

  int coveredInRing(int r) => counts[r].where((c) => c > 0).length;

  /// 0..1 overall coverage score (the middle ring counts most).
  double get score {
    final low = coveredInRing(0) / segments, mid = coveredInRing(1) / segments, high = coveredInRing(2) / segments;
    return (0.35 * low + 0.45 * mid + 0.2 * high).clamp(0.0, 1.0);
  }
}
