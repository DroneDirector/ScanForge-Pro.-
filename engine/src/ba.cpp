// ScanForge Pro engine - bundle adjustment (Levenberg-Marquardt with Schur complement).
//
// Refines all solved camera poses, the 3D points and (optionally) the shared
// focal length and radial distortion by minimising the robust (Huber)
// reprojection error.
#include "sf_internal.h"

#include <algorithm>
#include <cmath>

namespace sf {

namespace {

struct Obs {
    int cam;
    int pt;
    double u, v;
};

struct State {
    std::vector<cv::Matx33d> R;
    std::vector<cv::Vec3d> t;
    std::vector<cv::Vec3d> X;
    double f, k1;
};

inline double huberCost(double e, double d) { return e <= d ? e * e : 2 * d * e - d * d; }

double totalCost(const State& s, const std::vector<Obs>& obs, double cx, double cy, double delta) {
    double c = 0;
    for (const Obs& o : obs) {
        cv::Vec3d Xc = s.R[o.cam] * s.X[o.pt] + s.t[o.cam];
        if (Xc[2] <= 1e-9) { c += huberCost(1e3, delta); continue; }
        double x = Xc[0] / Xc[2], y = Xc[1] / Xc[2];
        double d = 1 + s.k1 * (x * x + y * y);
        double ru = s.f * d * x + cx - o.u, rv = s.f * d * y + cy - o.v;
        c += huberCost(std::sqrt(ru * ru + rv * rv), delta);
    }
    return c;
}

}  // namespace

double bundleAdjust(Reconstruction& rec, const BAOptions& opt) {
    const int nv = int(rec.views.size());
    std::vector<int> camOf(nv, -1), camView;
    for (int i = 0; i < nv; ++i)
        if (rec.views[i].registered) {
            camOf[i] = int(camView.size());
            camView.push_back(i);
        }
    const int C = int(camView.size());
    if (C < 2) return 0;
    int fixedView = (opt.fixedView >= 0 && opt.fixedView < nv && rec.views[opt.fixedView].registered)
                        ? opt.fixedView
                        : camView[0];

    const int nI = opt.refineIntrinsics ? 2 : 0;
    std::vector<int> camOff(C, -1);
    int P = nI;
    for (int c = 0; c < C; ++c)
        if (camView[c] != fixedView) {
            camOff[c] = P;
            P += 6;
        }

    // points + observations
    std::vector<int> ptTrack;
    std::vector<Obs> obs;
    for (int tid = 0; tid < int(rec.tracks.size()); ++tid) {
        const Track& t = rec.tracks[tid];
        if (!t.valid) continue;
        int reg = 0;
        for (auto& o : t.obs) reg += rec.views[o.view].registered ? 1 : 0;
        if (reg < 2) continue;
        int pid = int(ptTrack.size());
        ptTrack.push_back(tid);
        for (auto& o : t.obs) {
            if (!rec.views[o.view].registered) continue;
            const cv::Point2f& pt = rec.views[o.view].kps[o.kp].pt;
            obs.push_back({camOf[o.view], pid, pt.x, pt.y});
        }
    }
    const int NP = int(ptTrack.size());
    if (obs.empty() || NP == 0) return 0;

    std::vector<std::vector<int>> ptObs(NP);
    for (int k = 0; k < int(obs.size()); ++k) ptObs[obs[k].pt].push_back(k);

    State s;
    s.R.resize(C);
    s.t.resize(C);
    for (int c = 0; c < C; ++c) {
        s.R[c] = rec.views[camView[c]].R;
        s.t[c] = rec.views[camView[c]].t;
    }
    s.X.resize(NP);
    for (int p = 0; p < NP; ++p) s.X[p] = rec.tracks[ptTrack[p]].X;
    s.f = rec.K.f;
    s.k1 = rec.K.k1;
    const double cx = rec.K.cx, cy = rec.K.cy, delta = opt.huber;

    double cost = totalCost(s, obs, cx, cy, delta);
    const double initialCost = cost;
    double lambda = 1e-3;

    // per-observation Jacobian storage
    std::vector<cv::Matx<double, 2, 6>> Jc(obs.size());
    std::vector<cv::Matx<double, 2, 2>> Ji(obs.size());
    std::vector<cv::Matx<double, 2, 3>> Jp(obs.size());
    std::vector<cv::Vec2d> res(obs.size());
    std::vector<double> wgt(obs.size());

    for (int iter = 0; iter < opt.maxIterations; ++iter) {
        // ---- linearise
        for (size_t k = 0; k < obs.size(); ++k) {
            const Obs& o = obs[k];
            const cv::Matx33d& R = s.R[o.cam];
            cv::Vec3d RX = R * s.X[o.pt];
            cv::Vec3d Xc = RX + s.t[o.cam];
            if (Xc[2] <= 1e-9) { wgt[k] = 0; continue; }
            double iz = 1.0 / Xc[2];
            double x = Xc[0] * iz, y = Xc[1] * iz;
            double r2 = x * x + y * y;
            double d = 1 + s.k1 * r2;
            double ru = s.f * d * x + cx - o.u, rv = s.f * d * y + cy - o.v;
            res[k] = cv::Vec2d(ru, rv);
            double e = std::sqrt(ru * ru + rv * rv);
            wgt[k] = e <= delta ? 1.0 : delta / e;

            double dudx = s.f * (d + 2 * s.k1 * x * x), dudy = s.f * 2 * s.k1 * x * y;
            double dvdx = dudy, dvdy = s.f * (d + 2 * s.k1 * y * y);
            // d(x,y)/dXc
            cv::Matx23d dxy(iz, 0, -x * iz, 0, iz, -y * iz);
            cv::Matx22d duv(dudx, dudy, dvdx, dvdy);
            cv::Matx23d J = duv * dxy;  // d(u,v)/dXc
            cv::Matx33d negSkew(0, RX[2], -RX[1], -RX[2], 0, RX[0], RX[1], -RX[0], 0);
            cv::Matx23d Jw = J * negSkew;
            for (int r = 0; r < 2; ++r)
                for (int q = 0; q < 3; ++q) {
                    Jc[k](r, q) = Jw(r, q);
                    Jc[k](r, q + 3) = J(r, q);
                }
            Jp[k] = J * R;
            Ji[k] = opt.refineDistortion ? cv::Matx22d(d * x, s.f * r2 * x, d * y, s.f * r2 * y)
                                         : cv::Matx22d(d * x, 0, d * y, 0);
        }

        // ---- normal equations
        cv::Mat A = cv::Mat::zeros(P, P, CV_64F);
        cv::Mat gy = cv::Mat::zeros(P, 1, CV_64F);
        std::vector<cv::Matx33d> V(NP, cv::Matx33d::zeros());
        std::vector<cv::Vec3d> gp(NP, cv::Vec3d(0, 0, 0));
        std::vector<cv::Matx<double, 6, 3>> Wc(obs.size());
        std::vector<cv::Matx<double, 2, 3>> WI(NP, cv::Matx<double, 2, 3>::zeros());

        for (size_t k = 0; k < obs.size(); ++k) {
            double w = wgt[k];
            if (w == 0) { Wc[k] = cv::Matx<double, 6, 3>::zeros(); continue; }
            const Obs& o = obs[k];
            cv::Vec2d r = res[k];
            V[o.pt] += w * Jp[k].t() * Jp[k];
            gp[o.pt] += w * Jp[k].t() * r;
            int off = camOff[o.cam];
            if (off >= 0) {
                cv::Matx66d cc = w * Jc[k].t() * Jc[k];
                cv::Vec6d gc = w * Jc[k].t() * r;
                for (int a = 0; a < 6; ++a) {
                    gy.at<double>(off + a) += gc[a];
                    double* row = A.ptr<double>(off + a);
                    for (int b = 0; b < 6; ++b) row[off + b] += cc(a, b);
                }
                Wc[k] = w * Jc[k].t() * Jp[k];
            } else {
                Wc[k] = cv::Matx<double, 6, 3>::zeros();
            }
            if (nI) {
                cv::Matx22d ii = w * Ji[k].t() * Ji[k];
                cv::Vec2d gi = w * Ji[k].t() * r;
                for (int a = 0; a < 2; ++a) {
                    gy.at<double>(a) += gi[a];
                    for (int b = 0; b < 2; ++b) A.at<double>(a, b) += ii(a, b);
                }
                if (off >= 0) {
                    cv::Matx<double, 2, 6> ic = w * Ji[k].t() * Jc[k];
                    for (int a = 0; a < 2; ++a)
                        for (int b = 0; b < 6; ++b) {
                            A.at<double>(a, off + b) += ic(a, b);
                            A.at<double>(off + b, a) += ic(a, b);
                        }
                }
                WI[o.pt] += w * Ji[k].t() * Jp[k];
            }
        }

        // ---- damped solve, retried with stronger damping on failure
        bool accepted = false;
        for (int attempt = 0; attempt < 8 && !accepted; ++attempt) {
            cv::Mat S = A.clone();
            for (int a = 0; a < P; ++a) {
                double& dd = S.at<double>(a, a);
                dd += lambda * std::max(dd, 1e-9);
            }
            cv::Mat b = gy.clone();
            if (nI && !opt.refineDistortion) S.at<double>(1, 1) += 1.0;  // k1 held
            std::vector<cv::Matx33d> Vinv(NP);
            for (int p = 0; p < NP; ++p) {
                cv::Matx33d Vd = V[p];
                for (int a = 0; a < 3; ++a) Vd(a, a) += lambda * std::max(Vd(a, a), 1e-9);
                Vinv[p] = Vd.inv(cv::DECOMP_CHOLESKY);
                const auto& ol = ptObs[p];
                // row blocks: intrinsics (WI) and camera blocks (Wc per obs)
                cv::Vec3d vg = Vinv[p] * gp[p];
                if (nI) {
                    cv::Matx<double, 2, 3> WV = WI[p] * Vinv[p];
                    cv::Vec2d bv = WI[p] * vg;
                    for (int a = 0; a < 2; ++a) b.at<double>(a) -= bv[a];
                    cv::Matx22d ii = WV * WI[p].t();
                    for (int a = 0; a < 2; ++a)
                        for (int c2 = 0; c2 < 2; ++c2) S.at<double>(a, c2) -= ii(a, c2);
                    for (int k : ol) {
                        int off = camOff[obs[k].cam];
                        if (off < 0) continue;
                        cv::Matx<double, 2, 6> ic = WV * Wc[k].t();
                        for (int a = 0; a < 2; ++a)
                            for (int c2 = 0; c2 < 6; ++c2) {
                                S.at<double>(a, off + c2) -= ic(a, c2);
                                S.at<double>(off + c2, a) -= ic(a, c2);
                            }
                    }
                }
                for (int k : ol) {
                    int oa = camOff[obs[k].cam];
                    if (oa < 0) continue;
                    cv::Matx<double, 6, 3> WVa = Wc[k] * Vinv[p];
                    cv::Vec6d bv = Wc[k] * vg;
                    for (int a = 0; a < 6; ++a) b.at<double>(oa + a) -= bv[a];
                    for (int k2 : ol) {
                        int ob = camOff[obs[k2].cam];
                        if (ob < 0) continue;
                        cv::Matx66d blk = WVa * Wc[k2].t();
                        for (int a = 0; a < 6; ++a) {
                            double* row = S.ptr<double>(oa + a);
                            for (int c2 = 0; c2 < 6; ++c2) row[ob + c2] -= blk(a, c2);
                        }
                    }
                }
            }
            cv::Mat dy;
            bool ok = P == 0 ? true : cv::solve(S, -b, dy, cv::DECOMP_CHOLESKY);
            if (!ok) {
                lambda *= 10;
                continue;
            }
            if (P == 0) dy = cv::Mat::zeros(0, 1, CV_64F);

            // trial state
            State tr = s;
            if (nI) {
                tr.f = s.f + dy.at<double>(0);
                tr.k1 = std::clamp(s.k1 + dy.at<double>(1), -0.5, 0.5);
                if (tr.f < 0.2 * s.f || tr.f > 5 * s.f) { lambda *= 10; continue; }
            }
            for (int c = 0; c < C; ++c) {
                int off = camOff[c];
                if (off < 0) continue;
                cv::Vec3d dw(dy.at<double>(off), dy.at<double>(off + 1), dy.at<double>(off + 2));
                cv::Vec3d dt(dy.at<double>(off + 3), dy.at<double>(off + 4), dy.at<double>(off + 5));
                tr.R[c] = rodrigues(dw) * s.R[c];
                tr.t[c] = s.t[c] + dt;
            }
            for (int p = 0; p < NP; ++p) {
                cv::Vec3d rhs = gp[p];
                for (int k : ptObs[p]) {
                    int off = camOff[obs[k].cam];
                    if (off < 0) continue;
                    cv::Vec6d dc;
                    for (int a = 0; a < 6; ++a) dc[a] = dy.at<double>(off + a);
                    rhs += Wc[k].t() * dc;
                }
                if (nI) rhs += WI[p].t() * cv::Vec2d(dy.at<double>(0), dy.at<double>(1));
                tr.X[p] = s.X[p] - Vinv[p] * rhs;
            }
            double nc = totalCost(tr, obs, cx, cy, delta);
            if (nc < cost) {
                double rel = (cost - nc) / std::max(cost, 1e-12);
                s = std::move(tr);
                cost = nc;
                lambda = std::max(lambda / 3.0, 1e-7);
                accepted = true;
                if (rel < 1e-6) iter = opt.maxIterations;  // converged
            } else {
                lambda *= 4;
            }
        }
        if (!accepted) break;
    }

    // write back
    for (int c = 0; c < C; ++c) {
        rec.views[camView[c]].R = s.R[c];
        rec.views[camView[c]].t = s.t[c];
    }
    for (int p = 0; p < NP; ++p) rec.tracks[ptTrack[p]].X = s.X[p];
    if (nI) {
        rec.K.f = s.f;
        rec.K.k1 = s.k1;
    }
    (void)initialCost;
    return std::sqrt(cost / obs.size());
}

}  // namespace sf
