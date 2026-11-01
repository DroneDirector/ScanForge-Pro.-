import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/project.dart';
import 'engine.dart';

/// Keeps reconstructions running while the user moves around the app.
class JobManager extends ChangeNotifier {
  JobManager._();
  static final instance = JobManager._();

  final Map<String, ReconstructionJob> _jobs = {};
  final Map<String, JobSnapshot> _last = {};
  Timer? _poll;

  bool isRunning(String projectId) => _jobs.containsKey(projectId);
  JobSnapshot? snapshot(String projectId) => _last[projectId];

  bool start(ScanProject project) {
    if (_jobs.containsKey(project.id)) return true;
    final photos = project.photos().map((f) => f.path).toList();
    final job = ReconstructionJob.start(project.dir, photos, quality: project.quality, focal35: project.focal35);
    if (job == null) return false;
    _jobs[project.id] = job;
    _projects[project.id] = project;
    _last[project.id] = JobSnapshot(JobState.running, 0, 0, 'Starting', 0);
    project.lastError = null;
    project.save();
    WakelockPlus.enable();
    _poll ??= Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
    notifyListeners();
    return true;
  }

  final Map<String, ScanProject> _projects = {};

  void _tick() {
    final finished = <String>[];
    _jobs.forEach((id, job) {
      final s = JobSnapshot(job.state, job.stage, job.progress, job.message, job.registered);
      _last[id] = s;
      if (s.state != JobState.running && s.state != JobState.confirm) finished.add(id);
    });
    for (final id in finished) {
      final job = _jobs.remove(id)!;
      final s = _last[id]!;
      job.dispose();
      final proj = _projects[id];
      if (proj != null) {
        proj.lastError = s.state == JobState.failed ? s.message : null;
        proj.save();
      }
    }
    if (_jobs.isEmpty) {
      _poll?.cancel();
      _poll = null;
      WakelockPlus.disable();
    }
    notifyListeners();
  }

  void cancel(String projectId) {
    _jobs[projectId]?.cancel();
  }

  /// Answers the "too few photos, continue?" question of a running job.
  void confirm(String projectId, bool proceed) {
    _jobs[projectId]?.confirm(proceed);
  }
}

class JobSnapshot {
  final JobState state;
  final int stage;
  final double progress;
  final String message;
  final int registered;
  JobSnapshot(this.state, this.stage, this.progress, this.message, this.registered);
}
