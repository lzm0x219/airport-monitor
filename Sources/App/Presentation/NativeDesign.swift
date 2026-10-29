import SwiftUI
import AppKit

struct CompactButton: ButtonStyle {
    var prominent = false
    var selected = false
    var quiet = false
    var height: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 9).frame(minHeight: height)
            .foregroundStyle(prominent ? Magpie.accent : Color.primary.opacity(selected ? 1 : 0.8))
            .modifier(CompactControlChrome(pressed: configuration.isPressed, prominent: prominent, selected: selected, quiet: quiet))
    }
}

struct CompactIconButton: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(selected ? .primary : .secondary)
            .modifier(CompactControlChrome(pressed: configuration.isPressed, selected: selected, quiet: true))
    }
}

private struct CompactControlChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var pressed = false
    var prominent = false
    var selected = false
    var quiet = false
    private var background: Color {
        if prominent { return Magpie.accent.opacity(pressed ? 0.2 : hovering && isEnabled ? 0.14 : 0.09) }
        if selected { return Color.primary.opacity(pressed ? 0.24 : 0.16) }
        if quiet && !pressed && !(hovering && isEnabled) { return .clear }
        return Magpie.pill.opacity(pressed ? 1 : hovering && isEnabled ? 0.9 : 0.7)
    }
    func body(content: Content) -> some View {
        content.background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

struct CompactSearchField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text).textFieldStyle(.plain).accessibilityLabel(title)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除\(title)")
            }
        }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
            .background(Magpie.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Magpie.line))
    }
}

struct CompactMenuLabel: View {
    let title: String
    var fillsWidth = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            if fillsWidth { Spacer(minLength: 4) }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).accessibilityHidden(true)
        }.font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 28)
            .background(Magpie.secondary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine).accessibilityLabel(title)
    }
}

struct CompactChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var body: some View {
        Menu {
            ForEach(options, id: \.1) { label, value in
                Button { selection = value } label: {
                    if selection == value { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: { CompactMenuLabel(title: options.first(where: { $0.1 == selection })?.0 ?? title, fillsWidth: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).tint(.primary)
            .accessibilityLabel(title).accessibilityValue(options.first(where: { $0.1 == selection })?.0 ?? "未选择")
    }
}

struct CompactFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 28)
            .background(Magpie.secondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Magpie.line))
    }
}

struct Surface<Content: View>: View {
    var verticalPadding: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View { content.padding(.vertical, verticalPadding).padding(.horizontal, horizontalPadding).frame(maxWidth: .infinity, alignment: .leading).background(Magpie.surface, in: RoundedRectangle(cornerRadius: 9)) }
}

/// Neutral, flat segments shared by navigation, filters and chart controls.
struct CompactSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @FocusState private var focusedOption: Value?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { label, value in
                Button { selection = value } label: {
                    Text(label).font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .padding(.horizontal, 9).frame(minHeight: 24)
                }.buttonStyle(SegmentButtonStyle(selected: selection == value)).focusable().focusEffectDisabled().focused($focusedOption, equals: value)
                    .onMoveCommand { direction in
                        guard let index = options.firstIndex(where: { $0.1 == value }), direction == .left || direction == .right else { return }
                        let next = min(options.count - 1, max(0, index + (direction == .left ? -1 : 1)))
                        selection = options[next].1; focusedOption = options[next].1
                    }
                    .accessibilityValue(selection == value ? "已选中" : "未选中")
                    .accessibilityAddTraits(selection == value ? [.isSelected] : [])
            }
        }.padding(2).background(Magpie.pill, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(selected ? Magpie.surface : configuration.isPressed || (hovering && isEnabled) ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .opacity(isEnabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 4)).onHover { hovering = $0 }
    }
}

struct BalanceReadout: View {
    let text: String
    var size: CGFloat = 20
    var color: Color = .primary
    var caption = "剩余"
    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(parts.first ?? "—")).font(.system(size: size, weight: .semibold)).foregroundStyle(color)
            if parts.count > 1 { Text(String(parts[1])).font(.system(size: 12, weight: .medium)).foregroundStyle(color) }
            if parts.count > 1 { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.monospacedDigit().fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(text + (parts.count > 1 ? " " + caption : ""))
    }
}

struct EmptyWorkspace: View {
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var actionDisabled = false
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CompactButton()).disabled(actionDisabled)
            }
        }.frame(maxWidth: .infinity, minHeight: 120).padding(24)
    }
}

struct DetailChrome<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    private enum Control { case close, done }
    @FocusState private var control: Control?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(CompactIconButton()).accessibilityLabel("关闭\(title)").focusable().focused($control, equals: .close) }.padding(.horizontal, 18).frame(height: 44)
            Divider()
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading).padding(18) }
            Divider()
            HStack { Spacer(); Button("完成", action: close).buttonStyle(CompactButton(prominent: true)).keyboardShortcut(.defaultAction).focusable().focused($control, equals: .done) }.padding(.horizontal, 18).frame(height: 48)
        }.background(Magpie.surface)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            .onExitCommand(perform: close)
            .onAppear { Task { @MainActor in await Task.yield(); control = .close } }
    }
}

struct NativeSheetSize: ViewModifier {
    var idealHeight: CGFloat = 400
    @State private var maximumHeight: CGFloat = 650
    func body(content: Content) -> some View {
        content.frame(width: 560, height: min(idealHeight, maximumHeight))
            .onAppear { let window = NSApp.keyWindow; maximumHeight = max(280, ((window?.sheetParent ?? window)?.frame.height ?? 700) - 48) }
    }
}

struct ExplanationSheet: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        DetailChrome(title: title, close: close) { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }
            .modifier(NativeSheetSize())
    }
}

