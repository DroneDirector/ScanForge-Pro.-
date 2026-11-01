// ScanForge Pro engine - incremental structure from motion (camera solving).
#include "sf_internal.h"

#include <opencv2/calib3d.hpp>

#include <algorithm>
#include <cmath>
#include <numeric>
#include <set>

namespace sf {

static const double kPi = 3.14159265358979323846;

bool projectPoint(const Intrinsics& K, const View& v, const cv::Vec3d& X, cv::Vec2d& uv) {
    cv::Vec3d Xc = v.R * X + v.t;
    if (Xc[2] <= 1e-9) return false;
    double x = Xc[0] / Xc[2], y = Xc[1] / Xc[2];
    double d = 1.0 + K.k1 * (x * x + y * y);
    uv = cv::Vec2d(K.f * d * x + K.cx, K.f * d * y + K.cy);
    return true;
}

// pixel -> undistorted normalized image coordinates
static cv::Vec2d normalize(const Intrinsics& K, const cv::Point2f& pt) {
    double xd = (pt.x - K.cx) / K.f, yd = (pt.y - K.cy) / K.f;
    double x = xd, y = yd;
    for (int it = 0; it < 6; ++it) {
        double d = 1.0 + K.k1 * (x * x + y * y);
        x = xd / d;
        y = yd / d;
    }
    return {x, y};
}

static double rayAngleDeg(const cv::Vec3d& X, const cv::Vec3d& c1, const cv::Vec3d& c2) {
    cv::Vec3d a = X - c1, b = X - c2;
    double na = cv::norm(a), nb = cv::norm(b);
    if (na < 1e-12 || nb < 1e-12) return 0;
    double c = std::clamp(a.dot(b) / (na * nb), -1.0, 1.0);
    return std::acos(c) * 180.0 / kPi;
}

// Triangulates a track from all of its observations in registered photos.
static bool triangulateTrack(Reconstruction& rec, Track& t, double minAngle, double maxErr) {
    std::vector<int> use;
    for (int k = 0; k < int(t.obs.size()); ++k)
        if (rec.views[t.obs[k].view].registered) use.push_back(k);
    if (use.size() < 2) return false;

    cv::Mat A(int(use.size()) * 2, 4, CV_64F);
    for (int r = 0; r < int(use.size()); ++r) {
        const Observation& o = t.obs[use[r]];
        const View& v = rec.views[o.view];
        cv::Vec2d xn = normalize(rec.K, v.kps[o.kp].pt);
        double P[3][4];
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 3; ++j) P[i][j] = v.R(i, j);
            P[i][3] = v.t[i];
        }
        for (int j = 0; j < 4; ++j) {
            A.at<double>(2 * r, j) = xn[0] * P[2][j] - P[0][j];
            A.at<double>(2 * r + 1, j) = xn[1] * P[2][j] - P[1][j];
        }
    }
    cv::Mat w, u, vt;
    cv::SVD::compute(A, w, u, vt, cv::SVD::MODIFY_A);
    double h = vt.at<double>(3, 3);
    if (std::abs(h) < 1e-12) return false;
    cv::Vec3d X(vt.at<double>(3, 0) / h, vt.at<double>(3, 1) / h, vt.at<double>(3, 2) / h);

    double maxAng = 0;
    for (size_t a = 0; a < use.size(); ++a) {
        const View& va = rec.views[t.obs[use[a]].view];
        cv::Vec2d uv;
        if (!projectPoint(rec.K, va, X, uv)) return false;
        cv::Point2f pt = va.kps[t.obs[use[a]].kp].pt;
        double e = std::hypot(uv[0] - pt.x, uv[1] - pt.y);
        if (e > maxErr) return false;
        for (size_t b = a + 1; b < use.size(); ++b)
            maxAng = std::max(maxAng, rayAngleDeg(X, va.center(), rec.views[t.obs[use[b]].view].center()));
    }
    if (maxAng < minAngle) return false;
    t.X = X;
    t.valid = true;
    return true;
}

static int triangulateNew(Reconstruction& rec, double minAngle, double maxErr) {
    int n = 0;
    for (auto& t : rec.tracks)
        if (!t.valid && triangulateTrack(rec, t, minAngle, maxErr)) ++n;
    return n;
}

// Removes observations with a large reprojection error; returns removed count.
static int filterOutliers(Reconstruction& rec, double maxErr) {
    int removed = 0;
    for (int tid = 0; tid < int(rec.tracks.size()); ++tid) {
        Track& t = rec.tracks[tid];
        if (!t.valid) continue;
        std::vector<Observation> keep;
        int reg = 0;
        for (const auto& o : t.obs) {
            const View& v = rec.views[o.view];
            if (!v.registered) { keep.push_back(o); continue; }
            cv::Vec2d uv;
            bool ok = projectPoint(rec.K, v, t.X, uv);
            double e = ok ? std::hypot(uv[0] - v.kps[o.kp].pt.x, uv[1] - v.kps[o.kp].pt.y) : 1e9;
            if (e <= maxErr) {
                keep.push_back(o);
                ++reg;
            } else {
                rec.views[o.view].kpTrack[o.kp] = -1;
                ++removed;
            }
        }
        t.obs.swap(keep);
        if (reg < 2) t.valid = false;
    }
    return removed;
}

