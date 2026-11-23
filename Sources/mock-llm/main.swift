import Foundation
import PAMock

// Runs the mock provider as a standalone process, for end-to-end checks of the packaged app.

let commandLine = Array(CommandLine.arguments.dropFirst())

func argValue(_ name: String) -> String? {
    guard let index = commandLine.firstIndex(of: name), index + 1 < commandLine.count else { return nil }
    return commandLine[index + 1]
}

var options = MockLLMServer.Options()
options.port = argValue("--port").flatMap { UInt16($0) } ?? 0
options.chunkDelay = argValue("--chunk-delay").flatMap { Double($0) } ?? 0.03
if let target = argValue("--write-path") {
    options.writeTarget = (target, "written by mock model at \(Date())")
}

let server = try MockLLMServer(options: options)
setvbuf(stdout, nil, _IONBF, 0)
print("mock-llm listening on \(server.baseURL)")

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
RunLoop.main.run()
