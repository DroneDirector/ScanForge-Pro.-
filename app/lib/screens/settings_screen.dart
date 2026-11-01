import 'package:flutter/material.dart';

import '../models/project.dart';
import '../services/app_settings.dart';
import '../services/engine.dart';
import '../services/updater.dart';
import '../theme.dart';
import '../widgets/update_dialog.dart';
import 'about_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = AppSettings.instance;
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    Updater.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  Future<void> _save() async {
    await s.save();
    setState(() {});
  }

  Future<void> _checkNow() async {
    setState(() => _checking = true);
    final current = await Updater.currentVersion();
    final rel = await Updater.latest();
    if (!mounted) return;
    setState(() => _checking = false);
    s.lastUpdateCheck = DateTime.now();
    await s.save();
    if (!mounted) return;
    if (rel == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not check for updates. Are you online?')));
    } else if (Updater.compare(rel.version, current) > 0) {
      await showUpdateDialog(context, rel, current);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('You have the latest version ($current).')));
    }
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(t, style: const TextStyle(color: SfColors.accent, fontWeight: FontWeight.w700, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 30), children: [
        if (Updater.supported) ...[
          _header('UPDATES'),
          Card(
            child: Column(children: [
              SwitchListTile(
                title: const Text('Check for updates automatically'),
                subtitle: const Text('When the app starts'),
                value: s.autoCheckUpdates,
                activeColor: SfColors.accent,
                onChanged: (v) {
                  s.autoCheckUpdates = v;
                  _save();
                },
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text('Check now'),
                subtitle: Text(_version.isEmpty ? '' : 'Installed version $_version'),
                trailing: _checking
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                onTap: _checking ? null : _checkNow,
              ),
              if (s.skippedVersion != null) ...[
                const Divider(height: 1),
                ListTile(
                  title: Text('Skipped version ${s.skippedVersion}'),
                  subtitle: const Text('Tap to be reminded about it again'),
                  trailing: const Icon(Icons.undo_rounded),
                  onTap: () {
                    s.skippedVersion = null;
                    _save();
                  },
                ),
              ],
            ]),
          ),
        ],
        _header('NEW SCANS'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Default quality'),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: [for (var q = 0; q < 4; q++) ButtonSegment(value: q, label: Text(Quality.names[q]))],
                selected: {s.defaultQuality},
                onSelectionChanged: (v) {
                  s.defaultQuality = v.first;
                  _save();
                },
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                value: Printer.byId(s.defaultPrinter).id,
                decoration: const InputDecoration(labelText: 'Default printer', border: OutlineInputBorder()),
                items: [for (final x in Printer.all) DropdownMenuItem(value: x.id, child: Text(x.name))],
                onChanged: (v) {
                  if (v == null) return;
                  s.defaultPrinter = v;
                  _save();
                },
              ),
            ]),
          ),
        ),
        _header('APP'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('About and credits'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Your scans and settings are stored on this device and are kept when the app updates.',
          style: TextStyle(color: SfColors.textDim, fontSize: 12),
        ),
      ]),
    );
  }
}
