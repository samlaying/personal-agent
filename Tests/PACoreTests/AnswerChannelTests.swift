import Testing
import Foundation
@testable import PACore

@Suite("AnswerChannel")
struct AnswerChannelTests {

    @Test func promptIsJustTheQuestionWhenThereIsNoContext() {
        let channel = AnswerChannel()
        #expect(channel.prompt(question: "  现在几点？\n") == "现在几点？")
    }

    @Test func contextGoesBeforeTheQuestion() {
        let channel = AnswerChannel()
        let prompt = channel.prompt(question: "总结一下", context: "用户在做一个 macOS app")
        #expect(prompt.contains("## 参考信息"))
        #expect(prompt.contains("用户在做一个 macOS app"))
        #expect(prompt.contains("## 问题"))
        #expect(prompt.hasSuffix("总结一下"))
    }

    @Test func blankContextIsIgnored() {
        let channel = AnswerChannel()
        #expect(channel.prompt(question: "你好", context: "   \n ") == "你好")
    }

    @Test func trimmingKeepsTheWholeQuestionAndCutsContext() {
        let channel = AnswerChannel(maxPromptChars: 100)
        let question = String(repeating: "问", count: 40)
        let context = String(repeating: "旧", count: 500)
        let prompt = channel.prompt(question: question, context: context)

        #expect(prompt.count <= 120)          // question + markers + whatever context fits
        #expect(prompt.contains(question))    // the question survives intact
        #expect(prompt.hasSuffix(question))
        #expect(!prompt.contains(String(repeating: "旧", count: 500)))
    }

    @Test func requestHasNoToolsAndTwoMessages() {
        let channel = AnswerChannel()
        let request = channel.request(model: "cn:glm-5.3-flash", prompt: "你好", temperature: 0.3)

        #expect(request.model == "cn:glm-5.3-flash")
        #expect(request.tools.isEmpty)
        #expect(request.temperature == 0.3)
        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == .system)
        #expect(request.messages[0].content == AnswerChannel.instruction)
        #expect(request.messages[1].role == .user)
        #expect(request.messages[1].content == "你好")
    }

    @Test func customInstructionIsUsed() {
        let channel = AnswerChannel(instruction: "只输出整理后的内容。")
        let request = channel.request(model: "m", prompt: "x")
        #expect(request.messages[0].content == "只输出整理后的内容。")
    }
}
