#!/usr/bin/env python3
"""Checks a GlassTrack solve against ground truth.

Usage: accuracy_test.py <project folder> <truth.json>

Reads the solved cameras from <project>/sparse_txt/images.txt, maps each extracted frame to
its plate frame via track_meta.json, aligns the solve to the truth with a similarity transform
(COLMAP's scale and origin are arbitrary) and fails if position, rotation or focal length errors
exceed the limits below.
"""
import json
import math
import os
import sys

# Pure Python (no numpy) so it runs on a stock macOS / CI image.


def sub(a, b): return [a[i] - b[i] for i in range(3)]
def add(a, b): return [a[i] + b[i] for i in range(3)]
def mul(a, s): return [v * s for v in a]
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def norm(a): return math.sqrt(dot(a, a))
def matvec(M, v): return [dot(M[i], v) for i in range(3)]
def matmul(A, B): return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
def transpose(M): return [[M[j][i] for j in range(3)] for i in range(3)]
def mean(vs): return [sum(v[i] for v in vs) / len(vs) for i in range(3)]


def largest_eigenvector(N):
    """Eigenvector of the largest eigenvalue of a symmetric matrix (cyclic Jacobi rotations)."""
    n = len(N)
    a = [row[:] for row in N]
    v = [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
    for _ in range(100):
        off = sum(a[i][j] ** 2 for i in range(n) for j in range(n) if i != j)
        if off < 1e-24:
            break
        for p in range(n):
            for q in range(p + 1, n):
                if abs(a[p][q]) < 1e-30:
                    continue
                theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                t = (1 if theta >= 0 else -1) / (abs(theta) + math.sqrt(theta * theta + 1))
                c = 1 / math.sqrt(t * t + 1)
                s = t * c
                for k in range(n):
                    akp, akq = a[k][p], a[k][q]
                    a[k][p], a[k][q] = c * akp - s * akq, s * akp + c * akq
                for k in range(n):
                    apk, aqk = a[p][k], a[q][k]
                    a[p][k], a[q][k] = c * apk - s * aqk, s * apk + c * aqk
                for k in range(n):
                    vkp, vkq = v[k][p], v[k][q]
                    v[k][p], v[k][q] = c * vkp - s * vkq, s * vkp + c * vkq
    i = max(range(n), key=lambda k: a[k][k])
    return [v[k][i] for k in range(n)]


def similarity(A, B):
    """Least-squares s, R, t with B ~ s R A + t (Horn's closed form with unit quaternions)."""
    ma, mb = mean(A), mean(B)
    A0 = [sub(a, ma) for a in A]
    B0 = [sub(b, mb) for b in B]
    S = [[sum(a[i] * b[j] for a, b in zip(A0, B0)) for j in range(3)] for i in range(3)]
    (xx, xy, xz), (yx, yy, yz), (zx, zy, zz) = S
    N = [[xx + yy + zz, yz - zy, zx - xz, xy - yx],
         [yz - zy, xx - yy - zz, xy + yx, zx + xz],
         [zx - xz, xy + yx, -xx + yy - zz, yz + zy],
         [xy - yx, zx + xz, yz + zy, -xx - yy + zz]]
    q = largest_eigenvector(N)
    R = quat_to_matrix(*q)
    s = sum(dot(b, matvec(R, a)) for a, b in zip(A0, B0)) / sum(dot(a, a) for a in A0)
    t = sub(mb, mul(matvec(R, ma), s))
    return s, R, t

MAX_POS_ERR = 0.02      # metres, mean over frames (path is ~12.6 m long)
MAX_ROT_ERR = 0.5       # degrees, worst frame
MAX_LENS_ERR = 0.5      # mm
MIN_SOLVED = 0.95       # fraction of extracted frames


def quat_to_matrix(w, x, y, z):
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def main(project, truth_path):
    meta = json.load(open(os.path.join(project, "track_meta.json")))
    truth = json.load(open(truth_path))
    model = os.path.join(project, "sparse_txt")

    cams = {}
    for line in open(os.path.join(model, "cameras.txt")):
        if line.startswith("#") or not line.strip():
            continue
        p = line.split()
        cams[int(p[0])] = (p[1], int(p[2]), int(p[3]), [float(v) for v in p[4:]])

    lines = [l for l in open(os.path.join(model, "images.txt")) if not l.startswith("#")]
    solved = {}
    i = 0
    while i < len(lines):
        p = lines[i].split()
        if len(p) >= 10:
            R = quat_to_matrix(*map(float, p[1:5]))       # world -> camera
            t = [float(v) for v in p[5:8]]
            Rc = transpose(R)                            # camera -> world
            solved[p[9]] = (mul(matvec(Rc, t), -1), Rc, int(p[8]))
            i += 2
        else:
            i += 1

    frames = meta["frames"]
    solved_fraction = len(solved) / len(frames)

    names = sorted(solved, key=lambda n: frames[n])
    A = [solved[n][0] for n in names]
    B = [truth["frames"][str(frames[n])]["position"] for n in names]
    scale, R_align, t_align = similarity(A, B)
    pos_err = [norm(sub(add(mul(matvec(R_align, a), scale), t_align), b)) for a, b in zip(A, B)]

    flip = [[1, 0, 0], [0, -1, 0], [0, 0, -1]]   # COLMAP camera (+Z forward, Y down) -> Blender camera
    rot_err = []
    for n in names:
        Rs = matmul(matmul(R_align, solved[n][1]), flip)
        Rt = truth["frames"][str(frames[n])]["rotation"]
        c = (sum(Rs[i][j] * Rt[i][j] for i in range(3) for j in range(3)) - 1) / 2
        rot_err.append(math.degrees(math.acos(max(-1.0, min(1.0, c)))))

    model_name, w, h, params = cams[solved[names[0]][2]]
    f = params[0]
    lens = f * truth["sensor_mm"] / max(w, h)
    lens_err = abs(lens - truth["lens_mm"])

    path = sum(norm(sub(B[i + 1], B[i])) for i in range(len(B) - 1))
    print("solved frames : %d / %d (%.0f%%)" % (len(solved), len(frames), 100 * solved_fraction))
    mean_pos = sum(pos_err) / len(pos_err)
    print("position error: mean %.4f m, max %.4f m (path %.2f m)" % (mean_pos, max(pos_err), path))
    print("rotation error: mean %.3f deg, max %.3f deg" % (sum(rot_err) / len(rot_err), max(rot_err)))
    print("focal length  : %.2f mm (truth %.2f mm)" % (lens, truth["lens_mm"]))

    failures = []
    if solved_fraction < MIN_SOLVED:
        failures.append("too few frames solved")
    if mean_pos > MAX_POS_ERR:
        failures.append("position error %.4f > %.4f" % (mean_pos, MAX_POS_ERR))
    if max(rot_err) > MAX_ROT_ERR:
        failures.append("rotation error %.3f > %.3f" % (max(rot_err), MAX_ROT_ERR))
    if lens_err > MAX_LENS_ERR:
        failures.append("focal length error %.2f > %.2f" % (lens_err, MAX_LENS_ERR))
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
