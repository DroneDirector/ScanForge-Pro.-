// ScanForge Pro engine - mesh clean-up, smoothing, PLY files and display meshes.
#include "sf_internal.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <numeric>
#include <queue>
#include <sstream>
#include <unordered_map>

namespace sf {

namespace {
struct DSU {
    std::vector<int> p;
    explicit DSU(size_t n) : p(n) { std::iota(p.begin(), p.end(), 0); }
    int find(int x) {
        while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; }
        return x;
    }
    void unite(int a, int b) { a = find(a); b = find(b); if (a != b) p[b] = a; }
};
}  // namespace

void removeUnusedVertices(Mesh& m) {
    std::vector<int> remap(m.v.size(), -1);
    Mesh out;
    for (auto& f : m.f)
        for (int k = 0; k < 3; ++k)
            if (remap[f[k]] < 0) {
                remap[f[k]] = int(out.v.size());
                out.v.push_back(m.v[f[k]]);
                out.c.push_back(m.c.empty() ? cv::Vec3b(180, 180, 180) : m.c[f[k]]);
            }
    out.f.reserve(m.f.size());
    for (auto& f : m.f) out.f.emplace_back(remap[f[0]], remap[f[1]], remap[f[2]]);
    m = std::move(out);
}

void keepMainComponents(Mesh& m, float minFraction) {
    if (m.f.empty()) return;
    DSU d(m.v.size());
    for (auto& f : m.f) { d.unite(f[0], f[1]); d.unite(f[1], f[2]); }
    std::unordered_map<int, int> count;
    for (auto& f : m.f) count[d.find(f[0])]++;
    int best = 0;
    for (auto& kv : count) best = std::max(best, kv.second);
    std::vector<cv::Vec3i> kept;
    for (auto& f : m.f)
        if (count[d.find(f[0])] >= best * minFraction) kept.push_back(f);
    m.f.swap(kept);
    removeUnusedVertices(m);
}

void taubinSmooth(Mesh& m, int iterations) {
    if (iterations <= 0 || m.v.empty()) return;
    const size_t n = m.v.size();
    std::vector<std::vector<int>> nb(n);
    for (auto& f : m.f)
        for (int k = 0; k < 3; ++k) {
            int a = f[k], b = f[(k + 1) % 3];
            nb[a].push_back(b);
            nb[b].push_back(a);
        }
    for (auto& l : nb) {
        std::sort(l.begin(), l.end());
        l.erase(std::unique(l.begin(), l.end()), l.end());
    }
    std::vector<cv::Vec3f> tmp(n);
    auto pass = [&](float factor) {
        parallelFor(0, int(n), [&](int i) {
            if (nb[i].empty()) { tmp[i] = m.v[i]; return; }
            cv::Vec3f avg(0, 0, 0);
            for (int j : nb[i]) avg += m.v[j];
            avg *= 1.f / nb[i].size();
            tmp[i] = m.v[i] + factor * (avg - m.v[i]);
        });
        m.v.swap(tmp);
    };
    for (int it = 0; it < iterations; ++it) {
        pass(0.5f);
        pass(-0.53f);
    }
}

bool isWatertight(const Mesh& m) {
    if (m.f.empty()) return false;
    std::unordered_map<uint64_t, int> edges;
    edges.reserve(m.f.size() * 3);
    for (auto& f : m.f)
        for (int k = 0; k < 3; ++k) {
            uint64_t a = uint32_t(f[k]), b = uint32_t(f[(k + 1) % 3]);
            if (a > b) std::swap(a, b);
            edges[(a << 32) | b]++;
        }
    for (auto& kv : edges)
        if (kv.second != 2) return false;
    return true;
}

// ---------------------------------------------------------------------------
// PLY (binary little endian, float xyz + uchar rgb, int faces)
// ---------------------------------------------------------------------------
bool savePLY(const std::string& path, const Mesh& m) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << "ply\nformat binary_little_endian 1.0\ncomment ScanForge Pro\n";
    f << "element vertex " << m.v.size() << "\n";
    f << "property float x\nproperty float y\nproperty float z\n";
    f << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    f << "element face " << m.f.size() << "\n";
    f << "property list uchar int vertex_indices\nend_header\n";
    for (size_t i = 0; i < m.v.size(); ++i) {
        f.write(reinterpret_cast<const char*>(&m.v[i][0]), 12);
        cv::Vec3b c = i < m.c.size() ? m.c[i] : cv::Vec3b(180, 180, 180);
        f.write(reinterpret_cast<const char*>(&c[0]), 3);
    }
    for (auto& t : m.f) {
        uint8_t three = 3;
        f.write(reinterpret_cast<const char*>(&three), 1);
        f.write(reinterpret_cast<const char*>(&t[0]), 12);
    }
    return bool(f);
}

