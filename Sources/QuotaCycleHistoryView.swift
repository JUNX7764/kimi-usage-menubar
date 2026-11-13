import AppKit
import Foundation

// 额度周期回顾卡片（Task 6：静态翻页 + 选中详情；完整鼠标/键盘/状态保持归 Task 7）。
// PanelUI 是 KimiUsage.swift 的 private，本文件用自有的少量 AppKit 布局工厂，
// 不扩大主文件访问权限；模块不读磁盘、网络或凭据，只吃 typed QuotaCycleSnapshot。

// MARK: - 展示模型（纯函数，可离线断言）

enum QuotaCycleVisualMetrics {
    static let summaryHeight: CGFloat = 28
    static let canvasHeight: CGFloat = 61
    static let barAreaHeight: CGFloat = 46
    static let barWidth: CGFloat = 6
    static let barGap: CGFloat = 3
    static let barCornerRadius: CGFloat = 1
    static let stripHeight: CGFloat = 32
    static let stripCornerRadius: CGFloat = 6
    static let selectionFillAlpha: CGFloat = 0.07
    static let capFillAlpha: CGFloat = 0.16
}

/// 一根双柱组对应的一个可展示轮次。
struct QuotaCycleItem: Equatable {
    let id: UUID
    let startLabel: String     // 精简开始日期 MM/DD
    let usedPercent: Double    // 0...100 原始观测值（非四舍五入）
    let usedText: String       // 顶部主数值
    let statusText: String     // 底部状态条左栏
    let remainingText: String  // 底部状态条右栏
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
        let statusText: String
        let remainingText: String
        switch record.end {
        case .natural:
            // 正常到期：到期时刻 = 接口 reset，非约值。
            title = "\(start)–\(dayLabel(record.expectedResetAt)) · 正常到期"
            value = record.wasObservedFull
                ? "最后观测已用 100% · 已用满"
                : "最后观测已用 \(percent(used)) · 到期未用约 \(percent(remaining))"
            spokenEnd = "正常到期"
            statusText = "正常到期"
            remainingText = record.wasObservedFull ? "已用满" : "到期未用约 \(percent(remaining))"
        case .windowChanged:
            // 异常窗口变化：边界只有观测区间，标（约）；原因未知，不归因。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 窗口变化（原因未知）"
            value = "最后观测已用 \(percent(used)) · 窗口变化前剩余约 \(percent(remaining))"
            spokenEnd = "窗口变化，原因未知"
            statusText = "窗口变化"
            remainingText = "变化前剩余约 \(percent(remaining))"
        case .gap:
            // 观测缺口：不计算确定的到期未用百分比。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 观测缺口"
            value = "最后观测已用 \(percent(used)) · 观测缺口，剩余无法判定"
            spokenEnd = "观测缺口，剩余无法判定"
            statusText = "观测缺口"
            remainingText = "剩余无法判定"
        case .none:
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约）"
            value = "最后观测已用 \(percent(used))"
            spokenEnd = "结束状态未知"
            statusText = "结束未知"
            remainingText = "最后剩余约 \(percent(remaining))"
        }
        let accessibility = "\(startPrecision(record))，\(spokenEnd)，已用 \(percent(used))"
            + (record.end == .gap ? "" : "，剩余 \(percent(remaining))")
            + "，最后观测时间 \(fullLabel(record.lastObservedAt))"
        return QuotaCycleItem(
            id: record.id, startLabel: start, usedPercent: used,
            usedText: percent(used), statusText: statusText, remainingText: remainingText,
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
            statusText: pending ? "窗口变化待确认" : "进行中",
            remainingText: "当前剩余 \(percent(remaining))",
            isCurrent: true, detailTitle: title, detailValue: value,
            lastObservedAt: record.lastObservedAt, accessibilityText: accessibility)
    }
}

// MARK: - 图内详情浮层

private final class QuotaCycleHoverLabel: NSView {
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 6
    private let lineSpacing: CGFloat = 2
    private let dateFont = NSFont.systemFont(ofSize: 10)
    private let valueFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private var date = ""
    private var value = ""
    var stringValue: String { "\(date)\n\(value)" }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(date: String, value: String) {
        self.date = date
        self.value = value
        toolTip = stringValue
        needsDisplay = true
    }

