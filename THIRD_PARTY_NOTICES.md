# Third-party notices

ScanForge Pro uses the following open source software. All of them allow commercial use.

| Component | Licence | Use |
|-----------|---------|-----|
| [OpenCV](https://opencv.org) 4.10 | Apache License 2.0 | Image decoding, SIFT features, geometry (essential matrix, PnP) |
| [Flutter](https://flutter.dev) | BSD 3-Clause | App framework |
| camera, path_provider, share_plus, sensors_plus, wakelock_plus | BSD 3-Clause | Flutter plugins |
| file_picker | MIT | Picking photos, saving exports |
| exif | MIT | Reading the 35 mm focal length |
| ffi | BSD 3-Clause | Calling the C++ engine |
| geolocator | MIT | Phone location for large scans (optional, off by default) |
| [ARCore SDK](https://github.com/google-ar/arcore-android-sdk) | Apache License 2.0 (uses Google Play Services for AR) | Live Scan tracking and depth |
| [MediaPipe Tasks](https://github.com/google-ai-edge/mediapipe) + Magic Touch model | Apache License 2.0 | AI object selection |
| Roboto font (test screenshots only) | Apache License 2.0 | Rendering screenshots |

The photogrammetry pipeline in `engine/` (matching, camera solving, bundle adjustment,
plane-sweep depth, TSDF fusion, marching tetrahedra, mesh simplification, STL/3MF writers)
is original ScanForge Pro code.

The Apache 2.0 licence text for OpenCV is available at https://www.apache.org/licenses/LICENSE-2.0
