import SceneKit
import SwiftUI
import simd

/// Interactive 3D preview of the sparse point cloud and the solved camera path.
struct PointCloudView: NSViewRepresentable {
    let model: SparseModel

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.scene = buildScene()
        view.autoenablesDefaultLighting = false
        view.pointOfView = view.scene?.rootNode.childNode(withName: "viewer", recursively: false)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let align = model.alignment

        let pts = model.points.map { align * $0 }
        let cams = model.cameras.map { align * $0.center }

        // Robust centre & scale from the cameras and the cloud.
        let centre = median(pts.isEmpty ? cams : pts)
        let spread = medianDistance(pts.isEmpty ? cams : pts, from: centre)
        let scale: Float = spread > 0 ? 3 / spread : 1
        func tf(_ p: SIMD3<Float>) -> SCNVector3 {
            let q = (p - centre) * scale
            return SCNVector3(q.x, q.y, q.z)
        }

        // Points
        if !pts.isEmpty {
            let verts = pts.map(tf)
            let src = SCNGeometrySource(vertices: verts)
            let colorData = model.colors.withUnsafeBufferPointer { buf -> Data in
                var floats: [Float] = []
                floats.reserveCapacity(buf.count * 3)
                for c in buf { floats += [c.x, c.y, c.z] }
                return floats.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            let colorSrc = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: verts.count,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let indices = (0..<Int32(verts.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 2.5
            element.minimumPointScreenSpaceRadius = 1.2
            element.maximumPointScreenSpaceRadius = 3
            let geo = SCNGeometry(sources: [src, colorSrc], elements: [element])
            geo.firstMaterial?.lightingModel = .constant
            scene.rootNode.addChildNode(SCNNode(geometry: geo))
        }

        // Camera path
        if cams.count > 1 {
            let verts = cams.map(tf)
            var idx: [Int32] = []
            for i in 0..<(verts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                  elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.systemOrange
            geo.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: geo))
        }

        // Camera frustums (subsampled)
        let every = max(1, model.cameras.count / 40)
        for (i, cam) in model.cameras.enumerated() where i % every == 0 {
            let node = frustumNode(highlight: i == 0)
            node.position = tf(align * cam.center)
            let r = align * cam.rotation * simd_float3x3(diagonal: SIMD3(1, -1, -1))
            node.simdOrientation = simd_quatf(r)
            node.scale = SCNVector3(0.18, 0.18, 0.18)
            scene.rootNode.addChildNode(node)
        }

        // Viewer: elevated, behind the camera path, looking at the cloud centre.
        let viewer = SCNNode()
        viewer.name = "viewer"
        viewer.camera = SCNCamera()
        viewer.camera?.zNear = 0.01
        viewer.camera?.zFar = 500
        viewer.camera?.fieldOfView = 55
        let path = cams.map { (($0 - centre) * scale) }
        var pc = path.reduce(SIMD3<Float>.zero, +) / Float(max(path.count, 1))
        pc.y = 0
        let dir = simd_length(pc) > 0.3 ? simd_normalize(pc) : SIMD3<Float>(0, 0, 1)
        let target = pc * 0.5
        let pos = target + dir * 9 + SIMD3<Float>(0, 6, 0)
        viewer.position = SCNVector3(pos.x, pos.y, pos.z)
        viewer.look(at: SCNVector3(target.x, target.y, target.z))
        scene.rootNode.addChildNode(viewer)
        return scene
    }

    private func frustumNode(highlight: Bool) -> SCNNode {
        // Pyramid looking down -Z
        let w: Float = 0.8, h: Float = 0.5, d: Float = 1
        let v: [SCNVector3] = [SCNVector3(0, 0, 0),
                               SCNVector3(-w, -h, -d), SCNVector3(w, -h, -d),
                               SCNVector3(w, h, -d), SCNVector3(-w, h, -d)]
        let idx: [Int32] = [0, 1, 0, 2, 0, 3, 0, 4, 1, 2, 2, 3, 3, 4, 4, 1]
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: v)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = highlight ? NSColor.systemGreen : NSColor.systemOrange.withAlphaComponent(0.8)
        geo.materials = [m]
        return SCNNode(geometry: geo)
    }

    private func median(_ v: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !v.isEmpty else { return .zero }
        func m(_ a: [Float]) -> Float { a.sorted()[a.count / 2] }
        return SIMD3(m(v.map(\.x)), m(v.map(\.y)), m(v.map(\.z)))
    }

    private func medianDistance(_ v: [SIMD3<Float>], from c: SIMD3<Float>) -> Float {
        guard !v.isEmpty else { return 1 }
        let d = v.map { simd_length($0 - c) }.sorted()
        return d[d.count / 2]
    }
}
