// ScanForge Pro engine - settings, progress reporting and small helpers.
#include "sf_internal.h"

#include <opencv2/calib3d.hpp>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <thread>

namespace sf {

Settings Settings::preset(int quality) {
    Settings s;
    switch (quality) {
        case 0:  // Fast
            s.sfmMaxDim = 1200; s.maxFeatures = 3500; s.maxImages = 60;
            s.depthMaxDim = 320; s.maxDepthViews = 20; s.depthLevels = 64;
            s.volumeRes = 128; s.smoothIters = 4; s.targetFaces = 60000;
            break;
        case 2:  // High
            s.sfmMaxDim = 2000; s.maxFeatures = 7000; s.maxImages = 160;
            s.depthMaxDim = 640; s.maxDepthViews = 48; s.depthLevels = 128;
            s.volumeRes = 256; s.smoothIters = 4; s.targetFaces = 300000;
            break;
        case 3:  // Ultra (PC)
            s.sfmMaxDim = 2400; s.maxFeatures = 9000; s.maxImages = 250;
            s.depthMaxDim = 900; s.maxDepthViews = 72; s.depthLevels = 160;
            s.volumeRes = 360; s.smoothIters = 3; s.targetFaces = 600000;
            break;
        default:  // Normal
            break;
    }
    return s;
}

int Reconstruction::numRegistered() const {
    int n = 0;
    for (const auto& v : views) n += v.registered ? 1 : 0;
    return n;
}

void Mesh::bounds(cv::Vec3f& mn, cv::Vec3f& mx) const {
    mn = cv::Vec3f(1e30f, 1e30f, 1e30f);
    mx = cv::Vec3f(-1e30f, -1e30f, -1e30f);
    for (const auto& p : v)
        for (int k = 0; k < 3; ++k) {
            mn[k] = std::min(mn[k], p[k]);
            mx[k] = std::max(mx[k], p[k]);
        }
    if (v.empty()) mn = mx = cv::Vec3f(0, 0, 0);
}

// ---------------------------------------------------------------------------
// Stage weights for the overall progress bar
// ---------------------------------------------------------------------------
static const float kStageStart[] = {0.00f, 0.02f, 0.14f, 0.30f, 0.45f, 0.80f, 0.93f, 1.0f};

void Progress::set(int stg, float stageFrac, const std::string& msg) {
    stage = stg;
    sub(stageFrac);
    if (!msg.empty()) {
        message(msg);
        log(msg);
    }
}

void Progress::sub(float stageFrac) {
    int s = std::clamp(stage.load(), 0, 6);
    float a = kStageStart[s], b = kStageStart[s + 1];
    float v = a + (b - a) * std::clamp(stageFrac, 0.f, 1.f);
    if (v > fraction.load()) fraction = v;
}

void Progress::message(const std::string& msg) {
    std::lock_guard<std::mutex> lk(mtx_);
    msg_ = msg;
}

std::string Progress::message() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return msg_;
}

void Progress::setLogFile(const std::string& path) {
    std::lock_guard<std::mutex> lk(mtx_);
    logPath_ = path;
}

void Progress::log(const std::string& line) {
    std::string path;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        path = logPath_;
    }
    if (path.empty()) return;
    std::ofstream f(path, std::ios::app);
    std::time_t now = std::time(nullptr);
    char ts[32];
    std::strftime(ts, sizeof(ts), "%H:%M:%S", std::localtime(&now));
    f << ts << "  " << line << "\n";
}

void Progress::checkCancel() const {
    if (cancelRequested.load()) throw Cancelled();
}

// ---------------------------------------------------------------------------
int hardwareThreads() {
    unsigned n = std::thread::hardware_concurrency();
    return n == 0 ? 4 : int(n);
}

void parallelFor(int begin, int end, const std::function<void(int)>& fn, int threads) {
    if (end <= begin) return;
    int n = threads > 0 ? threads : hardwareThreads();
    n = std::min(n, end - begin);
    if (n <= 1) {
        for (int i = begin; i < end; ++i) fn(i);
        return;
    }
    std::atomic<int> next{begin};
    std::vector<std::thread> pool;
    pool.reserve(n);
    for (int t = 0; t < n; ++t)
        pool.emplace_back([&]() {
            for (;;) {
                int i = next.fetch_add(1);
                if (i >= end) break;
                fn(i);
            }
        });
    for (auto& th : pool) th.join();
}

std::string fmt(const char* f, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, f);
    std::vsnprintf(buf, sizeof(buf), f, ap);
    va_end(ap);
    return buf;
}

cv::Matx33d rodrigues(const cv::Vec3d& w) {
    cv::Matx33d R;
    cv::Rodrigues(w, R);
    return R;
}

}  // namespace sf
