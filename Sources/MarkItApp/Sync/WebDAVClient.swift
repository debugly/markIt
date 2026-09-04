//
//  WebDAVClient.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import Foundation

public enum WebDAVError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(statusCode: Int, message: String)
    case networkError(Error)
    case parseError
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 WebDAV 服务器地址"
        case .unauthorized:
            return "身份验证失败，请检查用户名和密码"
        case .serverError(let code, let msg):
            if code == 405 {
                if !msg.isEmpty && msg != "method not allowed" {
                    return msg
                }
                return "方法不被允许 (405)。如果是群晖 NAS，WebDAV 无法在根目录直接创建新的共享文件夹。请先在群晖「控制面板 -> 共享文件夹」中新建该文件夹并赋予权限，或将云端路径填写在现有共享文件夹下（如 /已有共享文件夹名/子目录）。"
            }
            return "服务器错误 (\(code)): \(msg)"
        case .networkError(let err):
            return "网络连接失败: \(err.localizedDescription)"
        case .parseError:
            return "解析服务器响应失败"
        case .notFound:
            return "未找到指定的远程目录"
        }
    }
}

public final class WebDAVClient {
    private let baseURL: URL
    private let authHeader: String
    private let session: URLSession

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()

    public init(baseURL: URL, username: String, password: String, session: URLSession = .shared) {
        // Ensure baseURL ends with / if needed
        var urlString = baseURL.absoluteString
        if !urlString.hasSuffix("/") {
            urlString += "/"
        }
        self.baseURL = URL(string: urlString) ?? baseURL

        let credential = "\(username):\(password)"
        let base64 = credential.data(using: .utf8)?.base64EncodedString() ?? ""
        self.authHeader = "Basic \(base64)"
        self.session = session
    }

    private func makeURL(for remotePath: String, isDirectory: Bool = false) throws -> URL {
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return baseURL
        }
        var encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        if isDirectory && !encoded.hasSuffix("/") {
            encoded += "/"
        }
        guard let url = URL(string: encoded, relativeTo: baseURL) else {
            throw WebDAVError.invalidURL
        }
        return url.absoluteURL
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("MarkIt/0.4.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Unified request sender with detailed logging and error reporting
    @discardableResult
    private func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let urlString = request.url?.absoluteString ?? "unknown URL"
        print("[WebDAV Request] \(method) \(urlString)")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[WebDAV Error] \(method) \(urlString) -> 响应类型异常: 不是 HTTPURLResponse")
                throw WebDAVError.parseError
            }

            if http.statusCode >= 400 {
                var detail = ""
                if !data.isEmpty, let bodyStr = String(data: data, encoding: .utf8) {
                    let trimmed = bodyStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = trimmed.count > 300 ? String(trimmed.prefix(300)) + "..." : trimmed
                    detail = " | 响应内容: \(snippet)"
                }
                print("[WebDAV Error] \(method) \(urlString) -> HTTP \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))\(detail)")
            } else {
                print("[WebDAV Response] \(method) \(urlString) -> HTTP \(http.statusCode)")
            }

