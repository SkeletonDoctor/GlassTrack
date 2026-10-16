# GlassTrack

A native macOS (26+) Liquid Glass app that turns footage into a solved camera for Blender.
It runs COLMAP and FFmpeg in the background.

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

## Build
```bash
./scripts/build_app.sh     # → build/GlassTrack.app
```

## Headless / CLI
```bash
build/GlassTrack.app/Contents/MacOS/GlassTrack --cli shot.mp4 ~/Movies/GlassTrack balanced 2
```

Each project folder holds `images/`, `database.db`, `sparse/`, `sparse_txt/`, `track_meta.json` and `import_colmap_track.py`.
To re-import by hand, run: `blender --python import_colmap_track.py`.
