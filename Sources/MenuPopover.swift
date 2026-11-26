import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class FloatingMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class MenuModel: ObservableObject {
    struct Actions {
        var requestDockAccess: () -> Void = {}
        var toggleLogin: () -> Void = {}
        var checkForUpdates: () -> Void = {}
        var closePopover: () -> Void = {}
        var updateStatusIcon: () -> Void = {}
        var quit: () -> Void = {}
    }

    @Published var snowOn: Bool = true
    @Published var intensity: Intensity = .normal
    @Published var windOn: Bool = true
    @Published var windStrength: Int = 1
    @Published var shakeOn: Bool = true
    @Published var shakeStrength: ShakeStrength = .normal
    @Published var meltOn: Bool = true
    @Published var meltSpeed: Int = 1
    @Published var campfireOn: Bool = false
    @Published var snowmenOn: Bool = true
    @Published var autoPlow: Bool = true
    @Published var flakesOnTop: Bool = false
    @Published var hideInFullscreen: Bool = true
    @Published var batteryMode: BatteryMode = .auto
    @Published var launchAtLogin: Bool = false
    @Published var autoUpdateOn: Bool = false
    @Published var canCheckForUpdates: Bool = false
    @Published var updaterConfigured: Bool = false
    @Published var axTrusted: Bool = true
    @Published var snowmanCount: Int = 0
    @Published var isLowPower: Bool = false
    @Published var versionText: String = "0.5.3"
    @Published var activeTileID: String? = nil
    @Published var hoveredID: String? = nil

    private weak var engine: Engine?
    private weak var updater: Updater?
    private let actions: Actions
    private var tileResetWork: DispatchWorkItem?

    init(engine: Engine?, updater: Updater?, actions: Actions) {
        self.engine = engine
        self.updater = updater
        self.actions = actions
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty {
            versionText = v
        }
        if engine != nil { refresh() }
    }

    static func preview(campfire: Bool, axTrusted: Bool) -> MenuModel {
        let m = MenuModel(engine: nil, updater: nil, actions: Actions())
        m.snowOn = true
        m.intensity = .normal
        m.windOn = true
        m.windStrength = 1
        m.shakeOn = true
        m.shakeStrength = .normal
        m.meltOn = true
        m.meltSpeed = 1
        m.campfireOn = campfire
        m.snowmenOn = true
        m.autoPlow = true
        m.flakesOnTop = false
        m.hideInFullscreen = true
        m.batteryMode = .auto
        m.launchAtLogin = false
        m.autoUpdateOn = true
        m.canCheckForUpdates = true
        m.updaterConfigured = true
        m.axTrusted = axTrusted
        m.snowmanCount = campfire ? 2 : 3
        m.isLowPower = false
        m.versionText = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.5.3"
        return m
    }

    func refresh() {
        guard let engine else { return }
        let s = Settings.shared
        snowOn = s.snowOn
        intensity = s.intensity
        windOn = s.windOn
        windStrength = s.windStrength
        shakeOn = s.shakeOn
        shakeStrength = s.shakeStrength
        meltOn = s.meltOn
        meltSpeed = s.meltSpeed
        campfireOn = s.campfireOn
        snowmenOn = s.snowmenOn
        autoPlow = s.autoPlow
        flakesOnTop = s.flakesOnTop
        hideInFullscreen = s.hideInFullscreen
        batteryMode = s.batteryMode
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoUpdateOn = updater?.automaticallyChecksForUpdates ?? false
        canCheckForUpdates = updater?.canCheckForUpdates ?? false
        updaterConfigured = updater?.isConfigured ?? false
        axTrusted = AXIsProcessTrusted()
        snowmanCount = engine.props.filter { $0.kind == .snowman }.count
        isLowPower = engine.lowPower
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty {
            versionText = v
        }
    }

    func refreshLiveStats() {
        guard let engine else { return }
        let s = Settings.shared
        let count = engine.props.filter { $0.kind == .snowman }.count
        if count != snowmanCount { snowmanCount = count }
        if engine.lowPower != isLowPower { isLowPower = engine.lowPower }
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
        if s.campfireOn != campfireOn {
            campfireOn = s.campfireOn
            actions.updateStatusIcon()
        }
    }

    func setSnowOn(_ on: Bool) {
        snowOn = on
        guard let engine else { return }
        Settings.shared.snowOn = on
        engine.updateRate()
        actions.updateStatusIcon()
    }

    func setIntensity(_ value: Intensity) {
        intensity = value
        if !snowOn { snowOn = true }
        guard let engine else { return }
        Settings.shared.intensity = value
        if !Settings.shared.snowOn { Settings.shared.snowOn = true }
        engine.updateRate()
        actions.updateStatusIcon()
    }

    func setWindOn(_ on: Bool) {
        windOn = on
        guard let engine else { return }
        Settings.shared.windOn = on
        engine.updateMouseMoveMonitor()
    }

    func setWindStrength(_ value: Int) {
        windStrength = value
        if !windOn { setWindOn(true) }
        guard engine != nil else { return }
        Settings.shared.windStrength = value
    }

    func setShakeOn(_ on: Bool) {
        shakeOn = on
        guard engine != nil else { return }
        Settings.shared.shakeOn = on
    }

    func setShakeStrength(_ value: ShakeStrength) {
        shakeStrength = value
        if !shakeOn { setShakeOn(true) }
        guard engine != nil else { return }
        Settings.shared.shakeStrength = value
    }

    func setMeltOn(_ on: Bool) {
        meltOn = on
        guard let engine else { return }
        Settings.shared.meltOn = on
        engine.applySettings()
    }

    func setMeltSpeed(_ value: Int) {
        meltSpeed = value
        if !meltOn {
            meltOn = true
            if let engine {
                Settings.shared.meltOn = true
                Settings.shared.meltSpeed = value
                engine.lastMelt = engine.clock()
                engine.applySettings()
            }
            return
        }
        guard let engine else { return }
        Settings.shared.meltSpeed = value
        engine.lastMelt = engine.clock()
    }

    func setCampfireOn(_ on: Bool) {
        campfireOn = on
        guard let engine else { return }
        Settings.shared.campfireOn = on
        engine.applySettings()
        actions.updateStatusIcon()
    }

    func setSnowmenOn(_ on: Bool) {
        snowmenOn = on
        guard let engine else { return }
        Settings.shared.snowmenOn = on
        engine.applySettings()
        snowmanCount = engine.props.filter { $0.kind == .snowman }.count
    }

    func setAutoPlow(_ on: Bool) {
        autoPlow = on
        guard engine != nil else { return }
        Settings.shared.autoPlow = on
    }

    func setFlakesOnTop(_ on: Bool) {
        flakesOnTop = on
        guard let engine else { return }
        Settings.shared.flakesOnTop = on
        engine.applySettings()
    }

    func setHideInFullscreen(_ on: Bool) {
        hideInFullscreen = on
        guard let engine else { return }
        Settings.shared.hideInFullscreen = on
        engine.applySettings()
    }

    func setBatteryMode(_ mode: BatteryMode) {
        batteryMode = mode
        guard let engine else { return }
        Settings.shared.batteryMode = mode
        engine.updatePower()
        isLowPower = engine.lowPower
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard on != launchAtLogin else { return }
        actions.toggleLogin()
        if engine != nil {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = on
        }
    }

    func setAutoUpdateOn(_ on: Bool) {
        guard updaterConfigured else { return }
        autoUpdateOn = on
        updater?.automaticallyChecksForUpdates = on
    }

    func triggerPlow() {
        flashTile("plow")
        engine?.startPlow()
    }

    func triggerSpawnSnowman() {
        flashTile("spawn")
        guard let engine else { return }
        engine.spawnDemoSnowmen()
        snowmanCount = engine.props.filter { $0.kind == .snowman }.count
    }

    func triggerClearSnow() {
        flashTile("clear")
        guard let engine else { return }
        engine.clearSnow()
        snowmanCount = 0
    }

    func requestDockAccess() {
        actions.closePopover()
        actions.requestDockAccess()
    }

    func checkForUpdates() {
        actions.closePopover()
        actions.checkForUpdates()
    }

    func quit() {
        actions.quit()
    }

    private func flashTile(_ id: String) {
        tileResetWork?.cancel()
        activeTileID = id
        let work = DispatchWorkItem { [weak self] in
            self?.activeTileID = nil
        }
        tileResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    var intensityShortTitle: String {
        switch intensity {
        case .light: return "가랑눈"
        case .normal: return "보통 눈"
        case .heavy: return "많은 눈"
        case .blizzard: return "폭설"
        }
    }

    var statusSubtitle: String {
        if campfireOn {
            return "모닥불 모드 켜짐 · 가까이 가면 녹아요"
        }
        var parts: [String] = []
        parts.append(snowOn ? "\(intensityShortTitle) 내리는 중" : "눈 내림 멈춤")
        if snowmanCount > 0 { parts.append("눈사람 \(snowmanCount)") }
        if isLowPower { parts.append("절전") }
        return parts.joined(separator: " · ")
    }
}

private func safeSymbol(_ candidates: String...) -> String {
    for name in candidates {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
    }
    return "sparkles"
}

private extension Color {
    static let winterBlue = Color(red: 0.16, green: 0.53, blue: 0.96)
    static let winterDeepBlue = Color(red: 0.10, green: 0.36, blue: 0.86)
    static let emberOrange = Color(red: 0.98, green: 0.46, blue: 0.12)
    static let emberRed = Color(red: 0.90, green: 0.24, blue: 0.10)
    static let shakeIndigo = Color(red: 0.38, green: 0.38, blue: 0.94)
    static let meltCyan = Color(red: 0.12, green: 0.72, blue: 0.88)
    static let snowmanTeal = Color(red: 0.12, green: 0.70, blue: 0.68)
    static let plowAmber = Color(red: 0.96, green: 0.58, blue: 0.10)
    static let layerPurple = Color(red: 0.66, green: 0.34, blue: 0.92)
    static let leafGreen = Color(red: 0.20, green: 0.76, blue: 0.42)
    static let clearRose = Color(red: 0.92, green: 0.32, blue: 0.36)
    static let screenSlate = Color(red: 0.28, green: 0.48, blue: 0.85)
}

private struct FallbackGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let offscreen: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let baseFill: AnyShapeStyle = offscreen
            ? AnyShapeStyle(Color(white: isDark ? 0.14 : 0.98).opacity(isDark ? 0.80 : 0.84))
            : AnyShapeStyle(.ultraThinMaterial)
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(baseFill)
            )
            .overlay(
                Group {
                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(isDark ? 0.58 : 0.48))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.22 : 0.55),
                                Color.primary.opacity(isDark ? 0.10 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

private extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false, useFallback: Bool = false) -> some View {
        if !useFallback, #available(macOS 26.0, *) {
            let tinted = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            let glass = interactive ? tinted.interactive() : tinted
            self.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.modifier(FallbackGlassCard(cornerRadius: cornerRadius, tint: tint, offscreen: useFallback))
        }
    }
}

