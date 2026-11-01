# ScanForge Pro

Turn photos into printable 3D models. Walk around an object with your phone, and ScanForge Pro
builds a closed (watertight) 3D model you can view, scale to real size and export as **STL** or
**3MF**, ready for Bambu Lab printers (A1, A1 mini, P1, P2S, X1, H2D, H2S; Bambu Studio / Bambu Handy).

| Platform | Status |
|----------|--------|
| Android (ARM64, Android 8+) | Alpha: capture, import, on-device 3D processing, viewer, export |
| Windows | Planned: same app, GPU processing, use the phone as camera |
| iPhone / iPad | Planned: same app, Apple Object Capture on LiDAR devices |

## Features
- **Guided capture**: a coverage ring shows which sides and heights you have photographed;
  optional auto-capture takes a photo each time you reach a new angle and hold still.
- **Import photos** from a camera or drone (JPEG/PNG).
- **On-device photogrammetry**: SIFT features, incremental camera solving with bundle adjustment
  (focal length and lens distortion refined automatically), multi-view depth maps, volume fusion
  and a watertight mesh. Quality presets: Fast, Normal, High, Ultra.
- **Automatic table removal**: the floor is detected and the model gets a flat base that sits on
  the print bed. The cut height can be adjusted afterwards.
- **3D viewer**: rotate, zoom, pan, colour or shape-only view.
- **Real size**: enter one real measurement in mm; the model scales to match.
- **Export**: STL, 3MF (millimetres, centred on the chosen Bambu Lab build plate), PLY and OBJ
  with colours. Save to the device or share to another app.

## Repository layout
```
engine/   C++ 3D engine (shared by Android, Windows and iOS), plain C interface
app/      Flutter app (Android now; Windows and iOS in the next batches)
tools/    helper scripts (icon)
docs/     release notes
```

## Building
The GitHub workflow builds everything: it compiles and tests the engine on Linux with a
synthetic scan, downloads the OpenCV Android SDK, and builds `ScanForgePro-ARM-<version>.apk`.
Pushing a `v*` tag publishes a GitHub release with the APK.

Local engine test:
```
cmake -S engine -B build -DSF_BUILD_TOOLS=ON && cmake --build build
python3 engine/tests/make_synthetic.py /tmp/syn 40
./build/sf_cli /tmp/proj 1 /tmp/syn/*.jpg
```

## Credits
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). All licences used allow commercial sale.

© 2026 Azurafiles. Contact: simon@dronedirector.fo