bool savePointsPLY(const std::string& path, const std::vector<cv::Vec3f>& pts,
                   const std::vector<cv::Vec3b>& cols) {
    Mesh m;
    m.v = pts;
    m.c = cols;
    return savePLY(path, m);
}

bool loadPLY(const std::string& path, Mesh& m) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::string line;
    size_t nv = 0, nf = 0;
    bool binary = false, hasColor = false;
    std::vector<std::string> vprops;
    std::string current;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::istringstream ss(line);
        std::string w;
        ss >> w;
        if (w == "format") {
            std::string fm;
            ss >> fm;
            binary = fm == "binary_little_endian";
        } else if (w == "element") {
            ss >> current;
            if (current == "vertex") ss >> nv;
            else if (current == "face") ss >> nf;
        } else if (w == "property" && current == "vertex") {
            std::string type, name;
            ss >> type >> name;
            vprops.push_back(type + ":" + name);
            if (name == "red") hasColor = true;
        } else if (w == "end_header") {
            break;
        }
    }
    if (!binary) return false;
    // only our own layout is supported
    bool layoutOk = (vprops.size() == 3 || vprops.size() == 6) && vprops[0] == "float:x";
    if (!layoutOk) return false;
    m.clear();
    m.v.resize(nv);
    m.c.resize(nv, cv::Vec3b(180, 180, 180));
    for (size_t i = 0; i < nv; ++i) {
        f.read(reinterpret_cast<char*>(&m.v[i][0]), 12);
        if (hasColor) f.read(reinterpret_cast<char*>(&m.c[i][0]), 3);
    }
    m.f.resize(nf);
    for (size_t i = 0; i < nf; ++i) {
        uint8_t cnt;
        f.read(reinterpret_cast<char*>(&cnt), 1);
        if (cnt != 3) return false;
        f.read(reinterpret_cast<char*>(&m.f[i][0]), 12);
    }
    return bool(f);
}

// ---------------------------------------------------------------------------
// Model units -> millimetres, base on the build plate (z = 0), centred in x/y
// ---------------------------------------------------------------------------
void finalizeToMillimetres(Mesh& m, Volume& vol, bool firstTime) {
    cv::Vec3f mn, mx;
    m.bounds(mn, mx);
    if (firstTime) {
        float maxDim = std::max({mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]});
        // real size when known (metres -> mm), else 100 mm on the longest side
        vol.mmPerUnit = vol.metric ? 1000.0 : (maxDim > 0 ? 100.0 / maxDim : 1.0);
        vol.shiftUnits = cv::Vec3d(0.5 * (mn[0] + mx[0]), 0.5 * (mn[1] + mx[1]), mn[2]);
    } else {
        vol.shiftUnits[2] = mn[2];
    }
    const float s = float(vol.mmPerUnit);
    const cv::Vec3f sh(float(vol.shiftUnits[0]), float(vol.shiftUnits[1]), float(vol.shiftUnits[2]));
    for (auto& p : m.v) p = (p - sh) * s;
}

// ---------------------------------------------------------------------------
// Vertex clustering for a light display mesh
// ---------------------------------------------------------------------------
void decimateForDisplay(const Mesh& in, Mesh& out, int maxFaces) {
    if (int(in.f.size()) <= maxFaces) { out = in; return; }
    cv::Vec3f mn, mx;
    in.bounds(mn, mx);
    float ext = std::max({mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2], 1e-6f});
    int grid = 400;
    for (int attempt = 0; attempt < 12; ++attempt) {
        float cell = ext / grid;
        std::unordered_map<uint64_t, int> cellId;
        std::vector<int> remap(in.v.size());
        std::vector<cv::Vec3d> sum;
        std::vector<cv::Vec3d> csum;
        std::vector<int> cnt;
        for (size_t i = 0; i < in.v.size(); ++i) {
            cv::Vec3f q = (in.v[i] - mn) / cell;
            uint64_t key = (uint64_t(q[0]) << 42) | (uint64_t(q[1]) << 21) | uint64_t(q[2]);
            auto it = cellId.find(key);
            int id;
            if (it == cellId.end()) {
                id = int(sum.size());
                cellId[key] = id;
                sum.emplace_back(0, 0, 0);
                csum.emplace_back(0, 0, 0);
                cnt.push_back(0);
            } else {
                id = it->second;
            }
            remap[i] = id;
            sum[id] += cv::Vec3d(in.v[i]);
            csum[id] += cv::Vec3d(in.c[i][0], in.c[i][1], in.c[i][2]);
            cnt[id]++;
        }
        out.clear();
        for (size_t k = 0; k < sum.size(); ++k) {
            cv::Vec3d p = sum[k] / cnt[k], c = csum[k] / cnt[k];
            out.v.emplace_back(float(p[0]), float(p[1]), float(p[2]));
            out.c.emplace_back(uchar(c[0]), uchar(c[1]), uchar(c[2]));
        }
        for (auto& f : in.f) {
            int a = remap[f[0]], b = remap[f[1]], c = remap[f[2]];
            if (a != b && b != c && a != c) out.f.emplace_back(a, b, c);
        }
        if (int(out.f.size()) <= maxFaces) return;
        grid = int(grid * std::sqrt(double(maxFaces) / out.f.size()) * 0.95);
        if (grid < 16) return;
    }
}


