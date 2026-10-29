import Foundation
import Security

/// GitHub 令牌只存 iOS 钥匙串，代码任何地方都不打印/记录令牌。
enum TokenStore {
    private static let service = "com.youyou.tweakstudio.github"
    private static let account = "token"

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let token = String(data: data, encoding: .utf8)
        return (token?.isEmpty == false) ? token : nil
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct GitHubError: Error, LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

/// GitHub REST API 链路：建仓、逐文件推 Contents、查 Actions、从 Release 下载 deb。
/// 失败时把服务器返回的 message 简短显示出来，不静默。
final class GitHubClient {
    private let token: String

    init(token: String) { self.token = token }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         accept: String = "application/vnd.github+json") throws -> URLRequest {
        // path 本身带 / 和可能的查询串，直接拼字符串，不走 appendingPathComponent（会转义 ? 和 /）
        guard let url = URL(string: "https://api.github.com/" + path) else {
            throw GitHubError(text: "GitHub 地址拼错：\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest, allowed: [Int] = [200, 201]) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(text: "GitHub 没有返回有效响应")
        }
        if !allowed.contains(http.statusCode) {
            var reason = "HTTP \(http.statusCode)"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String, !message.isEmpty {
                reason += "：" + message
            }
            throw GitHubError(text: reason)
        }
        return data
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(text: "GitHub 返回格式不对")
        }
        return object
    }

    func getOwner() async throws -> String {
        let data = try await send(request("GET", "user"))
        let object = try jsonObject(data)
        guard let login = object["login"] as? String, !login.isEmpty else {
            throw GitHubError(text: "GitHub 没返回账号名，令牌可能无效")
        }
        return login
    }

    /// 每插件一个仓库：tweakstudio-<标识>，公开仓（沿用既有习惯）。已存在就复用更新。
    func ensureRepo(owner: String, slug: String, displayName: String) async throws -> String {
        let repo = "tweakstudio-\(slug)"
        let check = try request("GET", "repos/\(owner)/\(repo)")
        let (_, checkResponse) = try await URLSession.shared.data(for: check)
        if let http = checkResponse as? HTTPURLResponse, http.statusCode == 200 {
            return "\(owner)/\(repo)"
        }
        let body: [String: Any] = [
            "name": repo,
            "description": "插件工坊生成：\(displayName)",
            "private": false,
            "auto_init": false,
        ]
        do {
            _ = try await send(request("POST", "user/repos", body: body))
        } catch let error as GitHubError {
            // 名字已被占用时按已存在处理，其它错误原样抛出（带服务器原因）
            if !error.text.contains("name already exists") && !error.text.contains("422") {
                throw error
            }
        }
        return "\(owner)/\(repo)"
    }

    private func existingSHA(owner: String, repo: String, path: String) async -> String? {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        guard let req = try? request("GET", "repos/\(owner)/\(repo)/contents/\(encodedPath)") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["sha"] as? String
    }

    /// 逐文件推 Contents API（含 .github/workflows/build.yml；令牌权限不足时服务器原因会原样显示）。
    func uploadFiles(owner: String, repo: String, files: [(relative: String, data: Data)],
                     onProgress: @escaping (Int, Int) -> Void) async throws {
        var index = 0
        for file in files {
            index += 1
            onProgress(index, files.count)
            var body: [String: Any] = [
                "message": "TweakStudio: update \(file.relative)",
                "content": file.data.base64EncodedString(),
                "branch": "main",
            ]
            if let sha = await existingSHA(owner: owner, repo: repo, path: file.relative) {
                body["sha"] = sha
            }
            guard let encodedPath = file.relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw GitHubError(text: "文件名编码失败：\(file.relative)")
            }
            _ = try await send(request("PUT", "repos/\(owner)/\(repo)/contents/\(encodedPath)", body: body))
        }
    }

    struct RunState {
        var status: String          // queued / in_progress / completed / not_found
        var conclusion: String?     // success / failure / ...
        var url: String?
    }

    /// 最近 10 条 run（新到旧）。逐文件推送会触发一串 run 排队，查状态要在一串里找已完成的，
    /// 只看最新一条会永远停在 queued/in_progress，所以给上层返回整个数组自己挑。
    func recentRuns(owner: String, repo: String) async throws -> [RunState] {
        let data = try await send(request("GET", "repos/\(owner)/\(repo)/actions/runs?per_page=10"))
        let object = try jsonObject(data)
        let runs = object["workflow_runs"] as? [[String: Any]] ?? []
        return runs.map { run in
            RunState(status: (run["status"] as? String) ?? "unknown",
                     conclusion: run["conclusion"] as? String,
                     url: run["html_url"] as? String)
        }
    }

    func latestRun(owner: String, repo: String) async throws -> RunState {
        let runs = try await recentRuns(owner: owner, repo: repo)
        guard let run = runs.first else { return RunState(status: "not_found", conclusion: nil, url: nil) }
        return run
    }

    /// Release 里找 .deb 资产，返回文件名和公开下载地址（公开仓可直接下载，不带令牌跟随跳转）。
    func latestDebAsset(owner: String, repo: String) async throws -> (name: String, downloadURL: URL)? {
        let req = try request("GET", "repos/\(owner)/\(repo)/releases/latest")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError(text: "GitHub 没有返回有效响应") }
        if http.statusCode == 404 { return nil }
        if http.statusCode != 200 {
            var reason = "HTTP \(http.statusCode)"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String { reason += "：" + message }
            throw GitHubError(text: reason)
        }
        let object = try jsonObject(data)
        let assets = object["assets"] as? [[String: Any]] ?? []
        for asset in assets {
            if let name = asset["name"] as? String, name.hasSuffix(".deb"),
               let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString) {
                return (name, url)
            }
        }
        return nil
    }

    func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GitHubError(text: "下载 deb 失败：HTTP \(code)")
        }
        return data
    }
}
