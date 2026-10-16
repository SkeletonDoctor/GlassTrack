import SwiftUI

/// Soft, slowly drifting colour field behind the glass so it has something to refract.
struct AmbientBackground: View {
    var image: NSImage?

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                let t = Float(ctx.date.timeIntervalSinceReferenceDate * 0.08)
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5 + 0.08 * sin(t), 0], [1, 0],
                        [0, 0.5 + 0.1 * cos(t * 1.3)], [0.5 + 0.12 * cos(t), 0.5 + 0.12 * sin(t * 0.9)], [1, 0.5 + 0.1 * sin(t * 1.1)],
                        [0, 1], [0.5 + 0.08 * cos(t * 0.7), 1], [1, 1],
                    ],
                    colors: [
                        .indigo.opacity(0.55), .blue.opacity(0.45), .cyan.opacity(0.4),
                        .purple.opacity(0.4), .teal.opacity(0.3), .blue.opacity(0.4),
                        .mint.opacity(0.3), .indigo.opacity(0.45), .purple.opacity(0.5),
                    ]
                )
            }
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60)
                            .opacity(0.55)
                    }
                    .clipped()
                    .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}

extension View {
    /// Standard rounded glass panel.
    func glassCard(_ radius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: .rect(cornerRadius: radius))
    }
}

struct StatusPill: View {
    let status: JobStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
                .shadow(color: status.color.opacity(0.8), radius: status == .running ? 4 : 0)
            Text(status.label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(status.color.opacity(0.18)), in: .capsule)
    }
}

/// Round progress indicator; pass a negative `progress` for an indeterminate spinning arc.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 10
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: lineWidth)
                .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 1).blur(radius: 1).padding(lineWidth / 2))
            if progress < 0 {
                TimelineView(.animation) { ctx in
                    let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                    arc(0.28).rotationEffect(.degrees(angle - 90))
                }
            } else {
                arc(max(0.001, min(progress, 1)))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
            }
        }
    }

    private func arc(_ to: Double) -> some View {
        Circle()
            .trim(from: 0, to: to)
            .stroke(
                AngularGradient(colors: [tint.opacity(0.6), tint, tint.mix(with: .cyan, by: 0.5)], center: .center),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .shadow(color: tint.opacity(0.55), radius: lineWidth * 0.8)
    }
}

struct InfoChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(18)
    }
}
