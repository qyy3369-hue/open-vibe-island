import Foundation

public struct DeepSeekSessionRecord: Equatable, Sendable {
    public var sessionID: String
    public var workspaceID: String?
    public var workspaceTitle: String?
    public var title: String?
    public var workingDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: SessionPhase
    public var turns: Int
    public var steps: Int
    public var isRunningStep: Bool

    public init(
        sessionID: String,
        workspaceID: String? = nil,
        workspaceTitle: String? = nil,
        title: String? = nil,
        workingDirectory: String,
        createdAt: Date,
        updatedAt: Date,
        phase: SessionPhase,
        turns: Int = 0,
        steps: Int = 0,
        isRunningStep: Bool = false
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.title = title
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.turns = turns
        self.steps = steps
        self.isRunningStep = isRunningStep
    }

    public var effectiveWorkspaceName: String {
        if let workspaceTitle = workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceTitle.isEmpty {
            return workspaceTitle
        }
        return WorkspaceNameResolver.workspaceName(for: workingDirectory)
    }

    public var effectiveTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return effectiveWorkspaceName
    }

    public var sessionTitle: String {
        "DeepSeek · \(effectiveTitle)"
    }

    public var runningSummary: String {
        "DeepSeek is working on \(effectiveTitle) in \(effectiveWorkspaceName)."
    }

    public var completedSummary: String {
        "DeepSeek completed task in \(effectiveWorkspaceName)."
    }

    public var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: "DeepSeek Harness",
            workspaceName: effectiveWorkspaceName,
            paneTitle: effectiveTitle,
            workingDirectory: workingDirectory
        )
    }

    public func makeAgentSession() -> AgentSession {
        AgentSession(
            id: sessionID,
            title: sessionTitle,
            tool: .deepseekHarness,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: phase == .running ? runningSummary : completedSummary,
            updatedAt: updatedAt,
            jumpTarget: defaultJumpTarget
        )
    }
}

public enum DeepSeekStorageLocations {
    public static var defaultRoots: [URL] {
        var roots: [URL] = []
        if let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"], !dshHome.isEmpty {
            roots.append(URL(fileURLWithPath: dshHome, isDirectory: true).appendingPathComponent("storages", isDirectory: true))
        }
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.github.hairyf.deepseek-harness-desktop/data/dsh/storages", isDirectory: true)
        roots.append(appSupport)
        let dotDsh = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages", isDirectory: true)
        roots.append(dotDsh)
        return roots
    }
}

