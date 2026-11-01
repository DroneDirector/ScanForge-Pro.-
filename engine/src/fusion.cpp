// ScanForge Pro engine - depth fusion into a signed distance volume and
// watertight surface extraction.
//
// Depth maps are fused into a truncated signed distance field (TSDF) in an
// up-aligned model frame. Space that no photo ever observed is treated as
// solid, and the volume border plus everything below the detected floor is
// treated as empty, so the extracted surface is always closed (printable).
// The surface is extracted with marching tetrahedra.
#include "sf_internal.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <unordered_map>

namespace sf {

namespace {

cv::Vec3d cross(const cv::Vec3d& a, const cv::Vec3d& b) { return a.cross(b); }

cv::Vec3d unit(const cv::Vec3d& v) {
    double n = cv::norm(v);
    return n > 1e-12 ? v / n : cv::Vec3d(0, 0, 1);
}

cv::Matx33d frameFromUp(const cv::Vec3d& up, const cv::Vec3d& hint) {
    cv::Vec3d z = unit(up);
    cv::Vec3d x = hint - z * hint.dot(z);
    if (cv::norm(x) < 1e-6) x = std::abs(z[0]) < 0.9 ? cv::Vec3d(1, 0, 0) : cv::Vec3d(0, 1, 0);
    x = unit(x - z * x.dot(z));
    cv::Vec3d y = cross(z, x);
    return cv::Matx33d(x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2]);
}

double percentile(std::vector<double> v, double q) {
    if (v.empty()) return 0;
    size_t k = std::min(v.size() - 1, size_t(q * (v.size() - 1)));
    std::nth_element(v.begin(), v.begin() + k, v.end());
    return v[k];
}

}  // namespace

