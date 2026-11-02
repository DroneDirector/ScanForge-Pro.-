// ScanForge Pro engine - camera position priors (Live Scan), GPS and masks.
//
// Project folder files (all optional):
//   poses.txt  "up x y z", "size w h" and per photo
//              "<file> fx fy cx cy r00 r01 r02 r10 r11 r12 r20 r21 r22 tx ty tz"
//              world -> camera (x right, y down, z forward), metres.
//   gps.txt    per photo "<file> latitude longitude altitude"
//   masks/<photo name without extension>.png   white = object
#include "sf_internal.h"

#include <cmath>
#include <fstream>
#include <map>
#include <sstream>
#include <sys/stat.h>

namespace sf {

static std::string baseName(const std::string& path) {
    size_t s = path.find_last_of("/\\");
    return s == std::string::npos ? path : path.substr(s + 1);
}

static std::string stem(const std::string& name) {
    size_t d = name.find_last_of('.');
    return d == std::string::npos ? name : name.substr(0, d);
}

static bool fileExists(const std::string& p) {
    struct stat st;
    return ::stat(p.c_str(), &st) == 0;
}

void loadPriors(Reconstruction& rec, const std::string& dir, Progress& p) {
    std::map<std::string, View*> byName;
    for (auto& v : rec.views) byName[baseName(v.path)] = &v;
    const std::string sep = (!dir.empty() && (dir.back() == '/' || dir.back() == '\\')) ? "" : "/";

    int poses = 0, gps = 0, masks = 0;
    {
        std::ifstream f(dir + sep + "poses.txt");
        std::string line;
        while (std::getline(f, line)) {
            std::istringstream ss(line);
            std::string name;
            if (!(ss >> name) || name[0] == '#') continue;
            if (name == "up") {
                cv::Vec3d u;
                if (ss >> u[0] >> u[1] >> u[2] && cv::norm(u) > 0) {
                    rec.up = u / cv::norm(u);
                    rec.upKnown = true;
                }
                continue;
            }
            if (name == "size") {
                ss >> rec.priorK.width >> rec.priorK.height;
                continue;
            }
            double fx, fy, cx, cy, r[9], t[3];
            if (!(ss >> fx >> fy >> cx >> cy)) continue;
            bool ok = true;
            for (double& x : r) ok = ok && bool(ss >> x);
            for (double& x : t) ok = ok && bool(ss >> x);
            if (!ok) continue;
            auto it = byName.find(name);
            if (it == byName.end()) continue;
            View& v = *it->second;
            v.hasPrior = true;
            v.priorR = cv::Matx33d(r);
            v.priorT = cv::Vec3d(t[0], t[1], t[2]);
            if (!rec.priorK.valid) {
                rec.priorK.valid = true;
                rec.priorK.fx = fx; rec.priorK.fy = fy;
                rec.priorK.cx = cx; rec.priorK.cy = cy;
            }
            ++poses;
        }
    }
    {
        std::ifstream f(dir + sep + "gps.txt");
        std::string line;
        while (std::getline(f, line)) {
            std::istringstream ss(line);
            std::string name;
            double lat, lon, alt = 0;
            if (!(ss >> name >> lat >> lon)) continue;
            ss >> alt;
            auto it = byName.find(name);
            if (it == byName.end()) continue;
            it->second->hasGps = true;
            it->second->gps = cv::Vec3d(lat, lon, alt);
            ++gps;
        }
    }
    {
        std::ifstream f(dir + sep + "box.txt");
        double c[3], yaw, w, d, h;
        if (f >> c[0] >> c[1] >> c[2] >> yaw >> w >> d >> h && w > 0 && d > 0 && h > 0) {
            rec.hasBox = true;
            rec.boxCenter = cv::Vec3d(c[0], c[1], c[2]);
            rec.boxYaw = yaw;
            rec.boxW = w; rec.boxD = d; rec.boxH = h;
            p.log(fmt("priors: scan box %.0f x %.0f x %.0f mm", w * 1000, d * 1000, h * 1000));
        }
    }
    rec.turntable = fileExists(dir + sep + "turntable.txt");
    if (rec.turntable) p.log("priors: turntable scan");
    for (auto& v : rec.views) {
        std::string m = dir + sep + "masks/" + stem(baseName(v.path)) + ".png";
        if (fileExists(m)) {
            v.maskPath = m;
            ++masks;
        }
    }
    if (poses || gps || masks)
        p.log(fmt("priors: %d camera positions, %d GPS positions, %d object masks", poses, gps, masks));
}

// Box corners in world coordinates (Live Scan world: y is up).
std::vector<cv::Vec3d> Reconstruction::boxCorners() const {
    std::vector<cv::Vec3d> out;
    const double cy = std::cos(boxYaw), sy = std::sin(boxYaw);
    // ground axes and up axis (Live Scan: y up; other worlds: z up)
    const bool yUp = std::abs(up[1]) > 0.9 || !upKnown;
    const cv::Vec3d ex = cv::Vec3d(1, 0, 0);
    const cv::Vec3d ez = yUp ? cv::Vec3d(0, 0, 1) : cv::Vec3d(0, 1, 0);
    const cv::Vec3d eu = yUp ? cv::Vec3d(0, 1, 0) : cv::Vec3d(0, 0, 1);
    for (int k = 0; k < 8; ++k) {
        double lx = (k & 1 ? 0.5 : -0.5) * boxW, lz = (k & 2 ? 0.5 : -0.5) * boxD, lh = (k & 4 ? boxH : 0.0);
        out.push_back(boxCenter + ex * (cy * lx + sy * lz) + ez * (-sy * lx + cy * lz) + eu * lh);
    }
    return out;
}

void applyPriorIntrinsics(Reconstruction& rec) {
    if (!rec.priorK.valid || rec.views.empty()) return;
    const View& v = rec.views[0];
    int pw = rec.priorK.width > 0 ? rec.priorK.width : v.origW;
    if (pw <= 0) return;
    double sc = double(v.width) / pw;
    rec.K.f = 0.5 * (rec.priorK.fx + rec.priorK.fy) * sc;
    rec.K.cx = rec.priorK.cx * sc;
    rec.K.cy = rec.priorK.cy * sc;
    rec.K.k1 = 0;
}

// ---------------------------------------------------------------------------
// Similarity transform dst = s R src + t (Umeyama 1991)
// ---------------------------------------------------------------------------
bool umeyama(const std::vector<cv::Vec3d>& src, const std::vector<cv::Vec3d>& dst, double& s,
             cv::Matx33d& R, cv::Vec3d& t) {
    const size_t n = src.size();
    if (n < 3 || dst.size() != n) return false;
    cv::Vec3d ms(0, 0, 0), md(0, 0, 0);
    for (size_t i = 0; i < n; ++i) { ms += src[i]; md += dst[i]; }
    ms *= 1.0 / n;
    md *= 1.0 / n;
    cv::Matx33d S = cv::Matx33d::zeros();
    double vs = 0;
    for (size_t i = 0; i < n; ++i) {
        cv::Vec3d a = src[i] - ms, b = dst[i] - md;
        S += b * a.t();
        vs += a.dot(a);
    }
    S *= 1.0 / n;
    vs /= n;
    if (vs < 1e-18) return false;
    cv::Mat w, u, vt;
    cv::SVD::compute(cv::Mat(S), w, u, vt);
    cv::Matx33d U(u), Vt(vt);
    cv::Matx33d D = cv::Matx33d::eye();
    if (cv::determinant(U) * cv::determinant(Vt) < 0) D(2, 2) = -1;
    R = U * D * Vt;
    double tr = w.at<double>(0) * D(0, 0) + w.at<double>(1) * D(1, 1) + w.at<double>(2) * D(2, 2);
    s = tr / vs;
    t = md - s * (R * ms);
    return s > 0;
}

void applySimilarity(Reconstruction& rec, double s, const cv::Matx33d& R, const cv::Vec3d& t) {
    for (auto& v : rec.views) {
        if (!v.registered) continue;
        cv::Vec3d c = s * (R * v.center()) + t;
        v.R = v.R * R.t();
        v.t = -(v.R * c);
    }
    for (auto& tr : rec.tracks)
        if (tr.valid) tr.X = s * (R * tr.X) + t;
}

// Puts the solved model back into the Live Scan coordinate frame (metres).
void alignToPriors(Reconstruction& rec, Progress& p) {
    std::vector<cv::Vec3d> src, dst;
    for (auto& v : rec.views)
        if (v.registered && v.hasPrior) {
            src.push_back(v.center());
            dst.push_back(-(v.priorR.t() * v.priorT));
        }
    double s;
    cv::Matx33d R;
    cv::Vec3d t;
    if (!umeyama(src, dst, s, R, t)) return;
    applySimilarity(rec, s, R, t);
    double err = 0;
    for (size_t i = 0; i < src.size(); ++i) err += cv::norm(s * (R * src[i]) + t - dst[i]);
    rec.metric = true;
    p.log(fmt("priors: aligned to camera positions (scale %.4f, mean offset %.1f mm)", s,
              1000.0 * err / src.size()));
}

// Gives drone / large scans real size and a north-up orientation.
void alignToGps(Reconstruction& rec, Progress& p) {
    std::vector<const View*> g;
    for (auto& v : rec.views)
        if (v.registered && v.hasGps) g.push_back(&v);
    if (g.size() < 3) return;
    const double R0 = 6378137.0, deg = 3.14159265358979323846 / 180.0;
    const cv::Vec3d ref = g[0]->gps;
    std::vector<cv::Vec3d> src, dst;
    for (const View* v : g) {
        cv::Vec3d d = v->gps - ref;
        dst.emplace_back(d[1] * deg * R0 * std::cos(ref[0] * deg), d[0] * deg * R0, d[2]);
        src.push_back(v->center());
    }
    double spread = 0;
    for (auto& a : dst)
        for (auto& b : dst) spread = std::max(spread, cv::norm(a - b));
    if (spread < 3.0) {
        p.log("gps: positions too close together to help (needs several metres)");
        return;
    }
    double s;
    cv::Matx33d R;
    cv::Vec3d t;
    if (!umeyama(src, dst, s, R, t)) return;
    double err = 0;
    for (size_t i = 0; i < src.size(); ++i) err += cv::norm(s * (R * src[i]) + t - dst[i]);
    err /= src.size();
    if (err > 0.25 * spread) {
        p.log(fmt("gps: positions do not fit the photos (%.1f m off), not used", err));
        return;
    }
    applySimilarity(rec, s, R, t);
    rec.metric = true;
    rec.upKnown = true;
    rec.up = cv::Vec3d(0, 0, 1);
    p.log(fmt("gps: real size and north-up from %d positions (%.1f m average offset)", int(g.size()), err));
}

}  // namespace sf