// ---------------------------------------------------------------------------
// Initial pair
// ---------------------------------------------------------------------------
static bool initialize(Reconstruction& rec, Progress& p) {
    std::vector<int> order(rec.pairs.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return rec.pairs[a].m.size() > rec.pairs[b].m.size(); });
    if (order.size() > 40) order.resize(40);

    double bestScore = 0;
    int bestPair = -1;
    cv::Matx33d bestR;
    cv::Vec3d bestT;

    for (int pi : order) {
        const PairMatches& pm = rec.pairs[pi];
        if (pm.m.size() < 60) continue;
        const View& a = rec.views[pm.i];
        const View& b = rec.views[pm.j];
        std::vector<cv::Point2d> pa, pb;
        for (auto& m : pm.m) {
            cv::Vec2d x1 = normalize(rec.K, a.kps[m[0]].pt), x2 = normalize(rec.K, b.kps[m[1]].pt);
            pa.emplace_back(x1[0], x1[1]);
            pb.emplace_back(x2[0], x2[1]);
        }
        cv::Mat mask;
        cv::Mat E = cv::findEssentialMat(pa, pb, 1.0, cv::Point2d(0, 0), cv::RANSAC, 0.999,
                                         1.5 / rec.K.f, mask);
        if (E.empty() || E.rows != 3) continue;
        cv::Mat Rm, tm;
        int good = cv::recoverPose(E, pa, pb, Rm, tm, 1.0, cv::Point2d(0, 0), mask);
        if (good < 50) continue;
        cv::Matx33d R(Rm);
        cv::Vec3d t(tm);
        cv::Vec3d c2 = -(R.t() * t);
        // triangulation angles of inliers
        std::vector<double> angles;
        cv::Matx34d P1(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0);
        cv::Matx34d P2(R(0, 0), R(0, 1), R(0, 2), t[0], R(1, 0), R(1, 1), R(1, 2), t[1], R(2, 0),
                       R(2, 1), R(2, 2), t[2]);
        std::vector<cv::Point2d> ia, ib;
        for (int k = 0; k < mask.rows; ++k)
            if (mask.at<uchar>(k)) { ia.push_back(pa[k]); ib.push_back(pb[k]); }
        if (ia.size() < 50) continue;
        cv::Mat X4;
        cv::triangulatePoints(P1, P2, ia, ib, X4);
        X4.convertTo(X4, CV_64F);
        for (int k = 0; k < X4.cols; ++k) {
            double w = X4.at<double>(3, k);
            if (std::abs(w) < 1e-12) continue;
            cv::Vec3d X(X4.at<double>(0, k) / w, X4.at<double>(1, k) / w, X4.at<double>(2, k) / w);
            if (X[2] <= 0) continue;
            angles.push_back(rayAngleDeg(X, cv::Vec3d(0, 0, 0), c2));
        }
        if (angles.size() < 50) continue;
        std::nth_element(angles.begin(), angles.begin() + angles.size() / 2, angles.end());
        double med = angles[angles.size() / 2];
        if (med < 2.5) continue;
        double score = double(angles.size()) * std::min(1.0, med / 10.0);
        if (score > bestScore) {
            bestScore = score;
            bestPair = pi;
            bestR = R;
            bestT = t;
        }
    }
    if (bestPair < 0) return false;

    const PairMatches& pm = rec.pairs[bestPair];
    View& a = rec.views[pm.i];
    View& b = rec.views[pm.j];
    a.R = cv::Matx33d::eye();
    a.t = cv::Vec3d(0, 0, 0);
    b.R = bestR;
    b.t = bestT;
    a.registered = b.registered = true;
    int n = triangulateNew(rec, 1.0, 4.0);
    p.log(fmt("cameras: start pair %d/%d, %d points", pm.i, pm.j, n));
    if (n < 30) {
        a.registered = b.registered = false;
        for (auto& t : rec.tracks) t.valid = false;
        return false;
    }
    BAOptions o;
    o.refineIntrinsics = false;
    o.fixedView = pm.i;
    o.maxIterations = 15;
    bundleAdjust(rec, o);
    filterOutliers(rec, 4.0);
    return true;
}

