# Changelog

## 1.1.4 (alpha), 2026-11-02
- Live Scan waits for you: photos are only taken after you have tapped the object and its
  hologram dots are showing. No automatic picking of the object.
- The dots appear right after tapping (shaped from the AI outline), so you can see the object
  was recognised before scanning starts.
- New "AI guess" switch on the Live Scan screen (clearly shown ON or OFF, remembered): with it on,
  tapping lets the AI guess the object's whole shape; off uses depth only. After selecting, a
  badge shows which was used ("AI guess" or "Depth only").

## 1.1.3 (alpha), 2026-11-02
- Live Scan takes photos much more reliably: a photo every few centimetres or degrees you move
  (smaller steps for small objects), skipped only when the picture is actually blurry. The old
  rules (steadiness, framing and size estimates all at once) blocked too many photos.
- Photos start right away, even before the object is tapped; if nothing is tapped the object
  in the middle of the screen is picked automatically after a moment.
- When photos are not being taken the hint says why (moving too fast, blurry, object out of view).
- Live Scan diagnostics are added to the scan's log (log button on the scan page).

## 1.1.2 (alpha), 2026-11-02
- Live Scan fixes after the first real test (computer mouse):
  - Tapping the object selects only the object: the table height is measured and the object
    region is kept tight, so the table and things behind it are no longer included.
  - The hologram only shows the object: depth is added at each saved photo, inside the
    object's AI outline, instead of every frame (which added table noise).
  - The captured percentage never goes down while you scan.
  - Dots turn green more readily where photos have covered them.
  - The hologram stays visible when tracking is briefly lost and stays anchored to the object
    when you look away and come back.
  - Photos are taken more easily (less strict about steadiness and framing).
  - "Point the camera at the object" only shows when the object is really out of view.
  - Detail % is shown once enough is captured.

## 1.1.1 (alpha), 2026-11-02
- Small objects: the 3D engine now zooms in on the object in every photo when measuring depth,
  so small objects keep their detail (blobs before, clear shapes now).
- Live Scan: small objects can be selected even when the phone's depth sensing can't see them
  (sized from the AI outline); the AI outlines of the saved photos shape the hologram, so small
  objects light up too; photos are taken from as close as 10 cm, with distance hints.
- Scan with camera: tap the object to focus on it (focus ring).
- Cleaner flat base: table leftovers around the bottom are removed.

## 1.1.0 (alpha), 2026-11-02
- **Live Scan (ARCore)**: move around the object; sharp photos are picked automatically at each
  new angle, together with the exact camera position. Models get their real size in millimetres.
- **AR hologram**: the measured surface of the object glows over the camera view (green =
  captured, yellow = one photo, red = still needed), with angle rings around the object and a
  sweeping scan ring. "Captured" and "Detail" percentages and hints on where to go next.
- **AI object selection**: tap the object; an on-device AI (MediaPipe) outlines it. Every photo
  gets an object outline, so the table and background are removed and plain or dark objects
  (that photos alone cannot measure) can now be scanned.
- **GPS for large scans** (Settings, off by default): uses GPS data in imported photos (e.g.
  drones) and the phone's location when taking photos to give real size and north-up.
- Engine: starts from Live Scan camera positions, silhouette carving with object outlines,
  colours taken from the photos, GPS alignment.
- Fixed wrapped "Normal" label in the quality selector.

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
