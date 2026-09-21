extension PetController {
    func testWorkMenu() {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let image = NSImage(contentsOf: url)!
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        frames = PetState.allCases.map { st in
            guard st.rawValue < 9 else { return [] }
            return (0..<st.frameCount).map { cg.cropping(to: CGRect(x: $0 * 192, y: st.rawValue * 208, width: 192, height: 208))! }
        }
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        hoverBegan()
        let item = buildMenu().items.first { $0.title == "认真干活 💻" }!
        _ = perform(item.action!)
        precondition(state == .running, "Menu must start work")
        hoverEnded()
        precondition(state == .running, "Menu-dismissal mouse exit must not cancel work")
        hoverBegan()
        precondition(state == .running, "Pointer entry must not cancel work")
        for _ in 0..<600 { advanceFrame() }
        precondition(state == .running && loopsRemaining == nil, "Work must keep looping beyond 24 frames")
        hoverEnded()
        userTapped()
        userGrabbed()
        precondition(state == .running, "Left click and drag must not cancel work")
        precondition(actTimer == nil, "Random actions must be suspended")
        userRightClicked()
        precondition(state == .idle && !continuousWork && !actionInProgress, "Right click must stop work")
        precondition(actTimer != nil, "Normal scheduling must resume")
        _ = perform(item.action!)
        advanceFrame()
        precondition(state == .running && frameIndex == 1, "Work must restart after stopping")
        userRightClicked()
        hoverEnded()
        hoverBegan()
        precondition(state == hugState, "Hover must work after animation finishes")
        frameTimer?.invalidate()
        actTimer?.invalidate()
        print("PASS: menu selector, hover exit, hover entry, 600 frames, left click/drag, right-click stop, restart, hover recovery")
    }
}
let app = NSApplication.shared
PetController().testWorkMenu()
