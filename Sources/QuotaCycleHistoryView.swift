import AppKit
import Foundation

// 额度周期回顾卡片（Task 6：静态翻页 + 选中详情；完整鼠标/键盘/状态保持归 Task 7）。
// PanelUI 是 KimiUsage.swift 的 private，本文件用自有的少量 AppKit 布局工厂，
// 不扩大主文件访问权限；模块不读磁盘、网络或凭据，只吃 typed QuotaCycleSnapshot。

// MARK: - 展示模型（纯函数，可离线断言）

enum QuotaCycleVisualMetrics {
    static let canvasHeight: CGFloat = 96
    static let barAreaHeight: CGFloat = 66
    /// 单根额度槽（对齐 GLMUsage v1.5.3，仅色系不同）：灰槽 + 底部已用填充。
    static let trackFillAlpha: CGFloat = 0.25
    static let fillAlpha: CGFloat = 0.72
    static let fillAlphaHighlighted: CGFloat = 1.0
    /// 柔和列底层级（对齐 GLM：悬停 0.11 / 固定选中 0.08 / 当前轮 0.05）。
    static let hoverTintAlpha: CGFloat = 0.11
    static let selectedTintAlpha: CGFloat = 0.08
    static let currentTintAlpha: CGFloat = 0.05
}

/// 一根双柱组对应的一个可展示轮次。
struct QuotaCycleItem: Equatable {
    let id: UUID
    let startLabel: String     // 精简开始日期 MM/DD
    let usedPercent: Double    // 0...100 原始观测值（非四舍五入）
    let usedText: String       // 顶部主数值与逐轮百分比
    let isCurrent: Bool
    let detailTitle: String    // 第一行：日期区间 · 结束/进行状态
    let detailValue: String    // 第二行：已用与剩余（百分比，非 Token）
    let lastObservedAt: Date?  // 最后观测时间（VoiceOver 与 tooltip 完整读值）
    /// VoiceOver 完整选中详情：开始精度、结束状态、已用、剩余与最后观测时间。
    let accessibilityText: String
}

