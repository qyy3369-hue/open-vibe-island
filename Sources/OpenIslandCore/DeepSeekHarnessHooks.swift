import Foundation

/// Hook event types supported by DeepSeek Harness (dsh).
public enum DeepSeekHookEventName: String, Codable, Sendable {
    case turnStart = "turn-start"
    case turnEnd = "turn-end"
    case sessionStart = "session-start"
}

/// Payload emitted by DeepSeek Harness config-driven hooks.
///
/// DeepSeek Harness does not include the hook name in stdin, so OpenIslandHooks
/// supplies `hookEventName` from its managed `--event` argument before the
/// payload crosses the local bridge.
public struct DeepSeekHookPayload: Equatable, Codable, Sendable {
    public var sessionID: String
    public var workspacePaths: [String]
    public var modelName: String?
    public var terminationReason: String?
    public var error: String?
    public var hookEventName: DeepSeekHookEventName?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case workspacePaths
        case modelName
        case terminationReason
        case error
        case hookEventName
    }

    public init(
        sessionID: String,
        workspacePaths: [String],
        modelName: String? = nil,
        terminationReason: String? = nil,
        error: String? = nil,
        hookEventName: DeepSeekHookEventName? = nil
    ) {
        self.sessionID = sessionID
        self.workspacePaths = workspacePaths
        self.modelName = modelName
        self.terminationReason = terminationReason
        self.error = error
        self.hookEventName = hookEventName
    }
}

public extension DeepSeekHookPayload {
    var workingDirectory: String? {
        workspacePaths.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    var workspaceName: String {
        guard let workingDirectory else { return "Workspace" }
        return WorkspaceNameResolver.workspaceName(for: workingDirectory)
    }

    var sessionTitle: String {
        "DeepSeek · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: "DeepSeek Harness",
            workspaceName: workspaceName,
            paneTitle: "DeepSeek \(sessionID.prefix(8))",
            workingDirectory: workingDirectory
        )
    }

    var runningSummary: String {
        "DeepSeek Harness is working in \(workspaceName)."
    }

    var stoppedSummary: String {
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return "DeepSeek Harness stopped with an error in \(workspaceName)."
        }

        switch terminationReason?.lowercased() {
        case "error":
            return "DeepSeek Harness stopped with an error in \(workspaceName)."
        case "aborted":
            return "DeepSeek Harness task was aborted in \(workspaceName)."
        default:
            return "DeepSeek Harness completed the task in \(workspaceName)."
        }
    }

    func withHookEvent(_ event: DeepSeekHookEventName) -> DeepSeekHookPayload {
        var payload = self
        payload.hookEventName = event
        return payload
    }
}
