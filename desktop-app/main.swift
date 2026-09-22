import AppKit

// MARK: - Sprite atlas spec (Codex pet contract: 8 cols x 9 rows)

enum PetState: Int, CaseIterable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review, hug

    var durations: [Double] {
        switch self {
        case .idle:          return [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .runningRight,
             .runningLeft:   return [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
        case .waving:        return [0.14, 0.14, 0.14, 0.28]
        case .jumping:       return [0.14, 0.14, 0.14, 0.14, 0.28]
        case .failed:        return [0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.24]
        case .waiting:       return [0.15, 0.15, 0.15, 0.15, 0.15, 0.26]
        case .running:       return [0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
        case .review:        return [0.15, 0.15, 0.15, 0.15, 0.15, 0.28]
        case .hug:           return [0.16, 0.16, 0.16, 0.16, 0.16, 0.30]
        }
    }
    var frameCount: Int { durations.count }
}

// MARK: - Pet view (renders one frame, handles drag / click / context menu)

final class PetView: NSView {
    weak var controller: PetController?
    private var dragOrigin: NSPoint = .zero
    private var didDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage) { layer?.contents = image }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.hoverBegan() }
    override func mouseExited(with event: NSEvent) { controller?.hoverEnded() }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragOrigin = event.locationInWindow
        controller?.userGrabbed()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let p = event.locationInWindow
        let dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx,
                                      y: window.frame.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { controller?.userTapped() }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.userRightClicked()
        guard let menu = controller?.buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - Controller

final class PetController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var chatWindow: ChatWindowController?
    private var terminating = false
    private var petView: PetView!
    private var frames: [[CGImage]] = []   // [row][col]

    private var state: PetState = .idle
    private var frameIndex = 0
    private var loopsRemaining: Int?       // nil = loop forever
    private var onFinished: (() -> Void)?
    private var frameTimer: Timer?
    private var actTimer: Timer?
    private var walkTimer: Timer?
    private var walkTargetX: CGFloat = 0
    private var walking = false

    private var scale: CGFloat = 0.65
    private var cellSize = NSSize(width: 192, height: 208)

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard loadSpritesheet() else {
            let alert = NSAlert()
            alert.messageText = "找不到 spritesheet.webp"
            alert.informativeText = "请确认 App 内 Resources 目录里有珍珠小子的雪碧图。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        makeWindow()
        play(.idle, loops: nil)
        scheduleNextAct()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let chatWindow else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        DispatchQueue.main.async { [weak self] in
            chatWindow.requestClose { success in
                self?.terminating = false
                sender.reply(toApplicationShouldTerminate: success)
            }
        }
        return .terminateLater
    }

    private func loadSpritesheet() -> Bool {
        guard let url = Bundle.main.url(forResource: "spritesheet", withExtension: "webp"),
              let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }

        // Standard Codex atlas is 8 cols x 9 rows of 192x208 cells; this app also
        // accepts an extended sheet with a 10th "hug" row appended.
        let cw = cg.width / 8
        let ch = Int(Double(cw) * 208.0 / 192.0)
        let rowsInSheet = cg.height / ch
        cellSize = NSSize(width: cw, height: ch)
        frames = PetState.allCases.map { st in
            guard st.rawValue < rowsInSheet else { return [] }
            return (0..<st.frameCount).compactMap { col in
                cg.cropping(to: CGRect(x: col * cw, y: st.rawValue * ch, width: cw, height: ch))
            }
        }
        // The 9 standard rows are required; the hug row is optional.
        return PetState.allCases
            .filter { $0 != .hug }
            .allSatisfy { !frames[$0.rawValue].isEmpty }
    }

    /// Hug art ships in an optional 10th row; fall back to waving until it exists.
    private var hugState: PetState {
        frames.count > PetState.hug.rawValue && frames[PetState.hug.rawValue].count == PetState.hug.frameCount
            ? .hug : .waving
    }

    private var petSize: NSSize {
        NSSize(width: round(cellSize.width * scale), height: round(cellSize.height * scale))
    }

    private func makeWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = petSize
        let origin = NSPoint(x: screen.maxX - size.width - 80, y: screen.minY + 12)

        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        petView.controller = self
        petView.autoresizingMask = [.width, .height]
        window.contentView = petView
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Animation engine

    private func play(_ newState: PetState, loops: Int?, finished: (() -> Void)? = nil) {
        frameTimer?.invalidate()
        state = newState
        frameIndex = 0
        loopsRemaining = loops
        onFinished = finished
        showFrame()
        scheduleFrameAdvance()
    }

    private func showFrame() {
        petView.show(frames[state.rawValue][frameIndex])
    }

    private func scheduleFrameAdvance() {
        let t = Timer(timeInterval: state.durations[frameIndex], repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func advanceFrame() {
        frameIndex += 1
        if frameIndex >= state.frameCount {
            frameIndex = 0
            if var loops = loopsRemaining {
                loops -= 1
                loopsRemaining = loops
                if loops <= 0 {
                    let done = onFinished
                    onFinished = nil
                    done?()
                    return
                }
            }
        }
        showFrame()
        scheduleFrameAdvance()
    }

    private func backToIdle() {
        actionInProgress = false
        stopWalk()
        play(.idle, loops: nil)
    }

    // MARK: Random behaviors

    private func scheduleNextAct(after interval: Double = .random(in: 20...50)) {
        actTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.performRandomAct()
        }
        RunLoop.main.add(t, forMode: .common)
        actTimer = t
    }

    private func performRandomAct() {
        guard state == .idle, !walking else {
            scheduleNextAct(after: .random(in: 8...15))
            return
        }
        // Desktop standby stays in place: row 0 between rows 3, 5, 6 and 8.
        let standbyActs: [PetState] = [.waving, .failed, .waiting, .review]
        let nextState = standbyActs.randomElement()!
        playAct(nextState, loops: nextState == .failed ? 1 : 2)
    }

    private func playAct(_ st: PetState, loops: Int) {
        actionInProgress = true
        stopWalk()
        play(st, loops: loops) { [weak self] in
            self?.backToIdle()
            self?.scheduleNextAct()
        }
    }

    // MARK: Walking

    private func startWalk() {
        actionInProgress = false
        guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let w = window.frame.width
        let minX = screen.minX + 10, maxX = screen.maxX - w - 10
        guard maxX - minX > 200 else { return }

        var target: CGFloat = 0
        for _ in 0..<8 {
            target = .random(in: minX...maxX)
            if abs(target - window.frame.origin.x) > 150 { break }
        }
        walkTargetX = target
        walking = true
        let goingRight = target > window.frame.origin.x
        play(goingRight ? .runningRight : .runningLeft, loops: nil)

        walkTimer?.invalidate()
        let speed: CGFloat = 85 * scale / 0.65   // px per second, scales with pet size
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.walking else { return }
            var o = self.window.frame.origin
            let step = speed / 60.0
            if goingRight {
                o.x = min(o.x + step, self.walkTargetX)
            } else {
                o.x = max(o.x - step, self.walkTargetX)
            }
            self.window.setFrameOrigin(o)
            if abs(o.x - self.walkTargetX) < 0.5 {
                self.backToIdle()
                self.scheduleNextAct()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    private func stopWalk() {
        walking = false
        walkTimer?.invalidate()
        walkTimer = nil
    }

    // MARK: User interaction

    private var hovering = false
    // Menu-triggered animations survive pointer events while the menu closes.
    private var actionInProgress = false
    private var continuousWork = false

    func hoverBegan() {
        guard !hovering else { return }
        hovering = true
        guard !actionInProgress else { return }
        stopWalk()
        play(hugState, loops: nil)   // keep hugging while the mouse stays on him
    }

    func hoverEnded() {
        guard hovering else { return }
        hovering = false
        guard !actionInProgress else { return }
        backToIdle()
        scheduleNextAct()
    }

    func userGrabbed() {
        if walking { stopWalk(); if !hovering { play(.idle, loops: nil) }; scheduleNextAct() }
    }

    func userTapped() {
        guard !continuousWork else { return }
        guard !hovering else { return }   // already hugging under the cursor
        playAct(.waving, loops: 2)
        scheduleNextAct()
    }

    func userRightClicked() {
        guard continuousWork else { return }
        continuousWork = false
        backToIdle()
        scheduleNextAct()
    }

    // MARK: Context menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "和小鱼聊天", action: #selector(menuChat), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "打个招呼 👋", action: #selector(menuWave), keyEquivalent: "").target = self
        menu.addItem(withTitle: "跳一跳 🦘", action: #selector(menuJump), keyEquivalent: "").target = self
        menu.addItem(withTitle: "去散步 🚶", action: #selector(menuWalk), keyEquivalent: "").target = self
        menu.addItem(withTitle: "认真干活 💻", action: #selector(menuWork), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, s) in [("小", CGFloat(0.45)), ("中", CGFloat(0.65)), ("大", CGFloat(0.9))] {
            let item = NSMenuItem(title: title, action: #selector(menuResize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = abs(scale - s) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "体型", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出珍珠小子", action: #selector(menuQuit), keyEquivalent: "").target = self
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    @MainActor @objc private func menuChat() {
        guard !terminating else { return }
        if chatWindow == nil { chatWindow = ChatWindowController(petScreen: window.screen) }
        chatWindow?.present()
    }

    @objc private func menuWave() { playAct(.waving, loops: 2); scheduleNextAct() }
    @objc private func menuJump() { playAct(.jumping, loops: 2); scheduleNextAct() }
    @objc private func menuWalk() { stopWalk(); startWalk() }
    @objc private func menuWork() {
        stopWalk()
        actTimer?.invalidate()
        actTimer = nil
        continuousWork = true
        actionInProgress = true
        play(.running, loops: nil)
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuResize(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? CGFloat else { return }
        scale = s
        var frame = window.frame
        let newSize = petSize
        // keep bottom-center anchored
        frame.origin.x += (frame.width - newSize.width) / 2
        frame.size = newSize
        window.setFrame(frame, display: true)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
// Standard editing shortcuts also work while the accessory app's WebView is key.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "退出珍珠小子", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
mainMenu.addItem(appItem)
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "编辑")
for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                              ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
    editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
}
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
let controller = PetController()
app.delegate = controller
app.run()
