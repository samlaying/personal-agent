import Foundation

public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental parser for the `text/event-stream` wire format.
public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// Feed one line without its trailing newline. Returns the events that completed on it.
    public mutating func feed(line: String) -> [SSEEvent] {
        if line.isEmpty {
            return takeEvent()
        }
        if line.hasPrefix(":") {
            return []
        }

        let name: String
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = String(line[..<colon])
            value = line[line.index(after: colon)...]
        } else {
            name = line
            value = ""
        }
        if value.hasPrefix(" ") {
            value = value.dropFirst()
        }

        switch name {
        case "data":
            dataLines.append(String(value))
        case "event":
            eventName = String(value)
        default:
            break
        }
        return []
    }

    /// Flushes an event that was not terminated by a blank line before the stream ended.
    public mutating func finish() -> [SSEEvent] {
        takeEvent()
    }

    private mutating func takeEvent() -> [SSEEvent] {
        guard !dataLines.isEmpty else {
            eventName = nil
            return []
        }
        let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        dataLines.removeAll(keepingCapacity: true)
        eventName = nil
        return [event]
    }
}

/// Splits raw bytes into complete lines. Lines are cut at the newline byte, which never
/// appears inside a multi-byte UTF-8 sequence, so decoding a whole line is always safe.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds one byte and returns the line it completed, if any (newline stripped).
    public mutating func feed(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if let line = feed(byte) {
                lines.append(line)
            }
        }
        return lines
    }

    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
