import AppKit
import Foundation

// 额度周期回顾卡片（Task 6：静态翻页 + 选中详情；完整鼠标/键盘/状态保持归 Task 7）。
// PanelUI 是 KimiUsage.swift 的 private，本文件用自有的少量 AppKit 布局工厂，
// 不扩大主文件访问权限；模块不读磁盘、网络或凭据，只吃 typed QuotaCycleSnapshot。

// MARK: - 展示模型（纯函数，可离线断言）

/// 一根双柱组对应的一个可展示轮次。
struct QuotaCycleItem: Equatable {
    let id: UUID
    let startLabel: String     // 精简开始日期 MM/DD
    let usedPercent: Double    // 0...100 原始观测值（非四舍五入）
    let isCurrent: Bool
    let detailTitle: String    // 第一行：日期区间 · 结束/进行状态
    let detailValue: String    // 第二行：已用与剩余（百分比，非 Token）
}

enum QuotaCyclePresentation {
    static let pageSize = 6

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

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

    static func pageCount(_ items: [QuotaCycleItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize + 1
    }

    private static func makeClosedItem(_ record: QuotaCycleRecord) -> QuotaCycleItem {
        let start = dayLabel(record.inferredStartAt ?? record.firstObservedAt)
        let used = record.lastObservedUsedPercent
        let remaining = record.remainingAtLastObservation
        let title: String
        let value: String
        switch record.end {
        case .natural:
            // 正常到期：到期时刻 = 接口 reset，非约值。
            title = "\(start)–\(dayLabel(record.expectedResetAt)) · 正常到期"
            value = record.wasObservedFull
                ? "最后观测已用 100% · 已用满"
                : "最后观测已用 \(percent(used)) · 到期未用约 \(percent(remaining))"
        case .windowChanged:
            // 异常窗口变化：边界只有观测区间，标（约）；原因未知，不归因。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 窗口变化（原因未知）"
            value = "最后观测已用 \(percent(used)) · 窗口变化前剩余约 \(percent(remaining))"
        case .gap:
            // 观测缺口：不计算确定的到期未用百分比。
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约） · 观测缺口"
            value = "最后观测已用 \(percent(used)) · 观测缺口，剩余无法判定"
        case .none:
            title = "\(start)–\(dayLabel(record.boundaryUpper))（约）"
            value = "最后观测已用 \(percent(used))"
        }
        return QuotaCycleItem(
            id: record.id, startLabel: start, usedPercent: used,
            isCurrent: false, detailTitle: title, detailValue: value)
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
        return QuotaCycleItem(
            id: record.id, startLabel: start, usedPercent: used,
            isCurrent: true, detailTitle: title, detailValue: value)
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
    var selectedID: UUID?
    /// 点击选择回调（Task 7 再接悬停/键盘/跨页方向键与状态保持）
    var onSelect: ((UUID) -> Void)?

    private let barGap: CGFloat = 2
    private let maxBarWidth: CGFloat = 13

    var groupFramesForTest: [GroupFrame] { groupFrames(in: bounds) }

    private func groupFrames(in rect: CGRect) -> [GroupFrame] {
        guard !items.isEmpty else { return [] }
        let count = CGFloat(items.count)
        let slotWidth = rect.width / count
        let barTop: CGFloat = 1
        let barHeight = max(2, rect.height - barTop)
        let barWidth = min(maxBarWidth, max(3, (slotWidth - 8) / 2 - barGap / 2))
        let pairWidth = barWidth * 2 + barGap
        return items.enumerated().map { index, item in
            let slot = CGRect(x: rect.minX + CGFloat(index) * slotWidth, y: 0,
                              width: slotWidth, height: rect.height)
            let pairX = slot.midX - pairWidth / 2
            let usedHeight = item.usedPercent <= 0
                ? 2                                   // 有记录的零用量 = 低基线，不当缺失
                : max(2, barHeight * CGFloat(item.usedPercent / 100))
            return GroupFrame(
                slot: slot,
                cap: CGRect(x: pairX, y: barTop, width: barWidth, height: barHeight),
                used: CGRect(x: pairX + barWidth + barGap, y: barTop,
                             width: barWidth, height: min(barHeight, usedHeight)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = groupFrames(in: bounds)
        // 基线：1pt 全宽发丝线（与日图同款）
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard !frames.isEmpty else { return }
        for (frame, item) in zip(frames, items) {
            if item.id == selectedID {
                // 选中组浅色高亮：整列圆角底，深浅色/三种背景下都可辨
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: frame.slot.insetBy(dx: 1, dy: 0),
                             xRadius: 5, yRadius: 5).fill()
            }
            // 灰柱 = 额度上限 100%（secondaryLabelColor 动态色，读感弱化）
            NSColor.secondaryLabelColor.withAlphaComponent(item.id == selectedID ? 0.4 : 0.28).setFill()
            frame.cap.fill()
            // 蓝柱 = 已用比例（Kimi 动态深蓝，复用 PanelAccent.codex）
            PanelAccent.codex.color
                .withAlphaComponent(item.id == selectedID ? 1 : 0.78).setFill()
            frame.used.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let frames = groupFrames(in: bounds)
        guard let index = frames.firstIndex(where: { $0.slot.contains(CGPoint(x: x, y: bounds.midY)) }) else { return }
        selectedID = items[index].id
        onSelect?(items[index].id)
        needsDisplay = true
    }

    func select(_ id: UUID?) {
        selectedID = id
        needsDisplay = true
    }
}

// MARK: - 固定详情（两行、固定高度）

final class QuotaCycleDetailView: NSView {
    /// 两行固定详情（计划 §Task6：详情两行 32–36pt）；高度固定，窄屏/短历史下不变。
    static let fixedHeight: CGFloat = 36

    private let titleLabel: NSTextField
    private let valueLabel: NSTextField

    override init(frame frameRect: NSRect) {
        titleLabel = QuotaCycleWidget.label("", size: 12, weight: .semibold, wrapping: false)
        valueLabel = QuotaCycleWidget.label("", size: 11, color: .secondaryLabelColor, wrapping: false)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        let stack = QuotaCycleWidget.stack(spacing: 1)
        stack.alignment = .leading
        QuotaCycleWidget.addFullWidth(titleLabel, to: stack)
        QuotaCycleWidget.addFullWidth(valueLabel, to: stack)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: Self.fixedHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(item: QuotaCycleItem) {
        titleLabel.stringValue = item.detailTitle
        valueLabel.stringValue = item.detailValue
        toolTip = "\(item.detailTitle)\n\(item.detailValue)"
        setAccessibilityLabel("\(item.detailTitle)，\(item.detailValue)")
    }
}

// MARK: - 板块视图

/// 额度周期回顾：header（图标+标题+折叠箭头）+ 图例/翻页 + 双柱图 + 日期行 + 固定详情 + 提示。
/// 展开目标高度约 190pt；翻页/选择状态为视图内临时状态，跨重建保持由 Task 7 接管。
final class QuotaCycleHistorySectionView: NSView {
    private let canvas = QuotaCycleChartCanvas()
    private let detail = QuotaCycleDetailView()
    private let datesRow = QuotaCycleWidget.stack(orientation: .horizontal, spacing: 0)
    private let pagerStack = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
    private let pageLabel = QuotaCycleWidget.label("", size: 10, color: .secondaryLabelColor,
                                                   wrapping: false, monospacedDigits: true)
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let bodyStack = QuotaCycleWidget.stack(spacing: 4)

    private var allItems: [QuotaCycleItem] = []
    private var pageItems: [QuotaCycleItem] = []
    private var pageOffset = 0

    init(model: QuotaCycleSnapshot, expanded: Bool, target: AnyObject, action: Selector) {
        let back = QuotaCycleWidget.pagerButton(symbol: "chevron.left")
        let forward = QuotaCycleWidget.pagerButton(symbol: "chevron.right")
        backButton = back
        forwardButton = forward
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let root = QuotaCycleWidget.stack(spacing: 4)
        let toggle = QuotaCycleWidget.disclosureToggle(expanded: expanded, section: "额度周期回顾",
                                                       target: target, action: action)
        QuotaCycleWidget.addFullWidth(
            QuotaCycleWidget.cardHeader(icon: "clock.arrow.circlepath", title: "额度周期回顾",
                                        trailing: [toggle]), to: root)

        if expanded {
            allItems = QuotaCyclePresentation.items(from: model)
            if !model.loaded {
                // 作用域切换/读取中：中性占位，绝不显示上一账号数据
                let placeholder = QuotaCycleWidget.label("读取历史…", size: 11,
                                                         color: .secondaryLabelColor)
                QuotaCycleWidget.addFullWidth(placeholder, to: root)
            } else if allItems.isEmpty {
                // 空态：从首次成功读取后开始记录；不伪造历史柱
                let placeholder = QuotaCycleWidget.label(
                    "从首次成功读取 7 天额度后开始记录", size: 11, color: .secondaryLabelColor)
                QuotaCycleWidget.addFullWidth(placeholder, to: root)
            } else {
                // 图例（上限/已用）居左，翻页控件居右
                let legend = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
                legend.addArrangedSubview(QuotaCycleWidget.legendSwatch(
                    color: NSColor.secondaryLabelColor.withAlphaComponent(0.4)))
                legend.addArrangedSubview(QuotaCycleWidget.label("上限 100%", size: 10,
                                                                 color: .secondaryLabelColor, wrapping: false))
                legend.addArrangedSubview(QuotaCycleWidget.legendSwatch(color: PanelAccent.codex.color))
                legend.addArrangedSubview(QuotaCycleWidget.label("已用", size: 10,
                                                                 color: .secondaryLabelColor, wrapping: false))
                pagerStack.addArrangedSubview(back)
                pagerStack.addArrangedSubview(pageLabel)
                pagerStack.addArrangedSubview(forward)
                pageLabel.alignment = .center
                let controls = QuotaCycleWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
                controls.addArrangedSubview(legend)
                controls.addArrangedSubview(QuotaCycleWidget.spacer())
                controls.addArrangedSubview(pagerStack)
                QuotaCycleWidget.addFullWidth(controls, to: root)

                canvas.heightAnchor.constraint(equalToConstant: 72).isActive = true
                canvas.setAccessibilityLabel("额度周期回顾柱状图，每根灰色柱为额度上限 100%，蓝色柱为已用比例")
                QuotaCycleWidget.addFullWidth(canvas, to: root)
                datesRow.distribution = .fillEqually
                QuotaCycleWidget.addFullWidth(datesRow, to: root)
                QuotaCycleWidget.addFullWidth(detail, to: root)
                canvas.onSelect = { [weak self] id in self?.selectItem(id) }
                back.target = self
                back.action = #selector(pageBack)
                forward.target = self
                forward.action = #selector(pageForward)
                showPage(0)
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

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 翻页与选择（Task 6：静态控件可用；跨页方向键/悬停/状态保持归 Task 7）

    @objc private func pageBack() { showPage(pageOffset + 1) }

    @objc private func pageForward() { showPage(pageOffset - 1) }

    private func showPage(_ offset: Int) {
        pageOffset = max(0, min(offset, max(0, QuotaCyclePresentation.pageCount(allItems) - 1)))
        pageItems = QuotaCyclePresentation.page(allItems, pageOffset: pageOffset)
        canvas.items = pageItems
        // 默认选中本屏最新一轮（最右）
        selectItem(pageItems.last?.id)
        rebuildDates()
        let totalPages = QuotaCyclePresentation.pageCount(allItems)
        // 控件常驻（隐藏会让图例行塌缩、卡片高度随页数漂移）：单页时禁用并显示实际条数。
        pageLabel.stringValue = totalPages <= 1 ? "共 \(allItems.count) 个"
            : (pageOffset == 0 ? "最近 6 个" : "第 \(pageOffset + 1)/\(totalPages) 页")
        backButton.isEnabled = totalPages > 1 && pageOffset < totalPages - 1
        forwardButton.isEnabled = totalPages > 1 && pageOffset > 0
        backButton.setAccessibilityLabel("更早 6 个周期")
        forwardButton.setAccessibilityLabel("更新 6 个周期")
    }

    private func selectItem(_ id: UUID?) {
        canvas.select(id)
        guard let id, let item = pageItems.first(where: { $0.id == id }) else { return }
        detail.configure(item: item)
        for (view, item) in zip(datesRow.arrangedSubviews, pageItems) {
            (view as? NSTextField)?.textColor = item.id == id ? .labelColor : .secondaryLabelColor
        }
    }

    private func rebuildDates() {
        for view in datesRow.arrangedSubviews { datesRow.removeArrangedSubview(view); view.removeFromSuperview() }
        for item in pageItems {
            let label = QuotaCycleWidget.label(item.startLabel, size: 10,
                                               color: .secondaryLabelColor, wrapping: false,
                                               monospacedDigits: true)
            label.alignment = .center
            datesRow.addArrangedSubview(label)
        }
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
        swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return swatch
    }
}

private final class QuotaCycleSwatch: NSView {
    var swatchColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = swatchColor.cgColor
            layer?.cornerRadius = 2
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
