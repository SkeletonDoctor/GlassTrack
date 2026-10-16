import SwiftUI

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
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.title).fontWeight(.medium)
                    if let sub = opt.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, opt.subtitle == nil ? 6 : 7)
            .background {
                if isHover || isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.accentColor.opacity(isHover ? 0.45 : 0.18)),
                                     in: .rect(cornerRadius: 12, style: .continuous))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHover)
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
                    .shadow(color: selected ? .black.opacity(0.25) : .clear, radius: 1, y: 0.5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.accentColor.opacity(0.42)).interactive(), in: .capsule)
                                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.75))
                                .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)
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
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .glassEffect(.regular.tint(color.opacity(0.65)), in: .rect(cornerRadius: 9, style: .continuous))
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

// MARK: - Liquid Glass button style

/// Every button in the app: a real glass capsule (or circle) that refracts what's behind it,
/// reacts to the pointer, and tints for primary / destructive actions.
struct LiquidGlassButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    var circle: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .shadow(color: kind == .secondary ? .clear : .black.opacity(0.25), radius: 1, y: 0.5)
            .padding(.horizontal, circle ? pad.v : pad.h)
            .padding(.vertical, pad.v)
            .contentShape(shape)
            .glassEffect(glass.interactive(), in: shape)
            .overlay(shape.stroke(.white.opacity(configuration.isPressed ? 0.35 : 0.12), lineWidth: 0.75))
            .shadow(color: glow.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }

    private var glass: Glass {
        switch kind {
        case .primary: .regular.tint(Color.accentColor.opacity(0.4))
        case .destructive: .regular.tint(Color.red.opacity(0.4))
        case .secondary: .regular
        }
    }

    private var glow: Color {
        switch kind {
        case .primary: .accentColor
        case .destructive: .red
        case .secondary: .clear
        }
    }

    private var foreground: Color { kind == .secondary ? .primary : .white }

    private var font: Font {
        switch controlSize {
        case .extraLarge: .headline
        case .large: .body.weight(.semibold)
        case .small, .mini: .callout.weight(.medium)
        default: .body.weight(.medium)
        }
    }

    private var pad: (h: CGFloat, v: CGFloat) {
        switch controlSize {
        case .extraLarge: (24, 13)
        case .large: (18, 10)
        case .small, .mini: (10, 5)
        default: (14, 7)
        }
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static func liquidGlass(_ kind: LiquidGlassButtonStyle.Kind = .secondary, circle: Bool = false) -> LiquidGlassButtonStyle {
        LiquidGlassButtonStyle(kind: kind, circle: circle)
    }
}

// MARK: - Liquid Glass toggle

/// Glass track that fills with tinted glass when on, with a glass bubble knob.
struct LiquidGlassToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        HStack(spacing: 10) {
            configuration.label
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(.clear)
                        .frame(width: 48, height: 28)
                        .glassEffect(on ? .regular.tint(Color.accentColor.opacity(0.6)).interactive() : .regular.interactive(),
                                     in: .capsule)
                    Circle()
                        .fill(LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.25), radius: 2.5, y: 1.5)
                        .padding(3)
                }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

extension ToggleStyle where Self == LiquidGlassToggleStyle {
    static var liquidGlass: LiquidGlassToggleStyle { LiquidGlassToggleStyle() }
}