// ---------------------------------------------------------------------------
void fuseDepthMaps(const Reconstruction& rec, const std::vector<DepthMap>& maps,
                   const Settings& s, Progress& p, Volume& vol) {
    std::vector<const View*> cams;
    for (const auto& v : rec.views)
        if (v.registered) cams.push_back(&v);

    // ---- scene centre: least-squares intersection of the optical axes
    cv::Matx33d A = cv::Matx33d::zeros();
    cv::Vec3d b(0, 0, 0);
    for (const View* v : cams) {
        cv::Vec3d d = unit(v->axis());
        cv::Matx33d Pm = cv::Matx33d::eye() - d * d.t();
        A += Pm;
        b += Pm * v->center();
    }
    cv::Vec3d center;
    bool centerOk = false;
    {
        cv::Mat w;
        cv::SVD::compute(cv::Mat(A), w);
        if (w.at<double>(2) > 0.05 * w.at<double>(0)) {
            center = A.inv(cv::DECOMP_SVD) * b;
            centerOk = true;
        }
    }

    // ---- sample points from depth maps
    std::vector<cv::Vec3d> pts;
    for (const auto& dm : maps) {
        const View& v = rec.views[dm.view];
        cv::Matx33d Ki = dm.K.inv();
        for (int y = 0; y < dm.depth.rows; y += 3)
            for (int x = 0; x < dm.depth.cols; x += 3) {
                float d = dm.depth.at<float>(y, x);
                if (d <= 0) continue;
                cv::Vec3d Xc = Ki * cv::Vec3d(x, y, 1) * d;
                pts.push_back(v.R.t() * (Xc - v.t));
            }
    }
    if (pts.size() < 200) {
        for (const auto& t : rec.tracks)
            if (t.valid) pts.push_back(t.X);
    }
    if (pts.size() < 50) throw std::runtime_error("Too little 3D detail was found in the photos.");
    if (!centerOk) {
        std::vector<double> xs, ys, zs;
        for (auto& q : pts) { xs.push_back(q[0]); ys.push_back(q[1]); zs.push_back(q[2]); }
        center = cv::Vec3d(percentile(xs, 0.5), percentile(ys, 0.5), percentile(zs, 0.5));
    }

    // ---- up direction: normal of the ring of camera positions, oriented
    // like the photos' "up", else the average photo up.
    cv::Vec3d camUp(0, 0, 0), meanC(0, 0, 0);
    for (const View* v : cams) {
        camUp += -(v->R.t() * cv::Vec3d(0, 1, 0));
        meanC += v->center();
    }
    camUp = unit(camUp);
    meanC *= 1.0 / cams.size();
    cv::Vec3d up = camUp;
    if (cams.size() >= 6) {
        cv::Mat cov = cv::Mat::zeros(3, 3, CV_64F);
        for (const View* v : cams) {
            cv::Vec3d d = v->center() - meanC;
            cov += cv::Mat(d * d.t());
        }
        cv::Mat evals, evecs;
        cv::eigen(cov, evals, evecs);
        double l0 = evals.at<double>(0), l1 = evals.at<double>(1), l2 = evals.at<double>(2);
        if (l1 > 0.2 * l0 && l2 < 0.5 * l1) {
            cv::Vec3d n(evecs.at<double>(2, 0), evecs.at<double>(2, 1), evecs.at<double>(2, 2));
            if (n.dot(camUp) < 0) n = -n;
            if (n.dot(camUp) > 0.5) up = unit(n);
        }
    }
    double camDist = 0;
    {
        std::vector<double> ds;
        for (const View* v : cams) ds.push_back(cv::norm(v->center() - center));
        camDist = percentile(ds, 0.5);
    }

    cv::Matx33d M = frameFromUp(up, cams[0]->center() - center);
    std::vector<cv::Vec3d> mp;
    mp.reserve(pts.size());
    for (auto& q : pts) {
        cv::Vec3d m = M * (q - center);
        if (cv::norm(m) < 0.75 * camDist) mp.push_back(m);
    }
    if (mp.size() < 50) throw std::runtime_error("The object could not be separated from the background.");

    // ---- floor detection (RANSAC plane roughly perpendicular to up)
    double floorZ = -1e30;
    {
        std::vector<double> zs;
        for (auto& m : mp) zs.push_back(m[2]);
        double extent = percentile(zs, 0.99) - percentile(zs, 0.01);
        double thr = std::max(1e-9, extent * 0.012);
        std::mt19937 rng(7);
        std::uniform_int_distribution<size_t> pick(0, mp.size() - 1);
        int bestIn = 0;
        cv::Vec3d bestN(0, 0, 1);
        double bestD = 0;
        for (int it = 0; it < 400; ++it) {
            cv::Vec3d a = mp[pick(rng)], b2 = mp[pick(rng)], c = mp[pick(rng)];
            cv::Vec3d n = (b2 - a).cross(c - a);
            if (cv::norm(n) < 1e-12) continue;
            n = unit(n);
            if (n[2] < 0) n = -n;
            if (n[2] < std::cos(25.0 * 3.14159265 / 180.0)) continue;
            double d = n.dot(a);
            int in = 0, below = 0;
            for (size_t k = 0; k < mp.size(); k += 2) {
                double e = n.dot(mp[k]) - d;
                if (std::abs(e) < thr) ++in;
                else if (e < 0) ++below;
            }
            if (below > in / 4) continue;  // a floor has (almost) nothing below it
            if (in > bestIn) { bestIn = in; bestN = n; bestD = d; }
        }
        if (bestIn * 2 > int(mp.size() * 0.12)) {
            // least-squares refinement of the plane
            std::vector<cv::Vec3d> inl;
            for (auto& m : mp)
                if (std::abs(bestN.dot(m) - bestD) < thr) inl.push_back(m);
            cv::Vec3d c(0, 0, 0);
            for (auto& q : inl) c += q;
            c *= 1.0 / inl.size();
            cv::Mat cov = cv::Mat::zeros(3, 3, CV_64F);
            for (auto& q : inl) {
                cv::Vec3d d = q - c;
                cov += cv::Mat(d * d.t());
            }
            cv::Mat evals, evecs;
            cv::eigen(cov, evals, evecs);
            cv::Vec3d n(evecs.at<double>(2, 0), evecs.at<double>(2, 1), evecs.at<double>(2, 2));
            if (n[2] < 0) n = -n;
            // re-align the model frame with the floor normal
            cv::Vec3d upW = M.t() * n;
            cv::Vec3d cW = center + M.t() * c;
            cv::Matx33d M2 = frameFromUp(upW, cams[0]->center() - center);
            for (auto& m : mp) m = M2 * (center + M.t() * m - center);
            M = M2;
            floorZ = (M * (cW - center))[2];
            p.log(fmt("fusion: floor found (%d points)", int(inl.size())));
        } else {
            p.log("fusion: no floor found, keeping the full object");
        }
    }

    // ---- bounding box of the object (above the floor)
    // The object is what the photos are centred on: keep points close to the
    // vertical axis through the scene centre and above the floor. The upper
    // body of the object (clear of floor noise) fixes the footprint.
    std::vector<cv::Vec3d> cand;
    const double radial = 0.55 * camDist;
    for (auto& m : mp)
        if (m[2] >= floorZ && std::hypot(m[0], m[1]) <= radial) cand.push_back(m);
    if (cand.size() < 50) throw std::runtime_error("The object could not be separated from the floor.");
    std::vector<double> zc;
    for (auto& m : cand) zc.push_back(m[2]);
    const double zBase = floorZ > -1e29 ? floorZ : percentile(zc, 0.01);
    const double height = std::max(1e-9, percentile(zc, 0.99) - zBase);
    std::vector<double> xs, ys;
    for (auto& m : cand)
        if (m[2] > zBase + 0.08 * height) { xs.push_back(m[0]); ys.push_back(m[1]); }
    if (xs.size() < 30)
        for (auto& m : cand) { xs.push_back(m[0]); ys.push_back(m[1]); }
    double x0 = percentile(xs, 0.01), x1 = percentile(xs, 0.99);
    double y0 = percentile(ys, 0.01), y1 = percentile(ys, 0.99);
    double padXY = 0.15 * std::max(x1 - x0, y1 - y0);
    x0 -= padXY; x1 += padXY; y0 -= padXY; y1 += padXY;
    std::vector<double> zs;
    for (auto& m : cand)
        if (m[0] >= x0 && m[0] <= x1 && m[1] >= y0 && m[1] <= y1) zs.push_back(m[2]);
    double z1 = percentile(zs, 0.995);
    cv::Vec3d lo(x0, y0, zBase), hi(x1, y1, z1);
    cv::Vec3d ext = hi - lo;
    double maxExt = std::max({ext[0], ext[1], ext[2]});
    hi[2] += 0.10 * maxExt;
    lo[2] -= floorZ > -1e29 ? 0.04 * maxExt : 0.10 * maxExt;
    ext = hi - lo;
    maxExt = std::max({ext[0], ext[1], ext[2]});

    const float voxel = float(maxExt / s.volumeRes);
    vol.nx = std::max(8, int(std::ceil(ext[0] / voxel)) + 1);
    vol.ny = std::max(8, int(std::ceil(ext[1] / voxel)) + 1);
    vol.nz = std::max(8, int(std::ceil(ext[2] / voxel)) + 1);
    vol.voxel = voxel;
    vol.origin = lo;
    vol.M = M;
    vol.center = center;
    vol.targetFaces = s.targetFaces;
    vol.smoothIters = s.smoothIters;
    vol.floorZ = vol.autoFloorZ = float(floorZ > -1e29 ? floorZ + 0.75 * voxel : -1e30);
    const size_t N = size_t(vol.nx) * vol.ny * vol.nz;
    vol.tsdf.assign(N, 1.f);
    vol.weight.assign(N, 0.f);
    vol.color.assign(N, cv::Vec3b(160, 160, 160));
    vol.colorW.assign(N, 0);
    p.log(fmt("fusion: volume %dx%dx%d", vol.nx, vol.ny, vol.nz));

    // ---- integration
    struct Proj {
        cv::Matx33d A;  // image = A * p_model + b  (homogeneous)
        cv::Vec3d b;
        const DepthMap* dm;
        float trunc;
    };
    std::vector<Proj> projs;
    for (const auto& dm : maps) {
        const View& v = rec.views[dm.view];
        Proj pr;
        pr.A = dm.K * v.R * M.t();
        pr.b = dm.K * (v.R * center + v.t);
        pr.dm = &dm;
        double footprint = camDist / dm.K(0, 0);
        pr.trunc = float(std::max(3.0 * voxel, 3.0 * footprint));
        projs.push_back(pr);
    }

    std::atomic<int> slices{0};
    parallelFor(0, vol.nz, [&](int z) {
        if (p.cancelRequested) return;
        for (const Proj& pr : projs) {
            const cv::Mat& D = pr.dm->depth;
            const cv::Mat& Cimg = pr.dm->color;
            const int W = D.cols, H = D.rows;
            const float tr = pr.trunc;
            for (int y = 0; y < vol.ny; ++y) {
                cv::Vec3d pm0(vol.origin[0], vol.origin[1] + y * double(voxel), vol.origin[2] + z * double(voxel));
                cv::Vec3d q = pr.A * pm0 + pr.b;
                cv::Vec3d dq(pr.A(0, 0) * voxel, pr.A(1, 0) * voxel, pr.A(2, 0) * voxel);
                size_t base = vol.idx(0, y, z);
                for (int x = 0; x < vol.nx; ++x, q += dq) {
                    double Z = q[2];
                    if (Z <= 1e-9) continue;
                    int u = int(q[0] / Z + 0.5), v = int(q[1] / Z + 0.5);
                    if (u < 0 || v < 0 || u >= W || v >= H) continue;
                    float d = D.at<float>(v, u);
                    if (d <= 0) continue;
                    float sdf = float(d - Z);
                    if (sdf < -tr) continue;
                    size_t id = base + x;
                    float val = std::min(1.f, sdf / tr);
                    float& w = vol.weight[id];
                    float& t = vol.tsdf[id];
                    t = (t * w + val) / (w + 1.f);
                    w = std::min(w + 1.f, 250.f);
                    if (std::abs(sdf) < tr) {
                        uint16_t& cw = vol.colorW[id];
                        const cv::Vec3b& bgr = Cimg.at<cv::Vec3b>(v, u);
                        cv::Vec3b& c = vol.color[id];
                        float a = 1.f / (cw + 1.f);
                        for (int k = 0; k < 3; ++k)
                            c[k] = cv::saturate_cast<uchar>(c[k] * (1.f - a) + bgr[2 - k] * a);
                        if (cw < 60000) ++cw;
                    }
                }
            }
        }
        int sdone = ++slices;
        if ((sdone & 3) == 0) p.sub(float(sdone) / vol.nz);
    }, s.threads);
    p.checkCancel();
}

