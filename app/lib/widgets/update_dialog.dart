import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/updater.dart';
import '../theme.dart';
import 'release_notes_text.dart';

/// Shows "Update available" and handles download + install.
Future<void> showUpdateDialog(BuildContext context, ReleaseInfo release, String currentVersion) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(release: release, current: currentVersion),
  );
}

class _UpdateDialog extends StatefulWidget {
  final ReleaseInfo release;
  final String current;
  const _UpdateDialog({required this.release, required this.current});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _Phase { ask, downloading, permission, installing, error }

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.ask;
  double _progress = 0;
  File? _apk;
  String _error = '';
  CancelToken? _cancel;

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
    });
    try {
      _cancel = CancelToken();
      _apk ??= await Updater.download(widget.release, (v) {
        if (mounted) setState(() => _progress = v);
      }, cancel: _cancel);
      await _install();
    } on DownloadCancelled {
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = 'The download failed. Check your internet connection and try again.';
        });
      }
    }
  }

  Future<void> _install() async {
    final r = await Updater.install(_apk!);
    if (!mounted) return;
    switch (r) {
      case InstallResult.started:
        setState(() => _phase = _Phase.installing);
      case InstallResult.needsPermission:
        setState(() => _phase = _Phase.permission);
      case InstallResult.failed:
        setState(() {
          _phase = _Phase.error;
          _error = 'The installer could not be opened.';
        });
    }
  }

  Future<void> _skip() async {
    AppSettings.instance.skippedVersion = widget.release.version;
    await AppSettings.instance.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final mb = widget.release.size > 0 ? ' · ${(widget.release.size / 1048576).toStringAsFixed(0)} MB' : '';
    return AlertDialog(
      backgroundColor: SfColors.surface,
      title: const Row(children: [
        Icon(Icons.system_update_rounded, color: SfColors.accent),
        SizedBox(width: 10),
        Text('Update available'),
      ]),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.current}  →  ${widget.release.version}$mb',
              style: const TextStyle(fontWeight: FontWeight.w700, color: SfColors.accent)),
          const SizedBox(height: 10),
          if (_phase == _Phase.ask && widget.release.notes.trim().isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(child: ReleaseNotesText(widget.release.notes)),
            ),
          if (_phase == _Phase.downloading) ...[
            Text('Downloading… ${(_progress * 100).round()}%'),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: _progress, minHeight: 8, backgroundColor: SfColors.surfaceHigh),
            ),
          ],
          if (_phase == _Phase.permission)
            const Text(
              'Allow ScanForge Pro to install updates in the screen that just opened, '
              'then come back and tap Install.',
              style: TextStyle(height: 1.4),
            ),
          if (_phase == _Phase.installing)
            const Text('Follow the Android installer to finish the update. The app restarts when it is done.',
                style: TextStyle(height: 1.4)),
          if (_phase == _Phase.error) Text(_error, style: const TextStyle(color: Color(0xFFFF7A7A))),
          const SizedBox(height: 12),
          const Row(children: [
            Icon(Icons.verified_user_rounded, size: 16, color: SfColors.good),
            SizedBox(width: 6),
            Expanded(
              child: Text('Your scans and settings are kept.',
                  style: TextStyle(color: SfColors.textDim, fontSize: 12)),
            ),
          ]),
        ]),
      ),
      actions: [
        if (_phase == _Phase.ask) ...[
          TextButton(onPressed: _skip, child: const Text('Skip this version')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(onPressed: _start, child: const Text('Update')),
        ],
        if (_phase == _Phase.downloading)
          TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel')),
        if (_phase == _Phase.permission) ...[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(onPressed: _install, child: const Text('Install')),
        ],
        if (_phase == _Phase.installing) ...[
          TextButton(onPressed: _install, child: const Text('Open installer again')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
        if (_phase == _Phase.error) ...[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(onPressed: _start, child: const Text('Try again')),
        ],
      ],
    );
  }
}
