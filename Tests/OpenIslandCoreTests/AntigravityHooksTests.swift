import Foundation
import Testing
@testable import OpenIslandCore

struct AntigravityHooksTests {
    @Test
    func payloadDecodesOfficialPreInvocationShape() throws {
        let json = """
        {
          "conversationId": "ec33ebf9-0cba-4100-8142-c61503f6c587",
          "workspacePaths": ["/tmp/worktree"],
          "transcriptPath": "/tmp/brain/transcript.jsonl",
          "artifactDirectoryPath": "/tmp/brain",
          "modelName": "gemini-3.6-flash-medium",
          "invocationNum": 3,
          "initialNumSteps": 10
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder()
            .decode(AntigravityHookPayload.self, from: json)
            .withHookEvent(.preInvocation)

        #expect(payload.conversationID == "ec33ebf9-0cba-4100-8142-c61503f6c587")
        #expect(payload.workspaceName == "worktree")
        #expect(payload.hookEventName == .preInvocation)
        #expect(payload.defaultJumpTarget.terminalApp == "Antigravity")
    }

    @Test
    func installerPreservesUnrelatedHooksAndAddsLifecycleEvents() throws {
        let existing = """
        {
          "my-linter": {
            "PostToolUse": [{
              "matcher": "run_command",
              "hooks": [{"command": "./lint.sh"}]
            }]
          }
        }
        """.data(using: .utf8)!
        let preCommand = AntigravityHookInstaller.hookCommand(
            for: "/Applications/Open Island Dev.app/Contents/MacOS/OpenIslandHooks",
            event: .preInvocation
        )
        let stopCommand = AntigravityHookInstaller.hookCommand(
            for: "/Applications/Open Island Dev.app/Contents/MacOS/OpenIslandHooks",
            event: .stop
        )

        let installed = try AntigravityHookInstaller.installHooksJSON(
            existingData: existing,
            preInvocationCommand: preCommand,
            stopCommand: stopCommand
        )

        #expect(installed.changed)
        #expect(installed.managedHooksPresent)
        let installedData = try #require(installed.contents)
        let object = try JSONSerialization.jsonObject(with: installedData) as! [String: Any]
        #expect(object["my-linter"] != nil)
        let managed = object[AntigravityHookInstaller.managedHookName] as! [String: Any]
        #expect((managed["PreInvocation"] as? [[String: Any]])?.count == 1)
        #expect((managed["Stop"] as? [[String: Any]])?.count == 1)

        let uninstalled = try AntigravityHookInstaller.uninstallHooksJSON(existingData: installedData)
        let uninstalledData = try #require(uninstalled.contents)
        let remaining = try JSONSerialization.jsonObject(with: uninstalledData) as! [String: Any]
        #expect(remaining["my-linter"] != nil)
        #expect(remaining[AntigravityHookInstaller.managedHookName] == nil)
    }

    @Test
    func installerDoesNotOverwriteAUserHookWithTheReservedName() throws {
        let existing = """
        {
          "open-island-task-monitor": {
            "Stop": [{"command": "./my-stop-check.sh"}]
          }
        }
        """.data(using: .utf8)!

        #expect(throws: AntigravityHookInstallerError.self) {
            _ = try AntigravityHookInstaller.installHooksJSON(
                existingData: existing,
                preInvocationCommand: "OpenIslandHooks --source antigravity --event pre-invocation",
                stopCommand: "OpenIslandHooks --source antigravity --event stop"
            )
        }
    }

    @Test
    func installerRepairsItsOwnPartialDefinition() throws {
        let existing = """
        {
          "open-island-task-monitor": {
            "PreInvocation": [{
              "command": "'/tmp/OpenIslandHooks' --source antigravity --event pre-invocation"
            }]
          }
        }
        """.data(using: .utf8)!

        let installed = try AntigravityHookInstaller.installHooksJSON(
            existingData: existing,
            preInvocationCommand: "'/tmp/OpenIslandHooks' --source antigravity --event pre-invocation",
            stopCommand: "'/tmp/OpenIslandHooks' --source antigravity --event stop"
        )

        #expect(try AntigravityHookInstaller.containsManagedHooks(in: installed.contents))
    }

    @Test
    func preInvocationAndIdleStopProduceRunningThenCompletedEvents() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let runningPayload = AntigravityHookPayload(
            conversationID: "antigravity-session-1",
            workspacePaths: ["/tmp/worktree"],
            invocationNum: 0,
            hookEventName: .preInvocation
        )
        let stoppedPayload = AntigravityHookPayload(
            conversationID: "antigravity-session-1",
            workspacePaths: ["/tmp/worktree"],
            executionNum: 1,
            terminationReason: "model_stop",
            fullyIdle: true,
            hookEventName: .stop
        )

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAntigravityHook(runningPayload))
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAntigravityHook(stoppedPayload))

        var iterator = stream.makeAsyncIterator()
        let started = try await nextAntigravityEvent(from: &iterator, maxEvents: 6) {
            if case .sessionStarted = $0 { return true }
            return false
        }
        guard case let .sessionStarted(startPayload) = started else {
            Issue.record("Expected Antigravity session start")
            return
        }
        #expect(startPayload.tool == .antigravity)
        #expect(startPayload.initialPhase == .running)

        let completed = try await nextAntigravityEvent(from: &iterator, maxEvents: 6) {
            if case .sessionCompleted = $0 { return true }
            return false
        }
        guard case let .sessionCompleted(completionPayload) = completed else {
            Issue.record("Expected Antigravity completion")
            return
        }
        #expect(completionPayload.sessionID == "antigravity-session-1")
        #expect(completionPayload.summary == "Antigravity completed the task in worktree.")
    }

    @Test
    func subagentsInSameWorkspaceAggregateIntoSingleSession() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        // Main session starts
        let mainPayload = AntigravityHookPayload(
            conversationID: "main-conversation-uuid",
            workspacePaths: ["/tmp/my-project"],
            hookEventName: .preInvocation
        )
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAntigravityHook(mainPayload))

        var iterator = stream.makeAsyncIterator()
        let started = try await nextAntigravityEvent(from: &iterator, maxEvents: 6) {
            if case .sessionStarted = $0 { return true }
            return false
        }
        guard case let .sessionStarted(startEvent) = started else {
            Issue.record("Expected main session to start")
            return
        }
        #expect(startEvent.sessionID == "main-conversation-uuid")

        // Subagent starts with a different UUID but same workspace
        let subagentPayload = AntigravityHookPayload(
            conversationID: "subagent-uuid-999",
            workspacePaths: ["/tmp/my-project"],
            hookEventName: .preInvocation
        )
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAntigravityHook(subagentPayload))

        // Should receive activityUpdated for the MAIN session ID, NOT a new sessionStarted
        let subActivity = try await nextAntigravityEvent(from: &iterator, maxEvents: 6) {
            if case .activityUpdated = $0 { return true }
            return false
        }
        guard case let .activityUpdated(update) = subActivity else {
            Issue.record("Expected subagent to emit activity update on main session")
            return
        }
        #expect(update.sessionID == "main-conversation-uuid")

        // Subagent completes turn
        let stopPayload = AntigravityHookPayload(
            conversationID: "subagent-uuid-999",
            workspacePaths: ["/tmp/my-project"],
            terminationReason: "model_stop",
            hookEventName: .stop
        )
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAntigravityHook(stopPayload))

        let completed = try await nextAntigravityEvent(from: &iterator, maxEvents: 6) {
            if case .sessionCompleted = $0 { return true }
            return false
        }
        guard case let .sessionCompleted(comp) = completed else {
            Issue.record("Expected completion event for main session")
            return
        }
        #expect(comp.sessionID == "main-conversation-uuid")
    }
}

private func nextAntigravityEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator,
    maxEvents: Int,
    matching predicate: (AgentEvent) -> Bool
) async throws -> AgentEvent {
    for _ in 0..<maxEvents {
        if let event = try await iterator.next(), predicate(event) {
            return event
        }
    }
    throw AntigravityTestError.matchNotFound
}

private enum AntigravityTestError: Error {
    case matchNotFound
}
