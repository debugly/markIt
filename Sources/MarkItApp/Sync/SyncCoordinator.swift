//
//  SyncCoordinator.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import Foundation
import Combine

public final class SyncCoordinator: ObservableObject, @unchecked Sendable {
    public static let shared = SyncCoordinator()

    private let defaultsSuite = "com.debugly.markit"
    private let configsStorageKey = "WebDAVFolderConfigs"

    @Published public private(set) var configs: [WebDAVFolderConfig] = []
    @Published public private(set) var syncStatuses: [URL: FolderSyncStatus] = [:]

    private var autoSyncTimers: [UUID: DispatchWorkItem] = [:]
    private var activeSyncTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        loadConfigs()
    }

    // MARK: - Config Persistence

    private var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuite) ?? .standard
    }

    private func loadConfigs() {
        guard let data = defaults.data(forKey: configsStorageKey) else { return }
        if let decoded = try? JSONDecoder().decode([WebDAVFolderConfig].self, from: data) {
            self.configs = decoded
            for cfg in decoded {
                if let localURL = cfg.resolveLocalURL() {
                    self.syncStatuses[localURL] = .synced
                }
            }

            // 启动后批量预加载所有配置的 WebDAV 密码到内存缓存，避免频繁解密
            let accounts = decoded.map { $0.id.uuidString }
            CredentialVault.preload(accounts: accounts)
        }
    }

    /// 获取对应 WebDAV 配置的密码（优先命中内存缓存）
    public func password(for configId: UUID) -> String? {
        CredentialVault.loadPassword(for: configId.uuidString)
    }

    private func saveConfigs() {
        if let encoded = try? JSONEncoder().encode(configs) {
            defaults.set(encoded, forKey: configsStorageKey)
        }
    }

    // MARK: - Config Management

    public func addConfig(_ config: WebDAVFolderConfig, password: String) {
        // 保存密码到基于硬件绑定的安全加密保险箱
        _ = CredentialVault.savePassword(password, for: config.id.uuidString)
        configs.append(config)
        saveConfigs()
        if let localURL = config.resolveLocalURL()?.standardizedFileURL {
            syncStatuses[localURL] = .synced
        }
        // Kick off immediate sync
        Task {
            await syncFolder(configId: config.id)
        }
    }

    public func updateConfig(_ config: WebDAVFolderConfig, password: String) {
        _ = CredentialVault.savePassword(password, for: config.id.uuidString)
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            let oldLocal = configs[idx].resolveLocalURL()?.standardizedFileURL
            let newLocal = config.resolveLocalURL()?.standardizedFileURL
            if let oldLocal = oldLocal, oldLocal != newLocal {
                syncStatuses.removeValue(forKey: oldLocal)
            }
            configs[idx] = config
        } else {
            configs.append(config)
        }
        saveConfigs()
        if let localURL = config.resolveLocalURL()?.standardizedFileURL {
            syncStatuses[localURL] = .synced
        }
        Task {
            await syncFolder(configId: config.id)
        }
    }

    public func removeConfig(id: UUID) {
        if let cfg = configs.first(where: { $0.id == id }), let localURL = cfg.resolveLocalURL()?.standardizedFileURL {
            syncStatuses.removeValue(forKey: localURL)
        }
        CredentialVault.deletePassword(for: id.uuidString)
        configs.removeAll { $0.id == id }
        autoSyncTimers[id]?.cancel()
        autoSyncTimers.removeValue(forKey: id)
        activeSyncTasks[id]?.cancel()
        activeSyncTasks.removeValue(forKey: id)
        saveConfigs()

        // Clean up manifest and pending deletions
        try? FileManager.default.removeItem(at: manifestFileURL(for: id))
        var all = defaults.dictionary(forKey: pendingDeletionsKey) as? [String: [String]] ?? [:]
        all.removeValue(forKey: id.uuidString)
        defaults.set(all, forKey: pendingDeletionsKey)
    }

    public func config(for fileOrFolderURL: URL) -> WebDAVFolderConfig? {
        let filePath = fileOrFolderURL.standardizedFileURL.path
        for cfg in configs {
            if let localRoot = cfg.resolveLocalURL() {
                let rootPath = localRoot.standardizedFileURL.path
                if filePath == rootPath || filePath.hasPrefix(rootPath + "/") {
                    return cfg
                }
            }
        }
        return nil
    }

    public func rootConfig(for folderURL: URL) -> WebDAVFolderConfig? {
        let folderPath = folderURL.standardizedFileURL.path
        for cfg in configs {
            if let localRoot = cfg.resolveLocalURL() {
                if localRoot.standardizedFileURL.path == folderPath {
                    return cfg
                }
            }
        }
        return nil
    }

    public func syncStatus(for folderURL: URL) -> FolderSyncStatus {
        let stdURL = folderURL.standardizedFileURL
        for (key, status) in syncStatuses {
            if key.standardizedFileURL == stdURL || key.standardizedFileURL.path == stdURL.path {
                return status
            }
        }
        if let cfg = config(for: folderURL), let localRoot = cfg.resolveLocalURL() {
            let rootStd = localRoot.standardizedFileURL
            for (key, status) in syncStatuses {
                if key.standardizedFileURL == rootStd || key.standardizedFileURL.path == rootStd.path {
                    return status
                }
            }
        }
        return .synced
    }

    // MARK: - Manifest & Deletion Tracking

    private var manifestDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Markit/sync_manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifestFileURL(for configId: UUID) -> URL {
        manifestDirectoryURL.appendingPathComponent("\(configId.uuidString).json")
    }

    private func loadManifest(for configId: UUID) -> [String: SyncManifestEntry] {
        let file = manifestFileURL(for: configId)
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: SyncManifestEntry].self, from: data)) ?? [:]
    }

    private func saveManifest(_ manifest: [String: SyncManifestEntry], for configId: UUID) {
        let file = manifestFileURL(for: configId)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: file)
        }
    }

    private let pendingDeletionsKey = "WebDAVPendingDeletions"

    private func loadPendingDeletions(for configId: UUID) -> Set<String> {
        let all = defaults.dictionary(forKey: pendingDeletionsKey) as? [String: [String]] ?? [:]
        return Set(all[configId.uuidString] ?? [])
    }

    private func savePendingDeletions(_ set: Set<String>, for configId: UUID) {
        var all = defaults.dictionary(forKey: pendingDeletionsKey) as? [String: [String]] ?? [:]
        if set.isEmpty {
            all.removeValue(forKey: configId.uuidString)
        } else {
            all[configId.uuidString] = Array(set)
        }
        defaults.set(all, forKey: pendingDeletionsKey)
    }

    public func addPendingDeletion(configId: UUID, relativePath: String) {
        var set = loadPendingDeletions(for: configId)
        set.insert(relativePath)
        savePendingDeletions(set, for: configId)
    }

    public func removePendingDeletion(configId: UUID, relativePath: String) {
        var set = loadPendingDeletions(for: configId)
        set.remove(relativePath)
        set = set.filter { !$0.hasPrefix(relativePath + "/") }
        savePendingDeletions(set, for: configId)
    }

    private func isMarkedPendingDeletion(relativePath: String, in pendingDeletions: Set<String>) -> Bool {
        if pendingDeletions.contains(relativePath) { return true }
        for pending in pendingDeletions {
            if relativePath == pending || relativePath.hasPrefix(pending + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - Change Detection & Auto-Sync Trigger

    public func recordDeletion(fileOrFolderURL: URL) {
        guard let cfg = config(for: fileOrFolderURL), let localRoot = cfg.resolveLocalURL() else {
            return
        }
        let rootPath = localRoot.standardizedFileURL.path
        let itemPath = fileOrFolderURL.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else { return }

        let relPath = String(itemPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relPath.isEmpty else { return }

        addPendingDeletion(configId: cfg.id, relativePath: relPath)

        // Remove from manifest
        var manifest = loadManifest(for: cfg.id)
        manifest.removeValue(forKey: relPath)
        manifest = manifest.filter { !$0.key.hasPrefix(relPath + "/") }
        saveManifest(manifest, for: cfg.id)

        // Mark localRoot modified to trigger debounced sync
        markModified(fileOrFolderURL: localRoot)

        // Immediately attempt remote deletion in background
        if let password = password(for: cfg.id) {
            let serverURL = cfg.serverURL
            let username = cfg.username
            let remoteRoot = cfg.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let targetRemotePath = remoteRoot.isEmpty ? relPath : "\(remoteRoot)/\(relPath)"

            Task {
                let client = WebDAVClient(baseURL: serverURL, username: username, password: password)
                do {
                    print("[SyncCoordinator] 正在向云端同步删除: '\(targetRemotePath)'")
                    try await client.delete(remotePath: targetRemotePath)
                    print("[SyncCoordinator] 云端删除成功: '\(targetRemotePath)'")
                    self.removePendingDeletion(configId: cfg.id, relativePath: relPath)
                } catch {
                    print("[SyncCoordinator] 云端即时删除记录已保存（将在下次同步时重试）: \(error)")
                }
            }
        }
    }

    public func markModified(fileOrFolderURL: URL) {
        guard let cfg = config(for: fileOrFolderURL), let localRoot = cfg.resolveLocalURL() else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let rootKey = localRoot.standardizedFileURL
            if self.syncStatuses[rootKey]?.isSyncing != true {
                self.syncStatuses[rootKey] = .modified
            }
        }

        // Schedule debounced sync (4 seconds debounce)
        scheduleDebouncedAutoSync(for: cfg.id)
    }

    public func scheduleDebouncedAutoSync(for configId: UUID) {
        autoSyncTimers[configId]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task {
                await self.syncFolder(configId: configId)
            }
        }
        autoSyncTimers[configId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }

    // MARK: - Synchronization Engine

    public func syncAll() {
        for cfg in configs {
            Task {
                await syncFolder(configId: cfg.id)
            }
        }
    }

    public func syncFolder(url: URL) async {
        guard let cfg = config(for: url) else { return }
        await syncFolder(configId: cfg.id)
    }

    public func syncFolder(configId: UUID) async {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        let cfg = configs[index]
        guard let localRoot = cfg.resolveLocalURL() else {
            DispatchQueue.main.async { [weak self] in
                if let url = cfg.resolveLocalURL() {
                    self?.syncStatuses[url] = .error(message: "无法找到本地文件夹")
                }
            }
            return
        }

        guard let password = password(for: cfg.id) else {
            DispatchQueue.main.async { [weak self] in
                self?.syncStatuses[localRoot] = .error(message: "密码缺失，请重新配置 WebDAV")
            }
            return
        }

        // Avoid concurrent sync on same folder
        if let existingTask = activeSyncTasks[configId], !existingTask.isCancelled {
            return
        }

        let serverURL = cfg.serverURL
        let username = cfg.username
        let remotePath = cfg.remotePath
        let lastSync = cfg.lastSyncTime ?? Date.distantPast

        let rootKey = localRoot.standardizedFileURL
        let task = Task {
            DispatchQueue.main.async { [weak self] in
                self?.syncStatuses[rootKey] = .syncing(message: "正在同步...")
            }

            let client = WebDAVClient(baseURL: serverURL, username: username, password: password)

            do {
                print("[SyncCoordinator] 开始同步 '\(localRoot.path)' <-> '\(remotePath)'")
                // 1. Ensure remote root folder exists
                try await client.ensureDirectoryHierarchy(remotePath: remotePath)

                // 2. Perform two-way sync with manifest and deletion tracking
                let previousManifest = self.loadManifest(for: configId)
                var pendingDeletions = self.loadPendingDeletions(for: configId)
                var newManifest: [String: SyncManifestEntry] = [:]

                try await performDirectorySync(
                    client: client,
                    configId: configId,
                    localDirectory: localRoot,
                    remotePath: remotePath,
                    relativeDirPath: "",
                    lastSyncTime: lastSync,
                    previousManifest: previousManifest,
                    pendingDeletions: &pendingDeletions,
                    newManifest: &newManifest
                )

                // Save manifest and pending deletions
                self.saveManifest(newManifest, for: configId)
                self.savePendingDeletions(pendingDeletions, for: configId)

                // 3. Complete
                let now = Date()
                print("[SyncCoordinator] 同步成功完成: '\(localRoot.path)'")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.configs.firstIndex(where: { $0.id == configId }) {
                        self.configs[idx].lastSyncTime = now
                        self.saveConfigs()
                    }
                    self.syncStatuses[rootKey] = .synced
                    NotificationCenter.default.post(name: Notification.Name("WebDAVSyncDidComplete"), object: nil)
                }
            } catch {
                let errMsg = error.localizedDescription
                print("[SyncCoordinator Error] 文件夹同步失败 '\(localRoot.path)': \(errMsg) (\(error))")
                DispatchQueue.main.async { [weak self] in
                    self?.syncStatuses[rootKey] = .error(message: errMsg)
                }
            }

            self.activeSyncTasks.removeValue(forKey: configId)
        }

        activeSyncTasks[configId] = task
        await task.value
    }

    private func performDirectorySync(
        client: WebDAVClient,
        configId: UUID,
        localDirectory: URL,
        remotePath: String,
        relativeDirPath: String,
        lastSyncTime: Date,
        previousManifest: [String: SyncManifestEntry],
        pendingDeletions: inout Set<String>,
        newManifest: inout [String: SyncManifestEntry]
    ) async throws {
        let fileManager = FileManager.default

        // Fetch remote resources
        let remoteResources = try await client.listDirectory(remotePath: remotePath)
        var remoteMap: [String: WebDAVResource] = [:]
        for res in remoteResources {
            let cleanPath = res.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let filename = URL(fileURLWithPath: cleanPath).lastPathComponent
            if !filename.isEmpty {
                remoteMap[filename] = res
            }
        }

        // Fetch local items
        let localItems = (try? fileManager.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var localMap: [String: URL] = [:]
        for item in localItems {
            localMap[item.lastPathComponent] = item
        }

        // Process all unique filenames
        let allNames = Set(remoteMap.keys).union(localMap.keys)

        for name in allNames {
            // Ignore system/hidden files
            if name.hasPrefix(".") || name == ".DS_Store" { continue }

            let localURL = localMap[name]
            let remoteRes = remoteMap[name]
            let subRemotePath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
            let itemRelPath = relativeDirPath.isEmpty ? name : "\(relativeDirPath)/\(name)"
            let isPendingDelete = isMarkedPendingDeletion(relativePath: itemRelPath, in: pendingDeletions)
            let wasInManifest = previousManifest[itemRelPath] != nil

            if let local = localURL, let remote = remoteRes {
                // Exists in BOTH local and remote
                if isPendingDelete {
                    pendingDeletions.remove(itemRelPath)
                }

                if remote.isDirectory {
                    try await client.ensureDirectoryHierarchy(remotePath: subRemotePath)
                    newManifest[itemRelPath] = SyncManifestEntry(isDirectory: true)
                    try await performDirectorySync(
                        client: client,
                        configId: configId,
                        localDirectory: local,
                        remotePath: subRemotePath,
                        relativeDirPath: itemRelPath,
                        lastSyncTime: lastSyncTime,
                        previousManifest: previousManifest,
                        pendingDeletions: &pendingDeletions,
                        newManifest: &newManifest
                    )
                } else {
                    // It's a file
                    let localAttrs = try? fileManager.attributesOfItem(atPath: local.path)
                    let localMod = (localAttrs?[.modificationDate] as? Date) ?? Date.distantPast
                    let remoteMod = remote.lastModified ?? Date.distantPast

                    let localChangedSinceSync = localMod > lastSyncTime.addingTimeInterval(1.0)
                    let remoteChangedSinceSync = remoteMod > lastSyncTime.addingTimeInterval(1.0)

                    if localChangedSinceSync && remoteChangedSinceSync {
                        // Conflict! Keep local copy as conflict backup, then pull remote
                        let ext = local.pathExtension
                        let base = local.deletingPathExtension().lastPathComponent
                        let dateStr = Self.conflictDateFormatter.string(from: Date())
                        let conflictName = "\(base) (冲突-\(dateStr)).\(ext)"
                        let conflictURL = local.deletingLastPathComponent().appendingPathComponent(conflictName)
                        try? fileManager.copyItem(at: local, to: conflictURL)

                        // Download remote file to original name
                        try await client.downloadFile(remotePath: subRemotePath, to: local)
                        // Also upload conflict backup so remote gets the conflict file
                        let conflictRemotePath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + conflictName
                        try await client.uploadFile(localURL: conflictURL, remotePath: conflictRemotePath)
                    } else if localMod > remoteMod.addingTimeInterval(2.0) {
                        // Local is newer -> Upload
                        try await client.uploadFile(localURL: local, remotePath: subRemotePath)
                    } else if remoteMod > localMod.addingTimeInterval(2.0) {
                        // Remote is newer -> Download
                        try await client.downloadFile(remotePath: subRemotePath, to: local)
                    }

                    let finalAttrs = try? fileManager.attributesOfItem(atPath: local.path)
                    let finalMod = (finalAttrs?[.modificationDate] as? Date) ?? localMod
                    let finalSize = (finalAttrs?[.size] as? Int64) ?? 0
                    newManifest[itemRelPath] = SyncManifestEntry(isDirectory: false, lastModified: finalMod, contentLength: finalSize)
                }
            } else if let local = localURL {
                // Exists ONLY locally
                if wasInManifest {
                    // Existed previously, but now missing on remote -> Remote deleted it!
                    print("[SyncCoordinator] 检测到云端已删除: '\(itemRelPath)'，同步删除本地对应项")
                    try? fileManager.removeItem(at: local)
                } else {
                    // Newly created locally
                    let isDir = (try? local.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir {
                        try await client.createDirectory(remotePath: subRemotePath)
                        newManifest[itemRelPath] = SyncManifestEntry(isDirectory: true)
                        try await performDirectorySync(
                            client: client,
                            configId: configId,
                            localDirectory: local,
                            remotePath: subRemotePath,
                            relativeDirPath: itemRelPath,
                            lastSyncTime: lastSyncTime,
                            previousManifest: previousManifest,
                            pendingDeletions: &pendingDeletions,
                            newManifest: &newManifest
                        )
                    } else {
                        try await client.uploadFile(localURL: local, remotePath: subRemotePath)
                        let attrs = try? fileManager.attributesOfItem(atPath: local.path)
                        let mod = attrs?[.modificationDate] as? Date
                        let size = (attrs?[.size] as? Int64) ?? 0
                        newManifest[itemRelPath] = SyncManifestEntry(isDirectory: false, lastModified: mod, contentLength: size)
                    }
                }
            } else if let remote = remoteRes {
                // Exists ONLY remotely
                if isPendingDelete || wasInManifest {
                    // Deleted locally -> Sync deletion to remote!
                    print("[SyncCoordinator] 检测到本地已删除: '\(itemRelPath)'，同步删除云端对应项")
                    do {
                        try await client.delete(remotePath: subRemotePath)
                        pendingDeletions.remove(itemRelPath)
                        pendingDeletions = pendingDeletions.filter { !$0.hasPrefix(itemRelPath + "/") }
                    } catch {
                        print("[SyncCoordinator Error] 云端删除 '\(subRemotePath)' 失败: \(error)")
                    }
                } else {
                    // Newly created remotely
                    let targetLocal = localDirectory.appendingPathComponent(name)
                    if remote.isDirectory {
                        try fileManager.createDirectory(at: targetLocal, withIntermediateDirectories: true, attributes: nil)
                        newManifest[itemRelPath] = SyncManifestEntry(isDirectory: true)
                        try await performDirectorySync(
                            client: client,
                            configId: configId,
                            localDirectory: targetLocal,
                            remotePath: subRemotePath,
                            relativeDirPath: itemRelPath,
                            lastSyncTime: lastSyncTime,
                            previousManifest: previousManifest,
                            pendingDeletions: &pendingDeletions,
                            newManifest: &newManifest
                        )
                    } else {
                        try await client.downloadFile(remotePath: subRemotePath, to: targetLocal)
                        let attrs = try? fileManager.attributesOfItem(atPath: targetLocal.path)
                        let mod = remote.lastModified ?? (attrs?[.modificationDate] as? Date)
                        newManifest[itemRelPath] = SyncManifestEntry(isDirectory: false, lastModified: mod, contentLength: remote.contentLength)
                    }
                }
            }
        }
    }

    private static let conflictDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