enum QuotaCyclePresentation {
    static let pageSize = 6

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        return formatter
    }()

    private static func fullLabel(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return fullFormatter.string(from: date)
    }

    private static func dayLabel(_ date: Date?) -> String {
        guard let date else { return "--" }
        return dayFormatter.string(from: date)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// 全部轮次（已结束 + 当前），按时间旧→新排列；当前轮永远在最后（最新一屏最右）。
    /// 待确认候选不产生新的已确认历史柱，只体现在当前轮详情文案里。
    static func items(from snapshot: QuotaCycleSnapshot) -> [QuotaCycleItem] {
        var items: [QuotaCycleItem] = []
        for record in snapshot.closed {
            items.append(makeClosedItem(record))
        }
        if let current = snapshot.current {
            items.append(makeCurrentItem(current, pending: snapshot.pendingTransition != nil))
        }
        return items
    }

    /// 某一屏的轮次（旧→新）。pageOffset 0 = 最新一屏。
    static func page(_ items: [QuotaCycleItem], pageOffset: Int) -> [QuotaCycleItem] {
        guard !items.isEmpty else { return [] }
        let maxPage = max(0, (items.count - 1) / pageSize)
        let page = min(max(0, pageOffset), maxPage)
        let upper = max(0, items.count - page * pageSize)
        let lower = max(0, upper - pageSize)
        return Array(items[lower..<upper])
    }

    // 窗口化浏览的范围/条数计算在 QuotaCycleBrowser 上（纯整数，可离线断言）。

    static func pageCount(_ items: [QuotaCycleItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize + 1
    }

    private static func startPrecision(_ record: QuotaCycleRecord) -> String {
        switch record.startKind {
        case .inferred: return "开始时间为推算"
        case .observedTransition: return "开始时间已观测"
        case .afterGap: return "开始时间未知（观测缺口之后）"
        }
    }

    private static func makeClosedItem(_ record: QuotaCycleRecord) -> QuotaCycleItem {
        let start = dayLabel(record.inferredStartAt ?? record.firstObservedAt)
        let used = record.lastObservedUsedPercent
        let remaining = record.remainingAtLastObservation
        let title: String
        let value: String
        let spokenEnd: String
        switch record.end {
        case .natural:
            // 正常到期：到期时刻 = 接口 reset，非约值。
            title = "\(start)–\(dayLabel(record.expectedResetAt)) · 正常到期"
            value = record.wasObservedFull
                ? "最后观测已用 100% · 已用满"
                : "最后观测已用 \(percent(used)) · 到期未用约 \(percent(remaining))"
            spokenEnd = "正常到期"
        case .windowChanged:
            // 异常窗口变化：边界只有观测区间，标（约）；原因未知，不归因。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 窗口变化（原因未知）"
            value = "最后观测已用 \(percent(used)) · 窗口变化前剩余约 \(percent(remaining))"
            spokenEnd = "窗口变化，原因未知"
        case .gap:
            // 观测缺口：不计算确定的到期未用百分比。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 观测缺口"
            value = "最后观测已用 \(percent(used)) · 观测缺口，剩余无法判定"
            spokenEnd = "观测缺口，剩余无法判定"
        case .none:
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约）"
            value = "最后观测已用 \(percent(used))"
            spokenEnd = "结束状态未知"
        }
        let accessibility = "\(startPrecision(record))，\(spokenEnd)，已用 \(percent(used))"
            + (record.end == .gap ? "" : "，剩余 \(percent(remaining))")
            + "，最后观测时间 \(fullLabel(record.lastObservedAt))"
        return QuotaCycleItem(
            id: record.id, startLabel: start, usedPercent: used,
            usedText: percent(used),
            isCurrent: false, detailTitle: title, detailValue: value,
            lastObservedAt: record.lastObservedAt, accessibilityText: accessibility)
    }

    private static func makeCurrentItem(_ record: QuotaCycleRecord, pending: Bool) -> QuotaCycleItem {
        let start = dayLabel(record.inferredStartAt ?? record.firstObservedAt)
        let used = record.lastObservedUsedPercent
        let remaining = record.remainingAtLastObservation
        // 首轮开始时间为 reset 反推，标（约）；待确认候选只改文案，不加历史柱。
        let title = pending
            ? "\(start)–至今（约） · 窗口变化待确认"
            : "\(start)–至今（约） · 当前轮次"
        let value = pending
            ? "最后观测已用 \(percent(used)) · 当前剩余 \(percent(remaining))"
            : "已用 \(percent(used)) · 当前剩余 \(percent(remaining))"
        let spokenState = pending ? "窗口变化待确认" : "当前轮次进行中"
        let accessibility = "\(startPrecision(record))，\(spokenState)，已用 \(percent(used))"
            + "，当前剩余 \(percent(remaining))"
            + "，最后观测时间 \(fullLabel(record.lastObservedAt))"
        return QuotaCycleItem(
            id: record.id, startLabel: start, usedPercent: used,
            usedText: percent(used),
            isCurrent: true, detailTitle: title, detailValue: value,
            lastObservedAt: record.lastObservedAt, accessibilityText: accessibility)
    }
}

// MARK: - 图表画布（双柱：灰 = 上限 100%，Kimi 动态蓝 = 已用比例）
// 完整详情只经画布原生延迟 tooltip 呈现（真实命中区域有效），不再有图内即时浮层。

final class QuotaCycleChartCanvas: NSView {
    struct GroupFrame: Equatable {
        var slot: CGRect    // 整列命中区（翻页对齐、日期/百分比都按列）
        var track: CGRect   // 灰色上限槽（恒为 100% 高度，居中 12pt）
        var fill: CGRect?   // 蓝色已用填充（0–100%，从槽底生长）；0% 不画（不伪造面积）
    }
    struct LabelFrame: Equatable {
        var date: CGRect
        var percent: CGRect
    }

    private static let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var items: [QuotaCycleItem] = []
    /// 固定选择（控制器持久状态）；高亮与详情按「悬停 ?? 固定 ?? 本屏最新」显示。
    private(set) var fallbackID: UUID?
    /// 悬停临时查看的轮次；鼠标移出后清空并恢复固定选择。不发网络、不写盘。
    private(set) var hoveredID: UUID?
    /// 点击固定选择回调（控制器记录稳定 ID）。
    var onPin: ((UUID) -> Void)?
    /// 悬停变化回调（nil = 移出，恢复固定选择展示）。
    var onHover: ((UUID?) -> Void)?
    /// 左右方向键逐组（可能跨页/触发扩展，由控制器裁决）。
    var onStep: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// 预览断言：完整详情经画布原生延迟 tooltip 承载（真实命中区域有效），无图内浮层子视图。
    var toolTipForPreview: String? { toolTip }
    var canvasSubviewCountForPreview: Int { subviews.count }
    /// 预览断言：点击固定后画布可键盘逐组，但不绘制整幅系统焦点外框。
    var focusRingTypeForPreview: NSFocusRingType { focusRingType }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // 点击固定后画布是第一响应者（方向键逐组），但不绘制整幅焦点外框；
        // 键盘当前列只由品牌蓝日期/百分比表达，不叠加底板或基线。
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 当前实际高亮的轮次（悬停优先）。
    var effectiveID: UUID? { hoveredID ?? fallbackID }

    private func effectiveItem() -> QuotaCycleItem? {
        items.first { $0.id == effectiveID } ?? items.last
    }

    /// 完整详情只经画布原生延迟 tooltip 呈现；tooltip 设在画布自身，命中区域真实有效，
    /// 并随「悬停 ?? 固定 ?? 本屏最新」联动。
    private func syncTooltip(to item: QuotaCycleItem?) {
        toolTip = item.map { "\($0.detailTitle)\n\($0.detailValue)" }
    }

    override var acceptsFirstResponder: Bool { true }

    var groupFramesForTest: [GroupFrame] { groupFrames(in: bounds) }
    var labelFramesForTest: [LabelFrame] { labelFrames(in: bounds) }

    private func labelFrames(in rect: CGRect) -> [LabelFrame] {
        zip(items, groupFrames(in: rect)).map { item, group in
            func textFrame(_ text: String, font: NSFont, y: CGFloat) -> CGRect {
                let size = (text as NSString).size(withAttributes: [.font: font])
                let slotX = min(max(group.slot.midX - size.width / 2, group.slot.minX),
                                group.slot.maxX - size.width)
                let x = min(max(rect.minX, slotX), max(rect.minX, rect.maxX - size.width))
                return CGRect(x: x, y: y, width: size.width, height: size.height)
            }
            let date = textFrame(item.startLabel, font: Self.dateFont,
                                 y: QuotaCycleVisualMetrics.barAreaHeight + 3)
            let percent = textFrame(item.usedText, font: Self.percentFont, y: date.maxY + 2)
            return LabelFrame(date: date, percent: percent)
        }
    }

    private func groupFrames(in rect: CGRect) -> [GroupFrame] {
        guard !items.isEmpty else { return [] }
        let slotWidth = rect.width / CGFloat(QuotaCyclePresentation.pageSize)
        let contentWidth = slotWidth * CGFloat(items.count)
        let originX = rect.maxX - contentWidth
        return items.enumerated().map { index, item in
            let slot = CGRect(x: originX + CGFloat(index) * slotWidth, y: 0,
                              width: slotWidth, height: QuotaCycleVisualMetrics.canvasHeight)
            // 单根额度槽：绘图区 = 列内 barArea 高度；填充按该轮自身上限归一化，从槽底（视觉底边）生长
            let plotArea = NSRect(x: slot.minX, y: 0, width: slot.width,
                                  height: QuotaCycleVisualMetrics.barAreaHeight)
            let geometry = KimiPanelVisuals.slotBar(in: plotArea, usedPercent: item.usedPercent)
            return GroupFrame(slot: slot, track: geometry.track, fill: geometry.fill)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = groupFrames(in: bounds)
        let effective = effectiveID
        guard !frames.isEmpty else { return }
        // 100% 刻度（对齐 GLM v1.5.3：图区左上角，9pt secondary；先画，槽体绘制在其上）
        ("100%" as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: [
            .font: Self.dateFont, .foregroundColor: NSColor.secondaryLabelColor
        ])
        for (index, (frame, item)) in zip(frames, items).enumerated() {
            let hovered = item.id == hoveredID
            let pinned = item.id == fallbackID && hoveredID == nil
            // 柔和列底层级（GLM v1.5.3 同款）：悬停 0.11 / 固定选中 0.08 / 当前轮 0.05；
            // 圆角底只铺柱区（含 2pt 下探），日期/百分比行不铺。
            if hovered || pinned || item.isCurrent {
                let tint: CGFloat = hovered ? QuotaCycleVisualMetrics.hoverTintAlpha
                    : pinned ? QuotaCycleVisualMetrics.selectedTintAlpha
                    : QuotaCycleVisualMetrics.currentTintAlpha
                PanelAccent.codex.color.withAlphaComponent(tint).setFill()
                NSBezierPath(roundedRect: NSRect(x: frame.slot.minX + 1, y: 0,
                    width: max(0, frame.slot.width - 2),
                    height: QuotaCycleVisualMetrics.barAreaHeight + 2),
                    xRadius: 4, yRadius: 4).fill()
            }
            let trackPath = NSBezierPath(roundedRect: frame.track,
                xRadius: KimiPanelVisuals.slotCornerRadius,
                yRadius: KimiPanelVisuals.slotCornerRadius)
            NSColor.secondaryLabelColor.withAlphaComponent(QuotaCycleVisualMetrics.trackFillAlpha).setFill()
            trackPath.fill()
            if let fill = frame.fill {
                // 填充与灰槽同位同宽，被槽路径裁剪成同一轮廓；视觉顶边微圆（isFlipped：顶边 = minY）。
                // 填充透明度对齐 GLM：选中/悬停 1.0，其余 0.72。
                NSGraphicsContext.saveGraphicsState()
                trackPath.addClip()
                PanelAccent.codex.color.withAlphaComponent(
                    hovered || pinned ? QuotaCycleVisualMetrics.fillAlphaHighlighted
                    : QuotaCycleVisualMetrics.fillAlpha).setFill()
                // isFlipped 画布：底边圆角路径渲染为视觉顶边圆角（GLM v1.5.3 同款顶边微圆）
                KimiPanelVisuals.bottomRoundedPath(
                    in: fill, radius: KimiPanelVisuals.slotCornerRadius).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // 选中强化日期和百分比字色（GLM 同款：品牌蓝仅用于选中/悬停）。
            let labels = labelFrames(in: bounds)[index]
            (item.startLabel as NSString).draw(at: labels.date.origin, withAttributes: [
                .font: Self.dateFont,
                .foregroundColor: item.id == effective ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            (item.usedText as NSString).draw(at: labels.percent.origin, withAttributes: [
                .font: Self.percentFont,
                .foregroundColor: item.id == effective
                    ? PanelAccent.codex.color : NSColor.labelColor
            ])
        }
    }

    // MARK: 命中、悬停与键盘（整列命中；悬停临时查看，点击固定，方向键逐组）

    private func itemIndex(atX x: CGFloat) -> Int? {
        let frames = groupFrames(in: bounds)
        return frames.firstIndex(where: { $0.slot.contains(CGPoint(x: x, y: bounds.midY)) })
    }

    override func updateTrackingAreas() { installTrackingArea() }
    // 面板重建、Popover 关开切换：不依赖 AppKit 时机，入窗/布局时主动重挂
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 面板重建、Popover 关开切换：不依赖 AppKit 时机，入窗/布局时主动重挂
        if window == nil { hoveredID = nil }
        installTrackingArea()
    }
    override func layout() {
        super.layout()
        installTrackingArea()
    }
    private func installTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old); trackingArea = nil }
        guard window != nil else { return }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        // 进入图表即高亮光标所在列（用户在列间移动主要靠 mouseMoved，
        // 从图外直接进入同样给出即时详情）。
        updateHover(at: convert(event.locationInWindow, from: nil).x)
    }
    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil).x)
    }
    private func updateHover(at x: CGFloat) {
        guard let index = itemIndex(atX: x) else { return }
        let id = items[index].id
        guard id != hoveredID else { return }
        hoveredID = id
        onHover?(id)
        let item = items[index]
        // 完整详情经画布原生延迟 tooltip 呈现（真实命中区域有效），不再弹图内大浮层
        syncTooltip(to: item)
        setAccessibilityValue(item.accessibilityText)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        // 移出图表：tooltip 与顶部主数值恢复固定选择（默认本屏最新一轮）。
        guard hoveredID != nil else { return }
        hoveredID = nil
        onHover?(nil)
        syncTooltip(to: effectiveItem())
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let index = itemIndex(atX: x) else { return }
        hoveredID = nil
        onHover?(nil)
        window?.makeFirstResponder(self)   // 点击后即可用方向键继续逐组（无外框，仅列级高亮）
        onPin?(items[index].id)
        syncTooltip(to: items[index])      // 点击固定后 tooltip/详情对应固定项
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep?(-1)   // ← 向更早一组
        case 124: onStep?(1)    // → 向更新一组
        default: super.keyDown(with: event)
        }
    }

    /// 重建后由上层注入固定选择（nil = 本屏最新一轮为默认）；tooltip 跟随固定项。
    func setFallback(_ id: UUID?) {
        fallbackID = id ?? items.last?.id
        setAccessibilityValue(fallbackItem()?.accessibilityText ?? "")
        if hoveredID == nil { syncTooltip(to: fallbackItem()) }
        needsDisplay = true
    }

    func fallbackItem() -> QuotaCycleItem? {
        items.first { $0.id == fallbackID } ?? items.last
    }
}