struct MenuPopoverView: View {
    static let contentWidth: CGFloat = 342
    private static let cornerRadius: CGFloat = 24

    @ObservedObject var model: MenuModel
    var useFallbackGlass: Bool = false
    var scrollHeight: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var dividerColor: Color { Color.primary.opacity(isDark ? 0.12 : 0.08) }

    var body: some View {
        Group {
            if let scrollHeight {
                ScrollView { settingsContent }
                    .frame(height: scrollHeight)
            } else {
                settingsContent
            }
        }
        .frame(width: Self.contentWidth)
        .glassSurface(cornerRadius: Self.cornerRadius, useFallback: useFallbackGlass)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroHeader
            quickActionsRow
            sectionDivider
            sectionBlock(title: "효과 · 인터랙션") {
                effectRows
            }
            sectionDivider
            sectionBlock(title: "화면 · 시스템") {
                systemRows
            }
            if !model.axTrusted {
                accessibilityBanner
            }
            sectionDivider
            footerBar
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 0.75)
    }

    private var heroHeader: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                heroBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MacSnow")
                            .font(.system(size: 14, weight: .semibold))
                        Text("v\(model.versionText)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(isDark ? 0.13 : 0.075))
                            )
                    }
                    Text(model.statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(model.campfireOn ? .emberOrange : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                PillSwitch(
                    isOn: Binding(get: { model.snowOn }, set: { model.setSnowOn($0) }),
                    tint: .winterBlue,
                    title: "눈 내리기",
                    size: .regular
                )
            }

            intensityBar
        }
    }

    private var heroBadge: some View {
        let symbol = model.campfireOn ? "flame.fill" : "snowflake"
        let colors: [Color] = if model.campfireOn {
            [.emberOrange, .emberRed]
        } else if model.snowOn {
            [.winterBlue, .winterDeepBlue]
        } else {
            [Color.secondary.opacity(0.45), Color.secondary.opacity(0.30)]
        }
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .shadow(color: (model.campfireOn ? Color.emberOrange : (model.snowOn ? Color.winterBlue : .clear)).opacity(0.28),
                        radius: 5, y: 2)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var intensityBar: some View {
        let items: [(Intensity, String)] = [
            (.light, "가랑눈"),
            (.normal, "보통"),
            (.heavy, "많이"),
            (.blizzard, "폭설")
        ]
        return HStack(spacing: 3) {
            ForEach(items, id: \.0.rawValue) { level, title in
                let selected = model.intensity == level
                Button {
                    model.setIntensity(level)
                } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundColor(selected ? .white : (model.snowOn ? .primary : .secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color.winterBlue.opacity(model.snowOn ? 1 : 0.45) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.14 : 0.065))
        )
    }

    private var quickActionsRow: some View {
        let plowSymbol = safeSymbol("wind.snow", "bus.fill", "car.fill")
        return HStack(spacing: 6) {
            QuickTile(
                id: "campfire",
                title: "모닥불",
                symbol: "flame.fill",
                tint: .emberOrange,
                activeTint: .emberOrange,
                isActive: model.campfireOn,
                hoveredID: $model.hoveredID
            ) {
                model.setCampfireOn(!model.campfireOn)
            }
            QuickTile(
                id: "plow",
                title: "Dock 제설",
                symbol: plowSymbol,
                tint: .plowAmber,
                activeTint: .plowAmber,
                isActive: model.activeTileID == "plow",
                hoveredID: $model.hoveredID
            ) {
                model.triggerPlow()
            }
            QuickTile(
                id: "spawn",
                title: "눈사람",
                symbol: "snowman",
                useSnowmanGlyph: true,
                tint: .winterBlue,
                activeTint: .winterBlue,
                isActive: model.activeTileID == "spawn",
                hoveredID: $model.hoveredID
            ) {
                model.triggerSpawnSnowman()
            }
            QuickTile(
                id: "clear",
                title: "눈 치우기",
                symbol: "trash",
                tint: .clearRose,
                activeTint: .clearRose,
                isActive: model.activeTileID == "clear",
                hoveredID: $model.hoveredID
            ) {
                model.triggerClearSnow()
            }
        }
    }

    private func sectionBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            content()
        }
    }

    @ViewBuilder
    private var effectRows: some View {
        SettingRow(icon: "wind", iconColor: .winterBlue, title: "마우스 바람") {
            MiniChoicePill(
                options: [(0, "약"), (1, "중"), (2, "강")],
                selected: model.windStrength,
                enabled: model.windOn,
                tint: .winterBlue
            ) { model.setWindStrength($0) }
            SwitchControl(isOn: Binding(get: { model.windOn }, set: { model.setWindOn($0) }), tint: .winterBlue, title: "마우스 바람")
        }
        SettingRow(icon: "arrow.left.and.right", iconColor: .shakeIndigo, title: "창 흔들어 털기") {
            MiniChoicePill(
                options: [(0, "약"), (1, "중"), (2, "강")],
                selected: model.shakeStrength.rawValue,
                enabled: model.shakeOn,
                tint: .shakeIndigo
            ) { model.setShakeStrength(ShakeStrength(rawValue: $0) ?? .normal) }
            SwitchControl(isOn: Binding(get: { model.shakeOn }, set: { model.setShakeOn($0) }), tint: .shakeIndigo, title: "창 흔들어 털기")
        }
        SettingRow(icon: "drop.fill", iconColor: .meltCyan, title: "녹기 · 고드름") {
            MiniChoicePill(
                options: [(0, "느림"), (1, "보통"), (2, "빠름")],
                selected: model.meltSpeed,
                enabled: model.meltOn,
                tint: .meltCyan
            ) { model.setMeltSpeed($0) }
            SwitchControl(isOn: Binding(get: { model.meltOn }, set: { model.setMeltOn($0) }), tint: .meltCyan, title: "녹기 · 고드름")
        }
        SettingRow(icon: "snowman", useSnowmanGlyph: true, iconColor: .snowmanTeal, title: "눈사람 만들기", subtitle: "제목줄 클릭 · 굴리기") {
            SwitchControl(isOn: Binding(get: { model.snowmenOn }, set: { model.setSnowmenOn($0) }), tint: .snowmanTeal, title: "눈사람 만들기")
        }
        SettingRow(icon: safeSymbol("bus.fill", "car.fill"), iconColor: .plowAmber, title: "제설차 자동") {
            SwitchControl(isOn: Binding(get: { model.autoPlow }, set: { model.setAutoPlow($0) }), tint: .plowAmber, title: "제설차 자동")
        }
    }

    @ViewBuilder
    private var systemRows: some View {
        SettingRow(icon: "square.stack.3d.up.fill", iconColor: .layerPurple, title: "눈송이 창 위로") {
            SwitchControl(isOn: Binding(get: { model.flakesOnTop }, set: { model.setFlakesOnTop($0) }), tint: .layerPurple, title: "눈송이 창 위로")
        }
        SettingRow(icon: safeSymbol("rectangle.inset.filled", "macwindow"), iconColor: .screenSlate, title: "전체화면에서 숨기기") {
            SwitchControl(isOn: Binding(get: { model.hideInFullscreen }, set: { model.setHideInFullscreen($0) }), tint: .winterBlue, title: "전체화면에서 숨기기")
        }
        SettingRow(icon: "leaf.fill", iconColor: .leafGreen, title: "배터리 절약") {
            MiniChoicePill(
                options: [(0, "자동"), (1, "항상"), (2, "끄기")],
                selected: model.batteryMode.rawValue,
                enabled: true,
                tint: .leafGreen
            ) { model.setBatteryMode(BatteryMode(rawValue: $0) ?? .auto) }
        }
        SettingRow(icon: "power", iconColor: .winterBlue, title: "로그인 시 자동 실행") {
            SwitchControl(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }), tint: .winterBlue, title: "로그인 시 자동 실행")
        }
        SettingRow(icon: safeSymbol("arrow.triangle.2.circlepath", "arrow.clockwise"), iconColor: .snowmanTeal, title: "자동 업데이트") {
            if model.updaterConfigured {
                SwitchControl(isOn: Binding(get: { model.autoUpdateOn }, set: { model.setAutoUpdateOn($0) }), tint: .snowmanTeal, title: "자동 업데이트")
            } else {
                Text("키 없음")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(isDark ? 0.12 : 0.065))
                    )
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.plowAmber.opacity(isDark ? 0.28 : 0.22))
                    .frame(width: 26, height: 26)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.plowAmber)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Dock 크기 정확히 맞추기")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("손쉬운 사용 권한 필요")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                model.requestDockAccess()
            } label: {
                Text("권한 허용")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Color.plowAmber))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.plowAmber.opacity(isDark ? 0.20 : 0.13))
        )
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            FooterButton(
                id: "update",
                title: "업데이트 확인…",
                symbol: "arrow.clockwise",
                destructive: false,
                enabled: model.canCheckForUpdates,
                hoveredID: $model.hoveredID
            ) {
                model.checkForUpdates()
            }
            Spacer()
            FooterButton(
                id: "quit",
                title: "종료",
                symbol: "power",
                destructive: true,
                enabled: true,
                hoveredID: $model.hoveredID
            ) {
                model.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct SnowmanGlyph: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                    .fill(color)
                    .frame(width: w * 0.44, height: h * 0.17)
                    .position(x: w * 0.5, y: h * 0.11)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: w * 0.64, height: h * 0.08)
                    .position(x: w * 0.5, y: h * 0.21)
                Circle()
                    .fill(color)
                    .frame(width: w * 0.36, height: w * 0.36)
                    .position(x: w * 0.5, y: h * 0.38)
                Circle()
                    .fill(color)
                    .frame(width: w * 0.54, height: w * 0.54)
                    .position(x: w * 0.5, y: h * 0.72)
            }
        }
    }
}

