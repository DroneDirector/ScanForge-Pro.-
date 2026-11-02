// ScanForge Pro engine - C interface, background jobs and the viewer renderer.
#include "scanforge.h"
#include "sf_internal.h"

#include <opencv2/core.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <thread>

using namespace sf;

#define SF_VERSION_STRING "1.0.0"

struct sf_job {
    std::string dir;
    std::vector<std::string> images;
    Settings settings;
    Progress progress;
    std::atomic<int> state{SF_STATE_RUNNING};
    std::thread worker;
};

static std::string joinPath(const std::string& dir, const char* name) {
    if (dir.empty()) return name;
    char last = dir.back();
    return (last == '/' || last == '\\') ? dir + name : dir + "/" + name;
}

// ---------------------------------------------------------------------------
// Full pipeline
// ---------------------------------------------------------------------------
// Returns the share of the surface that the photos actually measured.
static float buildMesh(Volume& vol, Mesh& mesh, bool firstTime, const Reconstruction* rec = nullptr,
                       const std::vector<DepthMap>* maps = nullptr, bool silhouettes = false) {
    extractSurface(vol, mesh);
    keepMainComponents(mesh, 0.35f);
    if (std::getenv("SF_OLD_SMOOTH")) {
        taubinSmooth(mesh, vol.smoothIters);
    } else {
        // light general smoothing, then edge-preserving smoothing keeps corners crisp
        taubinSmooth(mesh, std::max(1, vol.smoothIters / 3));
        featureSmooth(mesh, std::getenv("SF_NIT") ? std::atoi(std::getenv("SF_NIT")) : 12 + 2 * vol.smoothIters, 15);
    }
    simplifyMesh(mesh, vol.targetFaces);
    featureSmooth(mesh, 2, 6);
    if (silhouettes && rec && maps) colorizeFromPhotos(vol, *rec, *maps, mesh);
    float measured = measuredSurfaceFraction(vol, mesh, silhouettes);
    finalizeToMillimetres(mesh, vol, firstTime);
    return measured;
}

static void runPipeline(sf_job* job) {
    Progress& p = job->progress;
    const Settings& s = job->settings;
    try {
        const std::string logPath = joinPath(job->dir, "log.txt");
        { std::ofstream clear(logPath, std::ios::trunc); }
        p.setLogFile(logPath);
        p.log(std::string("ScanForge Pro engine ") + SF_VERSION_STRING);
        if (s.threads > 0) cv::setNumThreads(s.threads);

        p.set(SF_STAGE_LOADING, 0.f, "Reading photos");
        Reconstruction rec;
        std::vector<std::string> imgs = job->images;
        if (int(imgs.size()) > s.maxImages) {
            std::vector<std::string> pick;
            for (int k = 0; k < s.maxImages; ++k) pick.push_back(imgs[size_t(double(k) * imgs.size() / s.maxImages)]);
            p.log(fmt("using %d of %d photos", s.maxImages, int(imgs.size())));
            imgs.swap(pick);
        }
        for (auto& path : imgs) {
            View v;
            v.path = path;
            rec.views.push_back(std::move(v));
        }

        loadPriors(rec, job->dir, p);
        p.set(SF_STAGE_FEATURES, 0.f, "Finding details in the photos");
        Settings fs = s;
        fs.turntableMasks = rec.turntable;
        detectFeatures(rec, fs, p);
        applyPriorIntrinsics(rec);

        p.set(SF_STAGE_MATCHING, 0.f, "Matching photos");
        matchFeatures(rec, s, p);
        buildTracks(rec);
        for (auto& v : rec.views) v.desc.release();
        p.log(fmt("tracks: %d", int(rec.tracks.size())));

        p.set(SF_STAGE_CAMERAS, 0.f, "Solving camera positions");
        bool solved = false;
        if (rec.posed()) solved = runPosedSfM(rec, s, p);
        if (!solved) {
            for (auto& v : rec.views) v.registered = false;
            for (auto& t : rec.tracks) t.valid = false;
            solved = runSfM(rec, s, p);
            if (solved && rec.numPriors() >= 3) alignToPriors(rec, p);
        }
        if (solved && !rec.metric) alignToGps(rec, p);
        if (!solved)
            throw std::runtime_error(
                "The camera positions could not be worked out. Take more photos with more overlap "
                "(each photo should share most of what it sees with the next one).");
        p.registered = rec.numRegistered();
        {
            const int reg = rec.numRegistered(), total = int(rec.views.size());
            if (reg < 6 || reg * 10 < total * 4) {
                bool go = p.askToContinue(fmt(
                    "Too few overlapping photos detected: only %d of %d photos could be placed around the "
                    "object. The model will probably be incomplete. Do you still want to proceed?",
                    reg, total));
                if (!go) throw Cancelled();
            }
        }

        p.set(SF_STAGE_DEPTH, 0.f, "Measuring depth");
        std::vector<DepthMap> maps;
        computeDepthMaps(rec, s, p, maps);
        if (maps.empty()) throw std::runtime_error("No depth could be measured from the photos.");

        p.set(SF_STAGE_FUSION, 0.f, "Building the 3D volume");
        Volume vol;
        fuseDepthMaps(rec, maps, s, p, vol);
        bool silhouettes = false;
        for (auto& dm : maps) silhouettes = silhouettes || !dm.mask.empty();

        p.set(SF_STAGE_MESH, 0.f, "Creating the mesh");
        Mesh mesh;
        float measured = buildMesh(vol, mesh, true, &rec, &maps, silhouettes);
        maps.clear();
        p.sub(0.7f);
        p.log(fmt("mesh: %.1f%% of the surface measured by photos", measured * 100.0));
        if (mesh.f.empty()) throw std::runtime_error("No surface could be created from the photos.");
        if (measured < 0.35f && !p.userAccepted) {
            bool go = p.askToContinue(fmt(
                "Too few overlapping photos detected: only %d%% of the object's surface could be measured, "
                "so the model may look like a block or miss parts. Do you still want to proceed?",
                int(measured * 100.f + 0.5f)));
            if (!go) throw Cancelled();
        }
        if (!saveVolume(joinPath(job->dir, "volume.bin"), vol)) p.log("warning: could not save volume");
        if (!savePLY(joinPath(job->dir, "mesh.ply"), mesh))
            throw std::runtime_error("The mesh could not be saved.");
        p.log(fmt("mesh: %d vertices, %d triangles, watertight: %s", int(mesh.v.size()), int(mesh.f.size()),
                  isWatertight(mesh) ? "yes" : "no"));
        p.set(SF_STAGE_FINISHED, 1.f, "Finished");
        p.fraction = 1.f;
        job->state = SF_STATE_DONE;
    } catch (const Cancelled&) {
        p.message("Cancelled");
        p.log("cancelled");
        job->state = SF_STATE_CANCELLED;
    } catch (const std::exception& e) {
        p.message(e.what());
        p.log(std::string("error: ") + e.what());
        job->state = SF_STATE_FAILED;
    } catch (...) {
        p.message("Unknown error");
        p.log("error: unknown");
        job->state = SF_STATE_FAILED;
    }
}