// MARK: - 板块视图

/// 板块渲染状态：全部由控制器按 QuotaCycleBrowser 计算后注入；视图只持有悬停这类
/// 转瞬即逝的临时状态，翻页/固定选择跨重建保持不变，不存在双状态。
struct QuotaCycleViewState: Equatable {
    /// 本屏可见轮次（旧→新）。
    var visibleItems: [QuotaCycleItem]
    /// 当前页码（0 = 已载入窗口内最新一屏）。
    var pageOffset: Int
    /// 已载入窗口内的总页数。
    var pageCount: Int
    /// 窗口之外是否还有未载入的更早记录（决定「更早记录」是否可用）。
    var hasMoreBeyondWindow: Bool
    /// 固定选择（nil = 默认本屏最新一轮）。
    var pinnedID: UUID?
}

/// 额度周期回顾：标题行 + 图例行（图例/更早/翻页）+ 双柱图 + 选中状态行。
/// 结构对齐 CodexUsage/GLMUsage（除色系）：无大主数值，图例与翻页在图上方一行，
/// 图下仅一行选中轮次窗口/状态；完整已用/剩余只在 tooltip 与 VoiceOver。
/// 交互整列命中：悬停临时详情、点击固定、方向键逐组跨页。
final class QuotaCycleHistorySectionView: NSView {
    private let canvas = QuotaCycleChartCanvas()
    private let statusLabel = QuotaCycleWidget.label("", size: 11, color: .secondaryLabelColor,
                                                    wrapping: false)
    private let pagerStack = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
    private let pageLabel = QuotaCycleWidget.label("", size: 10, color: .secondaryLabelColor,
                                                   wrapping: false, monospacedDigits: true)
    private let backButton: NSButton
    private let forwardButton: NSButton
    /// 「更早记录」：只在已载入的最旧页且窗口外还有记录时出现，每次扩展 12 条。
    private let earlierButton = QuotaCycleWidget.textLinkButton("更早记录")

