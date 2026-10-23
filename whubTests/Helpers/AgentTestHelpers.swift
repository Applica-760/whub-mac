import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

@MainActor
func testEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func testHistoryEntry(_ id: String = "thread-1", directory: String = FileManager.default.currentDirectoryPath) -> AgentHistoryEntry {
    AgentHistoryEntry(id: id, name: "History", preview: "Preview", directory: directory, updatedAt: Date(timeIntervalSince1970: 123))
}

@MainActor
func testImage() throws -> NSImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.addRepresentation(bitmap)
    return image
}

@MainActor
func testExchange(_ prompt: String = "Question", answer: String = "Answer") -> whub.AgentExchange {
    var exchange = whub.AgentExchange(input: [.text(prompt)])
    exchange.outputs = [.message(whub.AgentMessage(id: "answer", role: .answer, title: "Answer", content: .markdown(answer), status: .completed))]
    exchange.status = .completed
    return exchange
}

@MainActor
func testAgentTarget(_ adapter: any AgentAdapter) -> AgentExecutionTarget {
    .local(host: nil, runtime: AgentRuntime(makeAdapter: { _ in adapter }))
}

@MainActor
final class TestAgentSession: AgentAdapter {
    typealias AgentInput = WhubAgent.AgentInput
    typealias AgentContent = WhubAgent.AgentContent
    let kind = AgentKind.codex
    let events: AsyncStream<AgentEvent>
    private let emitter: AsyncStream<AgentEvent>.Continuation
    var sent: [[AgentInput]] = []
    var additional: [[AgentInput]] = []
    var changedOptions: [AgentModelOption] = []
    var responses: [String] = []
    var directories: [String] = []
    var interrupts = 0
    var isClosed = false
    var options: [AgentModelOption] = []
    var skills: [AgentSkill] = []
    var status: [AgentContent] = [.code("Status")]
    var sendAction: ([AgentInput]) async throws -> Void = { _ in }
    var additionalAction: ([AgentInput]) async throws -> Void = { _ in }
    var changeModelAction: (AgentModelOption) async throws -> Void = { _ in }
    var respondAction: (String, AgentResponse) async throws -> Void = { _, _ in }
    var historyAction: (String?) async throws -> AgentHistoryPage = { _ in AgentHistoryPage(entries: [], nextCursor: nil) }
    var resumeAction: (AgentHistoryEntry) async throws -> AgentHistorySnapshot = {
        var exchange = WhubAgent.AgentExchange(input: [.text("Question")])
        exchange.outputs = [.message(.init(id: "answer", role: .answer, title: "Answer", content: .markdown("Answer"), status: .completed))]
        exchange.status = .completed
        return AgentHistorySnapshot(entry: $0, exchanges: [exchange], selectedModelOption: nil)
    }
    init() {
        let stream = AsyncStream<AgentEvent>.makeStream()
        events = stream.stream
        emitter = stream.continuation
    }
    func emit(_ event: AgentEvent) { emitter.yield(event) }
    func finish() { emitter.finish() }
    func connect(directory: String) async throws { directories.append(directory) }
    func send(_ input: [AgentInput]) async throws { sent.append(input); try await sendAction(input) }
    func sendAdditionalInput(_ input: [AgentInput]) async throws { additional.append(input); try await additionalAction(input) }
    func interrupt() async throws { interrupts += 1 }
    func loadModelOptions() async throws -> [AgentModelOption] { options }
    func loadSkills() async throws -> [AgentSkill] { skills }
    func loadStatus() async throws -> [AgentContent] { status }
    func changeModel(_ option: AgentModelOption) async throws { changedOptions.append(option); try await changeModelAction(option) }
    func respond(to requestID: String, with response: AgentResponse) async throws {
        responses.append(requestID)
        try await respondAction(requestID, response)
    }
    func loadHistory(cursor: String?) async throws -> AgentHistoryPage { try await historyAction(cursor) }
    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot { try await resumeAction(entry) }
    func close() { isClosed = true; emitter.finish() }
}
