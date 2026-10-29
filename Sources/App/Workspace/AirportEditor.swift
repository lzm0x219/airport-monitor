import SwiftUI
import AppKit

struct AirportEditor: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var session: AirportEditingSession
    var onSaved: () -> Void = {}
    var onSettings: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: AirportEditingSession.Field?
    @State private var contentHeight: CGFloat = 400
    @State private var availableHeight: CGFloat = 600
    @State private var focusGeneration = UUID()
    @State private var restoringFocus = true
    private var profile: AirportProfile? { session.profile }
    private var needsSubscription: Bool { profile == nil || session.replacing || profile.map { !workspace.model(for: $0).hasURL } == true }
    init(workspace: AirportWorkspace, session: AirportEditingSession, onSaved: @escaping () -> Void = {}, onSettings: (() -> Void)? = nil) {
        self.workspace = workspace; self.session = session; self.onSaved = onSaved; self.onSettings = onSettings
    }
    init(workspace: AirportWorkspace, profile: AirportProfile?) {
        self.init(workspace: workspace, session: AirportEditingSession(workspace: workspace, profile: profile))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配置机场").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("保存后生效").font(.system(size: 11)).foregroundStyle(.secondary)
                Button(action: cancel) { Image(systemName: "xmark") }.buttonStyle(CompactIconButton()).accessibilityLabel("关闭配置").disabled(session.saving)
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        labeled("机场名称", field: .name) {
                            TextField("机场名称", text: $session.draft.name).focused($focus, equals: .name).accessibilityIdentifier("editor-name")
                        }
                        labeled("套餐名称（可选）", field: .plan) {
                            TextField("例如：月付套餐", text: $session.draft.plan)
                                .focused($focus, equals: .plan).accessibilityLabel("套餐名称，可选")
                        }
                        subscriptionSection
                        resetSection
                        reminderSection
                        guidanceSection
                        if let error = session.saveError {
                            Text(error).font(.system(size: 11)).foregroundStyle(Magpie.danger).fixedSize(horizontal: false, vertical: true).id(AirportEditingSession.Field.save)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                        .background(EditorScrollMemory(session: session))
                        .background { GeometryReader { Color.clear.preference(key: EditorContentHeight.self, value: $0.size.height) } }
                }.scrollIndicators(.visible).textFieldStyle(BorderlessEditorFieldStyle()).controlSize(.small).disabled(session.saving)
                    .onChange(of: session.fieldErrors) { _, errors in
                        let order: [AirportEditingSession.Field] = [.name, .subscription, .reset, .threshold, .expiry]
                        guard let field = order.first(where: { errors[$0] != nil }) else { return }
                        DispatchQueue.main.async {
                            guard session.fieldErrors[field] != nil else { return }
                            proxy.scrollTo(field, anchor: .center); focus = field
                        }
                    }
                    .onChange(of: session.saveError) { _, error in
                        guard error != nil else { return }
                        let generation = focusGeneration
                        DispatchQueue.main.async {
                            guard session.saveError == error, focusGeneration == generation,
                                  !session.saving else { return }
                            proxy.scrollTo(AirportEditingSession.Field.save, anchor: .bottom)
                            focus = .save
                        }
                    }
                    .onChange(of: focus) { _, field in
                        guard let field, !restoringFocus else { return }
                        session.focusedField = field
                        if field != .settings { proxy.scrollTo(field, anchor: nil) }
                    }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel).buttonStyle(WorkspaceButton(quiet: true))
                Button(session.saving ? "正在保存…" : session.saveError == nil ? "保存" : "重试保存", action: save)
                    .buttonStyle(WorkspaceButton(primary: true)).keyboardShortcut(.defaultAction)
                    .focusable().focused($focus, equals: .save).workspaceKeyboardActivation(save)
                    .workspaceFocusCue(focus == .save)
            }.padding(.horizontal, 20).padding(.vertical, 10).disabled(session.saving)
        }.font(.system(size: 12)).frame(width: 480, height: min(contentHeight + 94, availableHeight))
            .background(Magpie.surface).tint(Magpie.accent).interactiveDismissDisabled(session.saving)
            .focusEffectDisabled()
            .background {
                // A sheet can own the responder after disclosure/scroll actions.
                // Bind Escape even then; clicking Cancel still discards directly.
                Button(action: handleEscape) { EmptyView() }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .disabled(session.saving).hidden().accessibilityHidden(true)
            }
            .onPreferenceChange(EditorContentHeight.self) {
                if $0 > 0 { contentHeight = ceil($0); session.scheduleScrollRestoration() }
            }
            .onAppear {
                updateAvailableHeight()
                let destination = session.appeared ? session.focusedField : .name
                session.appeared = true
                restoringFocus = true
                let generation = UUID()
                focusGeneration = generation
                DispatchQueue.main.async {
                    guard focusGeneration == generation else { return }
                    focus = destination
                    DispatchQueue.main.async {
                        guard focusGeneration == generation else { return }
                        restoringFocus = false
                        session.scheduleScrollRestoration()
                    }
                }
            }
            .onDisappear { focusGeneration = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in updateAvailableHeight() }
            .onExitCommand(perform: handleEscape)
            .onChange(of: session.draft) { _, _ in session.fieldErrors = [:]; session.saveError = nil }
            .onChange(of: session.reminders) { _, _ in session.fieldErrors = [:]; session.saveError = nil }
            .onChange(of: session.airportRemindersEnabled) { _, _ in
                session.fieldErrors.removeValue(forKey: .threshold)
                session.fieldErrors.removeValue(forKey: .expiry)
                session.saveError = nil
            }
            .onChange(of: session.thresholdText) { _, text in
                session.fieldErrors.removeValue(forKey: .threshold); session.saveError = nil
                session.updateThresholdValue(from: text)
            }
            .onChange(of: session.expiryDaysText) { _, text in
                session.fieldErrors.removeValue(forKey: .expiry); session.saveError = nil
                session.updateExpiryValue(from: text)
            }
    }
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("订阅链接").foregroundStyle(.secondary)
                Spacer()
                if session.replacing {
                    Button("取消更换") { session.cancelReplacement() }.buttonStyle(WorkspaceButton(quiet: true))
                }
            }
            if needsSubscription {
                SecureField("HTTPS 订阅链接", text: $session.draft.subscription).focused($focus, equals: .subscription).accessibilityLabel("订阅链接")
                if profile != nil {
                    HStack {
                        note("链接用途")
                        Spacer()
                        CompactChoice(title: "链接用途", selection: $session.change,
                                      options: [("更新当前机场", .sameSource), ("更换数据来源", .newSource)])
                            .frame(width: 170, height: 30).focusEffectDisabled()
                    }
                    note(session.change == .sameSource ? "更新同一机场链接或令牌，历史保留；留空不更换。新读数仍受72小时限频。" : "旧来源历史独立保留，新来源重新积累；同一地址仍受72小时限频。")
                } else { note("链接仅保存在本机钥匙串。") }
            } else {
                HStack {
                    note("已保存 · 不回显").help("订阅链接仅保存在本机钥匙串")
                    Spacer()
                    Button("更换") { session.replacing = true; focus = .subscription }.buttonStyle(WorkspaceButton())
                }
            }
            fieldError(.subscription)
        }.id(AirportEditingSession.Field.subscription)
    }
    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("流量重置").fontWeight(.medium)
                Spacer()
                CompactChoice(title: "重置规则", selection: $session.draft.resetRule.kind,
                              options: ResetKind.allCases.map { ($0.label, $0) })
                    .frame(width: 170, height: 30).focusEffectDisabled()
            }
            if session.draft.resetRule.kind != .none {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        note(session.draft.resetRule.kind == .monthly ? "每月日期" : session.draft.resetRule.kind == .billing ? "购买日期" : "下次日期")
                        if session.draft.resetRule.kind == .monthly {
                            CompactChoice(title: "每月日期", selection: $session.draft.resetRule.day,
                                          options: (1...31).map { ("\($0) 日", $0) })
                                .frame(height: 30).focusEffectDisabled()
                        } else {
                            DatePicker("重置日期", selection: $session.draft.resetRule.anchor, displayedComponents: .date).labelsHidden().frame(height: 30)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        note("时间")
                        DatePicker("重置时间", selection: resetTime, displayedComponents: .hourAndMinute).labelsHidden().frame(height: 30)
                    }.frame(width: 86, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        note("时区")
                        Menu {
                            ForEach(Array(Set([TimeZone.current.identifier, "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Tokyo", "UTC", "America/Los_Angeles", "America/New_York", "Europe/London"])).sorted(), id: \.self) { zone in
                                Button(zone) { session.draft.resetRule.timeZoneID = zone; session.customTimeZone = false }
                            }
                            Button("自定义时区…") { session.customTimeZone = true; focus = .reset }
                        } label: {
                            CompactMenuLabel(title: timeZoneLabel, fillsWidth: true)
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).tint(.primary)
                            .frame(maxWidth: .infinity).frame(height: 30).focusEffectDisabled()
                            .help(session.draft.resetRule.timeZoneID).accessibilityLabel("重置时区，\(timeZoneLabel)")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if session.customTimeZone || TimeZone(identifier: session.draft.resetRule.timeZoneID) == nil {
                    TextField("IANA 时区，例如 Asia/Shanghai", text: $session.draft.resetRule.timeZoneID).focused($focus, equals: .reset).accessibilityLabel("重置时区")
                }
                Text("下次：\(ResetPresentation(rule: session.draft.resetRule, at: Date()).value)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            fieldError(.reset)
        }.id(AirportEditingSession.Field.reset)
            .environment(\.timeZone, session.draft.resetRule.calendar.timeZone)
            .environment(\.calendar, session.draft.resetRule.calendar).environment(\.locale, Locale(identifier: "zh_CN"))
    }
    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("机场提醒").fontWeight(.medium)
                Spacer()
                Toggle("机场提醒", isOn: $session.airportRemindersEnabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("机场提醒")
            }.frame(height: 28)
            if session.airportRemindersEnabled {
              VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("低余量", isOn: $session.reminders.lowEnabled).toggleStyle(.checkbox)
                    Spacer()
                    TextField("阈值", text: $session.thresholdText).frame(width: 68).focused($focus, equals: .threshold).accessibilityLabel("低余量阈值")
                        .disabled(!session.reminders.lowEnabled)
                    if session.reminders.thresholdMode == .legacyAbsoluteGB {
                        Text("GB").foregroundStyle(.secondary)
                        Button("改用百分比") { session.reminders.thresholdMode = .percent; session.reminders.lowThreshold = 10; session.thresholdText = "10" }.buttonStyle(CompactButton(quiet: true)).disabled(!session.reminders.lowEnabled)
                    } else { Text("%").foregroundStyle(.secondary) }
                }.id(AirportEditingSession.Field.threshold)
                fieldError(.threshold)
                if session.reminders.thresholdMode == .legacyAbsoluteGB { note("保留旧版十进制 GB 阈值；改用百分比后按总额度判断。") }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("预计不足", isOn: $session.reminders.forecastEnabled).toggleStyle(.checkbox)
                    Text("提醒需要更密集的有效读数，仅靠每72小时采样无法满足。界面预测不直接触发提醒。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("预计不足提醒采用独立的连续预测资格，并需连续两次满足条件；已有符合要求的密集历史仍可参与判断。")
                }
                HStack(spacing: 8) {
                    Toggle("即将到期", isOn: $session.reminders.expiryEnabled).toggleStyle(.checkbox)
                    Spacer()
                    Text("提前").foregroundStyle(.secondary)
                    TextField("天数", text: $session.expiryDaysText).frame(width: 48).focused($focus, equals: .expiry).accessibilityLabel("到期提前天数").disabled(!session.reminders.expiryEnabled)
                    Text("天").foregroundStyle(.secondary)
                }.id(AirportEditingSession.Field.expiry)
                fieldError(.expiry)
              }
            }
        }
    }
    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                note(reminderExplanation).frame(maxWidth: .infinity, alignment: .leading)
                if let onSettings {
                    Button("全局设置") {
                        session.focusedField = .settings
                        session.suspendScrollForSettings()
                        dismiss(); onSettings()
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Magpie.accent)
                        .focusable().focused($focus, equals: .settings).fixedSize()
                        .workspaceFocusCue(focus == .settings)
                        .workspaceKeyboardActivation {
                            guard !session.saving else { return }
                            session.suspendScrollForSettings()
                            dismiss(); onSettings()
                        }
                }
            }.id(AirportEditingSession.Field.settings)
        }
    }
    private var reminderExplanation: String {
        if !session.airportRemindersEnabled { return "本机场提醒已关闭，类型选择与提醒记录保留。" }
        if !session.reminders.lowEnabled && !session.reminders.forecastEnabled && !session.reminders.expiryEnabled { return "未选择提醒类型，本机场不会发送提醒。" }
        if let profile, !workspace.model(for: profile).remindersEnabled { return "全局系统通知已关闭。此处保存选择，可在全局设置中开启。" }
        if let profile, !profile.enabled || profile.archived { return "机场暂停或已移除，暂不发送提醒。" }
        if session.replacing && !session.draft.subscription.isEmpty && session.change == .newSource { return "保存后等待新来源读数，旧来源记录不参与新提醒。" }
        if let profile {
            let model = workspace.model(for: profile)
            if model.stale || model.error != nil || model.syncPending || model.linkVerificationPending || (session.replacing && !session.draft.subscription.isEmpty) {
                return session.reminders.expiryEnabled && model.latest?.subscription.expiry != nil
                    ? "用量提醒等待有效读数；到期按上次日期判断，尚未重新核实。"
                    : "等待有效新读数，暂不判断新的用量风险。"
            }
        }
        if session.reminders.expiryEnabled { return "首次按设定天数提醒，24 小时内及已到期逐级提醒，不补发旧档。" }
        return "仅在有效读数满足条件时提醒；未知或旧读数不判断新的用量风险。"
    }
    private var resetTime: Binding<Date> {
        Binding(get: {
            let rule = session.draft.resetRule
            if rule.kind == .once { return rule.anchor }
            return rule.calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: rule.anchor) ?? rule.anchor
        }, set: { value in
            if session.draft.resetRule.kind == .once { session.draft.resetRule.anchor = value }
            session.draft.resetRule.hour = session.draft.resetRule.calendar.component(.hour, from: value)
            session.draft.resetRule.minute = session.draft.resetRule.calendar.component(.minute, from: value)
        })
    }
    private var timeZoneLabel: String {
        let identifier = session.draft.resetRule.timeZoneID
        guard let zone = TimeZone(identifier: identifier) else { return "时区无效" }
        return zone.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")) ?? identifier
    }
    private func labeled<Content: View>(_ title: String, field: AirportEditingSession.Field, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(.secondary); content(); fieldError(field) }.id(field)
    }
    @ViewBuilder private func fieldError(_ field: AirportEditingSession.Field) -> some View {
        if let text = session.fieldErrors[field] { Text(text).font(.system(size: 11)).foregroundStyle(Magpie.danger).fixedSize(horizontal: false, vertical: true) }
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func cancel() { guard !session.saving else { return }; session.draft.subscription = ""; dismiss() }
    private func handleEscape() {
        guard !session.saving else { return }
        cancel()
    }
    private func updateAvailableHeight() {
        let window = NSApp.keyWindow
        availableHeight = min(650, max(300, (window?.sheetParent ?? window)?.contentLayoutRect.height ?? 650) - 36)
    }
    private func save() {
        guard !session.saving, session.validate(requiresSubscription: profile == nil || (needsSubscription && !session.replacing) || (session.replacing && session.change == .newSource)) == nil else { return }
        session.saving = true
        Task {
            let success = await workspace.save(profile: profile, name: session.draft.name, plan: session.draft.plan,
                subscription: session.draft.subscription, reset: session.draft.resetRule, threshold: session.draft.threshold,
                change: session.change, reminderPreferences: session.reminders, airportRemindersEnabled: session.airportRemindersEnabled)
            session.saving = false
            if success { session.draft.subscription = ""; dismiss(); onSaved() }
            else { session.saveError = workspace.message ?? "保存失败，原配置和历史保持，请重试。" }
        }
    }
}
struct BorderlessEditorFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 30)
            .background(Magpie.secondary, in: RoundedRectangle(cornerRadius: 6))
            .focusEffectDisabled()
    }
}
private struct EditorContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