// ---------------------------------------------------------------------------
// Watertight surface extraction
// ---------------------------------------------------------------------------
static inline float fieldValue(const Volume& vol, int x, int y, int z) {
    if (x <= 0 || y <= 0 || z <= 0 || x >= vol.nx - 1 || y >= vol.ny - 1 || z >= vol.nz - 1) return 1.f;
    float mz = float(vol.origin[2] + z * double(vol.voxel));
    if (mz < vol.floorZ) return 1.f;
    size_t id = vol.idx(x, y, z);
    if (vol.weight[id] <= 0.f) return -1.f;  // never observed: solid
    return vol.tsdf[id];
}

void extractSurface(const Volume& vol, Mesh& mesh) {
    mesh.clear();
    const int nx = vol.nx, ny = vol.ny, nz = vol.nz;
    std::vector<float> F(size_t(nx) * ny * nz);
    parallelFor(0, nz, [&](int z) {
        for (int y = 0; y < ny; ++y)
            for (int x = 0; x < nx; ++x) F[vol.idx(x, y, z)] = fieldValue(vol, x, y, z);
    });

    // Marching tetrahedra on the Kuhn (6 tetrahedra per cube) decomposition.
    // The decomposition is consistent between neighbouring cubes, so the
    // surface is always closed and manifold.
    static const int tets[6][4] = {{0, 1, 3, 7}, {0, 1, 5, 7}, {0, 2, 3, 7},
                                   {0, 2, 6, 7}, {0, 4, 5, 7}, {0, 4, 6, 7}};
    std::unordered_map<uint64_t, int> edgeVert;
    edgeVert.reserve(size_t(nx) * ny * 8);

    auto vertexColor = [&](size_t id) -> std::pair<cv::Vec3d, double> {
        double w = vol.colorW[id];
        const cv::Vec3b& c = vol.color[id];
        return {cv::Vec3d(c[0], c[1], c[2]), w};
    };
    auto edgeVertex = [&](size_t ia, size_t ib, float fa, float fb) -> int {
        if (ia > ib) { std::swap(ia, ib); std::swap(fa, fb); }
        const uint64_t key = uint64_t(ia) * 0x100000000ull + ib;
        auto it = edgeVert.find(key);
        if (it != edgeVert.end()) return it->second;
        double t = fa / double(fa - fb);
        auto pos = [&](size_t id) {
            int x = int(id % nx), y = int((id / nx) % ny), z = int(id / (size_t(nx) * ny));
            return vol.origin + cv::Vec3d(x, y, z) * double(vol.voxel);
        };
        cv::Vec3d p = pos(ia) * (1 - t) + pos(ib) * t;
        auto ca = vertexColor(ia), cb = vertexColor(ib);
        double wa = ca.second * (1 - t), wb = cb.second * t;
        cv::Vec3b col(150, 150, 150);
        if (wa + wb > 0) {
            cv::Vec3d c = (ca.first * wa + cb.first * wb) / (wa + wb);
            col = cv::Vec3b(uchar(c[0] + 0.5), uchar(c[1] + 0.5), uchar(c[2] + 0.5));
        } else if (ca.second > 0 || cb.second > 0) {
            col = ca.second > 0 ? vol.color[ia] : vol.color[ib];
        }
        int id = int(mesh.v.size());
        mesh.v.emplace_back(float(p[0]), float(p[1]), float(p[2]));
        mesh.c.push_back(col);
        edgeVert[key] = id;
        return id;
    };
    auto addTri = [&](int a, int b, int c, const cv::Vec3d& outward) {
        if (a == b || b == c || a == c) return;
        cv::Vec3f n = (mesh.v[b] - mesh.v[a]).cross(mesh.v[c] - mesh.v[a]);
        if (n[0] * outward[0] + n[1] * outward[1] + n[2] * outward[2] < 0) std::swap(b, c);
        mesh.f.emplace_back(a, b, c);
    };

    for (int z = 0; z < nz - 1; ++z)
        for (int y = 0; y < ny - 1; ++y)
            for (int x = 0; x < nx - 1; ++x) {
                size_t cid[8];
                float cv8[8];
                int inside = 0;
                for (int c = 0; c < 8; ++c) {
                    cid[c] = vol.idx(x + (c & 1), y + ((c >> 1) & 1), z + ((c >> 2) & 1));
                    cv8[c] = F[cid[c]];
                    inside += cv8[c] < 0 ? 1 : 0;
                }
                if (inside == 0 || inside == 8) continue;
                for (const auto& t : tets) {
                    int in[4], out[4], ni = 0, no = 0;
                    for (int k = 0; k < 4; ++k) {
                        if (cv8[t[k]] < 0) in[ni++] = t[k]; else out[no++] = t[k];
                    }
                    if (ni == 0 || ni == 4) continue;
                    auto cpos = [&](int c) { return cv::Vec3d(c & 1, (c >> 1) & 1, (c >> 2) & 1); };
                    cv::Vec3d ci(0, 0, 0), co(0, 0, 0);
                    for (int k = 0; k < ni; ++k) ci += cpos(in[k]);
                    for (int k = 0; k < no; ++k) co += cpos(out[k]);
                    cv::Vec3d outward = co / no - ci / ni;
                    auto E = [&](int a, int b) { return edgeVertex(cid[a], cid[b], cv8[a], cv8[b]); };
                    if (ni == 1) {
                        addTri(E(in[0], out[0]), E(in[0], out[1]), E(in[0], out[2]), outward);
                    } else if (ni == 3) {
                        addTri(E(out[0], in[0]), E(out[0], in[1]), E(out[0], in[2]), outward);
                    } else {
                        int a = E(in[0], out[0]), b = E(in[0], out[1]);
                        int c = E(in[1], out[1]), d = E(in[1], out[0]);
                        addTri(a, b, c, outward);
                        addTri(a, c, d, outward);
                    }
                }
            }
}

