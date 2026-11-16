# GlassTrack

[![Latest release](https://img.shields.io/github/v/release/SkeletonDoctor/GlassTrack?label=release)](https://github.com/SkeletonDoctor/GlassTrack/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/SkeletonDoctor/GlassTrack/total)](https://github.com/SkeletonDoctor/GlassTrack/releases)
[![CI](https://github.com/SkeletonDoctor/GlassTrack/actions/workflows/ci.yml/badge.svg)](https://github.com/SkeletonDoctor/GlassTrack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/SkeletonDoctor/GlassTrack)](LICENSE)

A native macOS app that turns footage into a solved camera for Blender.
It runs [COLMAP](https://colmap.github.io) and FFmpeg in the background.

![A finished track: solved camera path and point cloud, solve-quality chart and exports](docs/screenshots/results.png)

## Download

Get the latest **[GlassTrack .dmg or .zip from Releases](https://github.com/SkeletonDoctor/GlassTrack/releases/latest)**.

**Requirements:** an Apple Silicon Mac (M1 or later) running macOS 26 Tahoe or newer.

You only download it once. From version 1.3 on, GlassTrack [updates itself](#updates) from this page.

### First launch
The app is not notarized by Apple, so macOS blocks it the first time you open it:
1. Drag **GlassTrack** into Applications, then open it. Dismiss the warning.
2. Go to **System Settings → Privacy & Security**. Scroll down and click **Open Anyway** next to GlassTrack.

Or, in Terminal:
```bash
xattr -dr com.apple.quarantine /Applications/GlassTrack.app
```

On first launch, GlassTrack checks for COLMAP, FFmpeg and Blender. It offers to install any that are missing through Homebrew. If you don't have Homebrew, it opens the official Homebrew installer in Terminal, which asks for your password once.

## Updates
GlassTrack checks this repository's [Releases](https://github.com/SkeletonDoctor/GlassTrack/releases) when it starts, and once a day while it stays open. When a newer version is out, an **Update available** pill appears in the sidebar. Click it to read the release notes, then **Install and Relaunch**. The app downloads the new version, swaps itself and reopens. A solve that was running picks up where it left off.

- **Check by hand:** GlassTrack menu → **Check for Updates…**
- **Turn the automatic check off:** Settings → General → Updates.
- **Skip a version:** the update window has a **Skip This Version** button.

Before installing, GlassTrack compares the download with the SHA-256 checksum GitHub lists for it, and checks that it is an intact copy of GlassTrack at the expected version. The app is not signed with an Apple developer certificate, so these checks rest on GitHub over HTTPS and not on a publisher signature.

Versions 1.2 and older don't have the updater. Download 1.3 or newer by hand once.

## What it does
1. **Extract frames.** Video is decoded with hardware acceleration (AVFoundation). Variable-frame-rate, HDR and rotated phone footage is put onto an exact constant-frame-rate timeline, in SDR and upright. You choose every Nth frame or a target FPS, with optional downscaling and a frame cap. You can also drop a folder of photos.
2. **Mask people (optional).** Apple's on-device person segmentation hides actors and passers-by from tracking.
3. **Detect and match features.** COLMAP SIFT, then sequential matching (for video) or exhaustive matching (for photos).
4. **Solve the camera.** COLMAP's incremental `mapper` or its global mapper (GLOMAP). If less than 90% of frames solve, GlassTrack retries once with relaxed settings and keeps the better result.
5. **Build the Blender scene.** Blender runs headless and writes `<name>_track.blend` with:
   - an animated camera on the plate's frame numbers, with matching focal length and lens shift,
   - a coloured point cloud,
   - the plate as the camera background, with lens distortion set on the movie clip,
   - the scene's fps, resolution and frame range,
   - the detected ground plane levelled at z = 0, with a shadow catcher. Give a camera height to get the scene in real metres.
6. **Export for other apps.** After Effects (`.jsx`), FBX, Alembic and Nuke (`.nk` + `.chan`) camera files are written next to the `.blend`.

The app shows live progress for each stage, an ETA, a console, an interactive 3D preview and a per-frame solve-quality chart. Overall progress also shows on the Dock icon, and a notification tells you when a solve finishes while you're in another app. Tracks are saved between launches, and a solve interrupted by quitting resumes where it left off.
On first launch, missing tools are installed: Homebrew, then `colmap`, `ffmpeg` and optionally `blender`.

## Screenshots

**Drop in footage and pick a quality.** The app reads the clip's resolution, frame rate and length, and estimates how many frames it will solve.

![New Camera Track screen with the quality presets and frame options](docs/screenshots/new-track.png)

**Advanced settings** cover the lens model, matching, solver, ground plane, real-world scale and masking people.

<p align="center"><img src="docs/screenshots/dropdown.png" width="720" alt="Advanced settings with the lens-model dropdown open"></p>

**Live progress** shows each pipeline stage with its own ring, timer and the current frame.

![A solve in progress](docs/screenshots/tracking.png)

**Check the solve and export it.** The Solve Quality card charts per-frame reprojection error, and the exports work in After Effects, Nuke, FBX apps and Alembic apps.

![Solve quality chart and export files](docs/screenshots/quality.png)

**First launch** checks for COLMAP, FFmpeg and Blender, and installs anything missing.

![Toolchain setup screen](docs/screenshots/setup.png)

## Build from source
You need Xcode 26 or newer.
```bash
./scripts/build_app.sh     # → build/GlassTrack.app (arm64)
```

## Releasing
Push a version tag. GitHub Actions builds the app, packages the `.zip` and `.dmg`, and publishes the release. Installed copies then offer the update.
```bash
git tag v1.3 && git push origin v1.3
```
To write the release notes yourself, create the release for the tag on GitHub first; the workflow then only attaches the files. The notes are what users see in the update window. To package locally instead, run `VERSION=1.3 ./scripts/package_release.sh`.

The updater installs the release asset whose name ends in `.zip`, and reads the version from the tag (`v1.3` → 1.3).

## Tests
```bash
./scripts/accuracy_test.sh   # solves tests/data/synthetic_dolly.mp4 and compares to ground truth
```
CI (GitHub Actions, macOS) builds the app and runs this test on every push.

## Headless / CLI
```bash
build/GlassTrack.app/Contents/MacOS/GlassTrack --cli shot.mp4 ~/Movies/GlassTrack balanced 2
build/GlassTrack.app/Contents/MacOS/GlassTrack --check-update     # print installed and latest version
build/GlassTrack.app/Contents/MacOS/GlassTrack --install-update   # update the app in place
```

Each project folder holds `images/`, `database.db`, `sparse/`, `sparse_txt/`, `track_meta.json` and `import_colmap_track.py`.
To re-import by hand, run: `blender --python import_colmap_track.py`.

## License
GlassTrack is MIT licensed. COLMAP, FFmpeg and Blender are separate projects under their own licenses. They are installed on your machine and are not bundled with this app.