            return (data, http)
        } catch let error as WebDAVError {
            print("[WebDAV Error] \(method) \(urlString) -> 业务错误: \(error.localizedDescription)")
            throw error
        } catch {
            print("[WebDAV Error] \(method) \(urlString) -> 网络/系统异常: \(error.localizedDescription) (\(error))")
            throw error
        }
    }

    // MARK: - API Operations

    /// Tests connection and authentication by querying the root or given path
    public func testConnection(remotePath: String = "") async throws -> Bool {
        let targetURL = try makeURL(for: remotePath, isDirectory: true)
        var req = makeRequest(url: targetURL, method: "PROPFIND")
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (_, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] testConnection 401 Unauthorized: 密码或用户名不正确")
            throw WebDAVError.unauthorized
        }
        if http.statusCode == 207 || (http.statusCode >= 200 && http.statusCode < 300) {
            return true
        }
        // If 404, the server is reached and credentials are valid, but the target directory does not exist yet (can be auto-created)
        if http.statusCode == 404 {
            return true
        }
        // If 405 on PROPFIND, attempt OPTIONS check on the target URL
        if http.statusCode == 405 {
            print("[WebDAV] PROPFIND 遇到 405，正在尝试 OPTIONS 探测...")
            let optReq = makeRequest(url: targetURL, method: "OPTIONS")
            if let (_, optHttp) = try? await sendRequest(optReq) {
                if optHttp.statusCode == 401 {
                    print("[WebDAV Error] OPTIONS 401 Unauthorized: 密码或用户名不正确")
                    throw WebDAVError.unauthorized
                }
                if (200..<300).contains(optHttp.statusCode) {
                    return true
                }
            }
        }
        throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    /// Lists direct children of remotePath
    public func listDirectory(remotePath: String) async throws -> [WebDAVResource] {
        let url = try makeURL(for: remotePath, isDirectory: true)
        var req = makeRequest(url: url, method: "PROPFIND")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] listDirectory 401 Unauthorized for '\(remotePath)'")
            throw WebDAVError.unauthorized
        }
        if http.statusCode == 404 {
            print("[WebDAV Error] listDirectory 404 NotFound for '\(remotePath)'")
            throw WebDAVError.notFound
        }
        guard http.statusCode == 207 || (http.statusCode >= 200 && http.statusCode < 300) else {
            throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        let parser = WebDAVMultistatusParser(data: data, rootURL: baseURL)
        let resources = parser.parse()

        // Filter out the requested directory itself
        let targetPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return resources.filter { res in
            let resPath = res.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return resPath != targetPath
        }
    }

    /// Checks if a remote directory exists using PROPFIND Depth 0
    public func directoryExists(remotePath: String) async -> Bool {
        guard let url = try? makeURL(for: remotePath, isDirectory: true) else { return false }
        var req = makeRequest(url: url, method: "PROPFIND")
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        guard let (_, http) = try? await sendRequest(req) else {
            return false
        }
        return http.statusCode == 207 || (http.statusCode >= 200 && http.statusCode < 300)
    }

    /// Creates a remote directory
    public func createDirectory(remotePath: String) async throws {
        let url = try makeURL(for: remotePath, isDirectory: true)
        let req = makeRequest(url: url, method: "MKCOL")

        let (_, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] createDirectory 401 Unauthorized for '\(remotePath)'")
            throw WebDAVError.unauthorized
        }
        // 201 Created or 200/204
        if http.statusCode == 201 || http.statusCode == 200 || http.statusCode == 204 {
            return
        }
        // If 405, verify if the directory actually exists
        if http.statusCode == 405 {
            if await directoryExists(remotePath: remotePath) {
                print("[WebDAV] MKCOL 返回 405，经探测目录已存在，视作成功")
                return
            }
            print("[WebDAV Error] MKCOL 返回 405 且目录不存在，服务器拒绝在根路径创建目录")
            throw WebDAVError.serverError(statusCode: 405, message: "创建目录被拒 (405)。群晖 NAS 无法通过 WebDAV 直接在根目录创建共享文件夹。请在群晖「控制面板 -> 共享文件夹」中创建该文件夹，或将路径设为已有共享文件夹下的子目录（如 /共享文件夹名/子目录）")
        }
        print("[WebDAV Error] createDirectory 失败 '\(remotePath)': HTTP \(http.statusCode)")
        throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    /// Recursively ensures all folder segments exist
    public func ensureDirectoryHierarchy(remotePath: String) async throws {
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return }
        let segments = trimmed.split(separator: "/")
        var current = ""
        for (i, seg) in segments.enumerated() {
            current += (current.isEmpty ? "" : "/") + String(seg)
            // If the directory segment already exists (e.g. Synology shared folder), skip MKCOL
            if await directoryExists(remotePath: current) {
                print("[WebDAV] 目录层级 '\(current)' 已存在，跳过创建")
                continue
            }
            do {
                print("[WebDAV] 正在创建目录层级: '\(current)'")
                try await createDirectory(remotePath: current)
                print("[WebDAV] 目录层级创建成功: '\(current)'")
            } catch {
                if await directoryExists(remotePath: current) {
                    print("[WebDAV] 目录层级 '\(current)' 创建后检测已存在")
                    continue
                }
                print("[WebDAV Error] 目录层级 '\(current)' 创建失败: \(error.localizedDescription)")
                // If it is the last segment and still doesn't exist, propagate error
                if i == segments.count - 1 {
                    throw error
                }
            }
        }
    }

    /// Uploads a file to remotePath
    public func uploadFile(localURL: URL, remotePath: String) async throws {
        let url = try makeURL(for: remotePath)
        let data = try Data(contentsOf: localURL)

        var req = makeRequest(url: url, method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (_, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] uploadFile 401 Unauthorized for '\(remotePath)'")
            throw WebDAVError.unauthorized
        }
        guard http.statusCode == 200 || http.statusCode == 201 || http.statusCode == 204 else {
            print("[WebDAV Error] uploadFile 失败 '\(remotePath)': HTTP \(http.statusCode)")
            throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    /// Downloads a file from remotePath to local destination
    public func downloadFile(remotePath: String, to localURL: URL) async throws {
        let url = try makeURL(for: remotePath)
        let req = makeRequest(url: url, method: "GET")

        let (data, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] downloadFile 401 Unauthorized for '\(remotePath)'")
            throw WebDAVError.unauthorized
        }
        if http.statusCode == 404 {
            print("[WebDAV Error] downloadFile 404 NotFound for '\(remotePath)'")
            throw WebDAVError.notFound
        }
        guard http.statusCode >= 200 && http.statusCode < 300 else {
            print("[WebDAV Error] downloadFile 失败 '\(remotePath)': HTTP \(http.statusCode)")
            throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        // Ensure parent directory exists
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

        // Write safely
        try data.write(to: localURL, options: .atomic)
    }

    /// Deletes a file or directory at remotePath
    public func delete(remotePath: String) async throws {
        let url = try makeURL(for: remotePath)
        let req = makeRequest(url: url, method: "DELETE")

        let (_, http) = try await sendRequest(req)

        if http.statusCode == 401 {
            print("[WebDAV Error] delete 401 Unauthorized for '\(remotePath)'")
            throw WebDAVError.unauthorized
        }
        // 200, 204, or 404 is considered deleted
        guard http.statusCode == 200 || http.statusCode == 204 || http.statusCode == 404 else {
            print("[WebDAV Error] delete 失败 '\(remotePath)': HTTP \(http.statusCode)")
            throw WebDAVError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}

// MARK: - Multi-Status XML Parser

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private let xmlParser: XMLParser
    private let rootURL: URL
    private var resources: [WebDAVResource] = []

    // Current item parsing state
    private var currentHref: String = ""
    private var isCurrentCollection: Bool = false
    private var currentContentLength: Int64 = 0
    private var currentLastModified: Date? = nil
    private var currentETag: String? = nil
    private var currentCharacters: String = ""
    private var inResponse: Bool = false

    init(data: Data, rootURL: URL) {
        self.xmlParser = XMLParser(data: data)
        self.rootURL = rootURL
        super.init()
        self.xmlParser.delegate = self
    }

    func parse() -> [WebDAVResource] {
        xmlParser.parse()
        return resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let tag = (qName ?? elementName).lowercased()
        currentCharacters = ""

        if tag.hasSuffix("response") {
            inResponse = true
            currentHref = ""
            isCurrentCollection = false
            currentContentLength = 0
            currentLastModified = nil
            currentETag = nil
        } else if inResponse && tag.hasSuffix("collection") {
            isCurrentCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentCharacters += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = (qName ?? elementName).lowercased()
        let text = currentCharacters.trimmingCharacters(in: .whitespacesAndNewlines)

        if inResponse {
            if tag.hasSuffix("href") {
                currentHref = text
            } else if tag.hasSuffix("getlastmodified") {
                currentLastModified = parseDate(text)
            } else if tag.hasSuffix("getcontentlength") {
                currentContentLength = Int64(text) ?? 0
            } else if tag.hasSuffix("getetag") {
                currentETag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if tag.hasSuffix("response") {
                inResponse = false
                if !currentHref.isEmpty {
                    // Extract path
                    let cleanHref = currentHref.removingPercentEncoding ?? currentHref
                    let urlPath = URL(string: currentHref)?.path ?? cleanHref
                    let resource = WebDAVResource(
                        href: currentHref,
                        path: urlPath,
                        isDirectory: isCurrentCollection,
                        contentLength: currentContentLength,
                        lastModified: currentLastModified,
                        etag: currentETag
                    )
                    resources.append(resource)
                }
            }
        }
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let d = formatter.date(from: string) { return d }

        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let d = formatter.date(from: string) { return d }

        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let d = formatter.date(from: string) { return d }

        return nil
    }
}
