import AppKit
import Foundation

// MARK: - 卡片布局模型（纯 Foundation，可离线断言）
// 借鉴 GlmUsage PanelCustomization：稳定卡片 ID + order/hidden，JSON 持久化。
// 隐藏 ≠ 收起：隐藏卡数据照常获取与统计，折叠状态（usageExpanded 等）不受影响。

enum KimiPanelCardID: String, CaseIterable, Codable {
    case quota, usage, brief, history, tools

    var title: String {
        switch self {
        case .quota: return "用量进度"
        case .usage: return "用量情况"
        case .brief: return "用量简析"
        case .history: return "额度周期回顾"
        case .tools: return "工具明细"
        }
    }
}

enum KimiPanelMoveDirection {
    case up, down
    var offset: Int { self == .up ? -1 : 1 }
}

struct KimiPanelLayout: Equatable {
    private struct Stored: Codable {
        let order: [String]
        let hidden: [String]
    }

    static let defaultsKey = "panelCardLayout.v1"
    static let `default` = KimiPanelLayout(order: KimiPanelCardID.allCases, hidden: [])

    private(set) var order: [KimiPanelCardID]
    private(set) var hidden: Set<KimiPanelCardID>

    var visibleOrder: [KimiPanelCardID] { order.filter { !hidden.contains($0) } }

    func isVisible(_ id: KimiPanelCardID) -> Bool { !hidden.contains(id) }

