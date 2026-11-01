// Dart bindings for the ScanForge Pro C++ engine (engine/include/scanforge.h).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

DynamicLibrary _open() {
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libscanforge.so');
  if (Platform.isWindows) return DynamicLibrary.open('scanforge.dll');
  return DynamicLibrary.process(); // iOS / macOS: linked into the app
}

final DynamicLibrary _lib = _open();

// ---- signatures --------------------------------------------------------------
typedef _JobStartC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Double, Int32);
typedef _JobStart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int, double, int);
typedef _JobIntC = Int32 Function(Pointer<Void>);
typedef _JobInt = int Function(Pointer<Void>);
typedef _JobFloatC = Float Function(Pointer<Void>);
typedef _JobFloat = double Function(Pointer<Void>);
typedef _JobVoidC = Void Function(Pointer<Void>);
typedef _JobVoid = void Function(Pointer<Void>);
typedef _JobMsgC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _JobMsg = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _RemeshC = Int32 Function(Pointer<Utf8>, Float, Int32);
typedef _Remesh = int Function(Pointer<Utf8>, double, int);
typedef _MeshLoadC = Pointer<Void> Function(Pointer<Utf8>);
typedef _MeshLoad = Pointer<Void> Function(Pointer<Utf8>);
typedef _MeshInfoC = Int32 Function(Pointer<Void>, Pointer<Float>);
typedef _MeshInfo = int Function(Pointer<Void>, Pointer<Float>);
typedef _MeshRenderC = Int32 Function(Pointer<Void>, Float, Float, Float, Float, Float, Int32, Int32, Int32,
    Pointer<Pointer<Float>>, Pointer<Pointer<Int32>>);
typedef _MeshRender = int Function(Pointer<Void>, double, double, double, double, double, int, int, int,
    Pointer<Pointer<Float>>, Pointer<Pointer<Int32>>);
typedef _MeshExportC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Float, Float, Float, Pointer<Utf8>);
typedef _MeshExport = int Function(Pointer<Void>, Pointer<Utf8>, int, double, double, double, Pointer<Utf8>);
typedef _VersionC = Pointer<Utf8> Function();

final _jobStart = _lib.lookupFunction<_JobStartC, _JobStart>('sf_job_start');
final _jobState = _lib.lookupFunction<_JobIntC, _JobInt>('sf_job_state');
final _jobStage = _lib.lookupFunction<_JobIntC, _JobInt>('sf_job_stage');
final _jobRegistered = _lib.lookupFunction<_JobIntC, _JobInt>('sf_job_registered');
final _jobProgress = _lib.lookupFunction<_JobFloatC, _JobFloat>('sf_job_progress');
final _jobMessage = _lib.lookupFunction<_JobMsgC, _JobMsg>('sf_job_message');
final _jobCancel = _lib.lookupFunction<_JobVoidC, _JobVoid>('sf_job_cancel');
final _jobFree = _lib.lookupFunction<_JobVoidC, _JobVoid>('sf_job_free');
final _remesh = _lib.lookupFunction<_RemeshC, _Remesh>('sf_remesh');
final _meshLoad = _lib.lookupFunction<_MeshLoadC, _MeshLoad>('sf_mesh_load');
final _meshFree = _lib.lookupFunction<_JobVoidC, _JobVoid>('sf_mesh_free');
final _meshInfo = _lib.lookupFunction<_MeshInfoC, _MeshInfo>('sf_mesh_info');
final _meshWatertight = _lib.lookupFunction<_JobIntC, _JobInt>('sf_mesh_is_watertight');
final _meshRender = _lib.lookupFunction<_MeshRenderC, _MeshRender>('sf_mesh_render');
final _meshExport = _lib.lookupFunction<_MeshExportC, _MeshExport>('sf_mesh_export');
final _version = _lib.lookupFunction<_VersionC, _VersionC>('sf_version');

String engineVersion() => _version().toDartString();

enum JobState { running, done, failed, cancelled }

class Quality {
  static const fast = 0;
  static const normal = 1;
  static const high = 2;
  static const ultra = 3;
  static const names = ['Fast', 'Normal', 'High', 'Ultra'];
}

const stageNames = [
  'Reading photos',
  'Finding details',
  'Matching photos',
  'Solving camera positions',
  'Measuring depth',
  'Building 3D volume',
  'Creating mesh',
  'Finished',
];

/// A running reconstruction (the work happens on a native background thread).
class ReconstructionJob {
  Pointer<Void> _job;
  final Pointer<Uint8> _msg = calloc<Uint8>(512);