// ---------------------------------------------------------------------------
// Quadric edge-collapse simplification (keeps the mesh closed and manifold)
// ---------------------------------------------------------------------------
namespace {
struct Quadric {
    double a[10] = {0};  // symmetric 4x4 upper triangle
    void addPlane(double nx, double ny, double nz, double d, double w) {
        double p[4] = {nx, ny, nz, d};
        int k = 0;
        for (int i = 0; i < 4; ++i)
            for (int j = i; j < 4; ++j) a[k++] += w * p[i] * p[j];
    }
    Quadric& operator+=(const Quadric& o) {
        for (int i = 0; i < 10; ++i) a[i] += o.a[i];
        return *this;
    }
    double eval(const cv::Vec3d& v) const {
        double x = v[0], y = v[1], z = v[2];
        return a[0] * x * x + 2 * a[1] * x * y + 2 * a[2] * x * z + 2 * a[3] * x + a[4] * y * y +
               2 * a[5] * y * z + 2 * a[6] * y + a[7] * z * z + 2 * a[8] * z + a[9];
    }
    bool optimum(cv::Vec3d& out) const {
        cv::Matx33d A(a[0], a[1], a[2], a[1], a[4], a[5], a[2], a[5], a[7]);
        cv::Vec3d b(-a[3], -a[6], -a[8]);
        double det = cv::determinant(A);
        if (std::abs(det) < 1e-18) return false;
        out = A.inv() * b;
        return true;
    }
};

struct EdgeCand {
    double cost;
    int a, b;
    uint32_t va, vb;
    cv::Vec3d pos;
    bool operator<(const EdgeCand& o) const { return cost > o.cost; }  // min-heap
};
}  // namespace

