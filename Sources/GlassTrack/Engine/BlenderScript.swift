import Foundation

/// Python script that turns a COLMAP text model into an animated Blender camera,
/// a coloured point cloud and a background plate. Written next to every solve so it
/// can also be run by hand:  blender --python import_colmap_track.py -- --meta track_meta.json
enum BlenderScript {
    static let fileName = "import_colmap_track.py"

    static let source = #"""
# GlassTrack — COLMAP → Blender camera track importer
import bpy, json, os, sys, math, statistics
from mathutils import Matrix, Vector, Quaternion


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    args = {"meta": os.path.join(here, "track_meta.json"), "out": None}
    i = 0
    while i < len(argv):
        if argv[i] in ("--meta", "--out") and i + 1 < len(argv):
            args[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    return args


def data_lines(path):
    with open(path, "r") as f:
        return [l.rstrip("\n") for l in f if not l.startswith("#")]


def read_cameras(path):
    cams = {}
    for line in data_lines(path):
        p = line.split()
        if len(p) < 5:
            continue
        cams[int(p[0])] = (p[1], int(p[2]), int(p[3]), [float(x) for x in p[4:]])
    return cams


def read_images(path):
    lines = data_lines(path)
    images = []
    i = 0
    while i < len(lines):
        p = lines[i].split()
        if len(p) >= 10:
            q = Quaternion((float(p[1]), float(p[2]), float(p[3]), float(p[4])))
            t = Vector((float(p[5]), float(p[6]), float(p[7])))
            images.append({"id": int(p[0]), "q": q, "t": t, "camera": int(p[8]), "name": " ".join(p[9:])})
            i += 2  # second line holds the 2D points (may be empty)
        else:
            i += 1
    return images


def read_points(path, limit):
    pts = []
    for line in data_lines(path):
        p = line.split()
        if len(p) < 7:
            continue
        pts.append(((float(p[1]), float(p[2]), float(p[3])), (int(p[4]) / 255.0, int(p[5]) / 255.0, int(p[6]) / 255.0)))
    if limit and len(pts) > limit:
        step = len(pts) / float(limit)
        pts = [pts[int(i * step)] for i in range(limit)]
    return pts


def intrinsics(model, w, h, params):
    if model in ("SIMPLE_PINHOLE", "SIMPLE_RADIAL", "RADIAL", "SIMPLE_RADIAL_FISHEYE", "RADIAL_FISHEYE"):
        f = params[0]; cx, cy = params[1], params[2]; extra = params[3:]
    else:
        f = params[0]; cx, cy = params[2], params[3]; extra = params[4:]
    return f, cx, cy, extra


def set_interp_linear():
    try:
        bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    except Exception:
        pass


def point_material():
    mat = bpy.data.materials.get("COLMAP_PointColor") or bpy.data.materials.new("COLMAP_PointColor")
    try:
        if not mat.node_tree:
            mat.use_nodes = True
    except Exception:
        pass
    nt = mat.node_tree
    nt.nodes.clear()
    attr = nt.nodes.new("ShaderNodeAttribute"); attr.attribute_name = "Col"
    emit = nt.nodes.new("ShaderNodeEmission")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(attr.outputs["Color"], emit.inputs["Color"])
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def points_node_group(radius, material):
    ng = bpy.data.node_groups.new("COLMAP_Points", "GeometryNodeTree")
    ng.interface.new_socket(name="Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket(name="Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    gin = ng.nodes.new("NodeGroupInput")
    gout = ng.nodes.new("NodeGroupOutput")
    m2p = ng.nodes.new("GeometryNodeMeshToPoints")
    m2p.inputs["Radius"].default_value = radius
    setm = ng.nodes.new("GeometryNodeSetMaterial")
    setm.inputs["Material"].default_value = material
    ng.links.new(gin.outputs[0], m2p.inputs["Mesh"])
    ng.links.new(m2p.outputs["Points"], setm.inputs["Geometry"])
    ng.links.new(setm.outputs["Geometry"], gout.inputs[0])
    return ng


def find_ground(pts, cams, up, typical, iterations=3000):
    """RANSAC for the floor: a plane within 35 degrees of level, below every camera, with
    (almost) no points beneath it, i.e. the floor rather than a table, box top or a slice
    through the middle of the scene. Returns (normal, offset, inlier fraction), normal
    pointing towards the cameras, or None."""
    import numpy as np
    rng = np.random.default_rng(1)
    P = np.asarray(pts, dtype=np.float64)
    if len(P) < 50:
        return None
    if len(P) > 30000:
        P = P[rng.choice(len(P), 30000, replace=False)]
    C = np.asarray([tuple(c) for c in cams], dtype=np.float64)
    C = C[:: max(1, len(C) // 60)]
    u = np.asarray(tuple(up))
    tol = typical * 0.01
    cos_max = math.cos(math.radians(35))
    best = None
    for _ in range(iterations):
        a, b, c = P[rng.choice(len(P), 3, replace=False)]
        n = np.cross(b - a, c - a)
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            continue
        n /= ln
        if n @ u < 0:
            n = -n
        if n @ u < cos_max:
            continue
        d = n @ a
        if (C @ n - d).min() <= 0:
            continue
        h = P @ n - d
        below = np.count_nonzero(h < -tol)
        if below > len(P) * 0.03:
            continue
        count = np.count_nonzero(np.abs(h) < tol)
        if best is None or count > best[2]:
            best = (n, d, count)
    if best is None or best[2] < len(P) * 0.03:
        return None
    # Refine: least-squares plane through the inliers.
    n, d, _ = best
    inl = P[np.abs(P @ n - d) < tol]
    centroid = inl.mean(axis=0)
    w, v = np.linalg.eigh(np.cov((inl - centroid).T))
    n2 = v[:, 0]
    if n2 @ n < 0:
        n2 = -n2
    nv = Vector(n2.tolist()).normalized()
    return nv, nv.dot(Vector(centroid.tolist())), len(inl) / len(P)


def main():
    args = parse_args()
    meta_path = os.path.abspath(args["meta"])
    root = os.path.dirname(meta_path)
    with open(meta_path) as f:
        meta = json.load(f)

    model_dir = os.path.join(root, meta["model"])
    cams = read_cameras(os.path.join(model_dir, "cameras.txt"))
    images = read_images(os.path.join(model_dir, "images.txt"))
    points = read_points(os.path.join(model_dir, "points3D.txt"), meta.get("maxPoints", 300000))
    frame_map = meta.get("frames", {})

    def frame_of(name):
        base = os.path.basename(name)
        if base in frame_map:
            return int(frame_map[base])
        digits = "".join(c for c in os.path.splitext(base)[0] if c.isdigit())
        return int(digits) if digits else 1

    images.sort(key=lambda im: frame_of(im["name"]))
    if not images:
        raise RuntimeError("Model has no registered images")

    scene = bpy.context.scene
    name = meta.get("name", "COLMAP")
    if args["out"]:
        # Start from an empty scene when building a fresh .blend
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)

    # --- Alignment: make the average camera "up" point to +Z, centre on the cloud ----------
    poses = []
    for im in images:
        R = im["q"].to_matrix()            # world -> camera
        Rc = R.transposed()                # camera -> world
        C = -(Rc @ im["t"])
        poses.append((im, Rc, C))

    up = Vector((0, 0, 0))
    for _, Rc, _ in poses:
        up += Rc @ Vector((0, -1, 0))
    up = up.normalized() if up.length > 1e-9 else Vector((0, 0, 1))

    cam_mean_raw = sum((C for _, _, C in poses), Vector()) / len(poses)
    if points:
        typical = statistics.median((Vector(p) - cam_mean_raw).length for p, _ in points) or 1.0
    else:
        typical = 1.0

    # Ground plane: the dominant, roughly level plane below the cameras (RANSAC on the cloud).
    ground = None
    if points and meta.get("detectGround", True):
        ground = find_ground([p for p, _ in points], [C for _, _, C in poses], up, typical)
    if ground:
        n, d, inliers = ground        # plane: n·x = d, n points from the ground towards the cameras
        up = n
        print("GlassTrack: ground plane found (%d%% of points)" % round(100 * inliers))

    A = up.rotation_difference(Vector((0, 0, 1))).to_matrix()
    fwd = A @ (poses[0][1] @ Vector((0, 0, 1)))
    yaw = math.atan2(fwd.x, fwd.y)  # rotate so the first camera looks down +Y
    A = Matrix.Rotation(yaw, 3, "Z") @ A

    if points:
        pts_al = [A @ Vector(p) for p, _ in points]
        cx = statistics.median(v.x for v in pts_al)
        cy = statistics.median(v.y for v in pts_al)
        if ground:
            cz = ground[1]            # A maps n to +Z, so the plane sits at height d
        else:
            zs = sorted(v.z for v in pts_al)
            cz = zs[int(len(zs) * 0.05)]
        centre = Vector((cx, cy, cz))
    else:
        centre = Vector((0, 0, 0))

    # Scale: real-world camera height if given (needs a ground plane), else a tidy scene size.
    cam_height = float(meta.get("cameraHeight", 0) or 0)
    heights = [(A @ C).z - centre.z for _, _, C in poses]
    if ground and cam_height > 0 and statistics.median(heights) > 1e-9:
        scale = cam_height / statistics.median(heights)
        print("GlassTrack: scaled to camera height %.2f m" % cam_height)
    else:
        scale = float(meta.get("targetSceneSize", 8.0)) / typical

    root_obj = bpy.data.objects.new(name + "_Solve", None)
    root_obj.empty_display_type = "ARROWS"
    root_obj.empty_display_size = 0.5
    scene.collection.objects.link(root_obj)
    root_obj.matrix_world = Matrix.Diagonal((scale, scale, scale, 1.0)) @ Matrix.Translation(-centre) @ A.to_4x4()

    # --- Camera -------------------------------------------------------------------------
    first_cam = cams[images[0]["camera"]]
    model, cw, ch, params = first_cam
    f, cx0, cy0, extra = intrinsics(model, cw, ch, params)
    src_w = int(meta.get("sourceWidth") or cw)
    src_h = int(meta.get("sourceHeight") or ch)
    big = float(max(cw, ch))

    cam_data = bpy.data.cameras.new(name + "_Camera")
    cam_data.sensor_fit = "AUTO"
    cam_data.sensor_width = 36.0
    cam_data.lens = f * 36.0 / big
    cam_data.shift_x = -(cx0 - cw / 2.0) / big
    cam_data.shift_y = (cy0 - ch / 2.0) / big
    cam_data.clip_start = 0.01
    cam_data.clip_end = 10000
    cam_obj = bpy.data.objects.new(name + "_Camera", cam_data)
    scene.collection.objects.link(cam_obj)
    cam_obj.parent = root_obj
    cam_obj.matrix_parent_inverse = Matrix.Identity(4)
    cam_obj.rotation_mode = "XYZ"
    scene.camera = cam_obj

    set_interp_linear()
    flip = Matrix.Diagonal((1.0, -1.0, -1.0))
    prev = None
    varying = len({im["camera"] for im in images}) > 1
    for im, Rc, C in poses:
        fr = frame_of(im["name"])
        rot = Rc @ flip
        eul = rot.to_euler("XYZ", prev) if prev else rot.to_euler("XYZ")
        prev = eul
        cam_obj.location = C
        cam_obj.rotation_euler = eul
        cam_obj.keyframe_insert("location", frame=fr)
        cam_obj.keyframe_insert("rotation_euler", frame=fr)
        if varying:
            m2, w2, h2, p2 = cams[im["camera"]]
            f2 = intrinsics(m2, w2, h2, p2)[0]
            cam_data.lens = f2 * 36.0 / float(max(w2, h2))
            cam_data.keyframe_insert("lens", frame=fr)

    frames = [frame_of(im["name"]) for im in images]
    total = int(meta.get("frameCount") or max(frames))
    scene.frame_start = 1
    scene.frame_end = max(total, max(frames))
    scene.render.resolution_x = src_w if not meta.get("undistorted") else int(round(cw * src_w / float(meta.get("extractWidth") or cw)))
    scene.render.resolution_y = src_h if not meta.get("undistorted") else int(round(ch * src_h / float(meta.get("extractHeight") or ch)))
    scene.render.resolution_percentage = 100
    fps = float(meta.get("fps") or 24.0)
    scene.render.fps = max(1, int(round(fps)))
    scene.render.fps_base = scene.render.fps / fps

    # --- Point cloud --------------------------------------------------------------------
    if points:
        me = bpy.data.meshes.new(name + "_Points")
        me.from_pydata([p for p, _ in points], [], [])
        col = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
        flat = []
        for _, c in points:
            flat.extend((c[0], c[1], c[2], 1.0))
        col.data.foreach_set("color", flat)
        pc = bpy.data.objects.new(name + "_PointCloud", me)
        scene.collection.objects.link(pc)
        pc.parent = root_obj
        pc.matrix_parent_inverse = Matrix.Identity(4)
        mod = pc.modifiers.new("Points", "NODES")
        mod.node_group = points_node_group(0.0025 * typical, point_material())

    # --- Ground / shadow catcher ---------------------------------------------------------
    if ground:
        xs = [(A @ Vector(p)).x - centre.x for p, _ in points]
        ys = [(A @ Vector(p)).y - centre.y for p, _ in points]
        xs.sort(); ys.sort()
        lo, hi = int(len(xs) * 0.05), int(len(xs) * 0.95) - 1
        size = max(xs[hi] - xs[lo], ys[hi] - ys[lo]) * scale * 1.5 or 10.0
        bpy.ops.mesh.primitive_plane_add(size=size, location=((xs[lo] + xs[hi]) / 2 * scale, (ys[lo] + ys[hi]) / 2 * scale, 0))
        g = bpy.context.object
        g.name = name + "_Ground"
        g.display_type = "WIRE"
        g.hide_render = False
        try:
            g.is_shadow_catcher = True
        except Exception:
            pass

    # --- Background plate ---------------------------------------------------------------
    plate = meta.get("plate")
    if plate:
        plate_path = plate if os.path.isabs(plate) else os.path.join(root, plate)
        try:
            clip = bpy.data.movieclips.load(plate_path)
            clip.frame_start = 1
            scene.active_clip = clip
            tc = clip.tracking.camera
            tc.sensor_width = 36.0
            tc.focal_length = cam_data.lens
            try:
                tc.principal_point = (cx0 / cw * 2 - 1, cy0 / ch * 2 - 1)
            except Exception:
                pass
            if model in ("SIMPLE_RADIAL", "RADIAL") and not meta.get("undistorted"):
                tc.distortion_model = "POLYNOMIAL"
                tc.k1 = extra[0] if len(extra) > 0 else 0.0
                tc.k2 = extra[1] if len(extra) > 1 else 0.0
            elif model in ("OPENCV", "FULL_OPENCV") and not meta.get("undistorted"):
                tc.distortion_model = "BROWN"
                tc.brown_k1, tc.brown_k2 = extra[0], extra[1]
                tc.brown_p1, tc.brown_p2 = extra[2], extra[3]
            cam_data.show_background_images = True
            bg = cam_data.background_images.new()
            bg.source = "MOVIE_CLIP"
            bg.clip = clip
            bg.alpha = 1.0
        except Exception as e:
            print("GlassTrack: could not load plate:", e)

    # Look through the solved camera in any open 3D view.
    for area in getattr(bpy.context.screen, "areas", []) or []:
        if area.type == "VIEW_3D":
            area.spaces[0].region_3d.view_perspective = "CAMERA"

    scene.frame_set(frames[0])
    print("GlassTrack: imported %d cameras, %d points" % (len(images), len(points)))

    if meta.get("exports", True) and args["out"]:
        try:
            export_all(scene, cam_obj, pc if points else None, name, os.path.join(root, "exports"))
        except Exception as e:
            print("GlassTrack: export failed:", e)
        scene.frame_set(frames[0])

    if args["out"]:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args["out"]))
        print("GlassTrack: saved", args["out"])


# --- Exports for other applications -------------------------------------------------------

def world_samples(scene, cam_obj):
    """(frame, world matrix, lens) for every frame of the scene."""
    out = []
    for f in range(scene.frame_start, scene.frame_end + 1):
        scene.frame_set(f)
        out.append((f, cam_obj.matrix_world.copy(), cam_obj.data.lens))
    return out


def export_all(scene, cam_obj, cloud, name, folder):
    os.makedirs(folder, exist_ok=True)
    samples = world_samples(scene, cam_obj)
    w, h = scene.render.resolution_x, scene.render.resolution_y
    fps = scene.render.fps / scene.render.fps_base

    # A world-space copy of the camera (no parent), baked on every frame, for FBX / Alembic.
    baked = bpy.data.objects.new(name + "_Camera", cam_obj.data)
    scene.collection.objects.link(baked)
    baked.rotation_mode = "XYZ"
    prev = None
    for f, m, lens in samples:
        loc, rot, _ = m.decompose()
        eul = rot.to_euler("XYZ", prev) if prev else rot.to_euler("XYZ")
        prev = eul
        baked.location = loc
        baked.rotation_euler = eul
        baked.keyframe_insert("location", frame=f)
        baked.keyframe_insert("rotation_euler", frame=f)

    def select_only(objs):
        bpy.ops.object.select_all(action="DESELECT")
        for o in objs:
            o.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]

