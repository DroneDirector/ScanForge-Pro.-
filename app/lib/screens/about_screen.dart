import 'package:flutter/material.dart';

import '../services/engine.dart';
import '../theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    String engine;
    try {
      engine = engineVersion();
    } catch (_) {
      engine = 'not loaded';
    }
    const credits = [
      ['OpenCV', 'Apache License 2.0', 'Image processing, feature detection (SIFT) and geometry.'],
      ['Flutter', 'BSD 3-Clause', 'App framework.'],
      ['camera, path_provider, share_plus, sensors_plus, wakelock_plus', 'BSD 3-Clause', 'Flutter plugins.'],
      ['file_picker', 'MIT', 'Choosing photos and saving files.'],
      ['exif', 'MIT', 'Reading the focal length and GPS position from photos.'],
      ['ARCore SDK', 'Apache License 2.0', 'Live Scan tracking and depth (Google Play Services for AR).'],
      ['MediaPipe + Magic Touch model', 'Apache License 2.0', 'On-device AI object selection.'],
      ['geolocator', 'MIT', 'Phone location for large scans (optional).'],
      ['ffi', 'BSD 3-Clause', 'Connecting the app to the 3D engine.'],
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        const Row(children: [
          Icon(Icons.view_in_ar_rounded, color: SfColors.accent, size: 44),
          SizedBox(width: 14),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ScanForge Pro', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            Text('Photos to printable 3D models', style: TextStyle(color: SfColors.textDim)),
          ]),
        ]),
        const SizedBox(height: 18),
        Text('3D engine $engine', style: const TextStyle(color: SfColors.textDim)),
        const SizedBox(height: 6),
        const Text('© 2026 Azurafiles. Contact: simon@dronedirector.fo',
            style: TextStyle(color: SfColors.textDim)),
        const SizedBox(height: 24),
        const Text('Open source credits', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        for (final c in credits)
          Card(
            child: ListTile(
              title: Text(c[0]),
              subtitle: Text('${c[1]} · ${c[2]}'),
            ),
          ),
        const SizedBox(height: 10),
        const Text(
          'The photogrammetry pipeline (camera solving, bundle adjustment, depth measuring, '
          'volume fusion, meshing and STL/3MF export) is ScanForge Pro\'s own code.',
          style: TextStyle(color: SfColors.textDim, fontSize: 13, height: 1.4),
        ),
      ]),
    );
  }
}
