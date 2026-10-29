import SwiftUI
import Combine

@MainActor
final class AirportConnectionSession: ObservableObject {
    let preview: SubscriptionPreview
    @Published var name = ""
    @Published var error: String?
    @Published var nameError: String?
    @Published var confirming = false
    var appeared = false
    var focusedField = "link"
    private var observation: AnyCancellable?
    init(workspace: AirportWorkspace) {
        preview = workspace.makePreview()
        observation = preview.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func cancel() { preview.cancel(); name = ""; error = nil; nameError = nil; appeared = false; focusedField = "link" }
}

struct InlineAirportConnection: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var session: AirportConnectionSession
    let onCancel: () -> Void
    let onAdded: (UUID) -> Void
    @FocusState private var focus: String?
    @State private var visible = false
    @State private var focusGeneration = UUID()
    private var reading: Bool { if case .reading = session.preview.state { return true }; return false }
    private var input: Binding<String> {
        Binding(get: { session.preview.input }, set: { session.preview.setInput($0); session.error = nil })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.preview.confirmation == nil ? "连接机场" : "确认机场").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("取消", action: cancel).buttonStyle(WorkspaceButton(quiet: true)).accessibilityLabel("取消添加机场").disabled(session.confirming)
                    .focusable().focused($focus, equals: "cancel")
                    .workspaceFocusCue(focus == "cancel")
                    .workspaceKeyboardActivation(cancel)
            }
            if let result = session.preview.confirmation {
                preview(result)
            } else {
                HStack(spacing: 8) {
                    SecureField("HTTPS 订阅链接", text: input).focused($focus, equals: "link").accessibilityLabel("添加订阅链接")
                        .disabled(reading || session.confirming).onSubmit(read)
                    Button(reading ? "正在读取…" : failed ? "重试读取" : "读取", action: read)
                        .buttonStyle(WorkspaceButton(primary: true)).disabled(reading || session.confirming || session.preview.input.isEmpty)
                }
                if case .failed(let message) = session.preview.state {
                    Text(message).font(.system(size: 11)).foregroundStyle(Magpie.danger).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(reading ? "读取流量信息中，仍可取消。" : "先查看额度和到期；确认添加后才保存链接与读数。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = session.error { Text(error).font(.system(size: 11)).foregroundStyle(Magpie.danger).fixedSize(horizontal: false, vertical: true) }
        }.font(.system(size: 12)).textFieldStyle(BorderlessEditorFieldStyle())
            .padding(.horizontal, 14).padding(.vertical, 12).focusEffectDisabled()
            .background(Magpie.surface, in: RoundedRectangle(cornerRadius: 9))
            .onAppear {
                visible = workspace.page == .airports
                let initial = !session.appeared
                session.appeared = true
                if visible { restoreFocus(initial ? "link" : session.focusedField) }
            }
            .onDisappear { visible = false; focusGeneration = UUID() }
            .onChange(of: workspace.page) { _, page in
                visible = page == .airports
                focusGeneration = UUID()
                if visible { restoreFocus(session.focusedField) }
                else { focus = nil }
            }
            .onChange(of: focus) { _, value in if let value { session.focusedField = value } }
            .onChange(of: session.name) { _, _ in session.nameError = nil; session.error = nil }
            .onExitCommand(perform: cancel)
    }
    private var failed: Bool { if case .failed = session.preview.state { return true }; return false }
    private func preview(_ result: SubscriptionPreview.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("机场名称").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                TextField("为机场命名", text: $session.name).focused($focus, equals: "name").accessibilityLabel("新机场名称").onSubmit(confirm)
            }
            if let error = session.nameError {
                Text(error).font(.system(size: 11)).foregroundStyle(Magpie.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 72)
            }
            HStack(spacing: 16) {
                summary("剩余", result.subscription.remaining.map { displayUnit.text($0) } ?? "未知")
                summary("总额", result.subscription.total == 0 ? "未知" : displayUnit.text(result.subscription.total))
                summary("到期", result.subscription.expiry.map { NativeFormat.day($0) } ?? "未提供")
            }.padding(.vertical, 4)
            Rectangle().fill(Magpie.line).frame(height: 1)
            HStack(spacing: 8) {
                Text("历史从本次读取开始，重置计划可稍后配置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("修改链接") {
                    // Invalidates the preview without dropping the entered URL.
                    let link = session.preview.input
                    session.preview.setInput(""); session.preview.setInput(link)
                    session.error = nil; session.nameError = nil; focus = "link"
                }.buttonStyle(WorkspaceButton(quiet: true))
                Button(session.confirming ? "正在添加…" : "确认添加", action: confirm)
                    .buttonStyle(WorkspaceButton(primary: true))
                    .focusable().focused($focus, equals: "confirm")
                    .workspaceFocusCue(focus == "confirm")
                    .workspaceKeyboardActivation(confirm)
            }
        }.disabled(session.confirming)
    }
    private var displayUnit: TrafficUnit { workspace.menuModel?.trafficUnit ?? TrafficUnit(rawValue: workspace.defaults.string(forKey: "trafficUnit") ?? "") ?? .gb }
    private func summary(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func read() {
        guard !reading, !session.confirming else { return }
        session.error = nil
        // Keep a keyboard-initiated read inside the form while the input is
        // disabled. Completion may return focus only if the user stayed here.
        let keyboardRead = focus == "link"
        let generation = focusGeneration
        if keyboardRead { focus = "cancel" }
        Task {
            await session.preview.read()
            guard keyboardRead, focus == "cancel", focusGeneration == generation,
                  visible, workspace.page == .airports else { return }
            if failed || session.preview.confirmation != nil {
                restoreFocus(session.preview.confirmation == nil ? "link" : "name")
            }
        }
    }
    private func restoreFocus(_ field: String) {
        let generation = UUID()
        focusGeneration = generation
        // The first pass can precede attachment to the native window. Callers
        // must own the entry/return action; background reads cannot steal focus.
        DispatchQueue.main.async {
            guard focusGeneration == generation, visible, workspace.page == .airports, !session.confirming else { return }
            let target = session.preview.confirmation == nil ? "link" : "name"
            if !reading { focus = field == target ? field : target }
        }
    }
    private func confirm() {
        guard !session.confirming, session.preview.confirmation != nil else { return }
        guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.nameError = "请为机场填写名称。"; focus = "name"; return
        }
        let generation = focusGeneration
        session.confirming = true; session.error = nil; session.nameError = nil
        Task {
            let id = await workspace.confirmPreview(session.preview, name: session.name)
            session.confirming = false
            if let id { session.cancel(); onAdded(id) }
            else {
                session.error = workspace.message ?? "添加失败，预览与输入已保留，请重试。"
                // Disabled controls lose native focus while saving. Restore it
                // only within the same visible form, never after a page change.
                if generation == focusGeneration, visible, workspace.page == .airports,
                   focus == nil || focus == "name" || focus == "confirm" {
                    restoreFocus("name")
                }
            }
        }
    }
    private func cancel() { guard !session.confirming else { return }; session.cancel(); onCancel() }
}
