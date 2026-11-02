import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Live state of a Live Scan, fed by the native AR session (or by demo data).
class LiveScanState extends ChangeNotifier {
  bool tracking = false;
  Float32List view = Float32List(16); // camera view matrix (column major)
  Float32List proj = Float32List(16); // projection matrix (column major)
  String hint = 'Move the phone slowly to start tracking';
  int photos = 0;
  bool selecting = false;
  bool auto = true;

  // selected object
  bool selected = false;
  bool aiSelection = false;
  Float32List? baseCenter; // x, y (bottom), z in metres
  double radius = 0;
  double bottom = 0;
  double top = 0;
  Float32List outline = Float32List(0); // x,y,z triples

  // hologram
  Float32List points = Float32List(0); // x,y,z,state quadruples
  double captured = 0; // 0..1
  double detail = 0; // 0..1
  Uint8List bins = Uint8List(72);
  DateTime? lastPhoto;
  String? message;

  void apply(Map<dynamic, dynamic> e) {
    switch (e['type']) {
      case 'frame':
        tracking = e['tracking'] == true;
        view = e['view'] as Float32List;
        proj = e['proj'] as Float32List;
        hint = e['hint'] as String? ?? hint;
        photos = (e['photos'] as int?) ?? photos;
        selecting = e['selecting'] == true;
        auto = e['auto'] != false;
      case 'points':
        points = e['data'] as Float32List;
        captured = (e['captured'] as num).toDouble();
        detail = (e['detail'] as num).toDouble();
        bins = e['bins'] as Uint8List;
      case 'selected':
        if (e['cleared'] == true) {
          selected = false;
          points = Float32List(0);
          outline = Float32List(0);
          captured = 0;
          detail = 0;
          bins = Uint8List(72);
        } else {
          selected = true;
          aiSelection = e['ai'] == true;
          baseCenter = e['center'] as Float32List;
          radius = (e['radius'] as num).toDouble();
          bottom = (e['bottom'] as num).toDouble();
          top = (e['top'] as num).toDouble();
          outline = e['outline'] as Float32List;
        }
      case 'photo':
        photos = e['photos'] as int;
        lastPhoto = DateTime.now();
      case 'message':
        message = e['text'] as String?;
    }
    notifyListeners();
  }
}

/// Talks to the native ARCore Live Scan.
class LiveScan {
  static const _ch = MethodChannel('scanforge/live');
  static const _events = EventChannel('scanforge/live/events');

  static bool get platformSupported => Platform.isAndroid;

  /// 'supported', 'install', 'checking', 'unsupported'
  static Future<String> availability() async {
    if (!platformSupported) return 'unsupported';
    try {
      for (var i = 0; i < 10; i++) {
        final a = await _ch.invokeMethod<String>('availability') ?? 'unsupported';
        if (a != 'checking') return a;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (_) {}
    return 'unsupported';
  }

  static Future<String> install() async => await _ch.invokeMethod<String>('install') ?? 'failed';
  static Future<bool> cameraPermission() async => await _ch.invokeMethod<bool>('cameraPermission') ?? false;

  StreamSubscription? _sub;
  final LiveScanState state = LiveScanState();

  Future<String> open(String projectDir) async {
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is Map) state.apply(e);
    });
    return await _ch.invokeMethod<String>('open', {'project': projectDir}) ?? 'error';
  }

  Future<void> tap(double x, double y) => _ch.invokeMethod('tap', {'x': x, 'y': y});
  Future<void> shutter() => _ch.invokeMethod('shutter');
  Future<void> setAuto(bool on) => _ch.invokeMethod('auto', {'on': on});
  Future<void> reset() => _ch.invokeMethod('reset');

  /// Returns number of photos saved and the photo rotation in degrees.
  Future<(int, int)> finish() async {
    final r = await _ch.invokeMethod<Map>('finish');
    await _sub?.cancel();
    _sub = null;
    return ((r?['photos'] as int?) ?? 0, (r?['rotation'] as int?) ?? 90);
  }
}