    let viewState: QuotaCycleViewState
    /// 测试断言用：当前展示详情对应的轮次（悬停 ?? 固定 ?? 本屏最新）。
    private(set) var displayedItem: QuotaCycleItem?
    /// 预览断言用：图下状态行文本（与选中联动）。
    var statusTextForPreview: String? {
        statusLabel.stringValue.isEmpty ? nil : statusLabel.stringValue
    }

    init(model: QuotaCycleSnapshot, state: QuotaCycleViewState, expanded: Bool,
         target: AnyObject, action: Selector,
         onPin: @escaping (UUID) -> Void,
         onPage: @escaping (Int) -> Void,
         onExtendWindow: @escaping () -> Void,
         onStep: @escaping (Int) -> Void) {
        viewState = state
        onPageCallback = onPage
        onExtendCallback = onExtendWindow
        let back = QuotaCycleWidget.pagerButton(symbol: "chevron.left")
        let forward = QuotaCycleWidget.pagerButton(symbol: "chevron.right")
        backButton = back
        forwardButton = forward
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let root = QuotaCycleWidget.stack(spacing: 6)
        let toggle = QuotaCycleWidget.disclosureToggle(expanded: expanded, section: "额度周期回顾",
                                                       target: target, action: action)
        // 标题行只留折叠箭头；翻页/更早下沉到图例行（对齐 CodexUsage/GLMUsage）
        QuotaCycleWidget.addFullWidth(
            QuotaCycleWidget.cardHeader(icon: "clock.arrow.circlepath", title: "额度周期回顾",
                                        trailing: [toggle]), to: root)

        if expanded {
            if !model.loaded {
                // 作用域切换/读取中：中性占位，绝不显示上一账号数据
                let placeholder = QuotaCycleWidget.label("读取历史…", size: 11,
                                                         color: .secondaryLabelColor)
                QuotaCycleWidget.addFullWidth(placeholder, to: root)
            } else if state.visibleItems.isEmpty {
                // 空态：从首次成功读取后开始记录；不伪造历史柱
                let placeholder = QuotaCycleWidget.label(
                    "从首次成功读取 7 天额度后开始记录", size: 11, color: .secondaryLabelColor)
                QuotaCycleWidget.addFullWidth(placeholder, to: root)
            } else {
                // 图例行（对齐 GLM v1.5.3）：左=「已用 / 距上限」文字图例，右=更早+翻页
                let legendRow = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 10)
                legendRow.addArrangedSubview(QuotaCycleWidget.label("已用 / 距上限", size: 10,
                    color: .secondaryLabelColor, wrapping: false))
                legendRow.addArrangedSubview(QuotaCycleWidget.spacer())
                // 行高固定：翻页/更早的单页隐藏不得改变卡片高度（短历史等高约束依赖）
                legendRow.heightAnchor.constraint(equalToConstant: 20).isActive = true

                // 「更早记录」只在已载入的最旧一页且窗口外还有记录时出现（隐藏避免高度漂移）；
                // 翻页控件沿用单页隐藏规则（对齐部署版行为）
                earlierButton.isHidden = true
                earlierButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
                if state.pageCount > 1 {
                    pagerStack.addArrangedSubview(back)
                    pagerStack.addArrangedSubview(pageLabel)
                    pagerStack.addArrangedSubview(forward)
                    pageLabel.alignment = .center
                    legendRow.addArrangedSubview(pagerStack)
                }
                legendRow.addArrangedSubview(earlierButton)
                QuotaCycleWidget.addFullWidth(legendRow, to: root)

                canvas.heightAnchor.constraint(
                    equalToConstant: QuotaCycleVisualMetrics.canvasHeight).isActive = true
                canvas.setAccessibilityLabel("额度周期回顾柱状图，每根灰色额度槽为上限 100%，槽内蓝色填充为已用比例")
                QuotaCycleWidget.addFullWidth(canvas, to: root)
                // 图下状态行（对齐兄弟 App）：显示「悬停 ?? 固定 ?? 本屏最新」轮次的窗口/状态一句话
                QuotaCycleWidget.addFullWidth(statusLabel, to: root)

                canvas.items = state.visibleItems
                canvas.onHover = { [weak self] id in self?.updateSelectionDisplay(hovering: id) }
                canvas.onPin = { [weak self] id in
                    guard let self else { return }
                    onPin(id)   // 控制器记录稳定 ID（不重建，视图就地更新）
                    self.updateSelectionDisplay(hovering: nil, pinnedOverride: id)
                }
                canvas.onStep = onStep
                back.target = self
                back.action = #selector(pageBack)
                forward.target = self
                forward.action = #selector(pageForward)
                earlierButton.target = self
                earlierButton.action = #selector(extendWindow)

                pageLabel.stringValue = Self.pageLabelText(state)
                backButton.isEnabled = state.pageCount > 1 && state.pageOffset < state.pageCount - 1
                forwardButton.isEnabled = state.pageCount > 1 && state.pageOffset > 0
                // 「更早记录」只在已载入的最旧页且窗口外还有记录时可用。
                let atOldestLoadedPage = state.pageOffset >= state.pageCount - 1
                earlierButton.isHidden = !(state.hasMoreBeyondWindow && atOldestLoadedPage)
                earlierButton.setAccessibilityLabel("更早记录：再载入 12 个周期")
                backButton.setAccessibilityLabel("更早 6 个周期")
                forwardButton.setAccessibilityLabel("更新 6 个周期")
                updateSelectionDisplay(hovering: nil)
            }
            if model.persistenceFailed {
                // 写盘失败：保留内存观测，明确提示未落盘（warning 语义色与日图同款橙）
                let notice = QuotaCycleWidget.label("历史未保存：本进程继续记录，下次成功写入后自动清除",
                                                    size: 11, color: RemainingColorTier.orange.color())
                QuotaCycleWidget.addFullWidth(notice, to: root)
            }
        }
        addSubview(root)
        QuotaCycleWidget.pin(root, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented")
    }

