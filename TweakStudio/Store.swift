import Foundation

@MainActor
final class TweakStore: ObservableObject {
    @Published var records: [TweakRecord] = []
    @Published var working: Bool = false
    @Published var statusText: String = ""
    @Published var owner: String? = nil

    let defaults: TweakDefaults?

    var rootDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("TweakStudio", isDirectory: true)
    }
    var projectsDir: URL { rootDir.appendingPathComponent("Projects", isDirectory: true) }
    private var recordsFile: URL { rootDir.appendingPathComponent("records.json") }

    init() {
        defaults = try? TweakDefaults.loadFromBundle()
        load()
    }

    // MARK: - 持久化

    func load() {
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: recordsFile),
              let decoded = try? JSONDecoder.tweak.decode([TweakRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let data = try? JSONEncoder.tweak.encode(records) else { return }
        try? data.write(to: recordsFile, options: .atomic)
    }

    func recordDir(_ record: TweakRecord) -> URL { projectsDir.appendingPathComponent(record.folderName, isDirectory: true) }
    func projectDir(_ record: TweakRecord) -> URL { recordDir(record).appendingPathComponent("project", isDirectory: true) }
    func zipURL(_ record: TweakRecord) -> URL { recordDir(record).appendingPathComponent(record.zipName) }
    func debURL(_ record: TweakRecord) -> URL? {
        guard let name = record.debName else { return nil }
        return recordDir(record).appendingPathComponent(name)
    }

    func delete(_ record: TweakRecord) {
        try? FileManager.default.removeItem(at: recordDir(record))
        records.removeAll { $0.id == record.id }
        save()
    }

    // MARK: - 检查（清单第 5 项）

    func check(input: TweakInput) -> [String] {
        guard let defaults else { return ["模板 defaults 读取失败"] }
        return Generator.validate(input: input, defaults: defaults)
    }

    // MARK: - 生成（清单第 3 项）

    @discardableResult
    func generate(input: TweakInput) async -> TweakRecord? {
        guard let defaults else { statusText = "模板 defaults 读取失败"; return nil }
        let problems = Generator.validate(input: input, defaults: defaults)
        if let first = problems.first {
            statusText = "先改这里：" + first
            return nil
        }
        working = true
        defer { working = false }
        do {
            let slug = input.slug.isEmpty ? input.name.lowercased() : input.slug
            let stamp = Int(Date().timeIntervalSince1970)
            let folderName = "\(slug)-\(stamp)"
            let dir = projectsDir.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let projectDir = dir.appendingPathComponent("project", isDirectory: true)
            _ = try Generator.generate(input: input, defaults: defaults, destination: projectDir)
            let found = Generator.doctor(projectDir: projectDir, input: input, defaults: defaults)
            var record = TweakRecord(input: input, folderName: folderName, zipName: "\(input.name)-project.zip")
            record.problems = found
            let zip = dir.appendingPathComponent(record.zipName)
            try ZipWriter.writeZip(of: projectDir, to: zip)
            records.insert(record, at: 0)
            save()
            statusText = found.isEmpty ? "生成好了，检查通过（静态检查，不等于真机可用）" : "生成好了，检查提醒：\(found.first!)"
            return record
        } catch {
            statusText = "生成失败：" + error.localizedDescription
            return nil
        }
    }

    // MARK: - 送去打成品（清单第 4 项）

    func client() -> GitHubClient? {
        guard let token = TokenStore.load() else { return nil }
        return GitHubClient(token: token)
    }

    func verifyToken() async {
        guard let client = client() else { statusText = "先在下面填 GitHub 令牌并保存"; return }
        working = true
        defer { working = false }
        do {
            owner = try await client.getOwner()
            statusText = "令牌可用，GitHub 账号：\(owner ?? "")"
        } catch {
            statusText = "令牌验证失败：" + error.localizedDescription
        }
    }

    func uploadAndBuild(record: TweakRecord) async {
        guard let client = client() else { statusText = "先填 GitHub 令牌并保存到钥匙串"; return }
        working = true
        defer { working = false }
        do {
            let ownerName = try await client.getOwner()
            owner = ownerName
            let slug = record.input.slug.isEmpty ? record.input.name.lowercased() : record.input.slug
            let fullName = try await client.ensureRepo(owner: ownerName, slug: slug, displayName: record.displayName)
            let repo = fullName.split(separator: "/").last.map(String.init) ?? "tweakstudio-\(slug)"
            update(record.id) { $0.repoFullName = fullName; $0.buildStatus = "推送中" }
            let files = try collectFiles(record: record)
            try await client.uploadFiles(owner: ownerName, repo: repo, files: files) { done, total in
                Task { @MainActor in self.statusText = "推送文件 \(done)/\(total)" }
            }
            update(record.id) { $0.buildStatus = "已推送，等待打包" }
            statusText = "已推到 \(fullName)，云端开始打包，下面会自动查状态（也可以在历史里点刷新状态）"
            await pollUntilDone(recordID: record.id, owner: ownerName, repo: repo)
        } catch {
            update(record.id) { $0.buildStatus = "推送失败：" + error.localizedDescription }
            statusText = "推送失败：" + error.localizedDescription
        }
    }

    private func collectFiles(record: TweakRecord) throws -> [(relative: String, data: Data)] {
        let dir = projectDir(record)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw GeneratorError.message("工程目录读不到")
        }
        var files: [(String, Data)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.path.dropFirst(dir.path.count + 1))
            files.append((relative, try Data(contentsOf: url)))
        }
        return files.sorted { $0.0 < $1.0 }.map { (relative: $0.0, data: $0.1) }
    }

    private func pollUntilDone(recordID: UUID, owner: String, repo: String) async {
        guard let client = client() else { return }
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let record = records.first(where: { $0.id == recordID }) else { return }
            do {
                let run = try await client.latestRun(owner: owner, repo: repo)
                switch (run.status, run.conclusion) {
                case ("completed", .some("success")):
                    _ = record
                    await tryDownloadDeb(recordID: recordID, owner: owner, repo: repo)
                    return
                case ("completed", .some(let conclusion)):
                    update(recordID) { $0.buildStatus = "打包失败（\(conclusion)）" }
                    statusText = "云端打包结束了，但没成功：\(conclusion)"
                    return
                case ("not_found", _):
                    update(recordID) { $0.buildStatus = "已推送，还没看到打包任务" }
                default:
                    update(recordID) { $0.buildStatus = "打包中（\(run.status)）" }
                }
            } catch {
                update(recordID) { $0.buildStatus = "查状态失败：" + error.localizedDescription }
                return
            }
        }
        statusText = "等了几分钟还没打完，去历史里点刷新状态再看"
    }

    func refreshStatus(record: TweakRecord) async {
        guard let client = client() else { statusText = "先填 GitHub 令牌"; return }
        guard let fullName = record.repoFullName, let ownerName = fullName.split(separator: "/").first.map(String.init) else {
            statusText = "这个插件还没推送过"
            return
        }
        let repo = fullName.split(separator: "/").last.map(String.init) ?? ""
        working = true
        defer { working = false }
        do {
            let run = try await client.latestRun(owner: ownerName, repo: repo)
            switch (run.status, run.conclusion) {
            case ("completed", .some("success")):
                await tryDownloadDeb(recordID: record.id, owner: ownerName, repo: repo)
            case ("completed", .some(let conclusion)):
                update(record.id) { $0.buildStatus = "打包失败（\(conclusion)）" }
                statusText = "打包失败：\(conclusion)"
            case ("not_found", _):
                update(record.id) { $0.buildStatus = "已推送，还没看到打包任务" }
                statusText = "还没看到打包任务，刚推送的话等一会儿再刷新"
            default:
                update(record.id) { $0.buildStatus = "打包中（\(run.status)）" }
                statusText = "还在打包：\(run.status)"
            }
        } catch {
            statusText = "查状态失败：" + error.localizedDescription
        }
    }

    private func tryDownloadDeb(recordID: UUID, owner: String, repo: String) async {
        guard let client = client() else { return }
        do {
            guard let asset = try await client.latestDebAsset(owner: owner, repo: repo) else {
                update(recordID) { $0.buildStatus = "打包成功，但 Release 里还没找到 deb" }
                statusText = "打包成功，但 Release 里还没找到 deb，过一会儿刷新"
                return
            }
            let data = try await client.download(asset.downloadURL)
            guard let record = records.first(where: { $0.id == recordID }) else { return }
            let target = recordDir(record).appendingPathComponent(asset.name)
            try data.write(to: target, options: .atomic)
            update(recordID) { $0.debName = asset.name; $0.buildStatus = "打包成功，deb 已下载" }
            statusText = "成了，deb 已下载回来：\(asset.name)"
        } catch {
            update(recordID) { $0.buildStatus = "打包成功，下载 deb 失败：" + error.localizedDescription }
            statusText = "下载 deb 失败：" + error.localizedDescription
        }
    }

    private func update(_ id: UUID, _ mutate: (inout TweakRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        save()
    }
}

extension JSONEncoder {
    static var tweak: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var tweak: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
