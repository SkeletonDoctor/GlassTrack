import Foundation
import SwiftUI

// MARK: - Quality presets

enum QualityPreset: String, CaseIterable, Identifiable, Codable {
    case preview, balanced, high, ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "Preview"
        case .balanced: "Balanced"
        case .high: "High"
        case .ultra: "Ultra"
        }
    }

    var subtitle: String {
        switch self {
        case .preview: "Fast check, lower accuracy"
        case .balanced: "Good for most shots"
        case .high: "Final-quality track"
        case .ultra: "Full resolution, slowest"
        }
    }

    var symbol: String {
        switch self {
        case .preview: "hare"
        case .balanced: "dial.medium"
        case .high: "sparkles"
        case .ultra: "diamond"
        }
    }

    /// Longest edge used for feature extraction.
    var maxImageSize: Int {
        switch self {
        case .preview: 1280
        case .balanced: 2000
        case .high: 3200
        case .ultra: 8192
        }
    }

    var maxFeatures: Int {
        switch self {
        case .preview: 3000
        case .balanced: 8192
        case .high: 12000
        case .ultra: 20000
        }
    }

    var sequentialOverlap: Int {
        switch self {
        case .preview: 8
        case .balanced: 15
        case .high: 25
        case .ultra: 40
        }
    }

    /// Longest edge of the extracted JPEG frames (0 = native).
    var frameMaxEdge: Int {
        switch self {
        case .preview: 1600
        case .balanced: 2560
        case .high: 0
        case .ultra: 0
        }
    }
}

enum CameraModel: String, CaseIterable, Identifiable, Codable {
    case simpleRadial = "SIMPLE_RADIAL"
    case radial = "RADIAL"
    case opencv = "OPENCV"
    case pinhole = "PINHOLE"
    case simplePinhole = "SIMPLE_PINHOLE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simpleRadial: "Simple Radial (recommended)"
        case .radial: "Radial"
        case .opencv: "OpenCV (wide / action cams)"
        case .pinhole: "Pinhole (no distortion)"
        case .simplePinhole: "Simple Pinhole"
        }
    }
}

enum MatcherKind: String, CaseIterable, Identifiable, Codable {
    case sequential, exhaustive

    var id: String { rawValue }
    var title: String { self == .sequential ? "Sequential (video)" : "Exhaustive (photos)" }
}

enum MapperKind: String, CaseIterable, Identifiable, Codable {
    case incremental, global

    var id: String { rawValue }
    var title: String { self == .incremental ? "Incremental (robust)" : "Global (fast, GLOMAP)" }
}

enum FrameSampling: String, CaseIterable, Identifiable, Codable {
    case everyNth, targetFPS

    var id: String { rawValue }
    var title: String { self == .everyNth ? "Every Nth frame" : "Target FPS" }
}

// MARK: - Job settings

struct JobSettings: Codable, Equatable {
    var quality: QualityPreset = .balanced
    var sampling: FrameSampling = .everyNth
    var frameStep: Int = 2
    var targetFPS: Double = 6
    var maxFrames: Int = 0              // 0 = unlimited
    var jpegQuality: Int = 2            // ffmpeg q:v, 2 (best) … 10
    var cameraModel: CameraModel = .simpleRadial
    var singleCamera: Bool = true
    var matcher: MatcherKind = .sequential
    var mapper: MapperKind = .incremental
    var loopDetection: Bool = false
    var undistort: Bool = false
    var buildBlend: Bool = true
    var useGPU: Bool = false
}

// MARK: - Pipeline stages

enum StageID: String, CaseIterable, Identifiable, Codable {
    case extract, features, matching, mapping, undistort, export, blender

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extract: "Extract Frames"
        case .features: "Detect Features"
        case .matching: "Match Features"
        case .mapping: "Solve Camera"
        case .undistort: "Undistort Frames"
        case .export: "Export Model"
        case .blender: "Build Blender Scene"
        }
    }

    var symbol: String {
        switch self {
        case .extract: "film.stack"
        case .features: "scope"
        case .matching: "point.3.connected.trianglepath.dotted"
        case .mapping: "camera.metering.matrix"
        case .undistort: "rectangle.dashed"
        case .export: "shippingbox"
        case .blender: "cube.transparent"
        }
    }

    /// Relative weight for the overall progress bar.
    var weight: Double {
        switch self {
        case .extract: 0.08
        case .features: 0.2
        case .matching: 0.22
        case .mapping: 0.35
        case .undistort: 0.07
        case .export: 0.03
        case .blender: 0.05
        }
    }
}

enum StageState: Equatable, Codable {
    case pending, running, done, skipped, failed(String)
}

struct StageProgress: Identifiable, Equatable, Codable {
    let id: StageID
    var state: StageState = .pending
    var fraction: Double = 0          // 0…1, negative = indeterminate
    var detail: String = ""
    var startedAt: Date?
    var finishedAt: Date?
}

enum JobStatus: Equatable, Codable {
    case idle, running, finished, failed(String), cancelled

    var label: String {
        switch self {
        case .idle: "Ready"
        case .running: "Tracking…"
        case .finished: "Solved"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .running: .blue
        case .finished: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

enum InputKind: String, Equatable, Codable {
    case video, imageFolder
}

struct VideoInfo: Equatable, Codable {
    var width: Int
    var height: Int
    var fps: Double
    var frameCount: Int
    var duration: Double
}

struct SolveStats: Equatable, Codable {
    var registeredImages: Int = 0
    var totalImages: Int = 0
    var points: Int = 0
    var meanReprojectionError: Double?
    var meanTrackLength: Double?
}

/// Everything needed to restore a track after relaunch.
struct JobSnapshot: Codable {
    var id: UUID
    var name: String
    var inputPath: String
    var inputKind: InputKind
    var settings: JobSettings
    var outputRoot: String
    var folderName: String
    var createdAt: Date
    var status: JobStatus
    var stages: [StageProgress]
    var log: [String]
    var videoInfo: VideoInfo?
    var imageCount: Int
    var stats: SolveStats?
    var startedAt: Date?
    var finishedAt: Date?
    var blendPath: String?
    var frameMap: [String: Int]
    var extractWidth: Int?
    var extractHeight: Int?
}
