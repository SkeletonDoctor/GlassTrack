import Foundation
import simd

/// Light-weight reader for COLMAP TXT models, used for the in-app 3D preview.
struct SparseModel {
    struct Camera {
        var center: SIMD3<Float>
        var rotation: simd_float3x3   // camera -> world
        var name: String
        var meanError: Float? = nil   // mean reprojection error (px) of this frame's 3D points
        var observations: Int = 0     // number of tracked points seen in this frame
    }

    var cameras: [Camera] = []
    var points: [SIMD3<Float>] = []
    var colors: [SIMD3<Float>] = []

    static func load(from dir: URL, maxPoints: Int = 150_000) -> SparseModel? {
        guard let imagesTxt = try? String(contentsOf: dir.appendingPathComponent("images.txt"), encoding: .utf8)
        else { return nil }
        var model = SparseModel()

        // Points first: keep a subsample for display, and every point's reprojection error.
        var pointError: [Int: Float] = [:]
        if let pts = try? String(contentsOf: dir.appendingPathComponent("points3D.txt"), encoding: .utf8) {
            let pl = pts.split(separator: "\n").filter { !$0.hasPrefix("#") }
            let stride = max(1, pl.count / maxPoints)
            pointError.reserveCapacity(pl.count)
            for (idx, line) in pl.enumerated() {
                let p = line.split(separator: " ", maxSplits: 8)
                guard p.count >= 8, let id = Int(p[0]) else { continue }
                if let e = Float(p[7]) { pointError[id] = e }
                if idx % stride == 0, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]),
                   let r = Float(p[4]), let g = Float(p[5]), let b = Float(p[6]) {
                    model.points.append(SIMD3(x, y, z))
                    model.colors.append(SIMD3(r, g, b) / 255)
                }
            }
        }

        let lines = imagesTxt.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
        var i = 0
        while i < lines.count {
            let p = lines[i].split(separator: " ")
            if p.count >= 10,
               let qw = Float(p[1]), let qx = Float(p[2]), let qy = Float(p[3]), let qz = Float(p[4]),
               let tx = Float(p[5]), let ty = Float(p[6]), let tz = Float(p[7]) {
                let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
                let r = simd_float3x3(q)              // world -> camera
                let rc = r.transpose
                let c = -(rc * SIMD3(tx, ty, tz))
                // Second line: X Y POINT3D_ID triples; average the error of this frame's 3D points.
                var sum: Float = 0, n = 0
                if i + 1 < lines.count {
                    let obs = lines[i + 1].split(separator: " ")
                    var k = 2
                    while k < obs.count {
                        if let id = Int(obs[k]), id >= 0, let e = pointError[id] { sum += e; n += 1 }
                        k += 3
                    }
                }
                model.cameras.append(Camera(center: c, rotation: rc, name: p[9...].joined(separator: " "),
                                            meanError: n > 0 ? sum / Float(n) : nil, observations: n))
                i += 2
            } else {
                i += 1
            }
        }
        model.cameras.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return model.cameras.isEmpty ? nil : model
    }

    /// Rotation that maps the average camera "up" to +Y (SceneKit's up axis).
    var alignment: simd_float3x3 {
        var up = SIMD3<Float>(0, 0, 0)
        for c in cameras { up += c.rotation * SIMD3(0, -1, 0) }
        guard simd_length(up) > 1e-6 else { return matrix_identity_float3x3 }
        let q = simd_quatf(from: simd_normalize(up), to: SIMD3(0, 1, 0))
        return simd_float3x3(q)
    }
}

/// Reads the number of registered images from a binary model (images.bin starts with a uint64 count).
func registeredImageCount(inBinaryModel dir: URL) -> Int {
    guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("images.bin")),
          let d = try? h.read(upToCount: 8), d.count == 8 else { return 0 }
    try? h.close()
    return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
}
