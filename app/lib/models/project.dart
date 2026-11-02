import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A scan project: a folder with photos, settings and the resulting model.
class ScanProject {
  final String id;
  final String dir;
  String name;
  DateTime created;
  int quality;
  double focal35;
  /// Uniform scale applied on export (1 = mesh as built, longest side 100 mm).
  double exportScale;
  String? lastError;
  String printer;
  /// Made with Live Scan (camera positions known, real size).
  bool liveScan;
  /// Rotation (degrees) to show Live Scan photos upright.
  int photoRotation;

  ScanProject({
    required this.id,
    required this.dir,
    required this.name,
    required this.created,
    this.quality = 1,
    this.focal35 = 0,
    this.exportScale = 1,
    this.lastError,
    this.printer = 'x1',
    this.liveScan = false,
    this.photoRotation = 0,
  });

  String get photosDir => p.join(dir, 'photos');
  String get meshPath => p.join(dir, 'mesh.ply');
  String get logPath => p.join(dir, 'log.txt');
  String get jsonPath => p.join(dir, 'project.json');
  String get gpsPath => p.join(dir, 'gps.txt');
  bool get hasCameraPositions => File(p.join(dir, 'poses.txt')).existsSync();

  /// Quarter turns needed to show a photo upright.
  int quarterTurnsFor(String path) =>
      p.basename(path).startsWith('LIVE_') ? (photoRotation ~/ 90) % 4 : 0;
  bool get hasModel => File(meshPath).existsSync();

  List<File> photos() {
    final d = Directory(photosDir);
    if (!d.existsSync()) return [];
    final list = d
        .listSync()
        .whereType<File>()
        .where((f) => ['.jpg', '.jpeg', '.png'].contains(p.extension(f.path).toLowerCase()))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return list;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'created': created.toIso8601String(),
        'quality': quality,
        'focal35': focal35,
        'exportScale': exportScale,
        'lastError': lastError,
        'printer': printer,
        'liveScan': liveScan,
        'photoRotation': photoRotation,
      };

  static ScanProject fromJson(String dir, Map<String, dynamic> j) => ScanProject(
        id: j['id'] as String? ?? p.basename(dir),
        dir: dir,
        name: j['name'] as String? ?? 'Scan',
        created: DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.now(),
        quality: (j['quality'] as num?)?.toInt() ?? 1,
        focal35: (j['focal35'] as num?)?.toDouble() ?? 0,
        exportScale: (j['exportScale'] as num?)?.toDouble() ?? 1,
        lastError: j['lastError'] as String?,
        printer: j['printer'] as String? ?? 'x1',
        liveScan: j['liveScan'] as bool? ?? false,
        photoRotation: (j['photoRotation'] as num?)?.toInt() ?? 0,
      );

  Future<void> save() async {
    await Directory(dir).create(recursive: true);
    final tmp = File('$jsonPath.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    await tmp.rename(jsonPath);
  }
}

/// Bambu Lab printers and their build plates (mm).
class Printer {
  final String id;
  final String name;
  final double bedX, bedY, maxZ;
  const Printer(this.id, this.name, this.bedX, this.bedY, this.maxZ);

  static const all = [
    Printer('x1', 'Bambu Lab X1 / X1C / X1E', 256, 256, 256),
    Printer('p2s', 'Bambu Lab P2S', 256, 256, 256),
    Printer('p1', 'Bambu Lab P1S / P1P', 256, 256, 256),
    Printer('a1', 'Bambu Lab A1', 256, 256, 256),
    Printer('a1mini', 'Bambu Lab A1 mini', 180, 180, 180),
    Printer('h2s', 'Bambu Lab H2S', 340, 320, 340),
    Printer('h2d', 'Bambu Lab H2D', 325, 320, 325),
    Printer('generic', 'Other printer (256 mm)', 256, 256, 256),
  ];

  static Printer byId(String id) => all.firstWhere((e) => e.id == id, orElse: () => all.first);
}