    try:
        select_only([baked])
        bpy.ops.export_scene.fbx(filepath=os.path.join(folder, name + "_camera.fbx"), use_selection=True,
                                 object_types={"CAMERA"}, bake_anim=True, bake_anim_use_all_actions=False,
                                 bake_anim_use_nla_strips=False, bake_anim_force_startend_keying=True,
                                 bake_anim_step=1.0, bake_anim_simplify_factor=0.0,
                                 add_leaf_bones=False)
        print("GlassTrack: exported FBX")
    except Exception as e:
        print("GlassTrack: FBX export failed:", e)
    try:
        select_only([baked] + ([cloud] if cloud else []))
        bpy.ops.wm.alembic_export(filepath=os.path.join(folder, name + "_camera.abc"), selected=True,
                                  start=scene.frame_start, end=scene.frame_end)
        print("GlassTrack: exported Alembic")
    except Exception as e:
        print("GlassTrack: Alembic export failed:", e)
    bpy.data.objects.remove(baked, do_unlink=True)

    write_nuke(samples, cam_obj.data, w, h, name, folder)
    write_after_effects(samples, cam_obj.data, w, h, fps, scene, name, folder)
    print("GlassTrack: exported Nuke and After Effects")


def write_nuke(samples, cam_data, w, h, name, folder):
    # Nuke is Y-up: Blender (x, y, z) -> Nuke (x, z, -y). Camera axes match (looks down -Z, +Y up).
    to_nuke = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0)))
    rows = []
    for f, m, lens in samples:
        loc = to_nuke @ m.to_translation()
        rot = (to_nuke @ m.to_3x3().normalized()).to_euler("ZXY")   # Nuke's default rot_order ZXY
        rows.append((f, loc, [math.degrees(a) for a in rot], lens))
    with open(os.path.join(folder, name + "_camera.chan"), "w") as fh:
        for f, loc, r, lens in rows:
            fh.write("%d %.6f %.6f %.6f %.6f %.6f %.6f\n" % (f, loc.x, loc.y, loc.z, r[0], r[1], r[2]))

    big = float(max(w, h))
    hap = cam_data.sensor_width * w / big
    vap = cam_data.sensor_width * h / big
    def curve(values):
        return "{curve x%d %s}" % (rows[0][0], " ".join("%.6f" % v for v in values))
    with open(os.path.join(folder, name + "_camera.nk"), "w") as fh:
        fh.write("Camera3 {\n")
        fh.write(" rot_order ZXY\n")
        fh.write(" translate {%s %s %s}\n" % (curve([r[1].x for r in rows]), curve([r[1].y for r in rows]),
                                              curve([r[1].z for r in rows])))
        fh.write(" rotate {%s %s %s}\n" % (curve([r[2][0] for r in rows]), curve([r[2][1] for r in rows]),
                                           curve([r[2][2] for r in rows])))
        lenses = [r[3] for r in rows]
        fh.write(" focal %s\n" % (("{%s}" % curve(lenses)) if max(lenses) - min(lenses) > 1e-4 else "%.6f" % lenses[0]))
        fh.write(" haperture %.6f\n vaperture %.6f\n" % (hap, vap))
        fh.write(" name %s_Camera\n}\n" % name.replace(" ", "_"))