void simplifyMesh(Mesh& m, int targetFaces) {
    if (int(m.f.size()) <= targetFaces || m.f.empty()) return;
    const int nv = int(m.v.size());
    std::vector<cv::Vec3d> P(nv);
    for (int i = 0; i < nv; ++i) P[i] = cv::Vec3d(m.v[i]);
    std::vector<Quadric> Q(nv);
    std::vector<std::vector<int>> vf(nv);
    std::vector<char> faceAlive(m.f.size(), 1);
    std::vector<cv::Vec3i> F = m.f;
    for (int fi = 0; fi < int(F.size()); ++fi) {
        const cv::Vec3i& f = F[fi];
        cv::Vec3d n = (P[f[1]] - P[f[0]]).cross(P[f[2]] - P[f[0]]);
        double area = cv::norm(n);
        if (area > 0) n /= area;
        double d = -n.dot(P[f[0]]);
        for (int k = 0; k < 3; ++k) {
            Q[f[k]].addPlane(n[0], n[1], n[2], d, area);
            vf[f[k]].push_back(fi);
        }
    }
    std::vector<uint32_t> ver(nv, 0);
    std::vector<char> alive(nv, 1);
    std::vector<cv::Vec3d> C(nv);
    for (int i = 0; i < nv; ++i) C[i] = cv::Vec3d(m.c[i][0], m.c[i][1], m.c[i][2]);

    auto makeCand = [&](int a, int b) {
        Quadric q = Q[a];
        q += Q[b];
        cv::Vec3d p;
        cv::Vec3d mid = (P[a] + P[b]) * 0.5;
        if (!q.optimum(p) || cv::norm(p - mid) > 2.0 * cv::norm(P[a] - P[b])) p = mid;
        double c = q.eval(p);
        return EdgeCand{std::max(0.0, c), a, b, ver[a], ver[b], p};
    };

    std::priority_queue<EdgeCand> heap;
    for (auto& f : F)
        for (int k = 0; k < 3; ++k) {
            int a = f[k], b = f[(k + 1) % 3];
            if (a < b) heap.push(makeCand(a, b));
        }

    int faces = int(F.size());
    std::vector<int> mark(nv, 0);
    int stamp = 0;
    while (faces > targetFaces && !heap.empty()) {
        EdgeCand e = heap.top();
        heap.pop();
        int a = e.a, b = e.b;
        if (!alive[a] || !alive[b] || ver[a] != e.va || ver[b] != e.vb) continue;
        // faces shared by a and b, and link condition
        std::vector<int> shared;
        for (int fi : vf[a])
            if (faceAlive[fi]) {
                const cv::Vec3i& f = F[fi];
                if (f[0] == b || f[1] == b || f[2] == b) shared.push_back(fi);
            }
        if (shared.size() != 2) continue;
        int common = 0;
        ++stamp;
        int stampA = stamp;
        for (int fi : vf[a])
            if (faceAlive[fi])
                for (int k = 0; k < 3; ++k) mark[F[fi][k]] = stampA;
        for (int fi : vf[b])
            if (faceAlive[fi])
                for (int k = 0; k < 3; ++k) {
                    int w = F[fi][k];
                    if (w != a && w != b && mark[w] == stampA) { mark[w] = -1; ++common; }
                }
        if (common != 2) continue;
        // reject collapses that flip or squash neighbouring faces
        bool bad = false;
        for (int pass = 0; pass < 2 && !bad; ++pass)
            for (int fi : vf[pass == 0 ? a : b]) {
                if (!faceAlive[fi]) continue;
                const cv::Vec3i& f = F[fi];
                if (f[0] == (pass ? a : b) || f[1] == (pass ? a : b) || f[2] == (pass ? a : b)) continue;
                cv::Vec3d p0 = P[f[0]], p1 = P[f[1]], p2 = P[f[2]];
                cv::Vec3d n0 = (p1 - p0).cross(p2 - p0);
                int self = pass == 0 ? a : b;
                cv::Vec3d q0 = f[0] == self ? e.pos : p0, q1 = f[1] == self ? e.pos : p1,
                          q2 = f[2] == self ? e.pos : p2;
                cv::Vec3d n1 = (q1 - q0).cross(q2 - q0);
                double l0 = cv::norm(n0), l1 = cv::norm(n1);
                if (l1 < 1e-20 || n0.dot(n1) < 0.25 * l0 * l1) { bad = true; break; }
            }
        if (bad) continue;
        // collapse b into a
        for (int fi : shared) { faceAlive[fi] = 0; --faces; }
        for (int fi : vf[b]) {
            if (!faceAlive[fi]) continue;
            cv::Vec3i& f = F[fi];
            for (int k = 0; k < 3; ++k)
                if (f[k] == b) f[k] = a;
            vf[a].push_back(fi);
        }
        vf[b].clear();
        alive[b] = 0;
        P[a] = e.pos;
        C[a] = (C[a] + C[b]) * 0.5;
        Q[a] += Q[b];
        ver[a]++;
        // compact face list of a and push new candidates
        std::vector<int> nf;
        for (int fi : vf[a])
            if (faceAlive[fi]) nf.push_back(fi);
        std::sort(nf.begin(), nf.end());
        nf.erase(std::unique(nf.begin(), nf.end()), nf.end());
        vf[a].swap(nf);
        for (int fi : vf[a])
            for (int k = 0; k < 3; ++k) {
                int w = F[fi][k];
                if (w != a) heap.push(a < w ? makeCand(a, w) : makeCand(w, a));
            }
    }

    Mesh out;
    std::vector<int> remap(nv, -1);
    for (int fi = 0; fi < int(F.size()); ++fi) {
        if (!faceAlive[fi]) continue;
        cv::Vec3i nfc;
        for (int k = 0; k < 3; ++k) {
            int v = F[fi][k];
            if (remap[v] < 0) {
                remap[v] = int(out.v.size());
                out.v.emplace_back(float(P[v][0]), float(P[v][1]), float(P[v][2]));
                out.c.emplace_back(uchar(C[v][0] + 0.5), uchar(C[v][1] + 0.5), uchar(C[v][2] + 0.5));
            }
            nfc[k] = remap[v];
        }
        out.f.push_back(nfc);
    }
    m = std::move(out);
}

}  // namespace sf
