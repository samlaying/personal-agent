import Foundation

public enum FilePath {
    /// Expands `~` and resolves relative paths against the home directory.
    public static func resolve(_ raw: String) -> URL {
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path).path
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

public struct CurrentTimeTool: AgentTool {
    public init() {}

    public let name = "get_current_time"
    public let summary = "获取当前的本地日期、时间和时区。"
    public let risk = RiskLevel.readOnly
    public let parameters = JSONSchema.object([:])

    private struct Arguments: Decodable {}

    public func run(arguments: String, context: ToolContext) async throws -> String {
        _ = try decode(Arguments.self, from: arguments)
        let now = Date.now
        let format = Date.FormatStyle(date: .complete, time: .standard, locale: Locale(identifier: "zh_CN"))
        return "\(now.formatted(format)) \(TimeZone.current.identifier)"
    }
}

public struct ListDirectoryTool: AgentTool {
    public init() {}

    public let name = "list_directory"
    public let summary = "列出目录里的文件和子目录，默认是用户主目录。路径可以是以 ~ 开头的绝对路径，或相对主目录的路径。"
    public let risk = RiskLevel.readOnly
    public let parameters = JSONSchema.object([
        "path": "目录路径，默认 ~",
        "limit": .int("最多返回的条目数，默认 200"),
    ])

    private struct Arguments: Decodable {
        var path: String?
        var limit: Int?
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        let directory = FilePath.resolve(args.path ?? "~")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        guard exists else { throw ToolError.failed("目录不存在：\(directory.path)") }
        guard isDirectory.boolValue else { throw ToolError.failed("不是目录：\(directory.path)") }

        let limit = min(max(args.limit ?? 200, 1), 1_000)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: []
        )
        let sorted = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var lines: [String] = ["\(directory.path)（共 \(sorted.count) 项\(sorted.count > limit ? "，显示前 \(limit) 项" : "")）"]
        for child in sorted.prefix(limit) {
            let name = child.lastPathComponent
            if child.hasDirectoryPath || (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                lines.append("[目录] \(name)/")
            } else {
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                lines.append("[文件] \(name)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct ReadFileTool: AgentTool {
    public init() {}

    public let name = "read_file"
    public let summary = "读取一个文本文件的内容。"
    public let risk = RiskLevel.readOnly
    public let parameters = JSONSchema.object([
        "path": "文件路径",
        "max_bytes": .int("最多读取的字节数，默认 64000，上限 400000"),
    ], required: ["path"])

    private struct Arguments: Decodable {
        var path: String
        var maxBytes: Int?

        private enum CodingKeys: String, CodingKey {
            case path
            case maxBytes = "max_bytes"
        }
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        let file = FilePath.resolve(args.path)
        guard !file.hasDirectoryPath else { throw ToolError.failed("这是一个目录，请用 list_directory 查看：\(file.path)") }

        let cap = min(max(args.maxBytes ?? 64_000, 256), 400_000)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: cap + 1) ?? Data()

        guard !data.prefix(8_192).contains(0) else {
            throw ToolError.failed("这是二进制文件，不能当作文本读取：\(file.path)")
        }
        guard let text = String(data: data.prefix(cap), encoding: .utf8) else {
            throw ToolError.failed("文件不是 UTF-8 编码的文本：\(file.path)")
        }
        return data.count > cap ? text + "\n\n…（文件较大，已截断）" : text
    }
}

public struct WriteFileTool: AgentTool {
    public init() {}

    public let name = "write_file"
    public let summary = "把内容写入文件，会按需创建父目录。默认覆盖原文件，append 为 true 时追加到末尾。"
    public let risk = RiskLevel.write
    public let parameters = JSONSchema.object([
        "path": "文件路径",
        "content": "要写入的完整内容",
        "append": .bool("是否追加而不是覆盖，默认 false"),
    ], required: ["path", "content"])

    private struct Arguments: Decodable {
        var path: String
        var content: String
        var append: Bool?
    }

    public func approvalSummary(for arguments: String) -> String {
        guard let args = try? decode(Arguments.self, from: arguments) else { return arguments }
        let action = (args.append == true ? "追加" : "写入") + (FileManager.default.fileExists(atPath: FilePath.resolve(args.path).path) ? "（覆盖已有文件）" : "")
        return "\(action) \(FilePath.resolve(args.path).path)，\(args.content.count) 个字符"
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        let file = FilePath.resolve(args.path)
        let payload = Data(args.content.utf8)
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        if args.append == true, manager.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: file, options: .atomic)
        }
        return "已\(args.append == true ? "追加" : "写入") \(payload.count) 字节到 \(file.path)"
    }
}

public struct ShellTool: AgentTool {
    public init() {}

