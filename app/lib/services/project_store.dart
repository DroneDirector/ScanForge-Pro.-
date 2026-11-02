import 'dart:convert';
import 'dart:io';

import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/project.dart';
import 'app_settings.dart';

/// Stores scan projects in the app's documents folder.
class ProjectStore {
  ProjectStore._();
  static final instance = ProjectStore._();

  Directory? _root;

  Future<Directory> root() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(docs.path, 'ScanForge', 'projects'));
    await _root!.create(recursive: true);
    return _root!;
  }

  Future<List<ScanProject>> list() async {
    final r = await root();
    final out = <ScanProject>[];
    for (final e in r.listSync().whereType<Directory>()) {
      final f = File(p.join(e.path, 'project.json'));
      if (!f.existsSync()) continue;
      try {
        out.add(ScanProject.fromJson(e.path, jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {}
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  Future<ScanProject> create({String? name}) async {
    final r = await root();
    final now = DateTime.now();
    final id = 'scan_${now.millisecondsSinceEpoch}';
    final proj = ScanProject(
      id: id,
      dir: p.join(r.path, id),
      name: name ?? 'Scan ${_two(now.day)}.${_two(now.month)}.${now.year} ${_two(now.hour)}:${_two(now.minute)}',
      created: now,
      quality: AppSettings.instance.defaultQuality,
      printer: AppSettings.instance.defaultPrinter,
    );
    await Directory(proj.photosDir).create(recursive: true);
    await proj.save();
    return proj;
  }

  Future<void> delete(ScanProject proj) async {
    final d = Directory(proj.dir);
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// Copies photos into the project (keeps the originals untouched).
  Future<int> importPhotos(ScanProject proj, List<String> paths) async {
    await Directory(proj.photosDir).create(recursive: true);
    var n = proj.photos().length;
    var added = 0;
    for (final src in paths) {
      final ext = p.extension(src).toLowerCase();
      if (!['.jpg', '.jpeg', '.png'].contains(ext)) continue;
      final dst = p.join(proj.photosDir, 'IMG_${(n + 1).toString().padLeft(4, '0')}$ext');
      await File(src).copy(dst);
      if (AppSettings.instance.useGps) {
        final g = await readGps(src);
        if (g != null) await addGps(proj, p.basename(dst), g.$1, g.$2, g.$3);
      }
      n++;
      added++;
    }
    if (proj.focal35 <= 0) {
      final ph = proj.photos();
      if (ph.isNotEmpty) {
        proj.focal35 = await readFocal35(ph.first.path);
        await proj.save();
      }
    }
    return added;
  }

  /// Next file name for a newly captured photo.
  String nextPhotoPath(ScanProject proj) {
    final n = proj.photos().length + 1;
    return p.join(proj.photosDir, 'IMG_${n.toString().padLeft(4, '0')}.jpg');
  }

  /// 35 mm equivalent focal length from EXIF, 0 if missing.
  static Future<double> readFocal35(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      final t = tags['EXIF FocalLengthIn35mmFilm'];
      if (t != null) {
        final v = double.tryParse(t.printable.split(' ').first);
        if (v != null && v > 5) return v;
      }
    } catch (_) {}
    return 0;
  }

  /// Records where a photo was taken (used only to give large scans real size).
  Future<void> addGps(ScanProject proj, String photoName, double lat, double lon, double alt) async {
    await File(proj.gpsPath).writeAsString('$photoName $lat $lon $alt\n', mode: FileMode.append, flush: true);
  }

  /// GPS position stored in a photo's EXIF data (latitude, longitude, altitude) or null.
  static Future<(double, double, double)?> readGps(String path) async {
    try {
      final tags = await readExifFromBytes(await File(path).readAsBytes());
      double? dms(String key, String refKey, String negative) {
        final t = tags[key];
        if (t == null) return null;
        final parts = t.printable.replaceAll(RegExp(r'[\[\]\s]'), '').split(',');
        if (parts.length < 3) return null;
        double val(String x) {
          final f = x.split('/');
          return f.length == 2 ? double.parse(f[0]) / double.parse(f[1]) : double.parse(f[0]);
        }
        var v = val(parts[0]) + val(parts[1]) / 60 + val(parts[2]) / 3600;
        if (tags[refKey]?.printable.trim().toUpperCase() == negative) v = -v;
        return v;
      }
      final lat = dms('GPS GPSLatitude', 'GPS GPSLatitudeRef', 'S');
      final lon = dms('GPS GPSLongitude', 'GPS GPSLongitudeRef', 'W');
      if (lat == null || lon == null) return null;
      var alt = 0.0;
      final a = tags['GPS GPSAltitude'];
      if (a != null) {
        final f = a.printable.trim().split('/');
        alt = f.length == 2 ? double.parse(f[0]) / double.parse(f[1]) : double.tryParse(f[0]) ?? 0;
        if (tags['GPS GPSAltitudeRef']?.printable.trim() == '1') alt = -alt;
      }
      return (lat, lon, alt);
    } catch (_) {
      return null;
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
