import Foundation
import Testing
@testable import OpenIslandCore

actor EventCounter {
    var startedEvents = 0
    var completedEvents = 0
    func incrementStarted() { startedEvents += 1 }
    func incrementCompleted() { completedEvents += 1 }
}

struct DeepSeekStorageWatcherTests {
    @Test
    func watcherEmitsStartedAndCompletedForAlreadyCompletedSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-short-1": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/short-task"
                },
                "rows": {
                  "title": { "val": "Fast Task" },
                  "sessionStats": {
                    "val": {
                      "turns": 1,
                      "openStep": null
                    }
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!
        try projCacheJSON.write(to: tempDir.appendingPathComponent("session_projcache.json"))
        
        let discovery = DeepSeekSessionDiscovery()
        
        let counter = EventCounter()
        
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        
        let emptyWatcher = DeepSeekStorageWatcher(discovery: discovery, storageRoots: [emptyDir], pollInterval: 0.1)
        
        emptyWatcher.eventHandler = { event in
            switch event {
            case .sessionStarted(let payload):
                if payload.sessionID == "session-short-1" {
                    Task { await counter.incrementStarted() }
                }
            case .sessionCompleted(let payload):
                if payload.sessionID == "session-short-1" {
                    Task { await counter.incrementCompleted() }
                }
            default:
                break
            }
        }
        
        emptyWatcher.start()
        
        // Write the file to emptyDir
        try projCacheJSON.write(to: emptyDir.appendingPathComponent("session_projcache.json"))
        
        // wait for poll
        try await Task.sleep(for: .milliseconds(300))
        emptyWatcher.stop()
        
        let finalStarted = await counter.startedEvents
        let finalCompleted = await counter.completedEvents
        #expect(finalStarted == 1)
        #expect(finalCompleted == 1)
    }
}
