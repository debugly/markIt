//
//  WebDAVModels.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import Foundation

public struct WebDAVFolderConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var serverURL: URL
    public var username: String
    public var remotePath: String
    public var localBookmark: Data?
    public var localPath: String
    public var lastSyncTime: Date?
    public var autoSyncEnabled: Bool

    public init(
        id: UUID = UUID(),
        serverURL: URL,
        username: String,
        remotePath: String,
        localBookmark: Data? = nil,
        localPath: String,
        lastSyncTime: Date? = nil,
        autoSyncEnabled: Bool = true
    ) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.remotePath = remotePath
        self.localBookmark = localBookmark
        self.localPath = localPath
        self.lastSyncTime = lastSyncTime
        self.autoSyncEnabled = autoSyncEnabled
    }

    /// Resolves the local folder URL from bookmark or local path
    public func resolveLocalURL() -> URL? {
        if let bookmarkData = localBookmark {
            var isStale = false
            #if os(macOS)
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolved
            }
            #endif
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolved
            }
        }
        let url = URL(fileURLWithPath: localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum FolderSyncStatus: Equatable, Sendable {
    case synced
    case modified
    case syncing(message: String)
    case error(message: String)

    public var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    public var isModified: Bool {
        if case .modified = self { return true }
        return false
    }
}

public struct WebDAVResource: Sendable {
    public let href: String
    public let path: String
    public let isDirectory: Bool
    public let contentLength: Int64
    public let lastModified: Date?
    public let etag: String?

    public init(
        href: String,
        path: String,
        isDirectory: Bool,
        contentLength: Int64 = 0,
        lastModified: Date? = nil,
        etag: String? = nil
    ) {
        self.href = href
        self.path = path
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.lastModified = lastModified
        self.etag = etag
    }
}

public struct SyncManifestEntry: Codable, Equatable, Sendable {
    public var isDirectory: Bool
    public var lastModified: Date?
    public var contentLength: Int64

    public init(isDirectory: Bool, lastModified: Date? = nil, contentLength: Int64 = 0) {
        self.isDirectory = isDirectory
        self.lastModified = lastModified
        self.contentLength = contentLength
    }
}