  ReconstructionJob._(this._job);

  static ReconstructionJob? start(String projectDir, List<String> images,
      {int quality = Quality.normal, double focal35 = 0, int threads = 0}) {
    final d = projectDir.toNativeUtf8();
    final l = images.join('\n').toNativeUtf8();
    try {
      final j = _jobStart(d, l, quality, focal35, threads);
      if (j == nullptr) return null;
      return ReconstructionJob._(j);
    } finally {
      calloc.free(d);
      calloc.free(l);
    }
  }

  bool get _alive => _job != nullptr;
  JobState get state => _alive ? JobState.values[_jobState(_job).clamp(0, 3)] : JobState.cancelled;
  int get stage => _alive ? _jobStage(_job) : 0;
  int get registered => _alive ? _jobRegistered(_job) : 0;
  double get progress => _alive ? _jobProgress(_job) : 0;
  String get message {
    if (!_alive) return '';
    final n = _jobMessage(_job, _msg, 512);
    return utf8.decode(_msg.asTypedList(n), allowMalformed: true);
  }

  void cancel() {
    if (_alive) _jobCancel(_job);
  }

  /// Waits for the native thread and releases the job.
  void dispose() {
    if (_alive) {
      _jobFree(_job);
      _job = nullptr;
    }
    calloc.free(_msg);
  }
}

/// Re-creates the mesh with a floor cut (mm above the bottom, negative = auto).
int remesh(String projectDir, double floorMm, {int smooth = -1}) {
  final d = projectDir.toNativeUtf8();
  try {
    return _remesh(d, floorMm, smooth);
  } finally {
    calloc.free(d);
  }
}

enum ExportFormat { stl, threeMf, ply, obj }

extension ExportFormatInfo on ExportFormat {
  String get extension => const ['stl', '3mf', 'ply', 'obj'][index];
  String get label => const ['STL', '3MF (Bambu Studio)', 'PLY (colour)', 'OBJ (colour)'][index];
}

class RenderResult {
  final Float32List positions;
  final Int32List colors;
  RenderResult(this.positions, this.colors);
}

/// A loaded mesh for viewing and exporting.
class EngineMesh {
  Pointer<Void> _m;
  final Pointer<Pointer<Float>> _pos = calloc<Pointer<Float>>();
  final Pointer<Pointer<Int32>> _col = calloc<Pointer<Int32>>();
  late final List<double> bounds; // min xyz, max xyz (mm)
  late final int triangles;
  late final bool watertight;

  EngineMesh._(this._m) {
    final b = calloc<Float>(6);
    triangles = _meshInfo(_m, b);
    bounds = List<double>.generate(6, (i) => b[i]);
    calloc.free(b);
    watertight = _meshWatertight(_m) == 1;
  }

  static EngineMesh? load(String plyPath) {
    final p = plyPath.toNativeUtf8();
    try {
      final m = _meshLoad(p);
      return m == nullptr ? null : EngineMesh._(m);
    } finally {
      calloc.free(p);
    }
  }

  double get sizeX => bounds[3] - bounds[0];
  double get sizeY => bounds[4] - bounds[1];
  double get sizeZ => bounds[5] - bounds[2];

  RenderResult? render(
      {required double yaw,
      required double pitch,
      required double zoom,
      required double panX,
      required double panY,
      required int width,
      required int height,
      bool clay = false}) {
    if (_m == nullptr) return null;
    final n = _meshRender(_m, yaw, pitch, zoom, panX, panY, width, height, clay ? 1 : 0, _pos, _col);
    if (n <= 0) return RenderResult(Float32List(0), Int32List(0));
    // copy: the native buffers are reused by the next render call
    return RenderResult(
      Float32List.fromList(_pos.value.asTypedList(n * 6)),
      Int32List.fromList(_col.value.asTypedList(n * 3)),
    );
  }

  /// Returns null on success, else an error text.
  String? export(String path, ExportFormat format,
      {double scale = 1, double bedX = 256, double bedY = 256, String name = 'Scan'}) {
    final p = path.toNativeUtf8();
    final n = name.toNativeUtf8();
    try {
      final r = _meshExport(_m, p, format.index, scale, bedX, bedY, n);
      return r == 0 ? null : 'Export failed (code $r)';
    } finally {
      calloc.free(p);
      calloc.free(n);
    }
  }

  void dispose() {
    if (_m != nullptr) {
      _meshFree(_m);
      _m = nullptr;
    }
    calloc.free(_pos);
    calloc.free(_col);
  }
}