extern "C" {

SF_API const char* sf_version(void) { return SF_VERSION_STRING; }

SF_API sf_job* sf_job_start(const char* project_dir, const char* image_list, int quality,
                            double focal35, int threads) {
    if (!project_dir || !image_list) return nullptr;
    auto* job = new sf_job();
    job->dir = project_dir;
    std::istringstream ss(image_list);
    std::string line;
    while (std::getline(ss, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (!line.empty()) job->images.push_back(line);
    }
    job->settings = Settings::preset(quality);
    job->settings.focal35 = focal35;
    job->settings.threads = threads;
    job->worker = std::thread(runPipeline, job);
    return job;
}

SF_API int sf_job_state(sf_job* job) {
    if (!job) return SF_STATE_FAILED;
    int st = job->state.load();
    if (st == SF_STATE_RUNNING && job->progress.waitingForAnswer.load()) return SF_STATE_CONFIRM;
    return st;
}

SF_API void sf_job_confirm(sf_job* job, int proceed) {
    if (job) job->progress.answer(proceed != 0);
}
SF_API int sf_job_stage(sf_job* job) { return job ? job->progress.stage.load() : 0; }
SF_API float sf_job_progress(sf_job* job) { return job ? job->progress.fraction.load() : 0.f; }
SF_API int sf_job_registered(sf_job* job) { return job ? job->progress.registered.load() : 0; }

SF_API int sf_job_message(sf_job* job, char* buf, int buf_len) {
    if (!job || !buf || buf_len <= 0) return 0;
    std::string m = job->progress.message();
    int n = std::min(int(m.size()), buf_len - 1);
    std::memcpy(buf, m.data(), n);
    buf[n] = 0;
    return n;
}

SF_API void sf_job_cancel(sf_job* job) {
    if (job) job->progress.cancelRequested = true;
}

SF_API void sf_job_free(sf_job* job) {
    if (!job) return;
    job->progress.cancelRequested = true;
    job->progress.answer(false);
    if (job->worker.joinable()) job->worker.join();
    delete job;
}

SF_API int sf_remesh(const char* project_dir, float floor_mm, int smooth) {
    try {
        std::string dir = project_dir ? project_dir : "";
        Volume vol;
        if (!loadVolume(joinPath(dir, "volume.bin"), vol)) return 1;
        if (floor_mm < 0) {
            vol.floorZ = vol.autoFloorZ;
        } else {
            vol.floorZ = float(vol.shiftUnits[2] + floor_mm / vol.mmPerUnit);
        }
        if (smooth >= 0) vol.smoothIters = std::clamp(smooth, 0, 12);
        Mesh mesh;
        buildMesh(vol, mesh, false);
        if (mesh.f.empty()) return 2;
        if (!savePLY(joinPath(dir, "mesh.ply"), mesh)) return 3;
        saveVolume(joinPath(dir, "volume.bin"), vol);
        return 0;
    } catch (...) {
        return 4;
    }
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Mesh handle + viewer
// ---------------------------------------------------------------------------
struct sf_mesh {
    Mesh full;
    Mesh disp;
    std::vector<cv::Vec3f> normals;  // per display vertex
    cv::Vec3f center;
    float radius = 1.f;
    std::vector<float> pos;
    std::vector<int32_t> col;
    // scratch
    std::vector<cv::Vec3f> vview;
    std::vector<float> shade;
    std::vector<int> order, bucketStart;
    std::vector<float> depth;
};

static void computeNormals(const Mesh& m, std::vector<cv::Vec3f>& n) {
    n.assign(m.v.size(), cv::Vec3f(0, 0, 0));
    for (auto& f : m.f) {
        cv::Vec3f fn = (m.v[f[1]] - m.v[f[0]]).cross(m.v[f[2]] - m.v[f[0]]);
        for (int k = 0; k < 3; ++k) n[f[k]] += fn;
    }
    for (auto& v : n) {
        float l = float(cv::norm(v));
        v = l > 0 ? v / l : cv::Vec3f(0, 0, 1);
    }
}

extern "C" {

SF_API sf_mesh* sf_mesh_load(const char* ply_path) {
    if (!ply_path) return nullptr;
    auto m = std::make_unique<sf_mesh>();
    if (!loadPLY(ply_path, m->full) || m->full.f.empty()) return nullptr;
    decimateForDisplay(m->full, m->disp, 90000);
    computeNormals(m->disp, m->normals);
    cv::Vec3f mn, mx;
    m->full.bounds(mn, mx);
    m->center = (mn + mx) * 0.5f;
    m->radius = std::max(1e-3f, float(cv::norm(mx - mn)) * 0.5f);
    return m.release();
}

SF_API void sf_mesh_free(sf_mesh* mesh) { delete mesh; }

SF_API int sf_mesh_info(sf_mesh* mesh, float* out_bounds) {
    if (!mesh) return 0;
    if (out_bounds) {
        cv::Vec3f mn, mx;
        mesh->full.bounds(mn, mx);
        for (int k = 0; k < 3; ++k) {
            out_bounds[k] = mn[k];
            out_bounds[3 + k] = mx[k];
        }
    }
    return int(mesh->full.f.size());
}

SF_API int sf_mesh_is_watertight(sf_mesh* mesh) { return mesh && isWatertight(mesh->full) ? 1 : 0; }

SF_API int sf_mesh_render(sf_mesh* mesh, float yaw_deg, float pitch_deg, float zoom, float pan_x,
                          float pan_y, int width, int height, int mode, float** out_positions,
                          int32_t** out_colors) {
    if (!mesh || width <= 0 || height <= 0) return 0;
    const Mesh& m = mesh->disp;
    const size_t nv = m.v.size(), nf = m.f.size();
    const float yaw = yaw_deg * float(CV_PI / 180.0), pitch = pitch_deg * float(CV_PI / 180.0);
    const float cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch);
    const float D = 2.7f * mesh->radius / std::max(0.05f, zoom);
    const float fs = 1.15f * std::min(width, height);

    // view space: x right, y into the screen, z up
    mesh->vview.resize(nv);
    mesh->shade.resize(nv);
    const cv::Vec3f light = cv::Vec3f(-0.35f, -0.8f, 0.5f) / float(cv::norm(cv::Vec3f(-0.35f, -0.8f, 0.5f)));
    for (size_t i = 0; i < nv; ++i) {
        cv::Vec3f p = m.v[i] - mesh->center;
        float x1 = cy * p[0] - sy * p[1], y1 = sy * p[0] + cy * p[1], z1 = p[2];
        float y2 = cp * y1 - sp * z1, z2 = sp * y1 + cp * z1;
        mesh->vview[i] = cv::Vec3f(x1, y2, z2);
        const cv::Vec3f& n = mesh->normals[i];
        float nx1 = cy * n[0] - sy * n[1], ny1 = sy * n[0] + cy * n[1];
        float ny2 = cp * ny1 - sp * n[2], nz2 = sp * ny1 + cp * n[2];
        float lam = std::max(0.f, nx1 * light[0] + ny2 * light[1] + nz2 * light[2]);
        float head = std::max(0.f, -ny2);
        mesh->shade[i] = std::min(1.f, 0.25f + 0.5f * lam + 0.35f * head);
    }

    // project, cull back faces, sort far -> near
    mesh->depth.resize(nf);
    std::vector<int> visible;
    visible.reserve(nf);
    std::vector<cv::Vec2f> scr(nv);
    for (size_t i = 0; i < nv; ++i) {
        const cv::Vec3f& v = mesh->vview[i];
        float zc = std::max(1e-4f, v[1] + D);
        scr[i] = cv::Vec2f(width * 0.5f + pan_x + v[0] * fs / zc, height * 0.5f + pan_y - v[2] * fs / zc);
    }
    float dmin = 1e30f, dmax = -1e30f;
    for (size_t k = 0; k < nf; ++k) {
        const cv::Vec3i& f = m.f[k];
        const cv::Vec2f &a = scr[f[0]], &b = scr[f[1]], &c = scr[f[2]];
        float area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
        if (area >= 0) continue;  // facing away (screen y points down)
        float d = mesh->vview[f[0]][1] + mesh->vview[f[1]][1] + mesh->vview[f[2]][1];
        mesh->depth[k] = d;
        dmin = std::min(dmin, d);
        dmax = std::max(dmax, d);
        visible.push_back(int(k));
    }
    // bucket sort by depth (far first)
    const int B = 4096;
    std::vector<int> cnt(B + 1, 0);
    float scale = dmax > dmin ? (B - 1) / (dmax - dmin) : 0.f;
    for (int k : visible) cnt[B - 1 - int((mesh->depth[k] - dmin) * scale)]++;
    std::vector<int> start(B + 1, 0);
    for (int b = 0; b < B; ++b) start[b + 1] = start[b] + cnt[b];
    mesh->order.resize(visible.size());
    for (int k : visible) mesh->order[start[B - 1 - int((mesh->depth[k] - dmin) * scale)]++] = k;

    const size_t nt = mesh->order.size();
    mesh->pos.resize(nt * 6);
    mesh->col.resize(nt * 3);
    for (size_t t = 0; t < nt; ++t) {
        const cv::Vec3i& f = m.f[mesh->order[t]];
        for (int k = 0; k < 3; ++k) {
            int vi = f[k];
            mesh->pos[t * 6 + k * 2] = scr[vi][0];
            mesh->pos[t * 6 + k * 2 + 1] = scr[vi][1];
            float s = mesh->shade[vi];
            int r, g, b;
            if (mode == SF_RENDER_CLAY) {
                r = int(205 * s); g = int(203 * s); b = int(198 * s);
            } else {
                float s2 = 0.45f + 0.65f * s;
                const cv::Vec3b& c = m.c[vi];
                r = std::min(255, int(c[0] * s2));
                g = std::min(255, int(c[1] * s2));
                b = std::min(255, int(c[2] * s2));
            }
            mesh->col[t * 3 + k] = int32_t(0xFF000000u | (uint32_t(r) << 16) | (uint32_t(g) << 8) | uint32_t(b));
        }
    }
    if (out_positions) *out_positions = mesh->pos.data();
    if (out_colors) *out_colors = mesh->col.data();
    return int(nt);
}

SF_API int sf_mesh_export(sf_mesh* mesh, const char* path, int format, float scale, float bed_x,
                          float bed_y, const char* object_name) {
    if (!mesh || !path) return 1;
    std::string name = object_name && *object_name ? object_name : "Scan";
    if (scale <= 0) scale = 1.f;
    bool ok = false;
    try {
        switch (format) {
            case SF_FORMAT_STL: ok = exportSTL(path, mesh->full, scale, name); break;
            case SF_FORMAT_3MF: ok = export3MF(path, mesh->full, scale, bed_x > 0 ? bed_x : 256.f,
                                               bed_y > 0 ? bed_y : 256.f, name); break;
            case SF_FORMAT_PLY: ok = exportPLY(path, mesh->full, scale); break;
            case SF_FORMAT_OBJ: ok = exportOBJ(path, mesh->full, scale); break;
            default: return 2;
        }
    } catch (...) {
        ok = false;
    }
    return ok ? 0 : 3;
}

}  // extern "C"