    public let name = "run_shell_command"
    public let summary = "在本机执行一条 shell 命令（zsh），返回标准输出、标准错误和退出码。需要用户批准。"
    public let risk = RiskLevel.dangerous
    public let parameters = JSONSchema.object([
        "command": "要执行的命令，可以包含管道和重定向",
        "cwd": "工作目录，默认用户主目录",
        "timeout_seconds": .int("超时秒数，默认 30，最大 120"),
    ], required: ["command"])

    private struct Arguments: Decodable {
        var command: String
        var cwd: String?
        var timeoutSeconds: Int?

        private enum CodingKeys: String, CodingKey {
            case command
            case cwd
            case timeoutSeconds = "timeout_seconds"
        }
    }

    public func approvalSummary(for arguments: String) -> String {
        (try? decode(Arguments.self, from: arguments))?.command ?? arguments
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        guard !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("命令不能为空")
        }
        let timeout = min(max(args.timeoutSeconds ?? 30, 1), 120)
        let output = OutputCollector(limit: 32_000)
        let shell = try ShellProcess.launch(
            command: args.command,
            workingDirectory: args.cwd.map(FilePath.resolve),
            output: output
        )

        do {
            let status = try await withTimeout(seconds: Double(timeout)) { await shell.waitUntilExit() }
            return output.summary(exitStatus: status)
        } catch is CommandTimeout {
            shell.terminate()
            _ = await shell.waitUntilExit()
            return "命令超过 \(timeout) 秒没有结束，已终止。\n" + output.summary(exitStatus: nil)
        } catch {
            shell.terminate()
            _ = await shell.waitUntilExit()
            throw error
        }
    }
}

/// Owns one `Process`. `Process` is not Sendable, so every access goes through this object.
final class ShellProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let output: OutputCollector
    private var exitStatus: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    private init(output: OutputCollector) {
        self.output = output
    }

    static func launch(command: String, workingDirectory: URL?, output: OutputCollector) throws -> ShellProcess {
        let shell = ShellProcess(output: output)
        let process = shell.process

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.standardInput = FileHandle.nullDevice
        // stdout and stderr share one pipe, so one reader drains both and nothing can deadlock.
        process.standardOutput = shell.pipe
        process.standardError = shell.pipe
        shell.pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        process.terminationHandler = { finished in
            shell.finish(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            shell.pipe.fileHandleForReading.readabilityHandler = nil
            throw ToolError.failed("无法启动命令：\(error.localizedDescription)")
        }
        return shell
    }

    func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let exitStatus {
                    continuation.resume(returning: exitStatus)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    func terminate() {
        let (running, pid): (Bool, Int32) = lock.withLock { (process.isRunning, process.processIdentifier) }
        guard running else { return }
        process.terminate()
        // A login shell may ignore SIGTERM on behalf of its child; make sure the child goes away.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
    }

    private func finish(_ status: Int32) {
        pipe.fileHandleForReading.readabilityHandler = nil
        let pending = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            exitStatus = status
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.resume(returning: status)
    }
}

/// Drain pipe output on a background queue; read it once the process is gone.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let room = limit - data.count
            guard room > 0 else {
                truncated = true
                return
            }
            data.append(chunk.prefix(room))
            truncated = truncated || chunk.count > room
        }
    }

    func summary(exitStatus: Int32?) -> String {
        let (text, wasTruncated) = lock.withLock { (String(decoding: data, as: UTF8.self), truncated) }
        var lines = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if lines[0].isEmpty {
            lines[0] = "（没有输出）"
        }
        if wasTruncated {
            lines[0] += "\n…（输出过长，已截断）"
        }
        if let exitStatus {
            lines.append("[退出码 \(exitStatus)]")
        }
        return lines.joined(separator: "\n")
    }
}
