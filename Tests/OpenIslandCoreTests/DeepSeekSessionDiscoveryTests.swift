import Foundation
import Testing
@testable import OpenIslandCore

struct DeepSeekSessionDiscoveryTests {
    @Test
    func discoveryParsesWorkspaceAndSessionProjCacheFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspaceJSON = """
        {
          "tables": {
            "workspaces": {
              "ws-123": {
                "path": "/Users/test/Documents/my-project",
                "title": "my-project",
                "sessionIds": ["session-abc-456"]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-abc-456": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/my-project"
                },
                "rows": {
                  "title": {
                    "val": "实现新特性"
                  },
                  "sessionStats": {
                    "val": {
                      "turns": 2,
                      "steps": 10,
                      "openStep": null,
                      "pendingCalls": {}
                    }
                  },
                  "sessionListMetadata": {
                    "val": {
                      "lastPromptAt": 1786953600000
                    }
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        try workspaceJSON.write(to: tempDir.appendingPathComponent("workspace.json"))
        try projCacheJSON.write(to: tempDir.appendingPathComponent("session_projcache.json"))

        let discovery = DeepSeekSessionDiscovery()
        let sessions = discovery.loadSessions(from: tempDir)

        #expect(sessions.count == 1)
        let record = try #require(sessions.first)
        #expect(record.sessionID == "session-abc-456")
        #expect(record.effectiveWorkspaceName == "my-project")
        #expect(record.effectiveTitle == "实现新特性")
        #expect(record.workingDirectory == "/Users/test/Documents/my-project")
        #expect(record.phase == .completed)
        #expect(record.turns == 2)
        #expect(record.steps == 10)
        #expect(!record.isRunningStep)
    }

    @Test
    func discoveryDetectsRunningStateWhenOpenStepIsActive() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-running-1": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/repo"
                },
                "rows": {
                  "title": {
                    "val": "正在执行测试"
                  },
                  "sessionStats": {
                    "val": {
                      "turns": 1,
                      "steps": 3,
                      "openStep": {
                        "stepIndex": 3
                      },
                      "pendingCalls": {}
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
        let sessions = discovery.loadSessions(from: tempDir)

        #expect(sessions.count == 1)
        let record = try #require(sessions.first)
        #expect(record.sessionID == "session-running-1")
        #expect(record.phase == .running)
        #expect(record.isRunningStep)
        #expect(record.sessionTitle == "DeepSeek · 正在执行测试")
        #expect(record.runningSummary.contains("正在执行测试"))
    }

    @Test
    func discoverySkipsBlankSessionsWithoutAUserTask() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-blank-1": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/repo"
                },
                "rows": {
                  "sessionStats": {
                    "val": {
                      "turns": 0,
                      "steps": 0,
                      "openStep": null,
                      "pendingCalls": {}
                    }
                  },
                  "sessionListMetadata": {
                    "val": {
                      "blank": true,
                      "lastPromptAt": null
                    }
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        try projCacheJSON.write(to: tempDir.appendingPathComponent("session_projcache.json"))

        let sessions = DeepSeekSessionDiscovery().loadSessions(from: tempDir)

        #expect(sessions.isEmpty)
    }

    @Test
    func discoveryKeepsFirstPromptRunningBeforeItsFirstStepStarts() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-awaiting-step-1": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/repo"
                },
                "rows": {
                  "sessionStats": {
                    "val": {
                      "turns": 0,
                      "steps": 0,
                      "openStep": null,
                      "pendingCalls": {}
                    }
                  },
                  "sessionListMetadata": {
                    "val": {
                      "blank": false,
                      "lastPromptAt": 1786953600000
                    }
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        try projCacheJSON.write(to: tempDir.appendingPathComponent("session_projcache.json"))

        let sessions = DeepSeekSessionDiscovery().loadSessions(from: tempDir)
        let record = try #require(sessions.first)

        #expect(sessions.count == 1)
        #expect(record.phase == .running)
        #expect(record.turns == 0)
    }

    @Test
    func multipleSessionsInSameDirectoryAreKeptDistinct() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projCacheJSON = """
        {
          "tables": {
            "sessions": {
              "session-task-1": {
                "identity": {
                  "createdAt": 1786953500000,
                  "cwd": "/Users/test/Documents/shared-dir"
                },
                "rows": {
                  "title": {
                    "val": "Task 1"
                  },
                  "sessionStats": {
                    "val": {
                      "turns": 1,
                      "openStep": null
                    }
                  }
                }
              },
              "session-task-2": {
                "identity": {
                  "createdAt": 1786953600000,
                  "cwd": "/Users/test/Documents/shared-dir"
                },
                "rows": {
                  "title": {
                    "val": "Task 2"
                  },
                  "sessionStats": {
                    "val": {
                      "turns": 1,
                      "openStep": { "active": true }
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
        let sessions = discovery.loadSessions(from: tempDir)

        #expect(sessions.count == 2)
        let map = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        #expect(map["session-task-1"]?.phase == .completed)
        #expect(map["session-task-2"]?.phase == .running)
        #expect(map["session-task-1"]?.workingDirectory == "/Users/test/Documents/shared-dir")
        #expect(map["session-task-2"]?.workingDirectory == "/Users/test/Documents/shared-dir")
    }
}
