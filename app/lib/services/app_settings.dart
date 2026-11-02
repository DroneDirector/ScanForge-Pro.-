import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-wide settings, stored in the app's documents folder so they survive
/// app updates (only uninstalling the app removes them).
class AppSettings {
  AppSettings._();
  static final instance = AppSettings._();

  bool autoCheckUpdates = true;
  /// Use GPS positions (photo GPS data / phone location) for large scans. Off by default.
  bool useGps = false;
  /// Live Scan: let the AI guess the object's outline when tapping it.
  bool liveAiGuess = true;
  String? skippedVersion;
  int defaultQuality = 1;
  String defaultPrinter = 'x1';
  DateTime? lastUpdateCheck;

  File? _file;

  Future<File> _path() async {
    if (_file != null) return _file!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'ScanForge'));
    await dir.create(recursive: true);
    return _file = File(p.join(dir.path, 'settings.json'));
  }

  Future<void> load() async {
    try {
      final f = await _path();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      autoCheckUpdates = j['autoCheckUpdates'] as bool? ?? true;
      useGps = j['useGps'] as bool? ?? false;
      liveAiGuess = j['liveAiGuess'] as bool? ?? true;
      skippedVersion = j['skippedVersion'] as String?;
      defaultQuality = (j['defaultQuality'] as num?)?.toInt() ?? 1;
      defaultPrinter = j['defaultPrinter'] as String? ?? 'x1';
      lastUpdateCheck = DateTime.tryParse(j['lastUpdateCheck'] as String? ?? '');
    } catch (_) {
      // unreadable settings: keep defaults
    }
  }

  Future<void> save() async {
    final f = await _path();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'autoCheckUpdates': autoCheckUpdates,
      'useGps': useGps,
      'liveAiGuess': liveAiGuess,
      'skippedVersion': skippedVersion,
      'defaultQuality': defaultQuality,
      'defaultPrinter': defaultPrinter,
      'lastUpdateCheck': lastUpdateCheck?.toIso8601String(),
    }));
    await tmp.rename(f.path);
  }
}
