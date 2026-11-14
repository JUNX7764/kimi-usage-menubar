import AppKit

// 面板设置与视觉原语离线 fixture：只编译 Sources/PanelCustomization.swift + KimiPanelVisuals.swift，
// 不引入主文件入口；每项断言独立 case，输出「PASS: <case>」供 tests/panel_settings_test.py 驱动。

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

switch CommandLine.arguments.dropFirst().first {
case "layoutModel":
    check(KimiPanelLayout.default.order == KimiPanelCardID.allCases
          && KimiPanelLayout.default.hidden.isEmpty, "default layout changed")
    var custom = KimiPanelLayout.default
    custom.setVisible(false, for: .tools)
    custom.move(.brief, direction: .up)
    check(custom.order == [.quota, .brief, .usage, .history, .tools], "hide+move order")
    check(custom.visibleOrder == [.quota, .brief, .usage, .history], "hidden card removed from visibleOrder")
    check(!custom.isVisible(.tools) && custom.order.count == 5, "hidden card stays in editor order")
    let roundTrip = KimiPanelLayout.decode(try! custom.encoded())
    check(roundTrip == custom, "JSON round trip")
    check(KimiPanelLayout.decode(Data("bad".utf8)) == .default, "invalid JSON falls back")
    // 旧配置迁移：未知 ID 丢弃；缺失的 history 卡按默认序相对位置插入（quota→usage→brief→history→tools）
    let legacy = #"{"order":["usage","quota","brief","usage","futureCard"],"hidden":["tools","futureCard"]}"#.data(using: .utf8)!
    let migrated = KimiPanelLayout.decode(legacy)
    // GLM 同款：缺失卡插在默认序中「紧随其后的第一张已知卡」之前；无后继则追加末尾
    check(migrated.order == [.usage, .quota, .brief, .history, .tools], "legacy order migration: \(migrated.order)")
    // insert 分支：缺 usage/brief/history 三张卡都按默认序插在已知后继 tools 之前
    let legacySparse = #"{"order":["quota","tools"],"hidden":[]}"#.data(using: .utf8)!
    let sparseMigrated = KimiPanelLayout.decode(legacySparse)
    check(sparseMigrated.order == [.quota, .usage, .brief, .history, .tools],
          "sparse legacy migration must insert before first known successor: \(sparseMigrated.order)")
    check(migrated.hidden == [.tools], "unknown hidden dropped")
    var allHidden = KimiPanelLayout.default
    for id in KimiPanelCardID.allCases { allHidden.setVisible(false, for: id) }
    check(allHidden.visibleOrder.isEmpty && allHidden.order == KimiPanelCardID.allCases,
          "all-hidden keeps full order")
    // move(to:) 边界钳制：越界目标收敛到合法区间；不动其他卡
    var edge = KimiPanelLayout.default
    edge.move(.quota, to: -3)
    check(edge.order == KimiPanelCardID.allCases, "move below range clamps to first")
    edge.move(.quota, to: 99)
    check(edge.order == [.usage, .brief, .history, .tools, .quota], "move above range clamps to last")
    // 内存 backend 往返（不写真实 UserDefaults）
    let restore = KimiPanelLayoutStore.beginMemoryOverride()
    defer { restore() }
    KimiPanelLayoutStore.save(custom)
    check(KimiPanelLayoutStore.load() == custom, "store round trip")
    check(KimiPanelLayoutStore.hasValueForTest, "store persisted value")
    KimiPanelLayoutStore.setRawDataForTest(Data("broken".utf8))
    check(KimiPanelLayoutStore.load() == .default, "corrupt store falls back")
    print("PASS: layoutModel")

case "chipSizing":
    for value in ["+100.0%", "-22.5%", "持平", "新增 9.99B", "数据不足"] {
        let size = KimiDeltaChip.size(for: value, font: chipFont)
        check(size.height == 20 && size.width > 12, "chip \(value) has text and padding")
    }
    check(!KimiDeltaChip.requiresTwoRows(halfWidth: 135, captionWidth: 40, chipWidth: 65),
          "normal width stays one row")
    check(KimiDeltaChip.requiresTwoRows(halfWidth: 105, captionWidth: 40, chipWidth: 77),
          "narrow long values must switch to two rows")
    let chip = KimiDeltaChip(text: "+12.5%", font: chipFont, foreground: .systemBlue)
    chip.frame = NSRect(x: 0, y: 0, width: 60, height: 20)
    check(!chip.isAccessibilityElement(), "chip must not duplicate AX reading")
    check(abs(chip.intrinsicContentSize.height - 20) < 0.01, "chip intrinsic height 20")
    print("PASS: chipSizing")

case "slotGeometry":
    // 画布为 isFlipped（y 向下）：plotArea minY = 视觉顶，maxY = 视觉底基线
    let plot = NSRect(x: 20, y: 0, width: 43, height: 66)
    let zero = KimiPanelVisuals.slotBar(in: plot, usedPercent: 0)
    check(zero.track.width == KimiPanelVisuals.slotWidth && zero.track.midX == plot.midX,
          "one centered 12pt slot")
    check(zero.track.height == plot.height && zero.track.minY == plot.minY,
          "track spans the full plot height")
    check(zero.fill == nil, "0% does not fabricate usage")
    check(KimiPanelVisuals.slotBar(in: plot, usedPercent: .nan).fill == nil,
          "nonfinite does not fill")
    check(KimiPanelVisuals.slotBar(in: plot, usedPercent: -4).fill == nil,
          "negative does not fill")
    let half = KimiPanelVisuals.slotBar(in: plot, usedPercent: 50)
    check(abs(half.fill!.height / half.track.height - 0.5) < 0.0001, "fill is normalized")
    check(abs(half.fill!.maxY - half.track.maxY) < 0.0001 && half.fill!.width == half.track.width,
          "fill shares visual baseline and width")
    let full = KimiPanelVisuals.slotBar(in: plot, usedPercent: 100)
    check(full.fill == full.track, "100% fills the slot")
    let tiny = KimiPanelVisuals.slotBar(in: plot, usedPercent: 0.4)
    check(tiny.fill!.height < 1, "tiny use is not inflated to a stub")
    let over = KimiPanelVisuals.slotBar(in: plot, usedPercent: 140)
    check(abs(over.fill!.height - over.track.height) < 0.0001, "percent clamps to 100")
    let narrow = NSRect(x: 0, y: 0, width: 10, height: 66)
    check(KimiPanelVisuals.slotBar(in: narrow, usedPercent: 50).track.width == 6,
          "track shrinks instead of overflowing narrow columns")
    print("PASS: slotGeometry")

case "dailyCorners":
    // 每日画布为常规坐标（y 向上）：视觉顶边 = maxY
    let rect = NSRect(x: 0, y: 0, width: 6, height: 20)
    let path = KimiPanelVisuals.dailyBarPath(in: rect, isZero: false)
    check(abs(path.bounds.width - 6) < 0.001 && abs(path.bounds.height - 20) < 0.001,
          "rounding must preserve width and height")
    check(path.contains(NSPoint(x: 3, y: 0.1)), "bottom remains square")
    check(!path.contains(NSPoint(x: 0.15, y: 19.9)), "top corner is rounded")
    check(path.contains(NSPoint(x: 3, y: 18)), "top center still filled")
    let zeroPath = KimiPanelVisuals.dailyBarPath(in: NSRect(x: 0, y: 0, width: 6, height: 2), isZero: true)
    check(zeroPath.contains(NSPoint(x: 0.1, y: 1.9)), "zero-day marker remains rectangular")
    check(zeroPath.bounds == NSRect(x: 0, y: 0, width: 6, height: 2), "zero-day bounds unchanged")
    for height in [0.2, 1.0, 3.0, 20.0] {
        let tiny = KimiPanelVisuals.dailyBarPath(
            in: NSRect(x: 0, y: 0, width: 6, height: height), isZero: false)
        check(tiny.bounds.minY >= -0.0001 && tiny.bounds.maxY <= height + 0.0001,
              "short bars stay in bounds at \(height)")
    }
    // flipped 画布（额度槽填充）：bottomRoundedPath 渲染为视觉顶边圆角。
    // 凹弧 bug 回归锁：appendArc 恒为逆时针，角部弧角度必须递增——
    // 递减角度会画出 270° 弧向内啃角，顶边中间看似凸起（用户 2026-11-14 发现）。
    let flipRect = NSRect(x: 0, y: 0, width: 12, height: 10)
    let flipped = KimiPanelVisuals.bottomRoundedPath(in: flipRect, radius: 2)
    check(flipped.contains(NSPoint(x: 6, y: 0.5)), "flipped visual top edge middle filled")
    check(flipped.contains(NSPoint(x: 10.9, y: 0.7)),
          "flipped top-right corner arc interior must be filled (concave-arc regression)")
    check(flipped.contains(NSPoint(x: 1.1, y: 0.7)),
          "flipped top-left corner arc interior must be filled (concave-arc regression)")
    check(!flipped.contains(NSPoint(x: 11.8, y: 0.2)), "flipped corner outside arc stays empty")
    check(flipped.contains(NSPoint(x: 0.1, y: 9.9)), "flipped baseline corner square")
    // 常规坐标顶圆角路径同样锁凹弧回归
    let topPath = KimiPanelVisuals.topRoundedPath(in: NSRect(x: 0, y: 0, width: 12, height: 10), radius: 2)
    check(topPath.contains(NSPoint(x: 1.1, y: 9.3)), "top path corner arc interior filled")
    check(!topPath.contains(NSPoint(x: 11.8, y: 9.8)), "top path corner outside arc stays empty")
    print("PASS: dailyCorners")

case "tokenTransition":
    var s = KimiTokenTransition()
    s.set(100, at: 0, animated: true)
    check(s.display == 100 && !s.isAnimating, "first display snaps")
    s.set(200, at: 10, animated: true)
    check(s.isAnimating, "interaction animates")
    check(s.advance(at: 10) == 100, "starts at current value")
    let middle = s.advance(at: 10.160)!
    check(abs(middle - 187.5) < 0.001, "320ms cubic ease-out midpoint")
    s.set(50, at: 10.160, animated: true)
    check(abs(s.display! - middle) < 0.001, "retarget continues from current value")
    check(s.advance(at: 10.481) == 50 && !s.isAnimating, "latest target wins")
    s.set(nil, at: 11, animated: true)
    check(s.display == nil && s.target == nil && !s.isAnimating, "missing cancels")
    s.set(0, at: 12, animated: true)
    check(s.display == 0 && !s.isAnimating, "recovery and zero are real values")
    s.set(1_000_000, at: 13, animated: false)
    check(s.display == 1_000_000 && !s.isAnimating, "reduce motion / first show snaps")
    s.set(.nan, at: 14, animated: true)
    check(s.target == nil && !s.isAnimating, "nonfinite values do not animate")
    s.set(-5, at: 15, animated: true)
    check(s.target == nil && !s.isAnimating, "negative values do not animate")
    print("PASS: tokenTransition")

default:
    fputs("FAIL: unknown panel settings fixture case\n", stderr)
    exit(1)
}
