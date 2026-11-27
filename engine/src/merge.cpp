// ScanForge Pro engine - flip-and-merge.
//
// Two closed scans of the same object (for example standing, then flipped
// over to see the bottom) are lined up and combined. Each scan is a closed
// solid in which the part it could not see (the side resting on the table)
// was closed off, so each scan contains the whole object. Lining them up and
// keeping only the space inside both gives the complete object, with every
// side taken from the scan that actually saw it.
#include "sf_internal.h"

#include <opencv2/flann.hpp>

#include <algorithm>
#include <cmath>
#include <memory>
#include <sstream>

namespace sf {

namespace {

struct Cloud {
    std::vector<cv::Vec3f> p, n;
    std::vector<cv::Vec3b> c;
};

void vertexNormals(const Mesh& m, std::vector<cv::Vec3f>& n) {
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

// Surface points that were actually scanned: the flat cap that closes the
// side resting on the table is left out.
Cloud measuredCloud(const Mesh& m) {
    std::vector<cv::Vec3f> n;
    vertexNormals(m, n);
    cv::Vec3f mn, mx;
    m.bounds(mn, mx);
    const float h = std::max(1e-3f, mx[2] - mn[2]);
    const float capZ = mn[2] + std::max(1.0f, 0.012f * h);
    Cloud c;
    for (size_t i = 0; i < m.v.size(); ++i) {
        if (m.v[i][2] < capZ && n[i][2] < -0.85f) continue;
        c.p.push_back(m.v[i]);
        c.n.push_back(n[i]);
        c.c.push_back(i < m.c.size() ? m.c[i] : cv::Vec3b(160, 160, 160));
    }
    return c;
}

std::vector<cv::Vec3f> subsample(const std::vector<cv::Vec3f>& p, size_t maxN) {
    if (p.size() <= maxN) return p;
    std::vector<cv::Vec3f> out;
    out.reserve(maxN);
    for (size_t k = 0; k < maxN; ++k) out.push_back(p[size_t(double(k) * p.size() / maxN)]);
    return out;
}

cv::Vec3f centroid(const std::vector<cv::Vec3f>& p) {
    cv::Vec3d s(0, 0, 0);
    for (auto& q : p) s += cv::Vec3d(q[0], q[1], q[2]);
    s *= 1.0 / std::max<size_t>(1, p.size());
    return cv::Vec3f(float(s[0]), float(s[1]), float(s[2]));
}

cv::Matx33d principalAxes(const std::vector<cv::Vec3f>& p, const cv::Vec3f& c) {
    cv::Mat cov = cv::Mat::zeros(3, 3, CV_64F);
    for (auto& q : p) {
        cv::Vec3d d(q[0] - c[0], q[1] - c[1], q[2] - c[2]);
        cov += cv::Mat(d * d.t());
    }
    cv::Mat evals, evecs;
    cv::eigen(cov, evals, evecs);
    cv::Matx33d E;  // columns = axes
    for (int r = 0; r < 3; ++r)
        for (int k = 0; k < 3; ++k) E(r, k) = evecs.at<double>(k, r);
    if (cv::determinant(E) < 0)
        for (int r = 0; r < 3; ++r) E(r, 2) = -E(r, 2);
    return E;
}

// The 24 rotations that map the coordinate axes onto themselves.
std::vector<cv::Matx33d> cubeRotations() {
    std::vector<cv::Matx33d> out;
    const int perm[6][3] = {{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}};
    for (auto& pm : perm)
        for (int sgn = 0; sgn < 8; ++sgn) {
            cv::Matx33d R = cv::Matx33d::zeros();
            for (int r = 0; r < 3; ++r) R(r, pm[r]) = (sgn >> r) & 1 ? -1.0 : 1.0;
            if (cv::determinant(R) > 0) out.push_back(R);
        }
    return out;
}

bool rigidFit(const std::vector<cv::Vec3d>& src, const std::vector<cv::Vec3d>& dst, cv::Matx33d& R,
              cv::Vec3d& t) {
    const size_t n = src.size();
    if (n < 6) return false;
    cv::Vec3d ms(0, 0, 0), md(0, 0, 0);
    for (size_t i = 0; i < n; ++i) { ms += src[i]; md += dst[i]; }
    ms *= 1.0 / n;
    md *= 1.0 / n;
    cv::Matx33d S = cv::Matx33d::zeros();
    for (size_t i = 0; i < n; ++i) S += (dst[i] - md) * (src[i] - ms).t();
    cv::Mat w, u, vt;
    cv::SVD::compute(cv::Mat(S), w, u, vt);
    cv::Matx33d U(u), Vt(vt);
    cv::Matx33d D = cv::Matx33d::eye();
    if (cv::determinant(U) * cv::determinant(Vt) < 0) D(2, 2) = -1;
    R = U * D * Vt;
    t = md - R * ms;
    return true;
}

struct Nearest {
    cv::Mat data;
    std::unique_ptr<cv::flann::Index> index;
    explicit Nearest(const std::vector<cv::Vec3f>& p) {
        data = cv::Mat(int(p.size()), 3, CV_32F);
        for (size_t i = 0; i < p.size(); ++i)
            for (int k = 0; k < 3; ++k) data.at<float>(int(i), k) = p[i][k];
        index.reset(new cv::flann::Index(data, cv::flann::KDTreeIndexParams(4)));
    }
    // returns squared distance
    float query(const cv::Vec3f& q, int& id) const {
        float qv[3] = {q[0], q[1], q[2]};
        int ind[1];
        float dist[1];
        cv::Mat qm(1, 3, CV_32F, qv), im(1, 1, CV_32S, ind), dm(1, 1, CV_32F, dist);
        index->knnSearch(qm, im, dm, 1, cv::flann::SearchParams(32));
        id = ind[0];
        return dist[0];
    }
};

struct Fit {
    cv::Matx33d R = cv::Matx33d::eye();
    cv::Vec3d t = {0, 0, 0};
    double score = 1e30, rms = 1e30, overlap = 0;
};

Fit icp(const std::vector<cv::Vec3f>& src, const Nearest& dst, const std::vector<cv::Vec3f>& dstPts,
        cv::Matx33d R, cv::Vec3d t, double diag, int iters) {
    Fit fit;
    double thr = 0.25 * diag;
    const double thrMin = 0.006 * diag;
    for (int it = 0; it < iters; ++it) {
        std::vector<std::pair<double, int>> d;
        std::vector<int> nn(src.size());
        d.reserve(src.size());
        for (size_t i = 0; i < src.size(); ++i) {
            cv::Vec3d q = R * cv::Vec3d(src[i][0], src[i][1], src[i][2]) + t;
            int id;
            double dd = std::sqrt(double(dst.query(cv::Vec3f(float(q[0]), float(q[1]), float(q[2])), id)));
            nn[i] = id;
            d.emplace_back(dd, int(i));
        }
        std::sort(d.begin(), d.end());
        size_t keep = std::max<size_t>(6, size_t(d.size() * 0.7));
        std::vector<cv::Vec3d> a, b;
        double sum = 0;
        size_t inl = 0;
        for (size_t k = 0; k < d.size(); ++k) {
            if (d[k].first < thr) ++inl;
            if (k >= keep || d[k].first > thr) continue;
            int i = d[k].second;
            a.emplace_back(src[i][0], src[i][1], src[i][2]);
            const cv::Vec3f& p = dstPts[nn[i]];
            b.emplace_back(p[0], p[1], p[2]);
            sum += d[k].first * d[k].first;
        }
        if (a.size() < 6) break;
        fit.rms = std::sqrt(sum / a.size());
        fit.overlap = double(inl) / src.size();
        // re-fit the full transform from the original points
        cv::Matx33d R2;
        cv::Vec3d t2;
        if (!rigidFit(a, b, R2, t2)) break;
        // a = original source points, so R2/t2 is the complete transform
        R = R2;
        t = t2;
        thr = std::max(thrMin, thr * 0.7);
    }
    fit.R = R;
    fit.t = t;
    fit.score = fit.rms / std::max(0.05, fit.overlap * fit.overlap);
    return fit;
}

// Inside/outside of a closed mesh on a grid, by counting ray crossings
// along z through each column.
void occupancy(const Mesh& m, const cv::Vec3f& lo, float cell, int nx, int ny, int nz, std::vector<uint8_t>& occ) {
    occ.assign(size_t(nx) * ny * nz, 0);
    std::vector<std::vector<int>> bucket(size_t(nx) * ny);
    for (int fi = 0; fi < int(m.f.size()); ++fi) {
        const auto& f = m.f[fi];
        float x0 = 1e30f, x1 = -1e30f, y0 = 1e30f, y1 = -1e30f;
        for (int k = 0; k < 3; ++k) {
            x0 = std::min(x0, m.v[f[k]][0]); x1 = std::max(x1, m.v[f[k]][0]);
            y0 = std::min(y0, m.v[f[k]][1]); y1 = std::max(y1, m.v[f[k]][1]);
        }
        int ix0 = std::max(0, int(std::floor((x0 - lo[0]) / cell)));
        int ix1 = std::min(nx - 1, int(std::ceil((x1 - lo[0]) / cell)));
        int iy0 = std::max(0, int(std::floor((y0 - lo[1]) / cell)));
        int iy1 = std::min(ny - 1, int(std::ceil((y1 - lo[1]) / cell)));
        for (int y = iy0; y <= iy1; ++y)
            for (int x = ix0; x <= ix1; ++x) bucket[size_t(y) * nx + x].push_back(fi);
    }
    parallelFor(0, ny, [&](int y) {
        std::vector<float> hits;
        for (int x = 0; x < nx; ++x) {
            // tiny offset so rays never pass exactly through edges or corners
            const double px = lo[0] + x * double(cell) + 1.37e-4 * cell;
            const double py = lo[1] + y * double(cell) + 2.91e-4 * cell;
            hits.clear();
            for (int fi : bucket[size_t(y) * nx + x]) {
                const auto& f = m.f[fi];
                const cv::Vec3f &a = m.v[f[0]], &b = m.v[f[1]], &c = m.v[f[2]];
                double d = (b[0] - a[0]) * double(c[1] - a[1]) - (c[0] - a[0]) * double(b[1] - a[1]);
                if (std::abs(d) < 1e-14) continue;
                double l1 = ((px - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (py - a[1])) / d;
                double l2 = ((b[0] - a[0]) * (py - a[1]) - (px - a[0]) * (b[1] - a[1])) / d;
                if (l1 < 0 || l2 < 0 || l1 + l2 > 1) continue;
                hits.push_back(float(a[2] + l1 * (b[2] - a[2]) + l2 * (c[2] - a[2])));
            }
            if (hits.size() < 2) continue;
            std::sort(hits.begin(), hits.end());
            for (size_t k = 0; k + 1 < hits.size(); k += 2) {
                int z0 = std::max(0, int(std::ceil((hits[k] - lo[2]) / cell)));
                int z1 = std::min(nz - 1, int(std::floor((hits[k + 1] - lo[2]) / cell)));
                for (int z = z0; z <= z1; ++z) occ[(size_t(z) * ny + y) * nx + x] = 1;
            }
        }
    });
}

}  // namespace

int mergeMeshes(const Mesh& a, const Mesh& b, Mesh& out, std::string& log) {
    std::ostringstream L;
    Cloud ca = measuredCloud(a), cb = measuredCloud(b);
    if (ca.p.size() < 50 || cb.p.size() < 50) return 1;

    // ---- line up b with a: try many starting orientations, refine with ICP
    std::vector<cv::Vec3f> pa = subsample(ca.p, 6000), pb = subsample(cb.p, 1500);
    Nearest na(pa);
    const cv::Vec3f cA = centroid(pa), cB = centroid(pb);
    cv::Vec3f mnA, mxA;
    a.bounds(mnA, mxA);
    const double diag = std::max(1.0, cv::norm(mxA - mnA));
    const cv::Matx33d EA = principalAxes(pa, cA), EB = principalAxes(pb, cB);
    std::vector<cv::Matx33d> starts;
    for (const auto& S : cubeRotations()) {
        starts.push_back(S);
        starts.push_back(EA * S * EB.t());
    }
    Fit best;
    std::vector<Fit> coarse;
    for (const auto& R0 : starts) {
        cv::Vec3d t0 = cv::Vec3d(cA[0], cA[1], cA[2]) - R0 * cv::Vec3d(cB[0], cB[1], cB[2]);
        coarse.push_back(icp(subsample(pb, 400), na, pa, R0, t0, diag, 10));
    }
    std::sort(coarse.begin(), coarse.end(), [](const Fit& x, const Fit& y) { return x.score < y.score; });
    for (size_t k = 0; k < std::min<size_t>(4, coarse.size()); ++k) {
        Fit f = icp(pb, na, pa, coarse[k].R, coarse[k].t, diag, 40);
        if (f.score < best.score) best = f;
    }
    L << "merge: aligned, rms " << best.rms << " mm, overlap " << int(best.overlap * 100) << "%\n";
    if (best.overlap < 0.25) {
        log = L.str() + "merge: the two scans do not match well enough\n";
        return 2;
    }

    // ---- b in a's frame
    Mesh bt = b;
    for (auto& v : bt.v) {
        cv::Vec3d q = best.R * cv::Vec3d(v[0], v[1], v[2]) + best.t;
        v = cv::Vec3f(float(q[0]), float(q[1]), float(q[2]));
    }

    // ---- space inside both scans
    cv::Vec3f mnB, mxB;
    bt.bounds(mnB, mxB);
    cv::Vec3f lo, hi;
    for (int k = 0; k < 3; ++k) {
        lo[k] = std::max(mnA[k], mnB[k]);
        hi[k] = std::min(mxA[k], mxB[k]);
        if (hi[k] <= lo[k]) { log = L.str() + "merge: the scans do not overlap\n"; return 3; }
    }
    const float ext = std::max({hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]});
    const int res = 176;
    const float cell = ext / res;
    lo -= cv::Vec3f(3 * cell, 3 * cell, 3 * cell);
    hi += cv::Vec3f(3 * cell, 3 * cell, 3 * cell);
    const int nx = int(std::ceil((hi[0] - lo[0]) / cell)) + 1;
    const int ny = int(std::ceil((hi[1] - lo[1]) / cell)) + 1;
    const int nz = int(std::ceil((hi[2] - lo[2]) / cell)) + 1;
    std::vector<uint8_t> oa, ob;
    occupancy(a, lo, cell, nx, ny, nz, oa);
    occupancy(bt, lo, cell, nx, ny, nz, ob);

    Volume vol;
    vol.nx = nx; vol.ny = ny; vol.nz = nz;
    vol.voxel = cell;
    vol.origin = cv::Vec3d(lo[0], lo[1], lo[2]);
    vol.M = cv::Matx33d::eye();
    vol.center = cv::Vec3d(0, 0, 0);
    const size_t N = size_t(nx) * ny * nz;
    vol.tsdf.assign(N, 1.f);
    vol.weight.assign(N, 1.f);
    vol.color.assign(N, cv::Vec3b(160, 160, 160));
    vol.colorW.assign(N, 0);
    for (size_t i = 0; i < N; ++i) vol.tsdf[i] = (oa[i] && ob[i]) ? -1.f : 1.f;
    // soften the blocky inside/outside field so the surface lands between voxels
    std::vector<float> tmp(N);
    for (int pass = 0; pass < 2; ++pass)
        for (int axis = 0; axis < 3; ++axis) {
            const size_t step = axis == 0 ? 1 : axis == 1 ? size_t(nx) : size_t(nx) * ny;
            const int len = axis == 0 ? nx : axis == 1 ? ny : nz;
            parallelFor(0, nz, [&](int z) {
                for (int y = 0; y < ny; ++y)
                    for (int x = 0; x < nx; ++x) {
                        size_t i = vol.idx(x, y, z);
                        int c = axis == 0 ? x : axis == 1 ? y : z;
                        float m0 = vol.tsdf[i];
                        float l = c > 0 ? vol.tsdf[i - step] : m0;
                        float r = c < len - 1 ? vol.tsdf[i + step] : m0;
                        tmp[i] = 0.25f * l + 0.5f * m0 + 0.25f * r;
                    }
            });
            vol.tsdf.swap(tmp);
        }

    extractSurface(vol, out);
    oa.clear(); ob.clear();
    vol.tsdf.clear(); vol.weight.clear(); vol.color.clear(); vol.colorW.clear();
    keepMainComponents(out, 0.35f);
    if (out.f.empty()) { log = L.str() + "merge: nothing left after combining\n"; return 4; }
    taubinSmooth(out, 2);
    featureSmooth(out, 8, 6);
    simplifyMesh(out, 150000);

    // ---- colours from the nearest scanned point of either scan
    Cloud cbt = cb;
    for (auto& v : cbt.p) {
        cv::Vec3d q = best.R * cv::Vec3d(v[0], v[1], v[2]) + best.t;
        v = cv::Vec3f(float(q[0]), float(q[1]), float(q[2]));
    }
    std::vector<cv::Vec3f> allP = ca.p;
    std::vector<cv::Vec3b> allC = ca.c;
    allP.insert(allP.end(), cbt.p.begin(), cbt.p.end());
    allC.insert(allC.end(), cbt.c.begin(), cbt.c.end());
    Nearest nc(allP);
    out.c.resize(out.v.size());
    for (size_t i = 0; i < out.v.size(); ++i) {
        int id;
        nc.query(out.v[i], id);
        out.c[i] = allC[id];
    }

    // ---- standing on z = 0, centred
    cv::Vec3f mn, mx;
    out.bounds(mn, mx);
    const cv::Vec3f sh(0.5f * (mn[0] + mx[0]), 0.5f * (mn[1] + mx[1]), mn[2]);
    for (auto& v : out.v) v -= sh;
    L << "merge: " << out.v.size() << " vertices, " << out.f.size() << " triangles, watertight: "
      << (isWatertight(out) ? "yes" : "no") << "\n";
    log = L.str();
    return 0;
}

}  // namespace sf