// ---------------------------------------------------------------------------
// Volume file (compact: int8 distance, RGB colour)
// ---------------------------------------------------------------------------
static const char kVolMagic[8] = {'S', 'F', 'V', 'O', 'L', '0', '0', '3'};

bool saveVolume(const std::string& path, const Volume& vol) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f.write(kVolMagic, 8);
    int32_t dims[3] = {vol.nx, vol.ny, vol.nz};
    f.write(reinterpret_cast<const char*>(dims), sizeof(dims));
    double hdr[9 + 3 + 3 + 1 + 3 + 3 + 2];
    int k = 0;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) hdr[k++] = vol.M(r, c);
    for (int i = 0; i < 3; ++i) hdr[k++] = vol.origin[i];
    for (int i = 0; i < 3; ++i) hdr[k++] = vol.center[i];
    hdr[k++] = vol.voxel;
    hdr[k++] = vol.floorZ;
    hdr[k++] = vol.autoFloorZ;
    hdr[k++] = vol.mmPerUnit;
    for (int i = 0; i < 3; ++i) hdr[k++] = vol.shiftUnits[i];
    hdr[k++] = vol.targetFaces;
    hdr[k++] = vol.smoothIters;
    f.write(reinterpret_cast<const char*>(hdr), sizeof(double) * k);
    const size_t N = vol.tsdf.size();
    std::vector<int8_t> d(N);
    for (size_t i = 0; i < N; ++i)
        d[i] = vol.weight[i] <= 0 ? int8_t(-128) : int8_t(std::lround(std::clamp(vol.tsdf[i], -1.f, 1.f) * 127.f));
    f.write(reinterpret_cast<const char*>(d.data()), N);
    std::vector<uint8_t> cw(N);
    for (size_t i = 0; i < N; ++i) cw[i] = uint8_t(std::min<int>(vol.colorW[i], 255));
    f.write(reinterpret_cast<const char*>(cw.data()), N);
    f.write(reinterpret_cast<const char*>(vol.color.data()), N * 3);
    return bool(f);
}