private struct QuickTile: View {
    let id: String
    let title: String
    let symbol: String
    var useSnowmanGlyph: Bool = false
    let tint: Color
    let activeTint: Color
    let isActive: Bool
    @Binding var hoveredID: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var hovered: Bool { hoveredID == id }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if useSnowmanGlyph {
                    SnowmanGlyph(color: isActive ? .white : tint)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(isActive ? .white : tint)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? .white : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isActive ? activeTint.opacity(0.92)
                            : (hovered ? tint.opacity(isDark ? 0.24 : 0.14)
                                : Color.primary.opacity(isDark ? 0.10 : 0.05))
                    )
            )
            .shadow(color: isActive ? activeTint.opacity(0.26) : .clear, radius: 5, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID) }
    }
}

private struct SettingRow<Control: View>: View {
    let icon: String
    var useSnowmanGlyph: Bool = false
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: () -> Control

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(isDark ? 0.26 : 0.15))
                    .frame(width: 24, height: 24)
                if useSnowmanGlyph {
                    SnowmanGlyph(color: iconColor)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(iconColor)
                }
            }
            VStack(alignment: .leading, spacing: 0.5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                control()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4.5)
    }
}

private struct PillSwitch: View {
    enum Size { case regular, mini }
    @Binding var isOn: Bool
    let tint: Color
    let title: String
    var size: Size = .mini

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private var width: CGFloat { size == .regular ? 36 : 29 }
    private var height: CGFloat { size == .regular ? 20 : 16 }
    private var knob: CGFloat { height - 4 }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? tint : Color.primary.opacity(isDark ? 0.22 : 0.16))
                    .frame(width: width, height: height)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: Color.black.opacity(0.22), radius: 1.2, y: 0.6)
                    .padding(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "켜짐" : "꺼짐"))
    }
}

