/*
 * ScanForge Pro engine - public C interface.
 * Copyright (c) 2026 Azurafiles / DroneDirector. All rights reserved.
 *
 * The engine turns a set of photos of an object into a closed, printable
 * 3D mesh (photogrammetry) and exports it as STL, 3MF, PLY or OBJ.
 * The interface is plain C so it can be called from Dart (dart:ffi),
 * Swift, C# or C++ alike.
 */
#ifndef SCANFORGE_H
#define SCANFORGE_H

#include <stdint.h>

#if defined(_WIN32)
#define SF_API __declspec(dllexport)
#else
#define SF_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Reconstruction jobs ---------------------------------------------- */

/* Quality presets */
#define SF_QUALITY_FAST   0
#define SF_QUALITY_NORMAL 1
#define SF_QUALITY_HIGH   2
#define SF_QUALITY_ULTRA  3

/* Job states */
#define SF_STATE_RUNNING   0
#define SF_STATE_DONE      1
#define SF_STATE_FAILED    2
#define SF_STATE_CANCELLED 3
/* Paused: the photos look insufficient; the message explains why. Answer with
   sf_job_confirm(job, 1) to continue anyway or sf_job_confirm(job, 0) to stop. */
#define SF_STATE_CONFIRM   4

/* Pipeline stages (reported by sf_job_stage) */
#define SF_STAGE_LOADING      0
#define SF_STAGE_FEATURES     1
#define SF_STAGE_MATCHING     2
#define SF_STAGE_CAMERAS      3
#define SF_STAGE_DEPTH        4
#define SF_STAGE_FUSION       5
#define SF_STAGE_MESH         6
#define SF_STAGE_FINISHED     7

typedef struct sf_job sf_job;

/*
 * Starts a reconstruction on a background thread.
 *  project_dir : folder where results are written (mesh.ply, sparse.ply,
 *                volume.bin, log.txt). Must exist.
 *  image_list  : UTF-8, newline separated list of image file paths.
 *  quality     : SF_QUALITY_*
 *  focal35     : 35 mm equivalent focal length from EXIF, 0 if unknown.
 *  threads     : worker threads, 0 = all cores.
 * Returns NULL if the arguments are invalid.
 */
SF_API sf_job* sf_job_start(const char* project_dir, const char* image_list,
                            int quality, double focal35, int threads);

SF_API int   sf_job_state(sf_job* job);
SF_API int   sf_job_stage(sf_job* job);
/* Overall progress 0..1 */
SF_API float sf_job_progress(sf_job* job);
/* Copies the current status / error message (UTF-8) into buf. */
SF_API int   sf_job_message(sf_job* job, char* buf, int buf_len);
/* Number of photos whose camera position was solved (valid after CAMERAS). */
SF_API int   sf_job_registered(sf_job* job);
SF_API void  sf_job_cancel(sf_job* job);
/* Answers a SF_STATE_CONFIRM question: 1 = continue, 0 = stop. */
SF_API void  sf_job_confirm(sf_job* job, int proceed);
/* Waits for the thread to finish and frees the job. */
SF_API void  sf_job_free(sf_job* job);

/*
 * Re-builds mesh.ply from the saved volume with a new floor cut.
 *  floor_mm : cut height in millimetres above the current bottom of the
 *             model; a negative value restores the automatic floor.
 *  smooth   : smoothing passes (0..12), -1 keeps the current setting.
 * Returns 0 on success.
 */
SF_API int sf_remesh(const char* project_dir, float floor_mm, int smooth);

/* ---- Meshes, viewer and export ---------------------------------------- */

typedef struct sf_mesh sf_mesh;

SF_API sf_mesh* sf_mesh_load(const char* ply_path);
SF_API void     sf_mesh_free(sf_mesh* mesh);
/* out_bounds: min x,y,z then max x,y,z (millimetres). Returns triangle count. */
SF_API int      sf_mesh_info(sf_mesh* mesh, float* out_bounds);
/* Returns 1 if every edge is shared by exactly two triangles. */
SF_API int      sf_mesh_is_watertight(sf_mesh* mesh);

/* Viewer render modes */
#define SF_RENDER_COLOR 0
#define SF_RENDER_CLAY  1

/*
 * Projects the mesh for a 2D canvas (e.g. Flutter Canvas.drawVertices).
 * Produces a back-to-front sorted, non-indexed triangle list.
 *  out_positions : receives a pointer to 6 floats per triangle (x,y pixels)
 *  out_colors    : receives a pointer to 3 ARGB ints per triangle
 * The buffers are owned by the mesh and stay valid until the next call.
 * Returns the number of triangles.
 */
SF_API int sf_mesh_render(sf_mesh* mesh, float yaw_deg, float pitch_deg,
                          float zoom, float pan_x, float pan_y,
                          int width, int height, int mode,
                          float** out_positions, int32_t** out_colors);

/* Export formats */
#define SF_FORMAT_STL 0
#define SF_FORMAT_3MF 1
#define SF_FORMAT_PLY 2
#define SF_FORMAT_OBJ 3

/*
 * Writes the mesh scaled by `scale` (1 = as stored, millimetres).
 * bed_x / bed_y: printer bed size in mm, used to centre the part in 3MF.
 * Returns 0 on success.
 */
SF_API int sf_mesh_export(sf_mesh* mesh, const char* path, int format,
                          float scale, float bed_x, float bed_y,
                          const char* object_name);

SF_API const char* sf_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SCANFORGE_H */
