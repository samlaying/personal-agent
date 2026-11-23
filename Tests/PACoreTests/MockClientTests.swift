import Testing
import Foundation
@testable import PACore
import PAMock

struct MockClientTests {
    private func makeClient(_ server: MockLLMServer, apiKey: String = "test") -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: server.baseURL, apiKey: apiKey)
    }

    private func collect(_ client: OpenAICompatibleClient, prompt: String) async throws -> (String, [ToolCall], String?) {
        let request = ChatRequest(
            model: "mock-model",
            messages: [RequestMessage(role: .user, content: prompt)]
        )
        var text = ""
        var aggregator = StreamAggregator()
        for try await event in client.stream(request) {
            aggregator.apply(event)
        }
        text = aggregator.text
        return (text, aggregator.normalizedToolCalls(), aggregator.finishReason)
    }

    @Test func baseURLJoining() {
        let client = OpenAICompatibleClient(baseURL: "http://example.com/v1", apiKey: "")
        #expect(client.chatCompletionsURL?.absoluteString == "http://example.com/v1/chat/completions")

        let trailing = OpenAICompatibleClient(baseURL: "http://example.com/v1/", apiKey: "")
        #expect(trailing.chatCompletionsURL?.absoluteString == "http://example.com/v1/chat/completions")

        let complete = OpenAICompatibleClient(baseURL: "http://example.com/v1/chat/completions", apiKey: "")
        #expect(complete.chatCompletionsURL?.absoluteString == "http://example.com/v1/chat/completions")

        // A string without host parses as a URL these days; the request build must reject it.
        let broken = OpenAICompatibleClient(baseURL: "not a url", apiKey: "")
        do {
            _ = try broken.makeURLRequest(ChatRequest(model: "m", messages: []))
            Issue.record("should have thrown")
        } catch {
            #expect(error is ProviderError)
        }
    }

    @Test func streamsTextEndToEnd() async throws {
        let server = try MockLLMServer()
        defer { server.stop() }

        let (text, calls, finish) = try await collect(makeClient(server), prompt: "[[plain]] 你好")
        #expect(text.contains("纯文字"))
        #expect(calls.isEmpty)
        #expect(finish == "stop")
        #expect(server.requests().count == 1)
    }

    @Test func mergesFragmentsIntoToolCall() async throws {
        let server = try MockLLMServer()
        defer { server.stop() }

        let (_, calls, finish) = try await collect(makeClient(server), prompt: "现在几点了")
        #expect(calls.count == 1)
        #expect(calls[0].name == "get_current_time")
        #expect(calls[0].arguments == "{}")
        #expect(finish == "tool_calls")
    }

    @Test func httpErrorSurfacesBody() async throws {
        let server = try MockLLMServer()
        defer { server.stop() }

        do {
            _ = try await collect(makeClient(server), prompt: "[[http500]] 坏请求")
            Issue.record("should have thrown")
        } catch let error as ProviderError {
            if case .http(let status, let message) = error {
                #expect(status == 500)
                #expect(message.contains("mock server exploded"))
            } else {
                Issue.record("wrong error kind: \(error)")
            }
        }
    }

    @Test func wrongAPIKeyIsRejected() async throws {
        var options = MockLLMServer.Options()
        options.requiredAPIKey = "secret"
        let server = try MockLLMServer(options: options)
        defer { server.stop() }

        do {
            _ = try await collect(makeClient(server, apiKey: "wrong"), prompt: "hi")
            Issue.record("should have thrown")
        } catch let error as ProviderError {
            if case .http(let status, _) = error {
                #expect(status == 401)
            } else {
                Issue.record("wrong error kind: \(error)")
            }
        }
    }

    @Test func requestCarriesToolsAndMessages() async throws {
        let server = try MockLLMServer()
        defer { server.stop() }

        let client = makeClient(server)
        let request = ChatRequest(
            model: "mock-model",
            messages: [
                RequestMessage(role: .system, content: "系统提示"),
                RequestMessage(role: .user, content: "带工具的请求"),
            ],
            tools: [CurrentTimeTool().definition]
        )
        for try await _ in client.stream(request) {}

        let sent = server.requests()[0]
        let body = sent.json()
        #expect(body["model"] as? String == "mock-model")
        #expect(body["stream"] as? Bool == true)
        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1)
        #expect((tools[0]["function"] as? [String: Any])?["name"] as? String == "get_current_time")
    }
}
