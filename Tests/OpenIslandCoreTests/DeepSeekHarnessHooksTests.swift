import Foundation
import Testing
@testable import OpenIslandCore

struct DeepSeekHarnessHooksTests {
    @Test
    func payloadDecodesOfficialShape() throws {
        let json = """
        {
          "sessionId": "dsh-session-12345",
          "workspacePaths": ["/tmp/my-project"],
          "modelName": "deepseek-chat",
          "terminationReason": "completed"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder()
            .decode(DeepSeekHookPayload.self, from: json)
            .withHookEvent(.turnStart)

        #expect(payload.sessionID == "dsh-session-12345")
        #expect(payload.workspaceName == "my-project")
        #expect(payload.hookEventName == .turnStart)
        #expect(payload.defaultJumpTarget.terminalApp == "DeepSeek Harness")
        #expect(payload.sessionTitle == "DeepSeek · my-project")
        #expect(payload.runningSummary == "DeepSeek Harness is working in my-project.")
    }

    @Test
    func payloadStoppedSummaryHandlesAbortedAndErrors() {
        let errorPayload = DeepSeekHookPayload(
            sessionID: "s1",
            workspacePaths: ["/tmp/proj"],
            error: "Failed to connect",
            hookEventName: .turnEnd
        )
        #expect(errorPayload.stoppedSummary.contains("stopped with an error"))

        let abortedPayload = DeepSeekHookPayload(
            sessionID: "s2",
            workspacePaths: ["/tmp/proj"],
            terminationReason: "aborted",
            hookEventName: .turnEnd
        )
        #expect(abortedPayload.stoppedSummary.contains("aborted"))

        let completedPayload = DeepSeekHookPayload(
            sessionID: "s3",
            workspacePaths: ["/tmp/proj"],
            terminationReason: "completed",
            hookEventName: .turnEnd
        )
        #expect(completedPayload.stoppedSummary.contains("completed the task"))
    }

    @Test
    func installerInstallsAndUninstallsManagedBlockInYAML() {
        let existingYAML = """
        name: web-profile
        plugins:
          - console
        """

        let turnStartCmd = DeepSeekHookInstaller.hookCommand(
            for: "/path/to/openislandhooks",
            event: .turnStart
        )
        let turnEndCmd = DeepSeekHookInstaller.hookCommand(
            for: "/path/to/openislandhooks",
            event: .turnEnd
        )

        let mutation = DeepSeekHookInstaller.installHooks(
            existingContent: existingYAML,
            turnStartCommand: turnStartCmd,
            turnEndCommand: turnEndCmd
        )

        #expect(mutation.changed)
        #expect(mutation.managedHooksPresent)
        let installedContent = mutation.contents!
        #expect(DeepSeekHookInstaller.containsManagedHooks(in: installedContent))
        #expect(installedContent.contains("turn/start"))
        #expect(installedContent.contains("turn/end"))
        #expect(installedContent.contains("plugins:\n  - console"))

        // Uninstall
        let uninstalled = DeepSeekHookInstaller.uninstallHooks(existingContent: installedContent)
        #expect(uninstalled.changed)
        #expect(!uninstalled.managedHooksPresent)
        #expect(!DeepSeekHookInstaller.containsManagedHooks(in: uninstalled.contents))
        #expect(uninstalled.contents?.contains("plugins:\n  - console") == true)
    }

    @Test
    func bridgeServerProcessesDeepSeekEvents() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let startPayload = DeepSeekHookPayload(
            sessionID: "deepseek-session-1",
            workspacePaths: ["/tmp/my-workspace"],
            modelName: "deepseek-coder",
            hookEventName: .turnStart
        )
        let endPayload = DeepSeekHookPayload(
            sessionID: "deepseek-session-1",
            workspacePaths: ["/tmp/my-workspace"],
            terminationReason: "completed",
            hookEventName: .turnEnd
        )

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processDeepSeekHook(startPayload))
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processDeepSeekHook(endPayload))

        var iterator = stream.makeAsyncIterator()
        let started = try await nextDeepSeekEvent(from: &iterator, maxEvents: 6) {
            if case .sessionStarted = $0 { return true }
            return false
        }
        guard case let .sessionStarted(startEvent) = started else {
            Issue.record("Expected DeepSeek session start")
            return
        }
        #expect(startEvent.tool == .deepseekHarness)
        #expect(startEvent.initialPhase == .running)
        #expect(startEvent.title == "DeepSeek · my-workspace")

        let completed = try await nextDeepSeekEvent(from: &iterator, maxEvents: 6) {
            if case .sessionCompleted = $0 { return true }
            return false
        }
        guard case let .sessionCompleted(completionEvent) = completed else {
            Issue.record("Expected DeepSeek completion")
            return
        }
        #expect(completionEvent.sessionID == "deepseek-session-1")
        #expect(completionEvent.summary.contains("completed the task"))
    }
}

private func nextDeepSeekEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator,
    maxEvents: Int,
    matching predicate: (AgentEvent) -> Bool
) async throws -> AgentEvent {
    for _ in 0..<maxEvents {
        if let event = try await iterator.next(), predicate(event) {
            return event
        }
    }
    throw DeepSeekTestError.matchNotFound
}

private enum DeepSeekTestError: Error {
    case matchNotFound
}
