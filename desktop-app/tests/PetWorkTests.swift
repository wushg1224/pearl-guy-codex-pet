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
        hoverEnded()
        window = NSWindow(contentRect: NSRect(x: 240, y: 180, width: 125, height: 135),
                          styleMask: .borderless, backing: .buffered, defer: false)
        let standbyOrigin = window.frame.origin
        let allowedRows: Set<Int> = [0, 3, 5, 6, 8]
        var observedRows: Set<Int> = [state.rawValue]
        for _ in 0..<200 {
            performRandomAct()
            observedRows.insert(state.rawValue)
            precondition(allowedRows.contains(state.rawValue), "Standby must use only requested rows")
            precondition(!walking && walkTimer == nil, "Standby must never start walking")
            let count = state.frameCount * (loopsRemaining ?? 1)
            for _ in 0..<count {
                advanceFrame()
                precondition(window.frame.origin == standbyOrigin, "Standby must stay at the same position")
            }
            precondition(state == .idle && actTimer != nil, "Standby must return to idle and reschedule")
        }
        precondition(observedRows == allowedRows, "All five standby rows must be reachable")
        print("PASS: 200 standby actions, rows 0/3/5/6/8, fixed position, return to idle")
        frameTimer?.invalidate()
        actTimer?.invalidate()
        print("PASS: menu selector, hover exit, hover entry, 600 frames, left click/drag, right-click stop, restart, hover recovery")
    }
}
let app = NSApplication.shared
PetController().testWorkMenu()
