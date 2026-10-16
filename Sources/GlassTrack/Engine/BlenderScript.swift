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
    A = up.rotation_difference(Vector((0, 0, 1))).to_matrix()
    fwd = A @ (poses[0][1] @ Vector((0, 0, 1)))
    yaw = math.atan2(fwd.x, fwd.y)  # rotate so the first camera looks down +Y
    A = Matrix.Rotation(yaw, 3, "Z") @ A

    if points:
        pts_al = [A @ Vector(p) for p, _ in points]
        cx = statistics.median(v.x for v in pts_al)
        cy = statistics.median(v.y for v in pts_al)
        zs = sorted(v.z for v in pts_al)
        cz = zs[int(len(zs) * 0.05)]
        centre = Vector((cx, cy, cz))
        cam_mean = sum((A @ C for _, _, C in poses), Vector()) / len(poses)
        dists = sorted((v - cam_mean).length for v in pts_al)
        typical = dists[len(dists) // 2] or 1.0
    else:
        centre = Vector((0, 0, 0)); typical = 1.0
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

    if args["out"]:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args["out"]))
        print("GlassTrack: saved", args["out"])


main()
"""#
}
