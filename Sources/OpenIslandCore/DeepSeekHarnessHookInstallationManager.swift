import Foundation

public struct DeepSeekHookInstallationStatus: Equatable, Sendable {
    public var configDirectory: URL
    public var configFileURL: URL
    public var manifestURL: URL
    public var hooksBinaryURL: URL?
    public var managedHooksPresent: Bool
    public var manifest: DeepSeekHookInstallerManifest?

    public init(
        configDirectory: URL,
        configFileURL: URL,
        manifestURL: URL,
        hooksBinaryURL: URL?,
        managedHooksPresent: Bool,
        manifest: DeepSeekHookInstallerManifest?
    ) {
        self.configDirectory = configDirectory
        self.configFileURL = configFileURL
        self.manifestURL = manifestURL
        self.hooksBinaryURL = hooksBinaryURL
        self.managedHooksPresent = managedHooksPresent
        self.manifest = manifest
    }
}

public final class DeepSeekHookInstallationManager: @unchecked Sendable {
    public let configDirectory: URL
    public let managedHooksBinaryURL: URL
    private let fileManager: FileManager

    public init(
        configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/web", isDirectory: true),
        managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.configDirectory = configDirectory
        self.managedHooksBinaryURL = managedHooksBinaryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func status(hooksBinaryURL: URL? = nil) throws -> DeepSeekHookInstallationStatus {
        let configFileURL = configDirectory.appendingPathComponent("cordis.patch.yml")
        let manifestURL = configDirectory.appendingPathComponent(DeepSeekHookInstallerManifest.fileName)
        let resolvedBinaryURL = resolvedHooksBinaryURL(explicitURL: hooksBinaryURL)
        let content = try? String(contentsOf: configFileURL, encoding: .utf8)
        let manifest = try loadManifest(at: manifestURL)
        let managedHooksPresent = DeepSeekHookInstaller.containsManagedHooks(in: content)

        return DeepSeekHookInstallationStatus(
            configDirectory: configDirectory,
            configFileURL: configFileURL,
            manifestURL: manifestURL,
            hooksBinaryURL: resolvedBinaryURL,
            managedHooksPresent: managedHooksPresent,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(hooksBinaryURL: URL) throws -> DeepSeekHookInstallationStatus {
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let configFileURL = configDirectory.appendingPathComponent("cordis.patch.yml")
        let manifestURL = configDirectory.appendingPathComponent(DeepSeekHookInstallerManifest.fileName)
        let existingContent = try? String(contentsOf: configFileURL, encoding: .utf8)
        let installedBinaryURL = try ManagedHooksBinary.install(
            from: hooksBinaryURL,
            to: managedHooksBinaryURL,
            fileManager: fileManager
        )
        let turnStartCommand = DeepSeekHookInstaller.hookCommand(
            for: installedBinaryURL.path,
            event: .turnStart
        )
        let turnEndCommand = DeepSeekHookInstaller.hookCommand(
            for: installedBinaryURL.path,
            event: .turnEnd
        )
        let mutation = DeepSeekHookInstaller.installHooks(
            existingContent: existingContent,
            turnStartCommand: turnStartCommand,
            turnEndCommand: turnEndCommand
        )

        if mutation.changed, fileManager.fileExists(atPath: configFileURL.path) {
            try backupFile(at: configFileURL)
        }
        if let contents = mutation.contents {
            try contents.write(to: configFileURL, atomically: true, encoding: .utf8)
        }

        let manifest = DeepSeekHookInstallerManifest(
            turnStartCommand: turnStartCommand,
            turnEndCommand: turnEndCommand
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status(hooksBinaryURL: installedBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> DeepSeekHookInstallationStatus {
        let configFileURL = configDirectory.appendingPathComponent("cordis.patch.yml")
        let manifestURL = configDirectory.appendingPathComponent(DeepSeekHookInstallerManifest.fileName)
        let existingContent = try? String(contentsOf: configFileURL, encoding: .utf8)
        let mutation = DeepSeekHookInstaller.uninstallHooks(existingContent: existingContent)

        if mutation.changed, fileManager.fileExists(atPath: configFileURL.path) {
            try backupFile(at: configFileURL)
        }
        if let contents = mutation.contents {
            try contents.write(to: configFileURL, atomically: true, encoding: .utf8)
        } else if mutation.changed, fileManager.fileExists(atPath: configFileURL.path) {
            try fileManager.removeItem(at: configFileURL)
        }

        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    private func loadManifest(at url: URL) throws -> DeepSeekHookInstallerManifest? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeepSeekHookInstallerManifest.self, from: data)
    }

    private func resolvedHooksBinaryURL(explicitURL: URL?) -> URL? {
        if let explicitURL { return explicitURL.standardizedFileURL }
        guard fileManager.isExecutableFile(atPath: managedHooksBinaryURL.path) else { return nil }
        return managedHooksBinaryURL
    }

    private func backupFile(at url: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }
}