    static func pageLabelText(_ state: QuotaCycleViewState) -> String {
        guard state.pageCount > 1 else { return "共 \(state.visibleItems.count) 个" }
        return state.pageOffset == 0 ? "最近 \(QuotaCyclePresentation.pageSize) 个"
            : "第 \(state.pageOffset + 1)/\(state.pageCount) 页"
    }

    // MARK: 翻页、扩展与选择显示

    private var onPageCallback: ((Int) -> Void)?
    private var onExtendCallback: (() -> Void)?

    @objc private func pageBack() { onPageCallback?(+1) }

    @objc private func pageForward() { onPageCallback?(-1) }

    @objc private func extendWindow() { onExtendCallback?() }

    /// 主数值、状态条与高亮统一跟随「悬停 ?? 固定 ?? 本屏最新」。
    private func updateSelectionDisplay(hovering hoveredID: UUID?,
                                        pinnedOverride: UUID? = nil) {
        let pinned = pinnedOverride ?? viewState.pinnedID
        let effectiveID = hoveredID
            ?? pinned
            ?? viewState.visibleItems.last?.id
        canvas.setFallback(pinned)
        displayedItem = viewState.visibleItems.first { $0.id == effectiveID }
            ?? viewState.visibleItems.last
        if let item = displayedItem {
            statusLabel.stringValue = item.detailTitle
            statusLabel.toolTip = item.detailValue
            canvas.setAccessibilityValue(item.accessibilityText)
        }
        canvas.needsDisplay = true
    }
}