public enum DynamicJSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: DynamicJSONValue])
    case array([DynamicJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([DynamicJSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: DynamicJSONValue].self) {
            self = .object(dict)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(b):
            try container.encode(b)
        case let .number(n):
            try container.encode(n)
        case let .string(s):
            try container.encode(s)
        case let .array(arr):
            try container.encode(arr)
        case let .object(dict):
            try container.encode(dict)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public final class DeepSeekSessionDiscovery: @unchecked Sendable {
    public struct WorkspaceFile: Codable, Sendable {
        public struct WorkspaceEntry: Codable, Sendable {
            public var path: String?
            public var title: String?
            public var sessionIds: [String]?
            public var createdAt: String?
            public var updatedAt: String?
        }
        public struct Tables: Codable, Sendable {
            public var workspaces: [String: WorkspaceEntry]?
        }
        public var tables: Tables?
    }

    public struct SessionProjCacheFile: Codable, Sendable {
        public struct Identity: Codable, Sendable {
            public var createdAt: Double?
            public var cwd: String?
        }
        public struct SessionStatsVal: Codable, Sendable {
            public var turns: Int?
            public var steps: Int?
            public var lastTurn: Int?
            public var openStep: DynamicJSONValue?
            public var pendingCalls: [String: DynamicJSONValue]?
        }
        public struct SessionListMetadataVal: Codable, Sendable {
            public var blank: Bool?
            public var lastPromptAt: Double?
        }
        public struct ValWrapper<T: Codable & Sendable>: Codable, Sendable {
            public var ver: Int?
            public var seq: Int?
            public var val: T?
        }
        public struct Rows: Codable, Sendable {
            public var title: ValWrapper<String?>?
            public var sessionStats: ValWrapper<SessionStatsVal>?
            public var sessionListMetadata: ValWrapper<SessionListMetadataVal>?
        }
        public struct SessionEntry: Codable, Sendable {
            public var identity: Identity?
            public var rows: Rows?
        }
        public struct Tables: Codable, Sendable {
            public var sessions: [String: SessionEntry]?
        }
        public var tables: Tables?
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discoverSessions(storageRoots: [URL] = DeepSeekStorageLocations.defaultRoots) -> [DeepSeekSessionRecord] {
        var records: [String: DeepSeekSessionRecord] = [:]

        for root in storageRoots {
            let loaded = loadSessions(from: root)
            for record in loaded {
                if let existing = records[record.sessionID] {
                    if record.updatedAt > existing.updatedAt {
                        records[record.sessionID] = record
                    }
                } else {
                    records[record.sessionID] = record
                }
            }
        }

        return Array(records.values)
    }

    public func loadSessions(from storageDirectoryURL: URL) -> [DeepSeekSessionRecord] {
        let workspaceURL = storageDirectoryURL.appendingPathComponent("workspace.json")
        let projCacheURL = storageDirectoryURL.appendingPathComponent("session_projcache.json")

        guard fileManager.fileExists(atPath: projCacheURL.path) else {
            return []
        }

        var workspaceMap: [String: (workspaceID: String, title: String?, path: String)] = [:]
        if let workspaceData = try? Data(contentsOf: workspaceURL),
           let workspaceFile = try? JSONDecoder().decode(WorkspaceFile.self, from: workspaceData),
           let workspaces = workspaceFile.tables?.workspaces {
            for (wsID, wsEntry) in workspaces {
                guard let path = wsEntry.path else { continue }
                if let sessionIds = wsEntry.sessionIds {
                    for sessionID in sessionIds {
                        workspaceMap[sessionID] = (workspaceID: wsID, title: wsEntry.title, path: path)
                    }
                }
            }
        }

        guard let projCacheData = try? Data(contentsOf: projCacheURL),
              let projCacheFile = try? JSONDecoder().decode(SessionProjCacheFile.self, from: projCacheData),
              let sessions = projCacheFile.tables?.sessions else {
            return []
        }

        var records: [DeepSeekSessionRecord] = []
        for (sessionID, sessionEntry) in sessions {
            let wsInfo = workspaceMap[sessionID]
            let cwd = sessionEntry.identity?.cwd ?? wsInfo?.path ?? ""
            guard !cwd.isEmpty else { continue }

            let createdAtMs = sessionEntry.identity?.createdAt ?? 0
            let createdAt = createdAtMs > 0
                ? Date(timeIntervalSince1970: createdAtMs / 1000.0)
                : (try? fileManager.attributesOfItem(atPath: projCacheURL.path)[.creationDate] as? Date) ?? .now

            let listMetadata = sessionEntry.rows?.sessionListMetadata?.val
            let lastPromptAtMs = listMetadata?.lastPromptAt ?? 0
            let updatedAt = lastPromptAtMs > 0
                ? Date(timeIntervalSince1970: lastPromptAtMs / 1000.0)
                : createdAt

            let title = sessionEntry.rows?.title?.val ?? nil
            let stats = sessionEntry.rows?.sessionStats?.val
            let turns = stats?.turns ?? 0
            let steps = stats?.steps ?? 0

            let hasActiveOpenStep = stats?.openStep != nil && !stats!.openStep!.isNull
            let hasActivePendingCalls = stats?.pendingCalls?.isEmpty == false
            let hasActiveWork = hasActiveOpenStep || hasActivePendingCalls
            let hasObservedTask = lastPromptAtMs > 0 || turns > 0 || hasActiveWork
            guard listMetadata?.blank != true, hasObservedTask else { continue }

            // Before the first step starts, a submitted prompt has turns == 0
            // and no openStep yet. Keep it running until a completed turn is
            // durably observed instead of reporting a false completion.
            let isRunning = hasActiveWork || turns == 0

            let phase: SessionPhase = isRunning ? .running : .completed

            records.append(
                DeepSeekSessionRecord(
                    sessionID: sessionID,
                    workspaceID: wsInfo?.workspaceID,
                    workspaceTitle: wsInfo?.title,
                    title: title,
                    workingDirectory: cwd,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    phase: phase,
                    turns: turns,
                    steps: steps,
                    isRunningStep: isRunning
                )
            )
        }

        return records
    }
}

public final class DeepSeekStorageWatcher: @unchecked Sendable {
    public var eventHandler: (@Sendable (AgentEvent) -> Void)?

    private let discovery: DeepSeekSessionDiscovery
    private let storageRoots: [URL]
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.openisland.deepseek.storage-watcher")
    private var timer: DispatchSourceTimer?
    private var knownSessions: [String: DeepSeekSessionRecord] = [:]
    private var isStarted = false

    public init(
        discovery: DeepSeekSessionDiscovery = DeepSeekSessionDiscovery(),
        storageRoots: [URL] = DeepSeekStorageLocations.defaultRoots,
        pollInterval: TimeInterval = 2.0
    ) {
        self.discovery = discovery
        self.storageRoots = storageRoots
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    public func start() {
        queue.sync {
            guard !isStarted else { return }
            isStarted = true

            // Prime initial session state without firing completion notifications.
            let initialSessions = discovery.discoverSessions(storageRoots: storageRoots)
            for session in initialSessions {
                knownSessions[session.sessionID] = session
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.pollLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            isStarted = false
            knownSessions.removeAll()
        }
    }

    private func pollLocked() {
        let currentSessions = discovery.discoverSessions(storageRoots: storageRoots)
        let currentMap = Dictionary(uniqueKeysWithValues: currentSessions.map { ($0.sessionID, $0) })

        for (sessionID, current) in currentMap {
            if let previous = knownSessions[sessionID] {
                if previous.phase != current.phase || previous.steps != current.steps || previous.turns != current.turns {
                    if current.phase == .running {
                        eventHandler?(
                            .activityUpdated(
                                SessionActivityUpdated(
                                    sessionID: current.sessionID,
                                    summary: current.runningSummary,
                                    phase: .running,
                                    timestamp: .now
                                )
                            )
                        )
                    } else if previous.phase == .running && current.phase == .completed {
                        eventHandler?(
                            .sessionCompleted(
                                SessionCompleted(
                                    sessionID: current.sessionID,
                                    summary: current.completedSummary,
                                    timestamp: .now
                                )
                            )
                        )
                    } else if current.phase == .completed && current.updatedAt > previous.updatedAt {
                        eventHandler?(
                            .sessionCompleted(
                                SessionCompleted(
                                    sessionID: current.sessionID,
                                    summary: current.completedSummary,
                                    timestamp: .now
                                )
                            )
                        )
                    }
                }
            } else {
                // Newly discovered session while watcher is active
                // A fast task can finish before the first persisted snapshot is
                // observed. Bootstrap it as running so the immediately following
                // completion remains a real transition for notification dedupe.
                let initialPhase: SessionPhase = .running
                eventHandler?(
                    .sessionStarted(
                        SessionStarted(
                            sessionID: current.sessionID,
                            title: current.sessionTitle,
                            tool: .deepseekHarness,
                            origin: .live,
                            initialPhase: initialPhase,
                            summary: current.runningSummary,
                            timestamp: .now,
                            jumpTarget: current.defaultJumpTarget
                        )
                    )
                )
                if current.phase == .completed {
                    eventHandler?(
                        .sessionCompleted(
                            SessionCompleted(
                                sessionID: current.sessionID,
                                summary: current.completedSummary,
                                timestamp: .now
                            )
                        )
                    )
                }
            }

            knownSessions[sessionID] = current
        }
    }
}
