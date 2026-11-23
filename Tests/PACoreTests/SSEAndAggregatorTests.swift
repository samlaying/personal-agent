import Testing
import Foundation
@testable import PACore

struct SSEParserTests {
    private func events(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in lines {
            events += parser.feed(line: line)
        }
        return events + parser.finish()
    }

    @Test func singleEvent() {
        let events = events(["data: hello", ""])
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
    }

    @Test func multilineDataIsJoinedWithNewlines() {
        let events = events(["data: line one", "data: line two", ""])
        #expect(events.count == 1)
        #expect(events[0].data == "line one\nline two")
    }

    @Test func eventNameAndComments() {
        let events = events([": keepalive", "event: custom", "data: x", "", "data: y", ""])
        #expect(events.count == 2)
        #expect(events[0].event == "custom")
        #expect(events[0].data == "x")
        #expect(events[1].event == nil)
    }

    @Test func unflushedTailIsRecovered() {
        let events = events(["data: tail"])
        #expect(events.count == 1)
        #expect(events[0].data == "tail")
    }

    @Test func colonSpaceIsStrippedOnce() {
        let events = events(["data:  double space", ""])
        #expect(events[0].data == " double space")
    }
}

struct LineSplitterTests {
    @Test func byteByByte() {
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in "ab\ncd\r\nef".utf8 {
            if let line = splitter.feed(byte) {
                lines.append(line)
            }
        }
        #expect(lines == ["ab", "cd"])
        #expect(splitter.finish() == "ef")
    }
}

struct StreamAggregatorTests {
    @Test func textAndReasoningAccumulate() {
        var aggregator = StreamAggregator()
        aggregator.apply(.reasoningDelta("想"))
        aggregator.apply(.reasoningDelta("一下"))
        aggregator.apply(.textDelta("你"))
        aggregator.apply(.textDelta("好"))
        #expect(aggregator.reasoning == "想一下")
        #expect(aggregator.text == "你好")
    }

    @Test func splitToolCallFragmentsMerge() {
        var aggregator = StreamAggregator()
        aggregator.apply(.toolCallDelta(index: 0, id: "call_1", name: "read_file", argumentsFragment: "{\"pa"))
        aggregator.apply(.toolCallDelta(index: 0, id: nil, name: nil, argumentsFragment: "th\": \"/tmp"))
        aggregator.apply(.toolCallDelta(index: 0, id: nil, name: nil, argumentsFragment: "/x\"}"))
        aggregator.apply(.finish(reason: "tool_calls"))

        let calls = aggregator.normalizedToolCalls()
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_1")
        #expect(calls[0].name == "read_file")
        #expect(calls[0].arguments == "{\"path\": \"/tmp/x\"}")
        #expect(aggregator.finishReason == "tool_calls")
    }

    @Test func twoCallsAndMissingID() {
        var aggregator = StreamAggregator()
        aggregator.apply(.toolCallDelta(index: 0, id: "a", name: "tool_a", argumentsFragment: "{}"))
        aggregator.apply(.toolCallDelta(index: 1, id: nil, name: "tool_b", argumentsFragment: "{}"))
        let calls = aggregator.normalizedToolCalls()
        #expect(calls.map(\.id) == ["a", "call_1"])
        #expect(calls.map(\.name) == ["tool_a", "tool_b"])
    }
}

struct StreamDecoderTests {
    @Test func chunkDecoding() throws {
        let json = """
        {"choices":[{"delta":{"reasoning_content":"思考","content":"答案"},"finish_reason":null},{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"t","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        """
        let events = try StreamDecoder.events(fromChunkJSON: json)
        #expect(events.contains(.reasoningDelta("思考")))
        #expect(events.contains(.textDelta("答案")))
        #expect(events.contains(.toolCallDelta(index: 0, id: "c1", name: "t", argumentsFragment: "{}")))
        #expect(events.contains(.finish(reason: "tool_calls")))
    }

    @Test func contentAsPartsArray() throws {
        let json = """
        {"choices":[{"delta":{"content":[{"text":"a"},{"text":"b"}]},"finish_reason":null}]}
        """
        let events = try StreamDecoder.events(fromChunkJSON: json)
        #expect(events.contains(.textDelta("ab")))
    }

    @Test func argumentsAsObjectInsteadOfString() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"t","arguments":{"path":"/tmp"}}}]}}]}
        """
        let events = try StreamDecoder.events(fromCompleteJSON: Data(json.utf8))
        let fragments = events.compactMap { event -> String? in
            if case .toolCallDelta(_, _, _, let fragment) = event { return fragment }
            return nil
        }
        #expect(fragments.count == 1)
        // The object form is re-encoded as JSON text; compare semantically, not byte-wise.
        let path = try JSONValue.parse(fragments[0])["path"]?.stringValue
        #expect(path == "/tmp")
    }

    @Test func finishWithoutReasonIsKeptOutOfEvents() {
        var aggregator = StreamAggregator()
        aggregator.apply(.finish(reason: nil))
        #expect(aggregator.finishReason == nil)
    }
}