    mutating func setVisible(_ visible: Bool, for id: KimiPanelCardID) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
    }

    mutating func move(_ id: KimiPanelCardID, direction: KimiPanelMoveDirection) {
        guard let index = order.firstIndex(of: id) else { return }
        move(id, to: index + direction.offset)
    }

    mutating func move(_ id: KimiPanelCardID, to destination: Int) {
        guard let source = order.firstIndex(of: id), !order.isEmpty else { return }
        let target = max(0, min(destination, order.count - 1))
        guard source != target else { return }
        let item = order.remove(at: source)
        order.insert(item, at: target)
    }

    /// 旧配置规范化：未知 ID 丢弃、hidden 与已知集求交；旧配置没有的新卡片按当前默认顺序
    /// 的相对位置插入（插在默认序里紧随其后的第一张已知卡之前），而不是静默丢弃或一律追加末尾。
    static func normalized(order savedOrder: [KimiPanelCardID], hidden savedHidden: Set<KimiPanelCardID>) -> Self {
        var result: [KimiPanelCardID] = []
        for id in savedOrder where !result.contains(id) { result.append(id) }

        for id in KimiPanelCardID.allCases where !result.contains(id) {
            guard let defaultIndex = KimiPanelCardID.allCases.firstIndex(of: id) else { continue }
            let successors = KimiPanelCardID.allCases[KimiPanelCardID.allCases.index(after: defaultIndex)...]
            if let next = successors.first(where: { result.contains($0) }),
               let index = result.firstIndex(of: next) {
                result.insert(id, at: index)
            } else {
                result.append(id)
            }
        }
        let known = Set(KimiPanelCardID.allCases)
        return Self(order: result, hidden: savedHidden.intersection(known))
    }

    static func decode(_ data: Data?) -> Self {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        return normalized(order: stored.order.compactMap(KimiPanelCardID.init),
                          hidden: Set(stored.hidden.compactMap(KimiPanelCardID.init)))
    }

    func encoded() throws -> Data {
        let stored = Stored(order: order.map(\.rawValue),
                            hidden: KimiPanelCardID.allCases.filter { hidden.contains($0) }.map(\.rawValue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }
}

/// 存取隔离（同 PanelBackgroundStyleStore 模式）：生产读写 standard UserDefaults 的单 key；
/// --self-test 经 beginMemoryOverride 换成进程内存字典——绝不在用户 Preferences 创建 suite plist。
/// 仅主线程访问（生产：设置页按钮动作在主线程；测试：单线程启动前阶段）。
enum KimiPanelLayoutStore {
    private static var memoryBackend: [String: Data]?

    /// --self-test 启用内存 backend；返回值用于恢复生产存取（配合 defer）。
    @discardableResult
    static func beginMemoryOverride() -> () -> Void {
        memoryBackend = [:]
        return { memoryBackend = nil }
    }

    /// --self-test 注入原始存储值（含损坏 JSON）验证回退；仅内存 backend 下生效。
    static func setRawDataForTest(_ data: Data) {
        memoryBackend?[KimiPanelLayout.defaultsKey] = data
    }

    /// --self-test 检查底层是否仍为空（缺省/未持久化断言）。
    static var hasValueForTest: Bool {
        return memoryBackend?[KimiPanelLayout.defaultsKey] != nil
    }

    static func load() -> KimiPanelLayout {
        let data: Data?
        if let memoryBackend {
            data = memoryBackend[KimiPanelLayout.defaultsKey]
        } else {
            data = UserDefaults.standard.data(forKey: KimiPanelLayout.defaultsKey)
        }
        return KimiPanelLayout.decode(data)
    }

    static func save(_ layout: KimiPanelLayout) {
        guard let data = try? layout.encoded() else { return }
        if memoryBackend != nil {
            memoryBackend?[KimiPanelLayout.defaultsKey] = data
        } else {
            UserDefaults.standard.set(data, forKey: KimiPanelLayout.defaultsKey)
        }
    }
}

// MARK: - 原位卡片设置页（面板内容区替换渲染，不弹独立窗口）
// 行内：显隐复选框 + 卡片名 + 上/下排序按钮（拖拽排序列为二期，先保证按钮路径完整）。
// 修改即时写内存并经控制器落盘（预览模式由 persistenceEnabled 门禁），不提供语义含糊的「取消」；
// 「恢复默认」只重置卡片顺序与显隐，不动背景样式、折叠状态或每日选中日。

private enum KimiSettingsWidget {
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

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func label(_ text: String, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      wrapping: Bool = true) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = wrapping ? 0 : 1
        label.cell?.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

final class KimiCardSettingsRowView: NSView {
    let cardID: KimiPanelCardID
    let checkbox: NSButton
    let upButton: NSButton
    let downButton: NSButton
    var onToggle: ((Bool) -> Void)?
    var onMove: ((KimiPanelMoveDirection) -> Void)?

    init(cardID: KimiPanelCardID, visible: Bool) {
        self.cardID = cardID
        checkbox = NSButton(checkboxWithTitle: "显示", target: nil, action: nil)
        checkbox.identifier = NSUserInterfaceItemIdentifier("CardToggle.\(cardID.rawValue)")
        checkbox.state = visible ? .on : .off
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.setAccessibilityLabel("\(cardID.title) 显示")

        func moveButton(_ symbol: String, _ identifier: String, _ accessibility: String) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.setAccessibilityLabel("\(cardID.title)\(accessibility)")
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return button
        }
        upButton = moveButton("chevron.up", "CardMoveUp.\(cardID.rawValue)", "上移")
        downButton = moveButton("chevron.down", "CardMoveDown.\(cardID.rawValue)", "下移")

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = self
        checkbox.action = #selector(toggleCard(_:))
        upButton.target = self
        upButton.action = #selector(rowMoveUp(_:))
        downButton.target = self
        downButton.action = #selector(rowMoveDown(_:))

        let title = KimiSettingsWidget.label(cardID.title, size: 12, wrapping: false)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = KimiSettingsWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        row.addArrangedSubview(checkbox)
        row.addArrangedSubview(title)
        row.addArrangedSubview(KimiSettingsWidget.spacer())
        row.addArrangedSubview(upButton)
        row.addArrangedSubview(downButton)
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        addSubview(row)
        KimiSettingsWidget.pin(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 动作名避开 NSResponder.moveUp:/moveDown:（同名选择器会被系统导航语义拦截）
    @objc private func toggleCard(_ sender: NSButton) { onToggle?(sender.state == .on) }
    @objc private func rowMoveUp(_ sender: NSButton) { onMove?(.up) }
    @objc private func rowMoveDown(_ sender: NSButton) { onMove?(.down) }
}

final class KimiCardSettingsView: NSView {
    private(set) var layout: KimiPanelLayout
    /// 修改即时回调：控制器更新内存布局并按 persistenceEnabled 落盘。
    var onLayoutChange: ((KimiPanelLayout) -> Void)?
    private let rowsStack = KimiSettingsWidget.stack(spacing: 4)
    private var rows: [KimiCardSettingsRowView] = []
    // IUO：按钮 target 指向 self，只能在 super.init 之后创建
    private var restoreButton: NSButton!
    private var backButton: NSButton!
    private var doneButton: NSButton!

    init(layout: KimiPanelLayout, doneTarget: AnyObject?, doneAction: Selector?) {
        self.layout = layout
        super.init(frame: .zero)
        restoreButton = NSButton(title: "恢复默认卡片布局", target: self, action: #selector(restoreDefault))
        // 「返回」与「完成」同为退出设置页回面板（GLM 同款）：改动经 onChange 即时生效，
        // 无可丢弃的待定修改；保留两个出口降低「完成=提交」的心理负担，完成绑回车键。
        backButton = NSButton(title: "返回", target: doneTarget, action: doneAction)
        backButton.bezelStyle = .rounded
        backButton.controlSize = .regular
        doneButton = NSButton(title: "完成", target: doneTarget, action: doneAction)
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        translatesAutoresizingMaskIntoConstraints = false

        let root = KimiSettingsWidget.stack(spacing: 8)
        let header = KimiSettingsWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        let icon = NSImageView(image: NSImage(systemSymbolName: "ellipsis",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(KimiSettingsWidget.label("卡片显示与排序", size: 13, weight: .semibold, wrapping: false))
        KimiSettingsWidget.addFullWidth(header, to: root)
        KimiSettingsWidget.addFullWidth(
            KimiSettingsWidget.label("隐藏的卡片仍会正常获取数据与统计；改动即时生效，重新打开面板后保留。",
                                     size: 11, color: .secondaryLabelColor),
            to: root)
        KimiSettingsWidget.addFullWidth(rowsStack, to: root)

        let buttons = KimiSettingsWidget.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        buttons.addArrangedSubview(restoreButton)
        buttons.addArrangedSubview(KimiSettingsWidget.spacer())
        buttons.addArrangedSubview(backButton)
        buttons.addArrangedSubview(doneButton)
        KimiSettingsWidget.addFullWidth(buttons, to: root)

        addSubview(root)
        KimiSettingsWidget.pin(root, to: self)
        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 打开设置页时焦点落点（控制器 makeFirstResponder，防止焦点残留「···」按钮被 Space 误触）。
    var initialKeyView: NSView { rows.first?.checkbox ?? restoreButton }

    private func rebuildRows() {
        for row in rows {
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows = layout.order.map { id in
            let row = KimiCardSettingsRowView(cardID: id, visible: layout.isVisible(id))
            row.onToggle = { [weak self] visible in
                guard let self else { return }
                self.layout.setVisible(visible, for: id)
                self.notifyChange()
            }
            row.onMove = { [weak self] direction in
                guard let self else { return }
                self.layout.move(id, direction: direction)
                self.notifyChange()
            }
            return row
        }
        for row in rows { KimiSettingsWidget.addFullWidth(row, to: rowsStack) }
        // 首行上移、末行下移禁用；key loop：复选框 → 上移 → 下移 → 下一行 → 恢复默认 → 完成 → 回环。
        for (index, row) in rows.enumerated() {
            row.upButton.isEnabled = index > 0
            row.downButton.isEnabled = index < rows.count - 1
            row.checkbox.nextKeyView = row.upButton
            row.upButton.nextKeyView = row.downButton
            if index + 1 < rows.count {
                row.downButton.nextKeyView = rows[index + 1].checkbox
            } else {
                row.downButton.nextKeyView = restoreButton
            }
        }
        // key loop 收尾：恢复默认 → 返回 → 完成 → 回到首行复选框
        restoreButton.nextKeyView = backButton
        backButton.nextKeyView = doneButton
        doneButton.nextKeyView = rows.first?.checkbox
        rowsStack.needsLayout = true
    }

    private func notifyChange() {
        rebuildRows()
        onLayoutChange?(layout)
    }

    @objc private func restoreDefault() {
        layout = .default
        notifyChange()
    }
}
