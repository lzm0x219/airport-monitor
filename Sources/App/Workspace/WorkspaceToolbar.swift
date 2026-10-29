import SwiftUI

/// The native toolbar and page have separate hosting roots. Only header events
/// and presentation state cross that boundary; the page owns the add session.
@MainActor
final class WorkspaceToolbarState: ObservableObject {
    @Published var addRequest = UUID()
    @Published var addFocusRequest = UUID()
    @Published var connectionActive = false
    @Published var feedback: String?
    var feedbackHovered = false
    var feedbackFocused = false
    private var feedbackToken = UUID()

    func announce(_ text: String) { feedback = text; scheduleFeedbackDismissal() }
    func clearFeedback() { feedback = nil; feedbackToken = UUID() }
    func scheduleFeedbackDismissal() {
        let token = UUID(); feedbackToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, token == feedbackToken, !feedbackHovered, !feedbackFocused else { return }
            feedback = nil
        }
    }
}

struct WorkspaceBrand: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("MenuBarIcon").renderingMode(.template).resizable().frame(width: 18, height: 18)
            Text("Airport Monitor")
                .font(.system(size: 13, weight: .semibold)).tracking(0.13)
                .foregroundStyle(.primary).lineLimit(1)
        }.fixedSize().frame(height: 32)
    }
}

struct WorkspaceToolbarFeedback: View {
    @ObservedObject var state: WorkspaceToolbarState
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            if let feedback = state.feedback {
                Text(feedback).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(feedback)
                Button { state.clearFeedback() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).focused($focused).accessibilityLabel("关闭操作提示")
            }
        }.frame(width: 110, height: 28, alignment: .leading)
            .onHover { state.feedbackHovered = $0; if !$0 { state.scheduleFeedbackDismissal() } }
            .onChange(of: focused) { _, value in
                state.feedbackFocused = value
                if !value { state.scheduleFeedbackDismissal() }
            }
            .accessibilityElement(children: .contain)
    }
}

struct WorkspaceNavigationTabs: View {
    @ObservedObject var workspace: AirportWorkspace
    @FocusState private var focusedPage: WorkspacePage?
    @State private var hoveredPage: WorkspacePage?

    var body: some View {
        HStack(spacing: 2) {
            tab("机场", page: .airports)
        }.padding(2).frame(height: 32).fixedSize()
            .focusEffectDisabled().accessibilityElement(children: .contain)
            .accessibilityLabel("页面切换")
    }
    private func tab(_ title: String, page: WorkspacePage) -> some View {
        Button { workspace.page = page } label: {
            Text(title).font(.system(size: 12, weight: workspace.page == page ? .semibold : .medium))
                .foregroundStyle(workspace.page == page ? .primary : .secondary)
                .padding(.horizontal, 14).frame(height: 28)
                .background(workspace.page == page ? Magpie.surface : hoveredPage == page ? Magpie.pill : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).focusable().focused($focusedPage, equals: page).focusEffectDisabled()
            .workspaceKeyboardActivation { workspace.page = page }
            .onHover { hoveredPage = $0 ? page : nil }
            .accessibilityLabel(title)
            .accessibilityValue(workspace.page == page ? "当前页面" : "未选中")
            .accessibilityAddTraits(workspace.page == page ? [.isSelected] : [])
    }
}

struct WorkspaceToolbarActions: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var state: WorkspaceToolbarState
    @FocusState private var addFocused: Bool
    @FocusState private var settingsFocused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Button { requestAdd() } label: {
                Image(systemName: "plus")
            }.buttonStyle(WorkspaceIconButton())
                .accessibilityLabel("添加机场")
                .disabled(workspace.catalogBlocked || workspace.page != .airports)
                .help("添加机场：连接订阅并预览信息")
                .focusable().focused($addFocused)
                .workspaceKeyboardActivation { requestAdd() }
                .opacity(workspace.page == .airports ? 1 : 0)
                .accessibilityHidden(workspace.page != .airports)
            Button { workspace.page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(WorkspaceIconButton()).help("设置")
                .focusable().focused($settingsFocused)
                .workspaceKeyboardActivation { workspace.page = .settings }
                .accessibilityLabel("设置")
                .accessibilityValue(workspace.page == .settings ? "当前页面" : "未选中")
                .accessibilityAddTraits(workspace.page == .settings ? [.isSelected] : [])
        }.fixedSize().frame(height: 32).focusEffectDisabled()
            .onChange(of: state.addFocusRequest) { _, _ in
                guard workspace.page == .airports, !workspace.catalogBlocked else { return }
                addFocused = true
            }
    }
    private func requestAdd() {
        guard workspace.page == .airports, !workspace.catalogBlocked else { return }
        state.addRequest = UUID()
    }
}
