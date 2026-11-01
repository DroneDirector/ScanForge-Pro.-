// ScanForge Pro - desktop command line tool for testing the engine.
//
//   sf_cli <project_dir> <quality 0-3> <image> [image ...]
//
// Runs the reconstruction, exports scan.stl / scan.3mf and renders
// preview images (preview_color.png / preview_clay.png).
#include "scanforge.h"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

static void renderPng(sf_mesh* m, const std::string& path, int mode, float yaw, float pitch) {
    const int W = 800, H = 800;
    float* pos = nullptr;
    int32_t* col = nullptr;
    int n = sf_mesh_render(m, yaw, pitch, 1.0f, 0, 0, W, H, mode, &pos, &col);
    cv::Mat img(H, W, CV_8UC3, cv::Scalar(40, 36, 32));
    for (int t = 0; t < n; ++t) {
        cv::Point pts[3];
        int r = 0, g = 0, b = 0;
        for (int k = 0; k < 3; ++k) {
            pts[k] = cv::Point(int(pos[t * 6 + 2 * k] * 16), int(pos[t * 6 + 2 * k + 1] * 16));
            uint32_t c = uint32_t(col[t * 3 + k]);
            r += (c >> 16) & 255; g += (c >> 8) & 255; b += c & 255;
        }
        cv::fillConvexPoly(img, pts, 3, cv::Scalar(b / 3, g / 3, r / 3), cv::LINE_AA, 4);
    }
    cv::imwrite(path, img);
}

int main(int argc, char** argv) {
    if (argc < 4) {
        std::printf("usage: sf_cli <project_dir> <quality 0-3> <image> [image ...]\n");
        return 1;
    }
    std::string dir = argv[1];
    int quality = std::atoi(argv[2]);
    std::string list;
    for (int i = 3; i < argc; ++i) list += std::string(argv[i]) + "\n";

    auto t0 = std::chrono::steady_clock::now();
    sf_job* job = sf_job_start(dir.c_str(), list.c_str(), quality, 0.0, 0);
    char msg[512];
    std::string last;
    while (sf_job_state(job) == SF_STATE_RUNNING) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        sf_job_message(job, msg, sizeof(msg));
        std::string cur = std::string(msg) + " " + std::to_string(int(sf_job_progress(job) * 100)) + "%";
        if (cur != last) { std::printf("  %s\n", cur.c_str()); last = cur; }
    }
    int st = sf_job_state(job);
    sf_job_message(job, msg, sizeof(msg));
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("state %d (%s), %d photos solved, %.1f s\n", st, msg, sf_job_registered(job), secs);
    sf_job_free(job);
    if (st != SF_STATE_DONE) return 2;

    sf_mesh* m = sf_mesh_load((dir + "/mesh.ply").c_str());
    if (!m) { std::printf("cannot load mesh\n"); return 3; }
    float b[6];
    int tris = sf_mesh_info(m, b);
    std::printf("mesh: %d triangles, size %.1f x %.1f x %.1f mm, watertight %d\n", tris, b[3] - b[0],
                b[4] - b[1], b[5] - b[2], sf_mesh_is_watertight(m));
    std::printf("stl %d, 3mf %d\n", sf_mesh_export(m, (dir + "/scan.stl").c_str(), SF_FORMAT_STL, 1, 0, 0, "Scan"),
                sf_mesh_export(m, (dir + "/scan.3mf").c_str(), SF_FORMAT_3MF, 1, 256, 256, "Scan"));
    renderPng(m, dir + "/preview_color.png", SF_RENDER_COLOR, 30, 25);
    renderPng(m, dir + "/preview_clay.png", SF_RENDER_CLAY, 120, 25);
    sf_mesh_free(m);
    return 0;
}
