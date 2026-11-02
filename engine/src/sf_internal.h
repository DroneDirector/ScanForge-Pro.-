// ScanForge Pro engine - internal types shared by the pipeline stages.
#pragma once

#include <opencv2/core.hpp>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace sf {

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
struct Settings {
    int sfmMaxDim = 1600;     // longest image side used for camera solving
    int maxFeatures = 5000;   // SIFT features per photo
    int maxImages = 120;      // photos used at most (evenly sampled)
    int depthMaxDim = 448;    // longest side of depth maps
    int maxDepthViews = 32;   // photos that get a depth map
    int depthLevels = 96;     // plane sweep depth steps
    int volumeRes = 176;      // voxels along the longest model side
    int smoothIters = 5;      // Taubin smoothing passes
    int targetFaces = 150000; // triangles in the final mesh
    double focal35 = 0.0;     // 35 mm equivalent focal length, 0 = unknown
    int threads = 0;          // 0 = hardware concurrency

    static Settings preset(int quality);
};

// ---------------------------------------------------------------------------
// Progress / cancellation
// ---------------------------------------------------------------------------
class Progress {
public:
    std::atomic<int> stage{0};
    std::atomic<float> fraction{0.f};   // overall 0..1
    std::atomic<bool> cancelRequested{false};
    std::atomic<int> registered{0};

    void set(int stg, float stageFrac, const std::string& msg = std::string());
    void sub(float stageFrac);          // progress inside the current stage
    void message(const std::string& msg);
    std::string message() const;
    void log(const std::string& line);
    void setLogFile(const std::string& path);
    void checkCancel() const;            // throws Cancelled
    // Pauses and asks the user whether to continue; true = continue.
    bool askToContinue(const std::string& question);
    void answer(bool proceed);
    std::atomic<bool> waitingForAnswer{false};
    std::atomic<bool> userAccepted{false};   // user already chose to continue once

private:
    mutable std::mutex mtx_;
    std::condition_variable cv_;
    int answer_ = -1;
    std::string msg_;
    std::string logPath_;
};

struct Cancelled {};

// ---------------------------------------------------------------------------
// Camera model: one shared pinhole camera with a single radial term.
// ---------------------------------------------------------------------------
struct Intrinsics {
    double f = 1000.0;
    double cx = 0.0, cy = 0.0;
    double k1 = 0.0;
};

struct View {
    std::string path;
    int width = 0, height = 0;          // SfM resolution
    std::vector<cv::KeyPoint> kps;
    cv::Mat desc;                        // RootSIFT, CV_32F
    std::vector<int> kpTrack;            // keypoint -> track id (-1 none)
    cv::Matx33d R = cv::Matx33d::eye(); // world -> camera rotation
    cv::Vec3d t = {0, 0, 0};             // world -> camera translation
    bool registered = false;
    int origW = 0, origH = 0;            // full photo size

    // Optional priors (Live Scan camera positions, GPS) and object mask
    bool hasPrior = false;
    cv::Matx33d priorR = cv::Matx33d::eye();
    cv::Vec3d priorT = {0, 0, 0};
    bool hasGps = false;
    cv::Vec3d gps = {0, 0, 0};           // latitude, longitude (deg), altitude (m)
    std::string maskPath;

    cv::Vec3d center() const { return -(R.t() * t); }
    cv::Vec3d axis() const { return cv::Vec3d(R(2, 0), R(2, 1), R(2, 2)); }
};

struct Observation {
    int view;
    int kp;
};

struct Track {
    std::vector<Observation> obs;
    cv::Vec3d X = {0, 0, 0};
    bool valid = false;
    cv::Vec3b color = {180, 180, 180};
};

struct PairMatches {
    int i, j;
    std::vector<cv::Vec2i> m;            // inlier keypoint index pairs
};

struct PriorIntrinsics {
    bool valid = false;
    double fx = 0, fy = 0, cx = 0, cy = 0;
    int width = 0, height = 0;           // photo size the intrinsics refer to
};

struct Reconstruction {
    std::vector<View> views;
    std::vector<Track> tracks;
    std::vector<PairMatches> pairs;
    Intrinsics K;
    PriorIntrinsics priorK;
    bool metric = false;                 // world units are metres
    bool upKnown = false;
    cv::Vec3d up = {0, 0, 1};
    int numRegistered() const;
    int numPriors() const;
    bool posed() const { return numPriors() * 2 >= int(views.size()) && numPriors() >= 3; }
};

// ---------------------------------------------------------------------------
// Meshes
// ---------------------------------------------------------------------------
struct Mesh {
    std::vector<cv::Vec3f> v;
    std::vector<cv::Vec3b> c;            // RGB per vertex
    std::vector<cv::Vec3i> f;

    void clear() { v.clear(); c.clear(); f.clear(); }
    void bounds(cv::Vec3f& mn, cv::Vec3f& mx) const;
};

