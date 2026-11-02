// ScanForge Pro engine - dense depth maps (multi-view plane sweep stereo).
//
// For each selected photo a depth map is estimated by sweeping fronto-parallel
// planes through the scene, warping neighbouring photos onto each plane and
// scoring the photo-consistency with normalised cross-correlation (NCC).
// Depth maps are then cross-checked against each other for geometric
// consistency to remove noise.
#include "sf_internal.h"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <map>
#include <numeric>

namespace sf {

namespace {

struct DenseImage {
    cv::Mat gray;    // CV_32F 0..1
    cv::Mat color;   // CV_8UC3
    cv::Mat mask;    // CV_8U 255 = object, may be empty
    cv::Matx33d K;
};

DenseImage loadDense(const Reconstruction& rec, const View& v, int maxDim) {
    DenseImage d;
    cv::Mat img = cv::imread(v.path, cv::IMREAD_COLOR);
    if (img.empty()) return d;
    double sc = double(maxDim) / std::max(img.cols, img.rows);
    int w = int(std::lround(img.cols * sc)), h = int(std::lround(img.rows * sc));
    cv::resize(img, img, cv::Size(w, h), 0, 0, cv::INTER_AREA);
    double s = double(w) / v.width;
    d.K = cv::Matx33d(rec.K.f * s, 0, rec.K.cx * s, 0, rec.K.f * s, rec.K.cy * s, 0, 0, 1);
    cv::Mat mask;
    if (!v.maskPath.empty()) {
        cv::Mat m = cv::imread(v.maskPath, cv::IMREAD_GRAYSCALE);
        if (!m.empty()) {
            cv::resize(m, mask, cv::Size(w, h), 0, 0, cv::INTER_NEAREST);
            cv::threshold(mask, mask, 127, 255, cv::THRESH_BINARY);
        }
    }
    if (std::abs(rec.K.k1) > 1e-6) {
        cv::Mat dist = (cv::Mat_<double>(4, 1) << rec.K.k1, 0, 0, 0);
        cv::Mat und;
        cv::undistort(img, und, cv::Mat(d.K), dist, cv::Mat(d.K));
        img = und;
        if (!mask.empty()) {
            cv::Mat map1, map2, um;
            cv::initUndistortRectifyMap(cv::Mat(d.K), dist, cv::Mat(), cv::Mat(d.K), mask.size(), CV_32FC1, map1, map2);
            cv::remap(mask, um, map1, map2, cv::INTER_NEAREST);
            mask = um;
        }
    }
    d.mask = mask;
    d.color = img;
    cv::Mat g;
    cv::cvtColor(img, g, cv::COLOR_BGR2GRAY);
    g.convertTo(d.gray, CV_32F, 1.0 / 255.0);
    return d;
}

double angleDeg(const cv::Vec3d& a, const cv::Vec3d& b) {
    double c = a.dot(b) / (cv::norm(a) * cv::norm(b) + 1e-12);
    return std::acos(std::clamp(c, -1.0, 1.0)) * 180.0 / 3.14159265358979323846;
}

double baselineWeight(double ang) {
    if (ang < 2.0) return 0.0;
    if (ang < 6.0) return (ang - 2.0) / 4.0;
    if (ang <= 30.0) return 1.0;
    if (ang < 50.0) return (50.0 - ang) / 20.0;
    return 0.0;
}

}  // namespace

void computeDepthMaps(const Reconstruction& rec, const Settings& s, Progress& p,
                      std::vector<DepthMap>& out) {
    out.clear();
    std::vector<int> reg;
    for (int i = 0; i < int(rec.views.size()); ++i)
        if (rec.views[i].registered) reg.push_back(i);

    // reference photos, evenly sampled
    std::vector<int> refs;
    if (int(reg.size()) <= s.maxDepthViews) {
        refs = reg;
    } else {
        for (int k = 0; k < s.maxDepthViews; ++k)
            refs.push_back(reg[size_t(double(k) * reg.size() / s.maxDepthViews)]);
    }

    // sparse points seen by each photo
    std::vector<std::vector<int>> visible(rec.views.size());
    for (int tid = 0; tid < int(rec.tracks.size()); ++tid) {
        const Track& t = rec.tracks[tid];
        if (!t.valid) continue;
        for (auto& o : t.obs)
            if (rec.views[o.view].registered) visible[o.view].push_back(tid);
    }

    // global depth fallback
    std::vector<double> allDepth;

    struct RefPlan {
        int view;
        std::vector<int> nbrs;
        double dmin, dmax;
    };
    std::vector<RefPlan> plans;
    for (int r : refs) {
        const View& vr = rec.views[r];
        const auto& vis = visible[r];
        if (vis.size() < 10) continue;
        std::vector<double> depths;
        cv::Vec3d mean(0, 0, 0);
        for (int tid : vis) {
            cv::Vec3d Xc = vr.R * rec.tracks[tid].X + vr.t;
            if (Xc[2] > 0) depths.push_back(Xc[2]);
            mean += rec.tracks[tid].X;
        }
        mean *= 1.0 / vis.size();
        if (depths.size() < 10) continue;
        std::sort(depths.begin(), depths.end());
        double dmin = depths[size_t(depths.size() * 0.02)] * 0.85;
        double dmax = depths[size_t(depths.size() * 0.98)] * 1.15;

        std::map<int, int> shared;
        for (int tid : vis)
            for (auto& o : rec.tracks[tid].obs)
                if (o.view != r && rec.views[o.view].registered) shared[o.view]++;
        std::vector<std::pair<double, int>> scored;
        for (auto& kv : shared) {
            const View& vn = rec.views[kv.first];
            double ang = angleDeg(vr.center() - mean, vn.center() - mean);
            double sc = kv.second * baselineWeight(ang);
            if (sc > 0) scored.emplace_back(sc, kv.first);
        }
        std::sort(scored.rbegin(), scored.rend());
        RefPlan plan{r, {}, dmin, dmax};
        for (size_t k = 0; k < scored.size() && plan.nbrs.size() < 4; ++k) plan.nbrs.push_back(scored[k].second);
        if (plan.nbrs.empty()) continue;
        plans.push_back(plan);
    }
    if (plans.empty()) return;

    // load the photos that are needed (refs + neighbours) at depth resolution
    std::map<int, DenseImage> imgs;
    for (auto& pl : plans) {
        imgs[pl.view];
        for (int n : pl.nbrs) imgs[n];
    }
    std::vector<int> toLoad;
    for (auto& kv : imgs) toLoad.push_back(kv.first);
    std::vector<DenseImage> loaded(toLoad.size());
    parallelFor(0, int(toLoad.size()), [&](int k) {
        loaded[k] = loadDense(rec, rec.views[toLoad[k]], s.depthMaxDim);
    }, std::min(4, hardwareThreads()));
    for (size_t k = 0; k < toLoad.size(); ++k) imgs[toLoad[k]] = std::move(loaded[k]);
    p.checkCancel();

    const int win = s.depthMaxDim >= 600 ? 9 : 7;
    const cv::Size wsz(win, win);
    std::vector<DepthMap> maps(plans.size());

    for (size_t pi = 0; pi < plans.size(); ++pi) {
        p.checkCancel();
        const RefPlan& pl = plans[pi];
        const DenseImage& R = imgs[pl.view];
        if (R.gray.empty()) continue;
        const View& vr = rec.views[pl.view];
        const cv::Size sz = R.gray.size();
        const int npx = sz.area();

        cv::Mat mI, mI2, I2, varI;
        cv::boxFilter(R.gray, mI, -1, wsz, cv::Point(-1, -1), true, cv::BORDER_REFLECT);
        cv::multiply(R.gray, R.gray, I2);
        cv::boxFilter(I2, mI2, -1, wsz, cv::Point(-1, -1), true, cv::BORDER_REFLECT);
        varI = mI2 - mI.mul(mI);

        const int L = s.depthLevels;
        const double invMin = 1.0 / pl.dmax, invMax = 1.0 / pl.dmin;
        auto invAt = [&](double k) { return invMin + k * (invMax - invMin) / (L - 1); };

        std::vector<cv::Matx33d> Hbase;  // per neighbour: K_n R_rel K_r^-1 and t part
        std::vector<cv::Vec3d> tpart;
        std::vector<const DenseImage*> nb;
        cv::Matx33d Kri = R.K.inv();
        for (int n : pl.nbrs) {
            const DenseImage& N = imgs[n];
            if (N.gray.empty()) continue;
            const View& vn = rec.views[n];
            cv::Matx33d Rrel = vn.R * vr.R.t();
            cv::Vec3d trel = vn.t - Rrel * vr.t;
            Hbase.push_back(N.K * Rrel * Kri);
            tpart.push_back(N.K * trel);
            nb.push_back(&N);
        }
        const int NN = int(nb.size());
        if (NN == 0) continue;

        cv::Mat best(sz, CV_32F, cv::Scalar(-2.f)), before(sz, CV_32F, cv::Scalar(-2.f)),
            after(sz, CV_32F, cv::Scalar(-2.f)), prev(sz, CV_32F, cv::Scalar(-2.f));
        cv::Mat bestIdx(sz, CV_32S, cv::Scalar(-10));
        std::vector<cv::Mat> ncc(NN);
        cv::Mat Jw, mJ, J2, mJ2, IJ, mIJ, score(sz, CV_32F);

        for (int k = 0; k < L; ++k) {
            double invd = invAt(k);
            for (int q = 0; q < NN; ++q) {
                // H = K_n (R_rel + t_rel n^T / d) K_r^-1 with n = (0,0,1), 1/d = invd
                cv::Matx33d H = Hbase[q];
                cv::Matx33d T(0, 0, tpart[q][0] * invd, 0, 0, tpart[q][1] * invd, 0, 0, tpart[q][2] * invd);
                H = H + T * Kri;
                cv::warpPerspective(nb[q]->gray, Jw, cv::Mat(H), sz, cv::INTER_LINEAR | cv::WARP_INVERSE_MAP,
                                    cv::BORDER_CONSTANT, cv::Scalar(-1.0));
                cv::boxFilter(Jw, mJ, -1, wsz, cv::Point(-1, -1), true, cv::BORDER_REFLECT);
                cv::multiply(Jw, Jw, J2);
                cv::boxFilter(J2, mJ2, -1, wsz, cv::Point(-1, -1), true, cv::BORDER_REFLECT);
                cv::multiply(R.gray, Jw, IJ);
                cv::boxFilter(IJ, mIJ, -1, wsz, cv::Point(-1, -1), true, cv::BORDER_REFLECT);
                cv::Mat& out = ncc[q];
                out.create(sz, CV_32F);
                const float* pmI = mI.ptr<float>();
                const float* pvI = varI.ptr<float>();
                const float* pmJ = mJ.ptr<float>();
                const float* pmJ2 = mJ2.ptr<float>();
                const float* pmIJ = mIJ.ptr<float>();
                const float* pJw = Jw.ptr<float>();
                float* po = out.ptr<float>();
                for (int i = 0; i < npx; ++i) {
                    float vj = pmJ2[i] - pmJ[i] * pmJ[i];
                    float cov = pmIJ[i] - pmI[i] * pmJ[i];
                    float v = -1.f;
                    if (vj > 1e-5f && pvI[i] > 1e-5f) v = cov / std::sqrt(vj * pvI[i]);
                    if (pJw[i] < 0.f) v = -1.f;  // outside the neighbour photo
                    po[i] = v;
                }
            }
            // aggregate: mean of best two neighbours
            float* ps = score.ptr<float>();
            for (int i = 0; i < npx; ++i) {
                float b1 = -1.f, b2 = -1.f;
                for (int q = 0; q < NN; ++q) {
                    float v = ncc[q].ptr<float>()[i];
                    if (v > b1) { b2 = b1; b1 = v; } else if (v > b2) { b2 = v; }
                }
                ps[i] = NN >= 2 ? 0.5f * (b1 + b2) : b1;
            }
            float* pb = best.ptr<float>();
            float* pbe = before.ptr<float>();
            float* paf = after.ptr<float>();
            float* ppr = prev.ptr<float>();
            int* pix = bestIdx.ptr<int>();
            for (int i = 0; i < npx; ++i) {
                float v = ps[i];
                if (v > pb[i]) {
                    pbe[i] = ppr[i];
                    pb[i] = v;
                    pix[i] = k;
                    paf[i] = -2.f;
                } else if (pix[i] == k - 1) {
                    paf[i] = v;
                }
                ppr[i] = v;
            }
            p.sub((float(pi) + float(k + 1) / L) / plans.size() * 0.9f);
        }

        // depth with sub-level refinement + confidence
        DepthMap& dm = maps[pi];
        dm.view = pl.view;
        dm.K = R.K;
        dm.color = R.color;
        dm.mask = R.mask;
        dm.depth = cv::Mat::zeros(sz, CV_32F);
        const float* pb = best.ptr<float>();
        const float* pbe = before.ptr<float>();
        const float* paf = after.ptr<float>();
        const int* pix = bestIdx.ptr<int>();
        const float* pvI = varI.ptr<float>();
        float* pd = dm.depth.ptr<float>();
        const float minNcc = 0.5f, minVar = 0.012f * 0.012f;
        for (int i = 0; i < npx; ++i) {
            int k = pix[i];
            if (k <= 0 || k >= L - 1) continue;
            if (pb[i] < minNcc || pvI[i] < minVar) continue;
            double off = 0;
            if (pbe[i] > -1.5f && paf[i] > -1.5f) {
                double den = pbe[i] - 2.0 * pb[i] + paf[i];
                if (den < -1e-6) off = std::clamp(0.5 * (pbe[i] - paf[i]) / den, -0.5, 0.5);
            }
            double invd = invAt(k + off);
            if (invd > 1e-9) pd[i] = float(1.0 / invd);
        }
        cv::Mat filt;
        cv::medianBlur(dm.depth, filt, 3);
        dm.depth.setTo(0, filt == 0);
        if (!dm.mask.empty()) dm.depth.setTo(0, dm.mask == 0);
    }
    p.checkCancel();

    // ---- geometric consistency between depth maps
    std::vector<int> good;
    for (size_t i = 0; i < maps.size(); ++i)
        if (!maps[i].depth.empty()) good.push_back(int(i));
    std::vector<cv::Mat> filtered(maps.size());
    parallelFor(0, int(good.size()), [&](int gi) {
        int i = good[gi];
        const DepthMap& a = maps[i];
        const View& va = rec.views[a.view];
        // closest other depth maps by viewing direction
        std::vector<std::pair<double, int>> cand;
        for (int j : good) {
            if (j == i) continue;
            double ang = angleDeg(va.axis(), rec.views[maps[j].view].axis());
            if (ang < 60) cand.emplace_back(ang, j);
        }
        std::sort(cand.begin(), cand.end());
        if (cand.size() > 6) cand.resize(6);
        int need = cand.size() >= 3 ? 2 : 1;
        cv::Mat out = cv::Mat::zeros(a.depth.size(), CV_32F);
        if (cand.empty()) { filtered[i] = a.depth.clone(); return; }
        cv::Matx33d Kai = a.K.inv();
        for (int y = 0; y < a.depth.rows; ++y) {
            const float* row = a.depth.ptr<float>(y);
            for (int x = 0; x < a.depth.cols; ++x) {
                float d = row[x];
                if (d <= 0) continue;
                cv::Vec3d Xc = Kai * cv::Vec3d(x, y, 1.0) * d;
                cv::Vec3d Xw = va.R.t() * (Xc - va.t);
                int agree = 0;
                for (auto& c : cand) {
                    const DepthMap& b = maps[c.second];
                    const View& vb = rec.views[b.view];
                    cv::Vec3d Xb = vb.R * Xw + vb.t;
                    if (Xb[2] <= 0) continue;
                    cv::Vec3d uv = b.K * Xb;
                    int u = int(std::lround(uv[0] / uv[2])), v = int(std::lround(uv[1] / uv[2]));
                    if (u < 0 || v < 0 || u >= b.depth.cols || v >= b.depth.rows) continue;
                    float db = b.depth.at<float>(v, u);
                    if (db <= 0) continue;
                    if (std::abs(db - Xb[2]) / Xb[2] < 0.008) ++agree;
                }
                if (agree >= need) out.at<float>(y, x) = d;
            }
        }
        filtered[i] = out;
    }, s.threads);

    int totalValid = 0;
    const char* dbg = std::getenv("SF_DEBUG_DIR");
    for (int i : good) {
        if (dbg) {
            double mx;
            cv::minMaxLoc(filtered[i], nullptr, &mx);
            cv::Mat a, b2;
            maps[i].depth.convertTo(a, CV_8U, mx > 0 ? 255.0 / mx : 1.0);
            filtered[i].convertTo(b2, CV_8U, mx > 0 ? 255.0 / mx : 1.0);
            cv::Mat both;
            cv::hconcat(a, b2, both);
            cv::imwrite(std::string(dbg) + fmt("/depth_%03d.png", maps[i].view), both);
        }
        maps[i].depth = filtered[i];
        totalValid += cv::countNonZero(maps[i].depth);
        out.push_back(std::move(maps[i]));
    }
    p.log(fmt("depth: %d depth maps, %d valid depth samples", int(out.size()), totalValid));
}

}  // namespace sf
