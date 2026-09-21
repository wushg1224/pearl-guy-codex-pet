import Foundation
import Darwin

/// Retain one manager per project. All client callbacks run on the main actor.
@MainActor
final class ChatServiceManager {
    private let projectDirectory: URL
    private let dependencies: ChatServiceDependencies
    private var starting = false
    private var latestProgress = "正在检查小鱼"
    private var observers: [(progress: (String) -> Void, completion: (Result<URL, Error>) -> Void)] = []

    init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
        self.dependencies = .live
    }

    // Internal injection point; the production handoff interface stays unchanged.
    init(projectDirectory: URL, dependencies: ChatServiceDependencies) {
        self.projectDirectory = projectDirectory
        self.dependencies = dependencies
    }

    func ensureReady(
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        observers.append((progress, completion))
        if starting {
            progress(latestProgress)
            return
        }
        starting = true
        report("正在检查小鱼")
        let worker = ChatServiceWorker(projectDirectory: projectDirectory, dependencies: dependencies)
        Task {
            let result = await Task.detached {
                await worker.run { message in await self.report(message) }
            }.value
            let completed = observers
            observers.removeAll()
            starting = false
            for observer in completed { observer.completion(result.mapError { $0 as Error }) }
        }
    }

    private func report(_ message: String) {
        latestProgress = message
        let current = observers
        for observer in current { observer.progress(message) }
    }
}

enum ChatServiceError: LocalizedError, Sendable {
    case directoryMissing, dockerMissing, dockerUnavailable, portOccupied
    case commandFailed(String, Int32?), dockerTimeout, startupTimeout

    var errorDescription: String? {
        switch self {
        case .directoryMissing: return "小鱼项目目录不存在或不是文件夹，请检查项目路径。"
        case .dockerMissing: return "未找到 Docker 命令，请先安装 Docker Desktop。"
        case .dockerUnavailable: return "Docker 引擎不可用，且未找到 Docker Desktop，请先安装或打开 Docker Desktop。"
        case .portOccupied: return "本机 8001 端口已被其他服务占用，无法确认是小鱼服务。请释放该端口后重试。"
        case let .commandFailed(operation, code):
            let detail = code.map { "（退出码 \($0)）" } ?? ""
            return "\(operation)失败\(detail)，请检查 Docker Desktop 和小鱼项目配置后重试。"
        case .dockerTimeout: return "等待 Docker 引擎启动超时（最多 120 秒），请检查 Docker Desktop 后重试。"
        case .startupTimeout: return "小鱼启动超时（启动命令与健康检查合计最多 180 秒），请检查 Docker 中的小鱼服务后重试。"
        }
    }
}

enum ChatHealth: Sendable { case ready, unavailable, occupied }
enum ChatCommandResult: Sendable { case exited(Int32), timedOut, launchFailed }

struct ChatServiceDependencies: Sendable {
    var health: @Sendable (TimeInterval) async -> ChatHealth
    var command: @Sendable (URL, [String], URL?, TimeInterval) async -> ChatCommandResult
    var directoryExists: @Sendable (URL) -> Bool
    var dockerExecutable: @Sendable () -> URL?
    var dockerApplication: @Sendable () -> URL?
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async -> Void

    static let live = ChatServiceDependencies(
        health: { await ChatServiceIO.health(timeout: $0) },
        command: { await ChatServiceIO.command(executable: $0, arguments: $1, directory: $2, timeout: $3) },
        directoryExists: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        },
        dockerExecutable: {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.docker/bin/docker",
                         "/Applications/Docker.app/Contents/Resources/bin/docker",
                         "\(home)/Applications/Docker.app/Contents/Resources/bin/docker"]
            let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/docker" }
            return (paths + environmentPaths).first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
        },
        dockerApplication: {
            [URL(fileURLWithPath: "/Applications/Docker.app"),
             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Docker.app")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
        },
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    )
}

private struct ChatServiceWorker: Sendable {
    let projectDirectory: URL
    let dependencies: ChatServiceDependencies
    private let serviceURL = URL(string: "http://127.0.0.1:8001")!

    func run(progress: @Sendable (String) async -> Void) async -> Result<URL, ChatServiceError> {
        do { return .success(try await prepare(progress: progress)) }
        catch let error as ChatServiceError { return .failure(error) }
        catch { return .failure(.commandFailed("启动小鱼", nil)) }
    }