// ---------------------------------------------------------------------------
// Pipeline stages
// ---------------------------------------------------------------------------
void parallelFor(int begin, int end, const std::function<void(int)>& fn, int threads = 0);
int  hardwareThreads();

// features.cpp
void detectFeatures(Reconstruction& rec, const Settings& s, Progress& p);
void matchFeatures(Reconstruction& rec, const Settings& s, Progress& p);
void buildTracks(Reconstruction& rec);

// priors.cpp
void loadPriors(Reconstruction& rec, const std::string& projectDir, Progress& p);
void applyPriorIntrinsics(Reconstruction& rec);
bool umeyama(const std::vector<cv::Vec3d>& src, const std::vector<cv::Vec3d>& dst, double& s,
             cv::Matx33d& R, cv::Vec3d& t);
void applySimilarity(Reconstruction& rec, double s, const cv::Matx33d& R, const cv::Vec3d& t);
void alignToPriors(Reconstruction& rec, Progress& p);
void alignToGps(Reconstruction& rec, Progress& p);

// sfm.cpp
bool runSfM(Reconstruction& rec, const Settings& s, Progress& p);
bool runPosedSfM(Reconstruction& rec, const Settings& s, Progress& p);
bool projectPoint(const Intrinsics& K, const View& v, const cv::Vec3d& X, cv::Vec2d& uv);

// ba.cpp
struct BAOptions {
    int maxIterations = 20;
    double huber = 2.0;
    bool refineIntrinsics = true;   // focal length
    bool refineDistortion = false;  // radial k1
    int fixedView = -1;   // view index whose pose is held fixed
};
double bundleAdjust(Reconstruction& rec, const BAOptions& opt);

// dense.cpp
struct DepthMap {
    int view = -1;
    cv::Mat depth;        // CV_32F, 0 = invalid
    cv::Mat color;        // CV_8UC3 BGR, same size
    cv::Mat mask;         // CV_8U, 255 = object (empty if no mask)
    cv::Matx33d K;        // intrinsics at depth resolution (undistorted)
};
void computeDepthMaps(const Reconstruction& rec, const Settings& s, Progress& p,
                      std::vector<DepthMap>& out);

// fusion.cpp
struct Volume {
    int nx = 0, ny = 0, nz = 0;
    float voxel = 1.f;            // model units
    cv::Vec3d origin;             // world position of voxel (0,0,0) in model frame
    cv::Matx33d M;                // world -> model frame rotation (rows: x,y,z axes)
    cv::Vec3d center;             // model frame origin in world
    std::vector<float> tsdf;
    std::vector<float> weight;
    std::vector<cv::Vec3b> color; // RGB
    std::vector<uint16_t> colorW;
    float floorZ = -1e30f;        // model z below which space is empty
    float autoFloorZ = -1e30f;
    double mmPerUnit = 1.0;
    int targetFaces = 150000;
    int smoothIters = 5;
    bool metric = false;           // model units are metres
    float observed = 1.f;          // share of the volume seen by the photos
    cv::Vec3d shiftUnits;         // subtracted before scaling to mm
    size_t idx(int x, int y, int z) const { return (size_t(z) * ny + y) * nx + x; }
};
void fuseDepthMaps(const Reconstruction& rec, const std::vector<DepthMap>& maps,
                   const Settings& s, Progress& p, Volume& vol);
void extractSurface(const Volume& vol, Mesh& mesh);
float measuredSurfaceFraction(const Volume& vol, const Mesh& mesh, bool silhouettes);
void colorizeFromPhotos(const Volume& vol, const Reconstruction& rec, const std::vector<DepthMap>& maps, Mesh& mesh);
bool saveVolume(const std::string& path, const Volume& vol);
bool loadVolume(const std::string& path, Volume& vol);

// mesh.cpp
void keepMainComponents(Mesh& m, float minFraction);
void taubinSmooth(Mesh& m, int iterations);
void featureSmooth(Mesh& m, int normalIters, int vertexIters);
void removeUnusedVertices(Mesh& m);
void simplifyMesh(Mesh& m, int targetFaces);
bool isWatertight(const Mesh& m);
bool savePLY(const std::string& path, const Mesh& m);
bool loadPLY(const std::string& path, Mesh& m);
bool savePointsPLY(const std::string& path, const std::vector<cv::Vec3f>& pts,
                   const std::vector<cv::Vec3b>& cols);
void finalizeToMillimetres(Mesh& m, Volume& vol, bool firstTime);
void decimateForDisplay(const Mesh& in, Mesh& out, int maxFaces);

// export.cpp
bool exportSTL(const std::string& path, const Mesh& m, float scale, const std::string& name);
bool export3MF(const std::string& path, const Mesh& m, float scale, float bedX, float bedY,
               const std::string& name);
bool exportOBJ(const std::string& path, const Mesh& m, float scale);
bool exportPLY(const std::string& path, const Mesh& m, float scale);

// Helpers
std::string fmt(const char* f, ...);
cv::Matx33d rodrigues(const cv::Vec3d& w);

}  // namespace sf
