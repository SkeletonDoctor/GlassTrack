import SwiftUI

// MARK: - Progress bar

/// Apple-style capsule progress bar: recessed track, glossy gradient fill with a soft glow,
/// a light sweep while active, and a gliding pill when the value is unknown (`nil`).
struct GlassProgressBar: View {
    var value: Double?
    var tint: Color = .accentColor
    var height: CGFloat = 8
    var active: Bool = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Recessed track
                Capsule()
                    .fill(.primary.opacity(0.09))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(colors: [.black.opacity(0.18), .white.opacity(0.10)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.75)
                    )

                if let value {
                    fill
                        .frame(width: max(height, w * min(max(value, 0), 1)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: value)
                        .opacity(value <= 0 ? 0 : 1)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let phase = (sin(t * 2.2) + 1) / 2
                        fill
                            .frame(width: w * 0.32)
                            .offset(x: (w - w * 0.32) * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private var fill: some View {
        Capsule()
            .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.25), tint],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .top) {
                // Specular highlight on the upper half
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: height * 0.55)
                    .padding(.horizontal, height * 0.25)
                    .padding(.top, 0.5)
            }
            .overlay {
                if active && value != nil { Shimmer() }
            }
            .clipShape(Capsule())
            .shadow(color: tint.opacity(0.55), radius: height * 0.6)
    }
}

/// A soft light band sweeping left to right.
private struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            GeometryReader { geo in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let band = max(40, geo.size.width * 0.35)
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.38), .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + (geo.size.width + band) * t)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Dropdown

struct DropdownOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var id: Value { value }
}

/// Glass capsule that opens a glass popover menu with icons, subtitles and a checkmark.
struct GlassDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [DropdownOption<Value>]
    var minWidth: CGFloat = 240

    @State private var open = false
    @State private var hovered: Value?

    private var current: DropdownOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 10) {
                if let s = current?.symbol {
                    Image(systemName: s)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                }
                Text(current?.title ?? "—")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: minWidth)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options) { opt in
                    row(opt)
                }
            }
            .padding(6)
            .frame(minWidth: minWidth + 40)
        }
    }

    private func row(_ opt: DropdownOption<Value>) -> some View {
        let isHover = hovered == opt.value
        let isSelected = selection == opt.value
        return Button {
            withAnimation(.snappy) { selection = opt.value }
            open = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                if let s = opt.symbol {
                    Image(systemName: s)
                        .frame(width: 20)
                        .foregroundStyle(isHover ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.title).fontWeight(.medium)
                    if let sub = opt.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(isHover ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHover ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, opt.subtitle == nil ? 6 : 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHover ? Color.accentColor : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? opt.value : (hovered == opt.value ? nil : hovered) }
    }
}

// MARK: - Segmented control

/// Capsule segmented control with a sliding, glowing selection pill.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [DropdownOption<Value>]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                let selected = opt.value == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = opt.value }
                } label: {
                    HStack(spacing: 6) {
                        if let s = opt.symbol { Image(systemName: s) }
                        Text(opt.title)
                    }
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            Capsule()
                                .fill(LinearGradient(colors: [Color.accentColor.mix(with: .white, by: 0.15), .accentColor],
                                                     startPoint: .top, endPoint: .bottom))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                                .shadow(color: Color.accentColor.opacity(0.45), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Stepper

/// Pill stepper: − value +, with a rolling number.
struct GlassStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Text("\(value)\(suffix)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .frame(minWidth: 44)
            stepButton("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .buttonRepeatBehavior(.enabled)
    }
}

// MARK: - Setting rows

/// System Settings–style row: icon tile, title + subtitle, trailing control.
struct SettingRow<Trailing: View>: View {
    let symbol: String
    var color: Color = .accentColor
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.2), color],
                                             startPoint: .top, endPoint: .bottom))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 6)
    }
}

struct SectionTitle: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// Thin hairline used between rows inside a glass card.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
    }
}