    private func prepare(progress: @Sendable (String) async -> Void) async throws -> URL {
        switch await dependencies.health(2) {
        case .ready: return serviceURL
        case .occupied: throw ChatServiceError.portOccupied
        case .unavailable: break
        }
        guard dependencies.directoryExists(projectDirectory) else { throw ChatServiceError.directoryMissing }
        guard let docker = dependencies.dockerExecutable() else { throw ChatServiceError.dockerMissing }

        let dockerDeadline = dependencies.now() + 120
        if !(try await engineReady(docker, deadline: dockerDeadline)) {
            await progress("正在启动 Docker")
            guard let application = dependencies.dockerApplication() else { throw ChatServiceError.dockerUnavailable }
            let opened = await dependencies.command(
                URL(fileURLWithPath: "/usr/bin/open"), ["-g", "-a", application.path], nil,
                min(10, try remaining(dockerDeadline, error: .dockerTimeout)))
            _ = try remaining(dockerDeadline, error: .dockerTimeout)
            try check(opened, operation: "启动 Docker Desktop", timeout: .dockerTimeout)
            while !(try await engineReady(docker, deadline: dockerDeadline)) {
                await dependencies.sleep(min(1, try remaining(dockerDeadline, error: .dockerTimeout)))
            }
        }

        await progress("正在启动小鱼")
        let startupDeadline = dependencies.now() + 180
        let composed = await dependencies.command(
            docker, ["compose", "up", "-d"], projectDirectory,
            try remaining(startupDeadline, error: .startupTimeout))
        _ = try remaining(startupDeadline, error: .startupTimeout)
        try check(composed, operation: "启动小鱼（Docker Compose）", timeout: .startupTimeout)
        while true {
            let status = await dependencies.health(min(2, try remaining(startupDeadline, error: .startupTimeout)))
            _ = try remaining(startupDeadline, error: .startupTimeout)
            switch status {
            case .ready: return serviceURL
            case .occupied: throw ChatServiceError.portOccupied
            case .unavailable:
                await dependencies.sleep(min(1, try remaining(startupDeadline, error: .startupTimeout)))
            }
        }
    }

    private func engineReady(_ docker: URL, deadline: TimeInterval) async throws -> Bool {
        let result = await dependencies.command(docker, ["info", "--format", "{{.ServerVersion}}"], nil,
                                                min(5, try remaining(deadline, error: .dockerTimeout)))
        _ = try remaining(deadline, error: .dockerTimeout)
        switch result {
        case .exited(0): return true
        case .launchFailed: throw ChatServiceError.commandFailed("检查 Docker 引擎", nil)
        default: return false
        }
    }

    private func remaining(_ deadline: TimeInterval, error: ChatServiceError) throws -> TimeInterval {
        let value = deadline - dependencies.now()
        guard value > 0 else { throw error }
        return value
    }

    private func check(_ result: ChatCommandResult, operation: String, timeout: ChatServiceError) throws {
        switch result {
        case .exited(0): return
        case .exited(let code): throw ChatServiceError.commandFailed(operation, code)
        case .timedOut: throw timeout
        case .launchFailed: throw ChatServiceError.commandFailed(operation, nil)
        }
    }
}

// Live adapters never run blocking process work on the main actor. Output is discarded:
// Compose diagnostics can contain configuration values and must not reach the UI.
enum ChatServiceIO {
    static func command(executable: URL, arguments: [String], directory: URL?, timeout: TimeInterval) async -> ChatCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // GUI apps often lack the PATH needed by Docker credential helpers.
                environment["PATH"] = ([executable.deletingLastPathComponent().path,
                    "/Applications/Docker.app/Contents/Resources/bin", "/usr/local/bin", "/opt/homebrew/bin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"] ?? ""]).joined(separator: ":")
                environment["DOCKER_CLI_HINTS"] = "false"
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() }
                catch { continuation.resume(returning: .launchFailed); return }
                while process.isRunning {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 {
                        // Stop only this invocation, never Docker Desktop or containers.
                        // SIGKILL avoids an unbounded wait on a CLI ignoring SIGTERM.
                        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                        continuation.resume(returning: .timedOut)
                        return
                    }
                    Thread.sleep(forTimeInterval: min(0.02, remaining))
                }
                continuation.resume(returning: .exited(process.terminationStatus))
            }
        }
    }

    static func classify(data: Data, response: URLResponse) -> ChatHealth {
        guard let response = response as? HTTPURLResponse,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["service"] as? String == "idol-companion" else { return .occupied }
        return (200..<300).contains(response.statusCode) ? .ready : .unavailable
    }

    static func health(timeout: TimeInterval) async -> ChatHealth {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8001/health")!)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            return classify(data: data, response: response)
        } catch {
            // A listening non-HTTP service is also a port conflict. Binding with
            // SO_REUSEADDR avoids mistaking old TIME_WAIT connections for a listener.
            return portIsOccupied() ? .occupied : .unavailable
        }
    }

    private static func portIsOccupied() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8001).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