// ---------------------------------------------------------------------------
// Registration of further photos (PnP)
// ---------------------------------------------------------------------------
static bool registerView(Reconstruction& rec, int vi, int minInliers) {
    View& v = rec.views[vi];
    std::vector<cv::Point3d> obj;
    std::vector<cv::Point2d> img;
    for (int k = 0; k < int(v.kps.size()); ++k) {
        int tid = v.kpTrack[k];
        if (tid < 0 || !rec.tracks[tid].valid) continue;
        const cv::Vec3d& X = rec.tracks[tid].X;
        obj.emplace_back(X[0], X[1], X[2]);
        img.emplace_back(v.kps[k].pt.x, v.kps[k].pt.y);
    }
    if (int(obj.size()) < minInliers) return false;
    cv::Matx33d Km(rec.K.f, 0, rec.K.cx, 0, rec.K.f, rec.K.cy, 0, 0, 1);
    cv::Mat dist = (cv::Mat_<double>(4, 1) << rec.K.k1, 0, 0, 0);
    cv::Mat rvec, tvec, inl;
    bool ok = cv::solvePnPRansac(obj, img, Km, dist, rvec, tvec, false, 1000, 4.0, 0.999, inl,
                                 cv::SOLVEPNP_EPNP);
    if (!ok || inl.rows < std::max(minInliers, int(0.3 * obj.size()))) return false;
    std::vector<cv::Point3d> o2;
    std::vector<cv::Point2d> i2;
    for (int r = 0; r < inl.rows; ++r) {
        o2.push_back(obj[inl.at<int>(r)]);
        i2.push_back(img[inl.at<int>(r)]);
    }
    cv::solvePnPRefineLM(o2, i2, Km, dist, rvec, tvec);
    std::vector<cv::Point2d> proj;
    cv::projectPoints(o2, rvec, tvec, Km, dist, proj);
    std::vector<double> errs;
    for (size_t k = 0; k < proj.size(); ++k) errs.push_back(cv::norm(proj[k] - i2[k]));
    std::nth_element(errs.begin(), errs.begin() + errs.size() / 2, errs.end());
    if (errs[errs.size() / 2] > 2.0) return false;
    v.R = rodrigues(cv::Vec3d(rvec));
    v.t = cv::Vec3d(tvec);
    v.registered = true;
    return true;
}

bool runSfM(Reconstruction& rec, const Settings& s, Progress& p) {
    (void)s;
    const int n = int(rec.views.size());
    if (!initialize(rec, p)) {
        p.log("cameras: no usable start pair");
        return false;
    }
    p.registered = rec.numRegistered();

    int lastBA = rec.numRegistered();
    std::set<int> failed;
    for (;;) {
        p.checkCancel();
        // candidates ordered by number of visible 3D points
        std::vector<std::pair<int, int>> cand;
        for (int i = 0; i < n; ++i) {
            if (rec.views[i].registered || failed.count(i)) continue;
            int c = 0;
            for (int tid : rec.views[i].kpTrack)
                if (tid >= 0 && rec.tracks[tid].valid) ++c;
            if (c >= 20) cand.emplace_back(c, i);
        }
        if (cand.empty()) {
            if (failed.empty()) break;
            failed.clear();  // retry once more after the model has grown
            bool any = false;
            for (int i = 0; i < n; ++i)
                if (!rec.views[i].registered) {
                    int c = 0;
                    for (int tid : rec.views[i].kpTrack)
                        if (tid >= 0 && rec.tracks[tid].valid) ++c;
                    if (c >= 15 && registerView(rec, i, 15)) { any = true; break; }
                }
            if (!any) break;
        } else {
            std::sort(cand.rbegin(), cand.rend());
            bool reg = false;
            for (size_t c = 0; c < cand.size() && c < 6; ++c) {
                if (registerView(rec, cand[c].second, 20)) { reg = true; break; }
                failed.insert(cand[c].second);
            }
            if (!reg) continue;
        }

        triangulateNew(rec, 1.5, 4.0);
        int nreg = rec.numRegistered();
        p.registered = nreg;
        p.sub(float(nreg) / n * 0.9f);
        p.message(fmt("Solving camera positions: %d of %d photos", nreg, n));

        if (nreg <= 6 || nreg >= int(lastBA * 1.25)) {
            BAOptions o;
            o.refineIntrinsics = nreg >= 8;
            o.maxIterations = 12;
            double rms = bundleAdjust(rec, o);
            p.log(fmt("cameras: %d solved, rms %.2f px, focal %.1f", nreg, rms, rec.K.f));
            filterOutliers(rec, 4.0);
            lastBA = nreg;
        }
    }

    // final refinement
    BAOptions o;
    o.refineIntrinsics = rec.numRegistered() >= 8;
    o.maxIterations = 30;
    bundleAdjust(rec, o);
    filterOutliers(rec, 3.0);
    triangulateNew(rec, 1.5, 3.0);
    o.refineDistortion = rec.numRegistered() >= 12;
    bundleAdjust(rec, o);
    filterOutliers(rec, 2.5);

    int valid = 0;
    for (auto& t : rec.tracks) valid += t.valid ? 1 : 0;
    p.registered = rec.numRegistered();
    p.log(fmt("cameras: %d of %d photos solved, %d points, focal %.1f px, k1 %.4f",
              rec.numRegistered(), n, valid, rec.K.f, rec.K.k1));
    return rec.numRegistered() >= 3;
}

}  // namespace sf