    private func size(of text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    func fitToContent() {
        let dateSize = size(of: date, font: dateFont)
        let valueSize = size(of: value, font: valueFont)
        frame.size = NSSize(
            width: ceil(max(dateSize.width, valueSize.width)) + horizontalInset * 2,
            height: ceil(dateSize.height + valueSize.height + lineSpacing) + verticalInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedWhite: dark ? 0.20 : 0.92, alpha: 0.96)
        }
        let bubble = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        background.setFill()
        bubble.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        bubble.lineWidth = 0.5
        bubble.stroke()
        let dateSize = size(of: date, font: dateFont)
        let valueSize = size(of: value, font: valueFont)
        let width = max(0, bounds.width - horizontalInset * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (date as NSString).draw(
            with: NSRect(x: horizontalInset, y: verticalInset, width: width, height: dateSize.height),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: dateFont, .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph])
        (value as NSString).draw(
            with: NSRect(x: horizontalInset, y: verticalInset + dateSize.height + lineSpacing,
                         width: width, height: valueSize.height),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
    }
}

// MARK: - 图表画布（双柱：灰 = 上限 100%，Kimi 动态蓝 = 已用比例）

final class QuotaCycleChartCanvas: NSView {
    struct GroupFrame: Equatable {
        var slot: CGRect    // 整列命中区（选择高亮、翻页对齐都按列）
        var cap: CGRect     // 灰色上限柱（恒为 100% 高度）
        var used: CGRect    // 蓝色已用柱（0–100%）
    }

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
    private let hover = QuotaCycleHoverLabel()

    var hoverVisibleForPreview: Bool { !hover.isHidden }
    var hoverTextForPreview: String { hover.stringValue }
    var hoverWithinBoundsForPreview: Bool { bounds.contains(hover.frame) }
    var hoverHitTestsForPreview: Bool { hover.hitTest(.zero) != nil }

    enum UsedBarStyle: Equatable { case filled, outlined }

