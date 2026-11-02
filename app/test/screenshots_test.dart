// Renders screenshots of new features with real app widgets and demo data.
// Run: flutter test test/screenshots_test.dart  (writes screenshots/*.png)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanforge_pro/models/project.dart';
import 'package:scanforge_pro/screens/home_screen.dart';
import 'package:scanforge_pro/screens/live_scan_screen.dart';
import 'package:scanforge_pro/screens/settings_screen.dart';
import 'package:scanforge_pro/services/app_settings.dart';
import 'package:scanforge_pro/services/live_scan.dart';
import 'package:scanforge_pro/theme.dart';

Future<ByteData> _font(String path) => Future.value(ByteData.view(File(path).readAsBytesSync().buffer));

Future<void> _loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(_font('test/fonts/Roboto-$w.ttf'));
  }
  await roboto.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (f.existsSync()) {
      final icons = FontLoader('MaterialIcons')..addFont(_font(f.path));
      await icons.load();
    }
  }
}

Future<void> _shot(WidgetTester tester, Widget home, String name) async {
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: home),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('screenshots').createSync(recursive: true);
    File('screenshots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('screenshot written: $name');
}

LiveScanState _state(Map<String, dynamic> d, String? phase) {
  final s = LiveScanState()
    ..tracking = true
    ..view = Float32List.fromList((d['view'] as List).map((e) => (e as num).toDouble()).toList())
    ..proj = Float32List.fromList((d['proj'] as List).map((e) => (e as num).toDouble()).toList());
  if (phase == null) {
    s.hint = 'Tap the object you want to scan';
    return s;
  }
  final ph = d[phase] as Map<String, dynamic>;
  Float32List f32(List l) => Float32List.fromList(l.map((e) => (e as num).toDouble()).toList());
  s
    ..selected = true
    ..aiSelection = true
    ..baseCenter = f32(d['center'] as List)
    ..radius = (d['radius'] as num).toDouble()
    ..bottom = (d['bottom'] as num).toDouble()
    ..top = (d['top'] as num).toDouble()
    ..outline = phase == 'selected' ? f32(d['outline'] as List) : Float32List(0)
    ..points = f32(ph['points'] as List)
    ..bins = Uint8List.fromList((ph['bins'] as List).cast<int>())
    ..captured = (ph['captured'] as num).toDouble()
    ..detail = (ph['detail'] as num).toDouble()
    ..photos = ph['photos'] as int
    ..hint = ph['hint'] as String;
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshots', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final data = jsonDecode(File('test/assets/demo_can.json').readAsStringSync()) as Map<String, dynamic>;
    final bytes = File('test/assets/demo_can.jpg').readAsBytesSync();
    final bg = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    });
    Widget background() => RawImage(image: bg, fit: BoxFit.cover, width: 360, height: 780);
    final project = ScanProject(id: 'demo', dir: '/tmp/demo', name: 'Soda can', created: DateTime(2026, 11, 2));

    await _shot(tester, LiveScanScreen(project: project, demoBackground: background(), demoState: _state(data, null)),
        '1_live_scan_tap_object');
    await _shot(
        tester,
        LiveScanScreen(project: project, demoBackground: background(), demoState: _state(data, 'selected')),
        '2_live_scan_ai_selected');
    await _shot(
        tester,
        LiveScanScreen(project: project, demoBackground: background(), demoState: _state(data, 'progress')),
        '3_live_scan_hologram_progress');

    final dice = jsonDecode(File('test/assets/demo_dice.json').readAsStringSync()) as Map<String, dynamic>;
    final diceBytes = File('test/assets/demo_dice.jpg').readAsBytesSync();
    final diceBg = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(diceBytes);
      return (await codec.getNextFrame()).image;
    });
    await _shot(
        tester,
        LiveScanScreen(
            project: project,
            demoBackground: RawImage(image: diceBg, fit: BoxFit.cover, width: 360, height: 780),
            demoState: _state(dice, 'progress')),
        '6_live_scan_small_object');

    await _shot(
      tester,
      Scaffold(
        backgroundColor: Colors.black,
        body: Column(children: [
          const Expanded(child: SizedBox()),
          Container(
            decoration: const BoxDecoration(
              color: SfColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: NewScanSheet(onLiveScan: () {}, onCamera: () {}, onImport: () {}),
          ),
        ]),
      ),
      '4_new_scan_menu',
    );

    AppSettings.instance.useGps = true;
    await _shot(tester, const SettingsScreen(), '5_settings_gps');
  });
}
