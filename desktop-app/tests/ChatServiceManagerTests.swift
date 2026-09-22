import Foundation
import Darwin

// Standalone test runner; no Package.swift or changes to build.sh are needed.
// From desktop-app:
// swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
//   -parse-as-library ChatServiceManager.swift tests/ChatServiceManagerTests.swift \
//   -o /tmp/ChatServiceManagerTests && /tmp/ChatServiceManagerTests
// All startup scenarios use substitutes. Only the process-adapter test launches
// harmless /usr/bin/true, /usr/bin/false and /bin/sleep; Docker is never invoked.

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private final class Fixture: @unchecked Sendable {
    struct Command: Sendable {
        let executable: URL
        let arguments: [String]
        let directory: URL?
        let timeout: TimeInterval
    }
    struct CommandStep: Sendable {
        let result: ChatCommandResult
        var elapsed: TimeInterval = 0
    }
    struct HealthStep: Sendable {
        let result: ChatHealth
        var elapsed: TimeInterval = 0
    }
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var commands: [Command] = []
    private var healthTimeouts: [TimeInterval] = []
    private var commandSteps: [CommandStep]
    private var healthSteps: [HealthStep]
    let directory: Bool
    let docker: Bool
    let application: Bool

    init(health: [HealthStep] = [.init(result: .unavailable)], commands: [CommandStep] = [],
         directory: Bool = true, docker: Bool = true, application: Bool = true) {
        healthSteps = health
        commandSteps = commands
        self.directory = directory
        self.docker = docker
        self.application = application
    }

    var recordedCommands: [Command] { lock.withLock { commands } }
    var recordedHealthTimeouts: [TimeInterval] { lock.withLock { healthTimeouts } }
    var elapsed: TimeInterval { lock.withLock { time } }

    var dependencies: ChatServiceDependencies {
        ChatServiceDependencies(
            health: { timeout in
                self.lock.withLock {
                    self.healthTimeouts.append(timeout)
                    let step = self.healthSteps.isEmpty ? HealthStep(result: .unavailable) : self.healthSteps.removeFirst()
                    self.time += step.elapsed
                    return step.result
                }
            },
            command: { executable, arguments, directory, timeout in
                self.lock.withLock {
                    self.commands.append(Command(executable: executable, arguments: arguments, directory: directory, timeout: timeout))
                    let step = self.commandSteps.isEmpty ? CommandStep(result: .exited(1)) : self.commandSteps.removeFirst()
                    self.time += step.elapsed
                    return step.result
                }
            },
            directoryExists: { _ in self.directory },
            dockerExecutable: { self.docker ? URL(fileURLWithPath: "/fake/docker") : nil },
            dockerApplication: { self.application ? URL(fileURLWithPath: "/fake/Docker.app") : nil },
            now: { self.elapsed },
            sleep: { seconds in self.lock.withLock { self.time += seconds } }
        )
    }
}

@MainActor
private final class Observation {
    var progress: [String] = []
    var allMainThread = true
    var completionCount = 0

    func run(_ manager: ChatServiceManager) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            manager.ensureReady(progress: {
                self.allMainThread = self.allMainThread && Thread.isMainThread
                self.progress.append($0)
            }, completion: {
                self.allMainThread = self.allMainThread && Thread.isMainThread
                self.completionCount += 1
                continuation.resume(returning: $0)
            })
        }
    }
}

@main
@MainActor
struct ChatServiceManagerTests {
    static let project = URL(fileURLWithPath: "/fake/小鱼 project")

    private static func manager(_ fixture: Fixture) -> ChatServiceManager {
        ChatServiceManager(projectDirectory: project, dependencies: fixture.dependencies)
    }