    static func usedBarStyle(for item: QuotaCycleItem) -> UsedBarStyle {
        item.isCurrent ? .outlined : .filled
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hover.isHidden = true
        addSubview(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 当前实际高亮的轮次（悬停优先）。
    var effectiveID: UUID? { hoveredID ?? fallbackID }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }

    var groupFramesForTest: [GroupFrame] { groupFrames(in: bounds) }

    private func groupFrames(in rect: CGRect) -> [GroupFrame] {
        guard !items.isEmpty else { return [] }
        let slotWidth = rect.width / CGFloat(QuotaCyclePresentation.pageSize)
        let contentWidth = slotWidth * CGFloat(items.count)
        let originX = rect.minX + (rect.width - contentWidth) / 2
        let pairWidth = QuotaCycleVisualMetrics.barWidth * 2 + QuotaCycleVisualMetrics.barGap
        return items.enumerated().map { index, item in
            let slot = CGRect(x: originX + CGFloat(index) * slotWidth, y: 0,
                              width: slotWidth, height: QuotaCycleVisualMetrics.canvasHeight)
            let pairX = slot.midX - pairWidth / 2
            let minimum: CGFloat = item.isCurrent ? 3 : 2
            let usedHeight = max(minimum,
                QuotaCycleVisualMetrics.barAreaHeight * CGFloat(item.usedPercent / 100))
            return GroupFrame(
                slot: slot,
                cap: CGRect(x: pairX, y: 0,
                            width: QuotaCycleVisualMetrics.barWidth,
                            height: QuotaCycleVisualMetrics.barAreaHeight),
                used: CGRect(x: pairX + QuotaCycleVisualMetrics.barWidth
                                 + QuotaCycleVisualMetrics.barGap,
                             y: QuotaCycleVisualMetrics.barAreaHeight
                                 - min(QuotaCycleVisualMetrics.barAreaHeight, usedHeight),
                             width: QuotaCycleVisualMetrics.barWidth,
                             height: min(QuotaCycleVisualMetrics.barAreaHeight, usedHeight)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = groupFrames(in: bounds)
        let effective = effectiveID
        guard !frames.isEmpty else { return }
        for (frame, item) in zip(frames, items) {
            if item.id == effective {
                NSColor.labelColor.withAlphaComponent(QuotaCycleVisualMetrics.selectionFillAlpha).setFill()
                NSRect(x: frame.slot.minX, y: 0, width: frame.slot.width,
                       height: QuotaCycleVisualMetrics.barAreaHeight).fill()
            }
            let capPath = NSBezierPath(roundedRect: frame.cap,
                xRadius: QuotaCycleVisualMetrics.barCornerRadius,
                yRadius: QuotaCycleVisualMetrics.barCornerRadius)
            NSColor.secondaryLabelColor.withAlphaComponent(QuotaCycleVisualMetrics.capFillAlpha).setFill()
            capPath.fill()
            let usedPath = NSBezierPath(roundedRect: frame.used,
                xRadius: QuotaCycleVisualMetrics.barCornerRadius,
                yRadius: QuotaCycleVisualMetrics.barCornerRadius)
            switch Self.usedBarStyle(for: item) {
            case .filled:
                PanelAccent.codex.color.setFill()
                usedPath.fill()
            case .outlined:
                PanelAccent.codex.color.setStroke()
                usedPath.lineWidth = 1
                usedPath.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: item.id == effective ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let text = item.startLabel as NSString
            let textWidth = text.size(withAttributes: attributes).width
            let slotX = min(max(frame.slot.midX - textWidth / 2, frame.slot.minX),
                            frame.slot.maxX - textWidth)
            let x = min(max(bounds.minX, slotX), max(bounds.minX, bounds.maxX - textWidth))
            text.draw(at: NSPoint(x: x, y: 49), withAttributes: attributes)
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
        if window == nil {
            hoveredID = nil
            hover.isHidden = true
        }
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
        let frame = groupFrames(in: bounds)[index]
        hover.setText(date: item.detailTitle, value: item.detailValue)
        hover.fitToContent()
        hover.frame.size.width = min(hover.frame.width, bounds.width)
        let selectedX = frame.slot.midX
        hover.frame.origin = NSPoint(
            x: selectedX < bounds.midX ? bounds.width - hover.frame.width : 0,
            y: 0)
        hover.isHidden = false
        setAccessibilityValue(item.accessibilityText)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        // 移出图表：隐藏浮层并恢复固定选择展示。
        hover.isHidden = true
        guard hoveredID != nil else { return }
        hoveredID = nil
        onHover?(nil)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let index = itemIndex(atX: x) else { return }
        hoveredID = nil
        hover.isHidden = true
        onHover?(nil)
        window?.makeFirstResponder(self)   // 点击后即可用方向键继续逐组
        onPin?(items[index].id)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep?(-1)   // ← 向更早一组
        case 124: onStep?(1)    // → 向更新一组
        default: super.keyDown(with: event)
        }
    }

    /// 重建后由上层注入固定选择（nil = 本屏最新一轮为默认）。
    func setFallback(_ id: UUID?) {
        fallbackID = id ?? items.last?.id
        setAccessibilityValue(fallbackItem()?.accessibilityText ?? "")
        needsDisplay = true
    }

    func fallbackItem() -> QuotaCycleItem? {
        items.first { $0.id == fallbackID } ?? items.last
    }
}

// MARK: - 主数值与状态条

final class QuotaCycleSummaryView: NSView {
    private let valueLabel: NSTextField
    var displayedUsedTextForPreview: String { valueLabel.stringValue }

    override init(frame frameRect: NSRect) {
        valueLabel = QuotaCycleWidget.label("", size: 19, weight: .semibold,
            color: PanelAccent.codex.color, wrapping: false, monospacedDigits: true)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let row = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 7)
        let valueStack = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .firstBaseline, spacing: 7)
        valueStack.addArrangedSubview(valueLabel)
        valueStack.addArrangedSubview(QuotaCycleWidget.label("已用", size: 10,
            color: .secondaryLabelColor, wrapping: false))
        row.addArrangedSubview(valueStack)
        row.addArrangedSubview(QuotaCycleWidget.spacer())
        let capLegend = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 5)
        capLegend.addArrangedSubview(QuotaCycleWidget.legendSwatch(
            color: NSColor.secondaryLabelColor.withAlphaComponent(QuotaCycleVisualMetrics.capFillAlpha)))
        capLegend.addArrangedSubview(QuotaCycleWidget.label("上限 100%", size: 10,
            color: .secondaryLabelColor, wrapping: false))
        row.addArrangedSubview(capLegend)
        addSubview(row)
        QuotaCycleWidget.pin(row, to: self)
        heightAnchor.constraint(equalToConstant: QuotaCycleVisualMetrics.summaryHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: QuotaCycleItem) {
        valueLabel.stringValue = item.usedText
        toolTip = "最后观测已用 \(item.usedText)"
        setAccessibilityLabel("已用 \(item.usedText)")
    }
}

final class QuotaCycleStatusStrip: NSView {
    private let statusLabel: NSTextField
    private let remainingLabel: NSTextField
    var statusTextForPreview: String { statusLabel.stringValue }
    var remainingTextForPreview: String { remainingLabel.stringValue }

    override init(frame frameRect: NSRect) {
        statusLabel = QuotaCycleWidget.label("", size: 11, wrapping: false)
        remainingLabel = QuotaCycleWidget.label("", size: 11, weight: .semibold,
            wrapping: false, monospacedDigits: true)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = QuotaCycleVisualMetrics.stripCornerRadius
        for label in [statusLabel, remainingLabel] {
            label.alignment = .center
            label.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        let row = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
        row.addArrangedSubview(statusLabel)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(divider)
        row.addArrangedSubview(remainingLabel)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.heightAnchor.constraint(equalToConstant: 18),
            statusLabel.widthAnchor.constraint(equalTo: remainingLabel.widthAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: QuotaCycleVisualMetrics.stripHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(item: QuotaCycleItem) {
        statusLabel.stringValue = item.statusText
        remainingLabel.stringValue = item.remainingText
        toolTip = "\(item.detailTitle)\n\(item.detailValue)"
        setAccessibilityLabel(item.accessibilityText)
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

/// 额度周期回顾：标题行翻页 + 主数值 + 双柱图 + 状态条 + 提示。
/// 交互整列命中：悬停临时详情、点击固定、方向键逐组跨页。
final class QuotaCycleHistorySectionView: NSView {
    private let canvas = QuotaCycleChartCanvas()
    private let summary = QuotaCycleSummaryView()
    private let statusStrip = QuotaCycleStatusStrip()
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
        var headerTrailing: [NSView] = []
        if expanded && model.loaded && !state.visibleItems.isEmpty {
            pagerStack.addArrangedSubview(back)
            pagerStack.addArrangedSubview(pageLabel)
            pagerStack.addArrangedSubview(forward)
            pageLabel.alignment = .center
            headerTrailing.append(pagerStack)
        }
        headerTrailing.append(toggle)
        QuotaCycleWidget.addFullWidth(
            QuotaCycleWidget.cardHeader(icon: "chart.bar.fill", title: "额度周期回顾",
                                        trailing: headerTrailing), to: root)

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
                QuotaCycleWidget.addFullWidth(summary, to: root)
                canvas.heightAnchor.constraint(
                    equalToConstant: QuotaCycleVisualMetrics.canvasHeight).isActive = true
                canvas.setAccessibilityLabel("额度周期回顾柱状图，每根灰色柱为额度上限 100%，蓝色柱为已用比例")
                QuotaCycleWidget.addFullWidth(canvas, to: root)
                QuotaCycleWidget.addFullWidth(statusStrip, to: root)

                // 「更早记录」位于状态条之下、卡片内：只在已载入的最旧一页且窗口外
                // 还有未载入记录时出现（隐藏会让卡片高度漂移，故用 isHidden）。
                earlierButton.isHidden = true
                earlierButton.translatesAutoresizingMaskIntoConstraints = false
                earlierButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
                earlierButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
                let earlierRow = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 0)
                earlierRow.addArrangedSubview(QuotaCycleWidget.spacer())
                earlierRow.addArrangedSubview(earlierButton)
                earlierRow.addArrangedSubview(QuotaCycleWidget.spacer())
                QuotaCycleWidget.addFullWidth(earlierRow, to: root)

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
            summary.configure(item: item)
            statusStrip.configure(item: item)
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

    /// 文字链接式小按钮（「更早记录」）：无边框、强调色文字，hover 手型由系统按钮行为给出。
    static func textLinkButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = PanelAccent.codex.color
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: PanelAccent.codex.color
        ])
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

    static func legendSwatch(color: NSColor) -> NSView {
        let swatch = QuotaCycleSwatch(frame: .zero)
        swatch.swatchColor = color
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: QuotaCycleVisualMetrics.barWidth).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true
        return swatch
    }
}

private final class QuotaCycleSwatch: NSView {
    var swatchColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = swatchColor.cgColor
            layer?.cornerRadius = QuotaCycleVisualMetrics.barCornerRadius
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
