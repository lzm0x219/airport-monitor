import SwiftUI
import AppKit

/// Explicit SwiftUI focus can land on the focus wrapper rather than the native
/// button. Keep keyboard activation local to workspace controls and respect disabled state.
private struct WorkspaceKeyboardActivation: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onKeyPress(.space, action: activate).onKeyPress(.return, action: activate)
    }
    private func activate() -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        action()
        return .handled
    }
}
private struct WorkspaceFocusCue: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content.focusEffectDisabled()
            .background(Color.primary.opacity(focused ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 4))
    }
}
extension View {
    /// A soft fill indicates keyboard focus without an outline or underline.
    func workspaceFocusCue(_ focused: Bool) -> some View {
        modifier(WorkspaceFocusCue(focused: focused))
    }
    func workspaceKeyboardActivation(_ action: @escaping () -> Void) -> some View {
        modifier(WorkspaceKeyboardActivation(action: action))
    }
}

/// Independent from status-bar controls so workspace styling stays isolated.
struct WorkspaceSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var disabledValues: Set<Value> = []
    @FocusState private var focusedOption: Value?
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { label, value in
                Button { selection = value; focusedOption = value } label: {
                    Text(label).font(.system(size: 11, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .padding(.horizontal, 7).frame(minHeight: 24)
                        .background(selection == value ? Magpie.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .workspaceFocusCue(focusedOption == value)
                }.buttonStyle(.plain).focusable().focusEffectDisabled().focused($focusedOption, equals: value)
                    .onMoveCommand { direction in
                        let available = options.filter { !disabledValues.contains($0.1) }
                        guard isEnabled, let index = available.firstIndex(where: { $0.1 == value }), direction == .left || direction == .right else { return }
                        select(available[min(available.count - 1, max(0, index + (direction == .left ? -1 : 1)))].1)
                    }
                    .onKeyPress(.home) { guard isEnabled, let first = options.first(where: { !disabledValues.contains($0.1) }) else { return .ignored }; select(first.1); return .handled }
                    .onKeyPress(.end) { guard isEnabled, let last = options.last(where: { !disabledValues.contains($0.1) }) else { return .ignored }; select(last.1); return .handled }
                    .disabled(disabledValues.contains(value)).opacity(disabledValues.contains(value) ? 0.4 : 1)
                    .accessibilityValue(selection == value ? "已选中" : "未选中")
                    .accessibilityAddTraits(selection == value ? [.isSelected] : [])
            }
        }.padding(3).background(Magpie.pill, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45).accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private func select(_ value: Value) {
        guard !disabledValues.contains(value) else { return }
        selection = value; focusedOption = value
    }
}

/// Workspace-only treatments: the menu-bar panel retains its existing controls.
struct WorkspaceButton: ButtonStyle {
    var primary = false
    var quiet = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).frame(height: 28)
            .modifier(WorkspaceButtonChrome(primary: primary, quiet: quiet,
                                            selected: selected, pressed: configuration.isPressed))
    }
}

/// The same state treatment as text actions, without changing shared panel controls.
struct WorkspaceIconButton: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .modifier(WorkspaceButtonChrome(primary: false, quiet: true,
                                            selected: selected, pressed: configuration.isPressed))
    }
}

struct WorkspaceMenuAction {
    let title: String
    var enabled = true
    var separatorBefore = false
    let perform: () -> Void
}

/// A focusable workspace trigger backed by a standard macOS menu. SwiftUI's
/// extra focus wrapper on Menu consumes Space without opening the native menu.
struct WorkspaceActionMenu: View {
    let label: String
    let actions: [WorkspaceMenuAction]
    let focus: FocusState<Bool>.Binding
    let onClose: () -> Void
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Image(systemName: "ellipsis") }
            .buttonStyle(WorkspaceIconButton(selected: presented))
            .focusable().focused(focus).workspaceFocusCue(focus.wrappedValue)
            .workspaceKeyboardActivation { presented = true }
            .accessibilityLabel(label)
            .background(WorkspaceMenuPresenter(presented: $presented, actions: actions, onClose: onClose))
    }
}

private struct WorkspaceMenuPresenter: NSViewRepresentable {
    @Binding var presented: Bool
    let actions: [WorkspaceMenuAction]
    let onClose: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard presented, !context.coordinator.opening else { return }
        let coordinator = context.coordinator
        coordinator.opening = true
        // A menu runs a nested event loop. Enter from the run loop instead of
        // holding the main dispatch queue, so async sync results can still publish.
        RunLoop.main.perform(inModes: [.common]) { [weak view] in
            guard let view, view.window != nil, coordinator.parent.presented else {
                coordinator.opening = false
                coordinator.parent.presented = false
                return
            }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.font = .systemFont(ofSize: 12)
            menu.minimumWidth = 152
            coordinator.actions = coordinator.parent.actions
            for (index, action) in coordinator.actions.enumerated() {
                if action.separatorBefore { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.title, action: #selector(Coordinator.activate(_:)), keyEquivalent: "")
                item.target = coordinator; item.tag = index; item.isEnabled = action.enabled
                menu.addItem(item)
            }
            // Keep the trailing action menu inside the narrow workspace window.
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - menu.size.width, y: view.bounds.minY), in: view)
            coordinator.opening = false
            coordinator.parent.presented = false
            coordinator.actions = []
            coordinator.parent.onClose()
        }
    }
    final class Coordinator: NSObject {
        var parent: WorkspaceMenuPresenter
        var opening = false
        var actions: [WorkspaceMenuAction] = []
        init(_ parent: WorkspaceMenuPresenter) { self.parent = parent }
        @objc func activate(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag), actions[sender.tag].enabled else { return }
            actions[sender.tag].perform()
        }
    }
}

private struct WorkspaceButtonChrome: ViewModifier {
    let primary: Bool
    let quiet: Bool
    let selected: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    private var fill: Color {
        guard enabled else { return quiet ? .clear : Magpie.pill.opacity(0.45) }
        if primary {
            return Magpie.accent.opacity(pressed ? 0.24 : hovering || selected ? 0.17 : scheme == .dark ? 0.11 : 0.08)
        }
        if pressed { return Color.primary.opacity(0.14) }
        if selected { return Color.primary.opacity(0.10) }
        return hovering ? Magpie.pill : quiet ? .clear : Magpie.pill.opacity(0.65)
    }
    func body(content: Content) -> some View {
        content.foregroundStyle(enabled ? (primary ? Magpie.accent : Color.primary.opacity(0.85)) : .secondary)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.5).focusEffectDisabled()
            .onHover { hovering = $0 }
    }
}

struct WorkspaceMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