private struct SwitchControl: View {
    @Binding var isOn: Bool
    let tint: Color
    let title: String

    var body: some View {
        PillSwitch(isOn: $isOn, tint: tint, title: title, size: .mini)
    }
}

private struct MiniChoicePill: View {
    let options: [(Int, String)]
    let selected: Int
    let enabled: Bool
    let tint: Color
    let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { value, label in
                let active = selected == value
                Button {
                    onSelect(value)
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: active ? .semibold : .medium))
                        .foregroundColor(active ? .white : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6.5)
                        .frame(height: 18)
                        .background(
                            Capsule(style: .continuous)
                                .fill(active ? tint.opacity(enabled ? 0.92 : 0.42) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.13 : 0.065))
        )
        .opacity(enabled ? 1 : 0.55)
    }
}

private struct FooterButton: View {
    let id: String
    let title: String
    let symbol: String
    let destructive: Bool
    let enabled: Bool
    @Binding var hoveredID: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var hovered: Bool { hoveredID == id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(
                !enabled ? .secondary.opacity(0.5)
                    : (destructive && hovered ? .white : .primary.opacity(0.85))
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        destructive && hovered && enabled ? Color.clearRose.opacity(0.88)
                            : (hovered && enabled ? Color.primary.opacity(isDark ? 0.16 : 0.10)
                                : Color.primary.opacity(isDark ? 0.09 : 0.05))
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .onHover { inside in hoveredID = inside ? id : (hoveredID == id ? nil : hoveredID) }
    }
}

@MainActor
enum PopoverRenderer {
    static func renderAll(to outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        renderOne(name: "popover-light.png", dark: false, campfire: false, axTrusted: false, outDir: outDir)
        renderOne(name: "popover-dark.png", dark: true, campfire: false, axTrusted: true, outDir: outDir)
        renderOne(name: "popover-campfire.png", dark: true, campfire: true, axTrusted: true, outDir: outDir)
        print("rendered popovers -> \(outDir)")
    }

