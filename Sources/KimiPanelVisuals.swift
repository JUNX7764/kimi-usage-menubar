import AppKit

// MARK: - 面板视觉原语（只懂几何与颜色，不理解额度/用量业务，可离线断言）
// 借鉴 GlmUsage 五项精修的实现形态：小型绘图原语 + 纯过渡状态 + 胶囊视图，
// 主文件只保留绘制调用与组装。所有新文件只声明类型，无 top-level main。

enum KimiPanelVisuals {
    /// 每日柱顶部微圆角：普通柱仅视觉顶边 1.5pt 圆角、底部齐平；零值日保持 2pt 直线短柱。
    static let dailyCornerRadius: CGFloat = 1.5
    /// 额度周期单根额度槽（对齐 GLMUsage v1.5.3）：居中 12pt 灰槽 + 底部已用填充。
    static let slotWidth: CGFloat = 12
    static let slotCornerRadius: CGFloat = 2

    /// 视觉顶边两角圆角的矩形路径（常规 AppKit 画布，y 向上，顶边 = maxY）。
    /// 弧段角度全部递增：appendArc 不带 clockwise: 参数时恒为逆时针（递增角），
    /// 递减角度会画出 270° 凹弧啃掉角部（历史 bug：填充顶边中间看似凸起）。
    /// 半径按矩形宽高自动钳制，短柱不越界；零尺寸返回空路径。
    static func topRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return NSBezierPath(rect: rect) }
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                       radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                       radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.close()
        return path
    }

    /// 视觉底边两角圆角的矩形路径（y 向上，底边 = minY）。
    /// 供 isFlipped 画布使用：flipped 坐标里同一几何渲染为视觉顶边圆角（额度槽填充顶边）。
    /// 角部弧角度同样全部递增（180→270→360），避免逆时针约束下的凹弧。
    static func bottomRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return NSBezierPath(rect: rect) }
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r),
                       radius: r, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r),
                       radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    /// 用量简析每日柱：零值日保持直线短柱，正常柱顶边微圆（画布 y 向上，顶边 = maxY）。
    static func dailyBarPath(in rect: NSRect, isZero: Bool) -> NSBezierPath {
        isZero ? NSBezierPath(rect: rect)
               : topRoundedPath(in: rect, radius: dailyCornerRadius)
    }

    /// 额度周期单槽几何（GLM v1.5.3 同构）：一根居中 12pt 上限槽；
    /// 填充从槽底（视觉底边）按已用比例生长，与槽同宽同基线。
    /// `plotArea` 为槽所在绘图区（isFlipped 画布内 y 向下：minY = 视觉顶、maxY = 视觉底基线）。
    /// 0%、缺失或非有限比例不产生填充（nil），不用最小高度伪造已用面积；
    /// 比例钳制在 0...100，标签与 VoiceOver 里的精确数值不受几何影响。
    static func slotBar(in plotArea: NSRect, usedPercent: Double)
        -> (track: NSRect, fill: NSRect?) {
        let width = min(slotWidth, max(0, plotArea.width - 4))
        let track = NSRect(x: plotArea.midX - width / 2, y: plotArea.minY,
                           width: width, height: plotArea.height)
        guard usedPercent.isFinite, usedPercent > 0, !track.isEmpty else {
            return (track, nil)
        }
        let fraction = CGFloat(min(100, max(0, usedPercent)) / 100)
        let fillHeight = track.height * fraction
        // 填充贴视觉底边生长：占用 [track.maxY - fillHeight, track.maxY]。
        let fill = NSRect(x: track.minX, y: track.maxY - fillHeight,
                          width: track.width, height: fillHeight)
        return (track, fill)
    }
}

// MARK: - 涨跌胶囊（比较条数值的 soft chip）

/// 比较条「日环比 / 7 日环比」数值胶囊：同色系低透明底 + 现有方向语义色文字。
/// 不理解比较口径——文本与颜色都由调用方给；AX 由外层比较条承担，胶囊不重复读数。
final class KimiDeltaChip: NSView {
    let valueLabel: NSTextField
    private let foreground: NSColor

