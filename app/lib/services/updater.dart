import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A published app version on GitHub.
class ReleaseInfo {
  final String version;
  final String title;
  final String notes;
  final String apkUrl;
  final int size;
  ReleaseInfo(this.version, this.title, this.notes, this.apkUrl, this.size);
}

enum InstallResult { started, needsPermission, failed }

/// In-app updates: checks the GitHub releases, downloads the new APK and
/// hands it to Android's installer. The update installs over the current
/// app, so scans and settings are kept.
class Updater {
  static const _repo = 'DroneDirector/ScanForge-Pro.-';
  static const _channel = MethodChannel('scanforge/update');

  static bool get supported => Platform.isAndroid;

  static Future<String> currentVersion() async {
    try {
      return await _channel.invokeMethod<String>('appVersion') ?? '0.0.0';
    } catch (_) {
      return '0.0.0';
    }
  }

  /// Compares dotted versions: >0 if a is newer than b.
  static int compare(String a, String b) {
    List<int> parse(String v) =>
        v.replaceAll(RegExp(r'^[vV]'), '').split(RegExp(r'[.+-]')).map((e) => int.tryParse(e) ?? 0).toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  /// Newest release with an Android APK, or null.
  static Future<ReleaseInfo?> latest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases?per_page=10'));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'ScanForgePro');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final list = jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
      ReleaseInfo? best;
      for (final r in list.cast<Map<String, dynamic>>()) {
        if (r['draft'] == true) continue;
        final assets = (r['assets'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        final apk = assets.where((a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk')).toList();
        if (apk.isEmpty) continue;
        final version = (r['tag_name'] as String? ?? '').replaceAll(RegExp(r'^[vV]'), '');
        if (version.isEmpty) continue;
        final info = ReleaseInfo(
          version,
          r['name'] as String? ?? 'ScanForge Pro $version',
          r['body'] as String? ?? '',
          apk.first['browser_download_url'] as String,
          (apk.first['size'] as num?)?.toInt() ?? 0,
        );
        if (best == null || compare(info.version, best.version) > 0) best = info;
      }
      return best;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Newer release than the installed app, or null.
  static Future<ReleaseInfo?> checkForUpdate() async {
    if (!supported) return null;
    final latestRel = await latest();
    if (latestRel == null) return null;
    final current = await currentVersion();
    return compare(latestRel.version, current) > 0 ? latestRel : null;
  }

  /// Downloads the APK; [onProgress] gets 0..1.
  static Future<File> download(ReleaseInfo r, void Function(double) onProgress) async {
    final cache = await getTemporaryDirectory();
    final dir = Directory(p.join(cache.path, 'updates'));
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'ScanForgePro-${r.version}.apk'));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(r.apkUrl));
      req.headers.set('User-Agent', 'ScanForgePro');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode})');
      final total = res.contentLength > 0 ? res.contentLength : r.size;
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      if (total > 0 && got < total) throw const HttpException('Download incomplete');
      return file;
    } finally {
      client.close();
    }
  }

  static Future<InstallResult> install(File apk) async {
    try {
      final can = await _channel.invokeMethod<bool>('canInstall') ?? false;
      if (!can) {
        await _channel.invokeMethod('openInstallPermission');
        return InstallResult.needsPermission;
      }
      await _channel.invokeMethod('installApk', {'path': apk.path});
      return InstallResult.started;
    } catch (_) {
      return InstallResult.failed;
    }
  }
}
