import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/project.dart';
import '../services/orientation_tracker.dart';
import '../services/project_store.dart';
import '../theme.dart';
import '../widgets/coverage_ring.dart';

/// Guided photo capture: the ring shows which sides are already covered.
class CaptureScreen extends StatefulWidget {
  final ScanProject project;
  const CaptureScreen({super.key, required this.project});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  String? _error;
  final _tracker = OrientationTracker();
  final _coverage = Coverage();
  Timer? _ui;
  bool _busy = false;
  bool _auto = false;
  int _count = 0;
  DateTime _lastShot = DateTime.fromMillisecondsSinceEpoch(0);
  bool _flash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.enable();
    _count = widget.project.photos().length;
    _tracker.start();
    _initCamera();
    _ui = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final ctrl = CameraController(back, ResolutionPreset.max,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await ctrl.initialize();
      await ctrl.setFlashMode(FlashMode.off);
      try {
        await ctrl.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _cam = ctrl);
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied'
          ? 'Camera access was denied. Allow camera access for ScanForge Pro in the system settings.'
          : 'Camera error: ${e.description ?? e.code}');
    } catch (e) {
      setState(() => _error = 'Camera error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _cam;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _cam = null;
      c?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _initCamera();
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (_auto && !_busy && _cam != null && _tracker.steady && _tracker.heading != null) {
      final since = DateTime.now().difference(_lastShot).inMilliseconds;
      if (since > 900 && !_coverage.isCovered(_tracker.heading, _tracker.downAngle)) {
        _shoot();
      }
    }
  }

  Future<void> _shoot() async {
    final cam = _cam;
    if (cam == null || _busy || cam.value.isTakingPicture) return;
    _busy = true;
    final heading = _tracker.heading;
    final down = _tracker.downAngle;
    try {
      final file = await cam.takePicture();
      final dst = ProjectStore.instance.nextPhotoPath(widget.project);
      await file.saveTo(dst);
      _coverage.add(heading, down);
      _count++;
      _lastShot = DateTime.now();
      if (_count == 1 && widget.project.focal35 <= 0) {
        widget.project.focal35 = await ProjectStore.readFocal35(dst);
        await widget.project.save();
      }
      HapticFeedback.lightImpact();
      setState(() => _flash = true);
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _flash = false);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not take photo: $e')));
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ui?.cancel();
    _tracker.stop();
    _cam?.dispose();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  String get _hint {
    if (_tracker.heading == null) return 'Hold the phone still for a moment';
    if (_count == 0) return 'Place the object in the middle, then take the first photo';
    final covered = _coverage.isCovered(_tracker.heading, _tracker.downAngle);
    if (!_tracker.steady) return 'Hold steady';
    if (_coverage.score > 0.85) return 'Great coverage. Tap Done when ready';
    if (covered) return 'Step sideways around the object';
    return 'New angle: take a photo';
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final heading = _tracker.heading;
    final ring = _coverage.ringFor(_tracker.downAngle);
    final seg = heading == null ? null : _coverage.segmentFor(heading);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (cam != null && cam.value.isInitialized)
          Center(child: CameraPreview(cam))
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: _error != null
                  ? Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))
                  : const CircularProgressIndicator(),
            ),
          ),
        // centre target
        IgnorePointer(
          child: Center(
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54, width: 1.5),
              ),
            ),
          ),
        ),
        if (_flash) Container(color: Colors.white24),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$_count photos',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(_hint, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    ]),
                  ),
                ),
                CoverageRing(coverage: _coverage, currentRing: ring, currentSegment: seg, size: 130),
              ]),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                _RoundToggle(
                  label: 'Auto',
                  active: _auto,
                  icon: Icons.motion_photos_auto_rounded,
                  onTap: () => setState(() => _auto = !_auto),
                ),
                GestureDetector(
                  onTap: _shoot,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    padding: const EdgeInsets.all(5),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _busy ? Colors.white54 : SfColors.accent,
                      ),
                    ),
                  ),
                ),
                _RoundToggle(
                  label: 'Done',
                  active: _count >= 20,
                  icon: Icons.check_rounded,
                  onTap: () => Navigator.pop(context),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _RoundToggle extends StatelessWidget {
  final String label;
  final bool active;
  final IconData icon;
  final VoidCallback onTap;
  const _RoundToggle({required this.label, required this.active, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? SfColors.accent : Colors.black54,
          ),
          child: Icon(icon, color: active ? Colors.black : Colors.white),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}