    /// 固有尺寸：文本宽 + 左右各 6pt 内边距，固定 20pt 高（30pt 比较条内居中）。
    static func size(for text: String, font: NSFont) -> NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12,
               height: 20)
    }

    /// 窄面板回退判定：说明文字 + 间隔 + 胶囊超过半条宽则两行排布，数字不允许截断。
    static func requiresTwoRows(halfWidth: CGFloat, captionWidth: CGFloat,
                                chipWidth: CGFloat, spacing: CGFloat = 5) -> Bool {
        captionWidth + spacing + chipWidth > halfWidth
    }

    init(text: String, font: NSFont, foreground: NSColor) {
        self.foreground = foreground
        valueLabel = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        valueLabel.font = font
        valueLabel.textColor = foreground
        valueLabel.maximumNumberOfLines = 1
        valueLabel.cell?.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        Self.size(for: valueLabel.stringValue, font: valueLabel.font!)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.layer?.backgroundColor = self.foreground
                .withAlphaComponent(dark ? 0.16 : 0.10).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 数值过渡（320ms cubic ease-out，纯状态可离线断言）

/// 选中日数值的过渡状态：0.320s cubic ease-out；快速重定向从当前显示值续走（不排队、不归零）；
/// 首次显示/无变化/非有限值不播放。时间轴用单调时钟（ProcessInfo.systemUptime），不用 wall clock。
struct KimiTokenTransition {
    static let duration: TimeInterval = 0.320
    private(set) var display: Double?
    private(set) var target: Double?
    private(set) var isAnimating = false
    private var from = 0.0
    private var startedAt: TimeInterval = 0

    /// `animated: false`（首显、重开、无变化、系统减少动态效果）与数值缺失（nil/非有限/负值）
    /// 都即时到位；缺失会取消进行中的动画并显示为 nil。
    mutating func set(_ raw: Double?, at now: TimeInterval, animated: Bool) {
        _ = advance(at: now)
        guard let value = raw, value.isFinite, value >= 0 else {
            display = nil; target = nil; isAnimating = false
            return
        }
        target = value
        guard animated, let current = display, current != value else {
            display = value; isAnimating = false
            return
        }
        from = current; startedAt = now; isAnimating = true
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Double? {
        guard isAnimating, let target else { return display }
        let t = min(1, max(0, (now - startedAt) / Self.duration))
        display = from + (target - from) * (1 - pow(1 - t, 3))
        if t >= 1 { display = target; isAnimating = false }
        return display
    }
}

/// 每日图选中行数值标签：交互切换时 320ms 过渡；首显/重建/缺数即时；AX 与 tooltip 始终报目标准确值。
/// 只在交互路径播放：面板重建经 `animated: false` 同步，不做后台常驻动画；窗口移除立即收尾。
final class KimiAnimatedTokenLabel: NSTextField {
    private let format: (Double) -> String
    private var transition = KimiTokenTransition()
    private var timer: Timer?
    private var motionObserver: NSObjectProtocol?
    private var exactText = ""
    var isAnimatingForTest: Bool { transition.isAnimating }

    init(format: @escaping (Double) -> String) {
        self.format = format
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = 1
        cell?.lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self?.finishImmediately()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been supported") }
    deinit {
        timer?.invalidate()
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    /// `animated` 只在窗口已挂载且未开启减少动态效果时生效；nil = 数据不足（即时、弱化色）。
    func setTokens(_ tokens: Double?, animated: Bool) {
        timer?.invalidate()
        timer = nil
        let allowed = animated && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transition.set(tokens, at: ProcessInfo.processInfo.systemUptime, animated: allowed)
        exactText = transition.target.map(format) ?? "数据不足"
        render()
        guard transition.isAnimating else { return }
        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.transition.advance(at: ProcessInfo.processInfo.systemUptime)
            self.render()
            if !self.transition.isAnimating {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    private func render() {
        if let display = transition.display {
            stringValue = format(display)
            textColor = .labelColor
        } else {
            stringValue = "数据不足"
            textColor = .secondaryLabelColor
        }
    }

    private func finishImmediately() {
        setTokens(transition.target, animated: false)
    }

    override func accessibilityValue() -> String? { exactText }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishImmediately() }
    }
}