    private static func renderOne(name: String, dark: Bool, campfire: Bool, axTrusted: Bool, outDir: String) {
        let model = MenuModel.preview(campfire: campfire, axTrusted: axTrusted)
        let backdrop = ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.08, green: 0.11, blue: 0.24), Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.10, green: 0.14, blue: 0.26)]
                    : [Color(red: 0.72, green: 0.84, blue: 0.96), Color(red: 0.86, green: 0.91, blue: 0.98), Color(red: 0.78, green: 0.85, blue: 0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(RadialGradient(
                    colors: [(campfire ? Color.emberOrange : Color.winterBlue).opacity(dark ? 0.38 : 0.26), .clear],
                    center: .center, startRadius: 10, endRadius: 160
                ))
                .frame(width: 320, height: 320)
                .offset(x: -90, y: -150)
            Circle()
                .fill(RadialGradient(
                    colors: [(campfire ? Color.emberRed : Color.meltCyan).opacity(dark ? 0.30 : 0.22), .clear],
                    center: .center, startRadius: 10, endRadius: 150
                ))
                .frame(width: 300, height: 300)
                .offset(x: 110, y: 120)
        }
        let rootView = ZStack {
            backdrop
            MenuPopoverView(model: model, useFallbackGlass: true)
        }
        .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let width = MenuPopoverView.contentWidth
        let fitting = hosting.fittingSize
        let size = NSSize(width: width, height: ceil(fitting.height))
        hosting.frame = NSRect(origin: .zero, size: size)

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.appearance = hosting.appearance
        win.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
