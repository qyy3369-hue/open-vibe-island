import Foundation

public struct DeepSeekHookInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-deepseek-hooks-install.json"

    public var turnStartCommand: String
    public var turnEndCommand: String
    public var installedAt: Date

    public init(
        turnStartCommand: String,
        turnEndCommand: String,
        installedAt: Date = .now
    ) {
        self.turnStartCommand = turnStartCommand
        self.turnEndCommand = turnEndCommand
        self.installedAt = installedAt
    }
}

public struct DeepSeekHookFileMutation: Equatable, Sendable {
    public var contents: String?
    public var changed: Bool
    public var managedHooksPresent: Bool

    public init(contents: String?, changed: Bool, managedHooksPresent: Bool) {
        self.contents = contents
        self.changed = changed
        self.managedHooksPresent = managedHooksPresent
    }
}

public enum DeepSeekHookInstaller {
    public static let beginMarker = "# --- Open Island managed hooks (do not edit) ---"
    public static let endMarker = "# --- End Open Island managed hooks ---"

    public enum HookEvent {
        case turnStart
        case turnEnd

        var dshEventName: String {
            switch self {
            case .turnStart: return "turn/start"
            case .turnEnd: return "turn/end"
            }
        }

        var cliArgument: String {
            switch self {
            case .turnStart: return "turn-start"
            case .turnEnd: return "turn-end"
            }
        }
    }

    public static func hookCommand(
        for binaryPath: String,
        event: HookEvent
    ) -> String {
        "\(shellQuote(binaryPath)) --source deepseek --event \(event.cliArgument)"
    }

    /// Generates the YAML block to inject into cordis.patch.yml.
    public static func managedYAMLBlock(
        turnStartCommand: String,
        turnEndCommand: String
    ) -> String {
        """
        \(beginMarker)
        hooks:
          - on: 'turn/start'
            run: '\(turnStartCommand)'
            timeout: 45
          - on: 'turn/end'
            run: '\(turnEndCommand)'
            timeout: 45
        \(endMarker)
        """
    }

    public static func installHooks(
        existingContent: String?,
        turnStartCommand: String,
        turnEndCommand: String
    ) -> DeepSeekHookFileMutation {
        var content = existingContent ?? ""

        // Remove existing managed block if present
        content = removeManagedBlock(from: content)

        // Append managed block
        let block = managedYAMLBlock(
            turnStartCommand: turnStartCommand,
            turnEndCommand: turnEndCommand
        )

        if !content.isEmpty && !content.hasSuffix("\n") {
            content += "\n"
        }
        content += block + "\n"

        let changed = content != (existingContent ?? "")
        return DeepSeekHookFileMutation(
            contents: content,
            changed: changed,
            managedHooksPresent: true
        )
    }

    public static func uninstallHooks(
        existingContent: String?
    ) -> DeepSeekHookFileMutation {
        guard let existingContent, !existingContent.isEmpty else {
            return DeepSeekHookFileMutation(contents: nil, changed: false, managedHooksPresent: false)
        }

        let cleaned = removeManagedBlock(from: existingContent)
        let changed = cleaned != existingContent
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeepSeekHookFileMutation(
            contents: trimmed.isEmpty ? nil : cleaned,
            changed: changed,
            managedHooksPresent: false
        )
    }

    public static func containsManagedHooks(in content: String?) -> Bool {
        guard let content else { return false }
        return content.contains(beginMarker) && content.contains(endMarker)
    }

    private static func removeManagedBlock(from content: String) -> String {
        guard let beginRange = content.range(of: beginMarker),
              let endRange = content.range(of: endMarker) else {
            return content
        }

        // Find the start of the line containing beginMarker
        var removeStart = beginRange.lowerBound
        if removeStart > content.startIndex {
            let beforeStart = content[content.startIndex..<removeStart]
            if let lastNewline = beforeStart.lastIndex(of: "\n") {
                removeStart = content.index(after: lastNewline)
            }
        }

        // Find the end of the line containing endMarker
        var removeEnd = endRange.upperBound
        if removeEnd < content.endIndex {
            if content[removeEnd] == "\n" {
                removeEnd = content.index(after: removeEnd)
            }
        }

        var result = String(content[content.startIndex..<removeStart])
        result += String(content[removeEnd..<content.endIndex])
        return result
    }

    private static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }
        return "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
