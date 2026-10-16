# GlassTrack

A native macOS Liquid Glass app that turns footage into a solved camera for Blender.
It runs [COLMAP](https://colmap.github.io) and FFmpeg in the background.

## Download

Get the latest **[GlassTrack .dmg or .zip from Releases](https://github.com/SkeletonDoctor/GlassTrack/releases/latest)**.

**Requirements:** an Apple Silicon Mac (M1 or later) running macOS 26 Tahoe or newer.

### First launch
The app is not notarized by Apple, so macOS blocks it the first time you open it:
1. Drag **GlassTrack** into Applications, then open it. Dismiss the warning.
2. Go to **System Settings → Privacy & Security**. Scroll down and click **Open Anyway** next to GlassTrack.

Or, in Terminal:
```bash
xattr -dr com.apple.quarantine /Applications/GlassTrack.app
```

On first launch, GlassTrack checks for COLMAP, FFmpeg and Blender. It offers to install any that are missing through Homebrew. If you don't have Homebrew, it opens the official Homebrew installer in Terminal, which asks for your password once.

## What it does
1. **Extract frames.** FFmpeg converts video into JPEGs (every Nth frame or a target FPS, with optional downscale and frame cap). You can also drop a folder of photos.
2. **Detect and match features.** COLMAP SIFT, then sequential matching (for video) or exhaustive matching (for photos).
3. **Solve the camera.** COLMAP's incremental `mapper` or its global mapper (GLOMAP). If COLMAP produces several partial models, the largest is used.
4. **Export.** You get a text model, solve stats (reprojection error, track length) and a Blender importer script.
5. **Build the Blender scene.** Blender runs headless and writes `<name>_track.blend` with:
   - an animated camera on the original frame numbers, with matching focal length and lens shift,
   - a coloured point cloud,
   - the plate as the camera background, with lens distortion set on the movie clip,
   - the scene's fps, resolution and frame range,
   - an up-aligned, auto-scaled `_Solve` parent empty that you can move or scale.

The app shows progress live for each stage, an overall ETA, a console and an interactive 3D preview of the solve.
Missing tools are installed on first launch: Homebrew, then `colmap`, `ffmpeg` and optionally `blender`.

## Build from source
You need Xcode 26 or newer.
```bash
./scripts/build_app.sh     # → build/GlassTrack.app (arm64)
```

## Headless / CLI
```bash
build/GlassTrack.app/Contents/MacOS/GlassTrack --cli shot.mp4 ~/Movies/GlassTrack balanced 2
```

Each project folder holds `images/`, `database.db`, `sparse/`, `sparse_txt/`, `track_meta.json` and `import_colmap_track.py`.
To re-import by hand, run: `blender --python import_colmap_track.py`.

## License
GlassTrack is MIT licensed. COLMAP, FFmpeg and Blender are separate projects under their own licenses. They are installed on your machine and are not bundled with this app.
