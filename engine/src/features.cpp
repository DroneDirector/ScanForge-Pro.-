// ScanForge Pro engine - feature detection, matching and track building.
#include "sf_internal.h"

#include <opencv2/calib3d.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/flann.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <map>
#include <numeric>
#include <stdexcept>
#include <unordered_map>

namespace sf {

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------
static void rootSift(cv::Mat& d) {
    for (int r = 0; r < d.rows; ++r) {
        float* p = d.ptr<float>(r);
        double s = 0;
        for (int c = 0; c < d.cols; ++c) s += std::abs(p[c]);
        if (s < 1e-12) continue;
        for (int c = 0; c < d.cols; ++c) p[c] = float(std::sqrt(std::abs(p[c]) / s));
    }
}

void detectFeatures(Reconstruction& rec, const Settings& s, Progress& p) {
    const int n = int(rec.views.size());
    std::atomic<int> done{0};
    std::vector<std::string> errors(n);
    int workers = std::min(hardwareThreads(), 4);
    if (s.threads > 0) workers = std::min(workers, s.threads);

    parallelFor(0, n, [&](int i) {
        if (p.cancelRequested) return;
        View& v = rec.views[i];
        cv::Mat img = cv::imread(v.path, cv::IMREAD_GRAYSCALE);  // applies EXIF orientation
        if (img.empty()) {
            errors[i] = "cannot read " + v.path;
            return;
        }
        double sc = std::min(1.0, double(s.sfmMaxDim) / std::max(img.cols, img.rows));
        if (sc < 1.0) cv::resize(img, img, cv::Size(), sc, sc, cv::INTER_AREA);
        v.width = img.cols;
        v.height = img.rows;
        auto sift = cv::SIFT::create(s.maxFeatures, 3, 0.03, 10.0, 1.6);
        sift->detectAndCompute(img, cv::noArray(), v.kps, v.desc);
        if (!v.desc.empty()) rootSift(v.desc);
        v.kpTrack.assign(v.kps.size(), -1);
        int d = ++done;
        p.sub(float(d) / n);
    }, workers);
    p.checkCancel();

    // Drop unreadable photos and photos whose size differs from the majority
    // (the camera model is shared by all photos).
    std::map<std::pair<int, int>, int> sizes;
    for (int i = 0; i < n; ++i)
        if (errors[i].empty()) sizes[{rec.views[i].width, rec.views[i].height}]++;
    std::pair<int, int> common{0, 0};
    int best = 0;
    for (auto& kv : sizes)
        if (kv.second > best) { best = kv.second; common = kv.first; }

    std::vector<View> kept;
    for (int i = 0; i < n; ++i) {
        View& v = rec.views[i];
        if (!errors[i].empty()) { p.log(errors[i]); continue; }
        if (std::make_pair(v.width, v.height) != common) {
            p.log("skipping photo with different size: " + v.path);
            continue;
        }
        if (v.kps.size() < 50) {
            p.log("skipping photo with too little detail: " + v.path);
            continue;
        }
        kept.push_back(std::move(v));
    }
    rec.views.swap(kept);
    if (rec.views.size() < 3) throw std::runtime_error("Not enough usable photos (at least 3 needed).");

    rec.K.cx = common.first * 0.5;
    rec.K.cy = common.second * 0.5;
    double maxDim = std::max(common.first, common.second);
    // 35 mm equivalent focal length refers to the 36 mm long side.
    rec.K.f = s.focal35 > 1.0 ? s.focal35 / 36.0 * maxDim : 0.85 * maxDim;
    rec.K.k1 = 0.0;
    p.log(fmt("features: %d photos, %dx%d, focal guess %.1f px", int(rec.views.size()),
              common.first, common.second, rec.K.f));
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------
static std::vector<std::pair<int, int>> choosePairs(int n) {
    std::vector<std::pair<int, int>> pairs;
    if (n <= 60) {
        for (int i = 0; i < n; ++i)
            for (int j = i + 1; j < n; ++j) pairs.emplace_back(i, j);
        return pairs;
    }
    // Large sets: neighbours in capture order (circular, because scans go
    // around the object) plus a sparse set of cross pairs to close loops.
    const int window = 12;
    int step = std::max(2, n / 24);
    std::vector<std::vector<char>> used(n, std::vector<char>(n, 0));
    auto add = [&](int a, int b) {
        if (a == b) return;
        if (a > b) std::swap(a, b);
        if (used[a][b]) return;
        used[a][b] = 1;
        pairs.emplace_back(a, b);
    };
    for (int i = 0; i < n; ++i) {
        for (int k = 1; k <= window; ++k) add(i, (i + k) % n);
        for (int j = i % step; j < n; j += step) add(i, j);
    }
    return pairs;
}

void matchFeatures(Reconstruction& rec, const Settings& s, Progress& p) {
    const int n = int(rec.views.size());
    auto pairs = choosePairs(n);
    p.log(fmt("matching: %d photo pairs", int(pairs.size())));

    // Group pairs by the "train" image so each index is used by one thread.
    std::vector<std::vector<int>> byTrain(n);
    for (int k = 0; k < int(pairs.size()); ++k) byTrain[pairs[k].second].push_back(k);

    std::vector<PairMatches> results(pairs.size());
    std::atomic<int> done{0};
    const int total = int(pairs.size());

    parallelFor(0, n, [&](int j) {
        if (byTrain[j].empty() || p.cancelRequested) return;
        const View& vj = rec.views[j];
        cv::flann::Index index(vj.desc, cv::flann::KDTreeIndexParams(4));
        for (int k : byTrain[j]) {
            if (p.cancelRequested) return;
            int i = pairs[k].first;
            const View& vi = rec.views[i];
            cv::Mat idx, dist;
            index.knnSearch(vi.desc, idx, dist, 2, cv::flann::SearchParams(48));
            // ratio test + keep best match per train keypoint
            std::unordered_map<int, std::pair<float, int>> bestForTrain;
            for (int r = 0; r < idx.rows; ++r) {
                float d0 = dist.at<float>(r, 0), d1 = dist.at<float>(r, 1);
                if (d0 < 0.64f * d1) {  // squared distances -> ratio 0.8
                    int t = idx.at<int>(r, 0);
                    auto it = bestForTrain.find(t);
                    if (it == bestForTrain.end() || d0 < it->second.first) bestForTrain[t] = {d0, r};
                }
            }
            PairMatches pm{i, j, {}};
            if (bestForTrain.size() >= 30) {
                std::vector<cv::Point2f> a, b;
                std::vector<cv::Vec2i> cand;
                for (auto& kv : bestForTrain) {
                    a.push_back(vi.kps[kv.second.second].pt);
                    b.push_back(vj.kps[kv.first].pt);
                    cand.emplace_back(kv.second.second, kv.first);
                }
                std::vector<uchar> mask;
                cv::Mat F = cv::findFundamentalMat(a, b, cv::FM_RANSAC, 1.5, 0.999, mask);
                if (!F.empty() && F.rows == 3) {
                    for (size_t q = 0; q < cand.size(); ++q)
                        if (mask[q]) pm.m.push_back(cand[q]);
                }
                if (pm.m.size() < 25) pm.m.clear();
            }
            results[k] = std::move(pm);
            int d = ++done;
            if ((d & 7) == 0) p.sub(float(d) / total);
        }
    }, s.threads);
    p.checkCancel();

    rec.pairs.clear();
    for (auto& r : results)
        if (!r.m.empty()) rec.pairs.push_back(std::move(r));
    p.log(fmt("matching: %d verified pairs", int(rec.pairs.size())));
    if (rec.pairs.empty()) throw std::runtime_error("The photos do not overlap enough to be matched.");
}

// ---------------------------------------------------------------------------
// Tracks (union-find over matched keypoints)
// ---------------------------------------------------------------------------
namespace {
struct DSU {
    std::vector<int> parent;
    explicit DSU(size_t n) : parent(n) { std::iota(parent.begin(), parent.end(), 0); }
    int find(int x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }
    void unite(int a, int b) {
        a = find(a);
        b = find(b);
        if (a != b) parent[b] = a;
    }
};
}  // namespace

void buildTracks(Reconstruction& rec) {
    const int n = int(rec.views.size());
    std::vector<int> offset(n + 1, 0);
    for (int i = 0; i < n; ++i) offset[i + 1] = offset[i] + int(rec.views[i].kps.size());
    DSU dsu(offset[n]);
    for (const auto& pm : rec.pairs)
        for (const auto& m : pm.m) dsu.unite(offset[pm.i] + m[0], offset[pm.j] + m[1]);

    std::unordered_map<int, int> rootToTrack;
    std::vector<Track> tracks;
    for (int i = 0; i < n; ++i)
        for (int k = 0; k < int(rec.views[i].kps.size()); ++k) {
            int g = offset[i] + k;
            int r = dsu.find(g);
            if (r == g && dsu.parent[g] == g) {
                // singleton roots are filtered below by observation count
            }
            auto it = rootToTrack.find(r);
            int tid;
            if (it == rootToTrack.end()) {
                tid = int(tracks.size());
                rootToTrack[r] = tid;
                tracks.emplace_back();
            } else {
                tid = it->second;
            }
            tracks[tid].obs.push_back({i, k});
        }

    // keep tracks with >= 2 observations and no duplicated photo
    rec.tracks.clear();
    for (auto& v : rec.views) v.kpTrack.assign(v.kps.size(), -1);
    for (auto& t : tracks) {
        if (t.obs.size() < 2) continue;
        bool dup = false;
        for (size_t a = 0; a < t.obs.size() && !dup; ++a)
            for (size_t b = a + 1; b < t.obs.size(); ++b)
                if (t.obs[a].view == t.obs[b].view) { dup = true; break; }
        if (dup) continue;
        int id = int(rec.tracks.size());
        for (auto& o : t.obs) rec.views[o.view].kpTrack[o.kp] = id;
        rec.tracks.push_back(std::move(t));
    }
}

}  // namespace sf