    static func expectFailure(_ result: Result<URL, Error>, containing text: String) throws {
        switch result {
        case .success: throw TestFailure(description: "Expected error containing \(text)")
        case .failure(let error):
            try expect(error.localizedDescription.contains(text), "Unexpected error: \(error.localizedDescription)")
        }
    }

    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("already ready skips directory and Docker checks", {
                let f = Fixture(health: [.init(result: .ready)], directory: false, docker: false)
                let o = Observation()
                let url = try await o.run(manager(f)).get()
                try expect(url.absoluteString == "http://127.0.0.1:8001", "Wrong URL")
                try expect(f.recordedCommands.isEmpty, "Started a process unnecessarily")
                try expect(o.progress == ["正在检查小鱼"] && o.allMainThread, "Callbacks/progress incorrect")
            }),
            ("starts Docker Desktop then Compose and polls health", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .unavailable), .init(result: .ready)],
                                commands: [.init(result: .exited(1)), .init(result: .exited(0)),
                                           .init(result: .exited(1)), .init(result: .exited(0)), .init(result: .exited(0))])
                let o = Observation()
                _ = try await o.run(manager(f)).get()
                let commands = f.recordedCommands
                try expect(commands.count == 5, "Wrong process count")
                try expect(commands[1].executable.path == "/usr/bin/open", "Desktop was not opened")
                try expect(commands[1].arguments == ["-g", "-a", "/fake/Docker.app"], "Incorrect Desktop launch")
                try expect(commands.last?.arguments == ["compose", "up", "-d"], "Unexpected Compose flags")
                try expect(commands.last?.directory == project, "Project directory was not preserved")
                try expect(o.progress == ["正在检查小鱼", "正在启动 Docker", "正在启动小鱼"], "Wrong progress")
                try expect(o.allMainThread && o.completionCount == 1, "Invalid callback delivery")
            }),
            ("running engine skips Desktop", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .ready)],
                                commands: [.init(result: .exited(0)), .init(result: .exited(0))], application: false)
                _ = try await Observation().run(manager(f)).get()
                try expect(f.recordedCommands.count == 2, "Unexpected Desktop launch")
            }),
            ("missing project directory", {
                let f = Fixture(directory: false)
                try expectFailure(await Observation().run(manager(f)), containing: "目录不存在")
                try expect(f.recordedCommands.isEmpty, "Started a process with invalid directory")
            }),
            ("missing Docker CLI", {
                let f = Fixture(docker: false)
                try expectFailure(await Observation().run(manager(f)), containing: "未找到 Docker 命令")
                try expect(f.recordedCommands.isEmpty, "Started a process without Docker")
            }),
            ("unavailable engine and missing Desktop", {
                let f = Fixture(application: false)
                try expectFailure(await Observation().run(manager(f)), containing: "Docker 引擎不可用")
                try expect(f.recordedCommands.count == 1, "Unexpected Compose launch")
            }),
            ("occupied port fails before launching anything", {
                let f = Fixture(health: [.init(result: .occupied)])
                try expectFailure(await Observation().run(manager(f)), containing: "8001")
                try expect(f.recordedCommands.isEmpty, "Started despite occupied port")
            }),
            ("occupied port during readiness wait", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .occupied)],
                                commands: [.init(result: .exited(0)), .init(result: .exited(0))])
                try expectFailure(await Observation().run(manager(f)), containing: "其他服务")
            }),
            ("Desktop launch failure", {
                let f = Fixture(commands: [.init(result: .exited(1)), .init(result: .exited(7))])
                try expectFailure(await Observation().run(manager(f)), containing: "启动 Docker Desktop失败（退出码 7）")
                try expect(f.recordedCommands.count == 2, "Continued after Desktop failure")
            }),
            ("process cannot be launched", {
                let f = Fixture(commands: [.init(result: .launchFailed)])
                try expectFailure(await Observation().run(manager(f)), containing: "检查 Docker 引擎失败")
            }),
            ("Compose failure gives a safe Chinese error", {
                let f = Fixture(commands: [.init(result: .exited(0)), .init(result: .exited(17))])
                try expectFailure(await Observation().run(manager(f)), containing: "Docker Compose）失败（退出码 17）")
            }),
            ("Docker deadline is 120 seconds", {
                let f = Fixture(commands: [.init(result: .exited(1)), .init(result: .exited(0))])
                try expectFailure(await Observation().run(manager(f)), containing: "120 秒")
                try expect(f.elapsed == 120, "Docker deadline exceeded")
                try expect(!f.recordedCommands.contains { $0.arguments.first == "compose" }, "Compose ran before engine readiness")
            }),
            ("hanging Compose has a bounded timeout", {
                let f = Fixture(commands: [.init(result: .exited(0)), .init(result: .timedOut, elapsed: 180)])
                try expectFailure(await Observation().run(manager(f)), containing: "180 秒")
                try expect(f.recordedCommands.last?.timeout == 180, "Compose timeout incorrect")
                try expect(f.recordedHealthTimeouts.count == 1, "Health polling continued after timeout")
            }),
            ("Compose and health share the 180 second budget", {
                let f = Fixture(commands: [.init(result: .exited(0)), .init(result: .exited(0), elapsed: 179)])
                try expectFailure(await Observation().run(manager(f)), containing: "180 秒")
                try expect(f.elapsed == 180, "Budget was reset after Compose")
                try expect(f.recordedHealthTimeouts == [2, 1], "Health request exceeded remaining budget")
            }),
            ("late healthy result cannot bypass deadline", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .ready, elapsed: 1)],
                                commands: [.init(result: .exited(0)), .init(result: .exited(0), elapsed: 179)])
                try expectFailure(await Observation().run(manager(f)), containing: "180 秒")
            }),
            ("duplicate calls share work and all receive main-thread callbacks", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .ready)],
                                commands: [.init(result: .exited(0)), .init(result: .exited(0))])
                let m = manager(f)
                var results: [Result<URL, Error>] = []
                var updates = [0, 0]
                var mainThread = true
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    for index in 0..<2 {
                        m.ensureReady(progress: { _ in
                            updates[index] += 1
                            mainThread = mainThread && Thread.isMainThread
                        }, completion: { result in
                            mainThread = mainThread && Thread.isMainThread
                            results.append(result)
                            if results.count == 2 { done.resume() }
                        })
                    }
                }
                try expect(results.count == 2 && updates.allSatisfy { $0 == 2 }, "Missing shared callbacks")
                for result in results { _ = try result.get() }
                try expect(mainThread, "Callback was off main thread")
                try expect(f.recordedCommands.count == 2, "Duplicate process launch")
            }),
            ("progress reentrancy shares the task", {
                let f = Fixture(health: [.init(result: .ready)])
                let m = manager(f)
                var completions = 0
                var subscribed = false
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let complete: (Result<URL, Error>) -> Void = { _ in
                        completions += 1
                        if completions == 2 { done.resume() }
                    }
                    m.ensureReady(progress: { _ in
                        if !subscribed {
                            subscribed = true
                            m.ensureReady(progress: { _ in }, completion: complete)
                        }
                    }, completion: complete)
                }
                try expect(f.recordedHealthTimeouts.count == 1, "Reentrant progress started another task")
            }),
            ("failure clears task so retry can succeed", {
                let f = Fixture(health: [.init(result: .unavailable), .init(result: .ready)],
                                commands: [.init(result: .launchFailed)])
                let m = manager(f)
                try expectFailure(await Observation().run(m), containing: "失败")
                _ = try await Observation().run(m).get()
                try expect(f.recordedHealthTimeouts.count == 2, "Retry reused stale failure")
            }),
            ("health identity and HTTP status are both validated", {
                let url = URL(string: "http://127.0.0.1:8001/health")!
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let bad = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
                let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
                let valid = Data(#"{"service":"idol-companion"}"#.utf8)
                try expect(ChatServiceIO.classify(data: valid, response: ok) == .ready, "Valid health rejected")
                try expect(ChatServiceIO.classify(data: valid, response: bad) == .unavailable, "503 treated as healthy")
                for body in [#"{"service":"other"}"#, #"{"status":"ok"}"#, "<html>hello</html>", #"{"service":123}"#] {
                    try expect(ChatServiceIO.classify(data: Data(body.utf8), response: ok) == .occupied, "Foreign service accepted")
                }
                try expect(ChatServiceIO.classify(data: Data(), response: redirect) == .occupied, "Redirect accepted")
            }),
            ("live process adapter handles exit, failure, timeout without blocking UI", {
                var heartbeat = false
                let beat = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    heartbeat = true
                }
                let start = ProcessInfo.processInfo.systemUptime
                let timeout = await ChatServiceIO.command(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                          arguments: ["5"], directory: nil, timeout: 0.15)
                let deliveredWhileWaiting = heartbeat
                await beat.value
                if case .timedOut = timeout {} else { throw TestFailure(description: "Process timeout missing") }
                try expect(deliveredWhileWaiting && ProcessInfo.processInfo.systemUptime - start < 2, "Process blocked callback delivery")
                let success = await ChatServiceIO.command(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], directory: nil, timeout: 2)
                if case .exited(0) = success {} else { throw TestFailure(description: "Exit 0 not recognized") }
                let failure = await ChatServiceIO.command(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], directory: nil, timeout: 2)
                if case .exited(1) = failure {} else { throw TestFailure(description: "Nonzero exit not recognized") }
                let missing = await ChatServiceIO.command(executable: URL(fileURLWithPath: "/missing/chat-test"), arguments: [], directory: nil, timeout: 2)
                if case .launchFailed = missing {} else { throw TestFailure(description: "Launch failure not recognized") }
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 { exit(1) }
    }
}
