import AppKit
import WebKit

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private var manager: ChatServiceManager?
    private var starting = false
    private var generation = UUID()
    private var closing = false
    private var closeCallbacks: [(Bool) -> Void] = []
    private var closeTimeout: DispatchWorkItem?
    private let status = NSTextField(wrappingLabelWithString: "正在检查小鱼")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    private let choose = NSButton(title: "选择小鱼目录…", target: nil, action: nil)
    private let banner = NSStackView()
    private let pageHost = NSView()
    private let frameKey = "PearlChatWindowFrame"
    private let directoryKey = "PearlChatProjectDirectory"

    init(petScreen: NSScreen?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "和小鱼聊天"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 400)
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        window.contentView = root
        banner.orientation = .vertical
        banner.alignment = .leading
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        spinner.style = .spinning
        spinner.controlSize = .small
        let buttons = NSStackView(views: [spinner, retry, choose])
        banner.addArrangedSubview(status)
        banner.addArrangedSubview(buttons)
        root.addArrangedSubview(banner)
        root.addArrangedSubview(pageHost)
        [banner, pageHost].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        status.widthAnchor.constraint(lessThanOrEqualTo: banner.widthAnchor, constant: -24).isActive = true
        pageHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        retry.target = self; retry.action = #selector(retryLoading)
        choose.target = self; choose.action = #selector(chooseDirectory)
        let visible = (petScreen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= 320, frame.height >= 400 { window.setFrame(frame, display: false) }
        } else {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        let destination = NSScreen.screens.first { $0.visibleFrame.intersects(window.frame) }?.visibleFrame ?? visible
        var frame = window.frame
        frame.size.width = min(frame.width, destination.width)
        frame.size.height = min(frame.height, destination.height)
        frame.origin.x = max(destination.minX, min(frame.minX, destination.maxX - frame.width))
        frame.origin.y = max(destination.minY, min(frame.minY, destination.maxY - frame.height))
        window.setFrame(frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        window?.deminiaturize(nil)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if webView == nil && !starting && !closing { start() }
    }

    private func showStatus(_ message: String, busy: Bool, canRetry: Bool) {
        banner.isHidden = false
        status.stringValue = message
        retry.isHidden = !canRetry
        choose.isHidden = busy || webView != nil
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var projectDirectory: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: directoryKey)
            ?? "/Users/ceci/Documents/GitHub/idol-companion", isDirectory: true)
    }

    private func validDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.appendingPathComponent("compose.yaml").path)
    }

    private func start() {
        guard !starting, !closing else { return }
        guard validDirectory(projectDirectory) else {
            showStatus("小鱼目录无效。请选择包含 compose.yaml 的项目目录。", busy: false, canRetry: true)
            return
        }
        starting = true
        let token = generation
        let service = ChatServiceManager(projectDirectory: projectDirectory)
        manager = service
        showStatus("正在检查小鱼", busy: true, canRetry: false)
        service.ensureReady(progress: { [weak self] message in
            guard let self, self.generation == token, !self.closing else { return }
            self.showStatus(message, busy: true, canRetry: false)
        }, completion: { [weak self] result in
            guard let self, self.generation == token, !self.closing else { return }
            self.starting = false
            self.manager = nil
            switch result {
            case .success(let url): self.loadPage(url)
            case .failure(let error): self.showStatus(error.localizedDescription, busy: false, canRetry: true)
            }
        })
    }

    @objc private func retryLoading() {
        guard !closing else { return }
        if webView != nil { requestClose { _ in } } else { start() }
    }

    @objc private func chooseDirectory() {
        guard !starting, !closing, webView == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择包含 compose.yaml 的小鱼项目目录"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard self.validDirectory(url) else {
                self.showStatus("所选目录不包含可读取的 compose.yaml，请重新选择。", busy: false, canRetry: true)
                return
            }
            UserDefaults.standard.set(url.path, forKey: self.directoryKey)
            self.start()
        }
    }

    private func loadPage(_ url: URL) {
        let configuration = WKWebViewConfiguration()
        // The app's persistent WebKit store is separate from Safari/Chrome data.
        configuration.websiteDataStore = .default()
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.navigationDelegate = self
        page.uiDelegate = self
        webView = page
        pageHost.addSubview(page)
        page.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            page.topAnchor.constraint(equalTo: pageHost.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
        ])
        showStatus("正在加载小鱼网页", busy: true, canRetry: false)
        page.load(URLRequest(url: url))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose { _ in }
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    private func saveFrame() {
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey) }
    }

    /// Both window close and app termination use this handshake. A JS save
    /// rejection keeps the live page; a dead/unresponsive process is released.
    func requestClose(completion: @escaping (Bool) -> Void) {
        closeCallbacks.append(completion)
        guard !closing else { return }
        closing = true
        generation = UUID()
        starting = false
        manager = nil
        guard let page = webView else { finishClose(success: true); return }
        showStatus("正在停止回复并保存…", busy: true, canRetry: false)
        let timeout = DispatchWorkItem { [weak self, weak page] in
            guard let self, self.closing, self.webView === page else { return }
            self.finishClose(success: true)
        }
        closeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        page.callAsyncJavaScript("""
            if (typeof window.pearlPetChat?.prepareToClose !== 'function') return 'unavailable';
            try { await window.pearlPetChat.prepareToClose(); return 'saved'; }
            catch (error) { return 'save-failed'; }
            """, arguments: [:], in: nil, in: .page) { [weak self, weak page] result in
                guard let self, self.closing, self.webView === page else { return }
                switch result {
                case .success(let value): self.finishClose(success: (value as? String) != "save-failed")
                case .failure: self.finishClose(success: true)
                }
            }
    }

    private func releasePage() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func finishClose(success: Bool) {
        closeTimeout?.cancel(); closeTimeout = nil
        closing = false
        if success {
            saveFrame()
            releasePage()
            window?.close()
        } else {
            showStatus("保存失败，窗口已保留。请重试关闭，或先复制需要的内容。", busy: false, canRetry: true)
            window?.makeKeyAndOrderFront(nil)
        }
        let callbacks = closeCallbacks
        closeCallbacks.removeAll()
        callbacks.forEach { $0(success) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closing else { return }
        webView.evaluateJavaScript("typeof window.pearlPetChat?.prepareToClose === 'function'") { [weak self, weak webView] value, error in
            guard let self, self.webView === webView, !self.closing else { return }
            if error == nil, value as? Bool == true {
                self.banner.isHidden = true
                self.spinner.stopAnimation(nil)
                self.window?.makeFirstResponder(webView)
            } else {
                self.releasePage()
                self.showStatus("网页缺少 PRD 2 关闭接口。请重建小鱼服务后重试。", busy: false, canRetry: true)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    private func navigationFailed(_ error: Error) {
        guard !closing, (error as NSError).code != NSURLErrorCancelled else { return }
        releasePage()
        showStatus("网页加载失败：\(error.localizedDescription)", busy: false, canRetry: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if closing { finishClose(success: true) }
        else {
            releasePage()
            showStatus("网页进程已停止。重试可恢复已保存的记录。", busy: false, canRetry: true)
        }
    }

    private func isLocal(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == 8001
    }
    private func openExternal(_ url: URL) {
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            openExternal(url)
            decisionHandler(.cancel)
        } else { decisionHandler(isLocal(url) ? .allow : .cancel) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternal(url) }
        return nil
    }
}
