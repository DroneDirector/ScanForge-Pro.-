# Changelog

## 1.0.6 (alpha), 2026-11-01
- The photo check no longer blocks building. When too few overlapping photos are detected
  (before building, after placing the photos, or when the surface is checked), the app warns
  and asks "Do you still want to proceed?" with Proceed / Stop.
- Only fewer than 3 photos still stops a build (a model needs at least 3).

## 1.0.5 (alpha), 2026-11-01
- Scan check: when there are not enough usable photos, the build stops with a clear
  "Not enough photos" message instead of producing a box-shaped model. The app checks how
  many photos could be placed and how much of the object's surface was actually measured.
- Warning before building a scan with fewer than 20 photos (Take more photos / Build anyway).
- "Take more photos" button on the error message.

## 1.0.4 (alpha), 2026-11-01
- Settings → Updates: new "Latest updates" drop-down with the 3 newest versions and what
  each one changed. The newest is marked "Latest" and the installed one "Installed"; an
  "Update to …" button appears when the latest is newer than the installed version.
- Update downloads can now be cancelled.

## 1.0.3 (alpha), 2026-11-01
- Added Bambu Lab P2S (256 × 256 × 256 mm) and H2S (340 × 320 × 340 mm) to the printer list
  for export, bed-fit check and 3MF placement.

## 1.0.2 (alpha), 2026-11-01
- In-app updates: the app checks for a new version when it starts (can be turned off),
  shows what's new, downloads it with a progress bar and opens the Android installer.
  Scans and settings are kept.
- New Settings screen: automatic update check, "Check now", skipped version, default
  quality and default printer for new scans. Settings are saved on the device and survive updates.

## 1.0.1 (alpha), 2026-11-01
- New animated start screen: a point cloud gathers into the ScanForge cube, a scan line
  reveals it and the scan rings spin up, with a glowing progress bar while the app loads.
- Start-up background now matches the app (no black flash).

## 1.0.0 (alpha), 2026-11-01
- First Android alpha.
- Guided capture with coverage ring and auto-capture.
- Photo import (JPEG/PNG).
- On-device 3D reconstruction with Fast / Normal / High / Ultra quality.
- Automatic floor detection and flat base; adjustable afterwards.
- 3D viewer with colour and shape-only modes.
- Real-size scaling in millimetres.
- Export to STL, 3MF (Bambu Lab build plates), PLY and OBJ.