// MARK: - 本文件自有的小型布局工厂（PanelUI 为 private，不扩大其访问权限）

private enum QuotaCycleWidget {
    static func stack(orientation: NSUserInterfaceLayoutOrientation = .vertical,
                      alignment: NSLayoutConstraint.Attribute = .width,
                      spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = orientation
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func label(_ text: String, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      wrapping: Bool = true,
                      monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = wrapping ? 0 : 1
        label.cell?.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// 与主文件 PanelUI.cardHeader 同款：14pt 图标 + 13pt semibold 标题 + trailing。
    static func cardHeader(icon: String, title: String, trailing: [NSView] = []) -> NSStackView {
        let header = stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        let imageView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
        imageView.contentTintColor = PanelAccent.codex.color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(imageView)
        header.addArrangedSubview(label(title, size: 13, weight: .semibold, wrapping: false))
        header.addArrangedSubview(spacer())
        for view in trailing { header.addArrangedSubview(view) }
        return header
    }

    /// 与主文件 PanelUI.disclosureToggle 同款折叠箭头（chevron.up/down，secondary 色）。
    static func disclosureToggle(expanded: Bool, section: String,
                                 target: AnyObject?, action: Selector?) -> NSButton {
        let name = expanded ? "chevron.up" : "chevron.down"
        let image = NSImage(systemSymbolName: name,
                            accessibilityDescription: expanded ? "折叠\(section)" : "展开\(section)")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        let toggle = NSButton(image: image ?? NSImage(), target: target, action: action)
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = expanded ? "折叠" : "展开"
        toggle.setAccessibilityLabel(expanded ? "折叠\(section)" : "展开\(section)")
        toggle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return toggle
    }

    /// 文字按钮（「更早记录」，对齐 GLM v1.5.3 同位置文字样式）。
    static func textLinkButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    static func pagerButton(symbol: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return button
    }
}