bool loadVolume(const std::string& path, Volume& vol) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    char magic[8];
    f.read(magic, 8);
    if (std::memcmp(magic, kVolMagic, 8) != 0) return false;
    int32_t dims[3];
    f.read(reinterpret_cast<char*>(dims), sizeof(dims));
    vol.nx = dims[0]; vol.ny = dims[1]; vol.nz = dims[2];
    double hdr[24];
    f.read(reinterpret_cast<char*>(hdr), sizeof(hdr));
    int k = 0;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) vol.M(r, c) = hdr[k++];
    for (int i = 0; i < 3; ++i) vol.origin[i] = hdr[k++];
    for (int i = 0; i < 3; ++i) vol.center[i] = hdr[k++];
    vol.voxel = float(hdr[k++]);
    vol.floorZ = float(hdr[k++]);
    vol.autoFloorZ = float(hdr[k++]);
    vol.mmPerUnit = hdr[k++];
    for (int i = 0; i < 3; ++i) vol.shiftUnits[i] = hdr[k++];
    vol.targetFaces = int(hdr[k++]);
    vol.smoothIters = int(hdr[k++]);
    const size_t N = size_t(vol.nx) * vol.ny * vol.nz;
    std::vector<int8_t> d(N);
    f.read(reinterpret_cast<char*>(d.data()), N);
    std::vector<uint8_t> cw(N);
    f.read(reinterpret_cast<char*>(cw.data()), N);
    vol.color.resize(N);
    f.read(reinterpret_cast<char*>(vol.color.data()), N * 3);
    if (!f) return false;
    vol.tsdf.resize(N);
    vol.weight.resize(N);
    vol.colorW.resize(N);
    for (size_t i = 0; i < N; ++i) {
        vol.weight[i] = d[i] == -128 ? 0.f : 1.f;
        vol.tsdf[i] = d[i] == -128 ? 1.f : d[i] / 127.f;
        vol.colorW[i] = cw[i];
    }
    return true;
}

}  // namespace sf