def write_after_effects(samples, cam_data, w, h, fps, scene, name, folder):
    # Same conventions as Blender's long-standing After Effects exporter: 100 px per unit,
    # AE X = X, AE Y = -Z, AE Z = Y; orientation from a ZYX euler with the camera's X corrected by -90.
    ae_size = 100.0
    big = float(max(w, h))
    times, pos, ori, zoom = [], [], [], []
    for f, m, lens in samples:
        loc = m.to_translation()
        r = m.to_euler("ZYX")
        times.append("%.6f" % ((f - scene.frame_start) / fps))
        pos.append("[%.4f,%.4f,%.4f]" % (loc.x * ae_size + w / 2.0, -loc.z * ae_size + h / 2.0, loc.y * ae_size))
        ori.append("[%.4f,%.4f,%.4f]" % (math.degrees(r.x) - 90.0, -math.degrees(r.y), -math.degrees(r.z)))
        # zoom (px) = lens * dimension / sensor, measured along the larger side (sensor_fit AUTO)
        zoom.append("%.4f" % (lens * (w if w >= h else h) / cam_data.sensor_width))
    duration = (scene.frame_end - scene.frame_start + 1) / fps
    plate = ""
    clip = scene.active_clip
    if clip:
        plate = bpy.path.abspath(clip.filepath).replace("\\", "/")
    js = []
    js.append("// GlassTrack camera for After Effects. File > Scripts > Run Script File…")
    js.append("(function () {")
    js.append("app.beginUndoGroup('GlassTrack camera');")
    js.append("var comp = app.project.items.addComp(%s, %d, %d, 1, %.6f, %.6f);" % (json.dumps(name + " Track"), w, h, duration, fps))
    if plate:
        js.append("try { var item = app.project.importFile(new ImportOptions(new File(%s)));" % json.dumps(plate))
        js.append("  var plate = comp.layers.add(item); plate.startTime = 0; } catch (e) {}")
    js.append("var cam = comp.layers.addCamera(%s, [%f, %f]);" % (json.dumps(name + " Camera"), w / 2.0, h / 2.0))
    js.append("cam.autoOrient = AutoOrientType.NO_AUTO_ORIENT;")
    js.append("var t = [%s];" % ",".join(times))
    js.append("cam.property('position').setValuesAtTimes(t, [%s]);" % ",".join(pos))
    js.append("cam.property('orientation').setValuesAtTimes(t, [%s]);" % ",".join(ori))
    js.append("cam.property('zoom').setValuesAtTimes(t, [%s]);" % ",".join(zoom))
    js.append("comp.openInViewer();")
    js.append("app.endUndoGroup();")
    js.append("})();")
    with open(os.path.join(folder, name + "_camera.jsx"), "w") as fh:
        fh.write("\n".join(js) + "\n")


main()
"""#
}
