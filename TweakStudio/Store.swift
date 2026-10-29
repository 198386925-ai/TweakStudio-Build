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

    // MARK: - 导入现成源码 zip（本版新增）

    /// 收一份现成的插件源码 zip：安全作用域读取 → 解压 → 定位工程根并检查 Makefile/control
    /// → 缺云端打包说明时自动补模板 build.yml → 存成一条历史记录，之后走和生成工程相同的推送/打包流程。
    @discardableResult
    func importProject(from pickedURL: URL) async -> TweakRecord? {
        working = true
        defer { working = false }
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let staging = rootDir.appendingPathComponent("ImportStaging-\(stamp)", isDirectory: true)
        var createdDir: URL? = nil
        defer { try? fm.removeItem(at: staging) }
        do {
            let scoped = pickedURL.startAccessingSecurityScopedResource()
            let zipData: Data
            do {
                zipData = try Data(contentsOf: pickedURL)
            } catch {
                if scoped { pickedURL.stopAccessingSecurityScopedResource() }
                throw GeneratorError.message("选中的 zip 读不到")
            }
            if scoped { pickedURL.stopAccessingSecurityScopedResource() }

            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            _ = try ZipReader.extract(data: zipData, to: extracted)
            let sourceRoot = try ProjectImporter.locateRoot(in: extracted)
            let control = ProjectImporter.parseControl(at: sourceRoot)
            let zipStem = pickedURL.deletingPathExtension().lastPathComponent
            let controlName = (control["Name"] ?? "").trimmingCharacters(in: .whitespaces)
            let display = controlName.isEmpty ? zipStem : controlName
            let slug = ProjectImporter.repoSlug(package: control["Package"], fallback: zipStem)

            var folderName = "\(slug)-\(stamp)"
            var suffix = 2
            while fm.fileExists(atPath: projectsDir.appendingPathComponent(folderName).path) {
                folderName = "\(slug)-\(stamp)-\(suffix)"
                suffix += 1
            }
            let dir = projectsDir.appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            createdDir = dir
            let projectDir = dir.appendingPathComponent("project", isDirectory: true)
            try fm.moveItem(at: sourceRoot, to: projectDir)

            var problems: [String] = []
            if injectWorkflowIfNeeded(projectDir: projectDir, display: display, slug: slug) {
                problems.append("原工程没有云端打包说明，已自动补上模板的 build.yml")
            }
            var input = TweakInput()
            input.name = display
            input.slug = slug
            input.displayName = display
            input.descriptionText = (control["Description"] ?? "")
                .split(separator: "\n").first.map(String.init) ?? ""
            var record = TweakRecord(input: input, folderName: folderName, zipName: "\(slug)-project.zip")
            record.problems = problems
            // 以补全后的工程重新打包，保证分享/重下的 zip 与将要推送的内容一致
            try ZipWriter.writeZip(of: projectDir, to: dir.appendingPathComponent(record.zipName))
            records.insert(record, at: 0)
            save()
            createdDir = nil
            statusText = problems.isEmpty
                ? "导入好了：\(display)，可以在历史里送去打成品"
                : "导入好了：\(display)（\(problems[0])）"
            return record
        } catch {
            if let createdDir { try? fm.removeItem(at: createdDir) }
            statusText = "导入失败：" + error.localizedDescription
            return nil
        }
    }

    /// 工程缺 .github/workflows 打包说明时，用自带模板补一份（占位符口径与 Generator 生成流程一致）。
    /// 返回 true 表示确实补了。已有任意 yml/yaml 就不动人家的。
    private func injectWorkflowIfNeeded(projectDir: URL, display: String, slug: String) -> Bool {
        let fm = FileManager.default
        let workflowsDir = projectDir.appendingPathComponent(".github/workflows", isDirectory: true)
        if let names = try? fm.contentsOfDirectory(atPath: workflowsDir.path),
           names.contains(where: { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }) {
            return false
        }
        guard let templatesDir = Bundle.main.url(forResource: "Templates", withExtension: nil),
              let raw = try? String(contentsOf: templatesDir.appendingPathComponent("github-workflow/build.yml"), encoding: .utf8),
              let defaults else { return false }
        // CI 标题与 Generator.prepare 一致：JSON 字符串片段（自带引号）
        var title = display
        let titleObject: [String] = [display + " v${{ steps.bump.outputs.package_version }}"]
        if let titleData = try? JSONSerialization.data(withJSONObject: titleObject, options: []),
           let titleJSON = String(data: titleData, encoding: .utf8) {
            title = String(titleJSON.dropFirst().dropLast())
        }
        let workflowName = (display.contains(":") || display.contains("\n")) ? slug : display
        let values = [
            "__NAME__": workflowName,
            "__SDK_VERSION__": defaults.sdk_version,
            "__CI_RELEASE_TITLE__": title,
        ]
        guard let rendered = try? Generator.substitute(raw, values),
              !Generator.containsToken(rendered) else { return false }
        do {
            try fm.createDirectory(at: workflowsDir, withIntermediateDirectories: true)
            try rendered.write(to: workflowsDir.appendingPathComponent("build.yml"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
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
        // 先把目录和文件路径都规范化再剥前缀算相对路径：真机上枚举出的文件 URL 带 /private 前缀、
        // 目录 path 不带，两边原始字符串长度对不齐，硬减会残留一段目录名，推出去的文件会多一层前缀。
        let basePath = dir.resolvingSymlinksInPath().path
        var files: [(String, Data)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let filePath = url.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(basePath + "/") else { continue }
            let relative = String(filePath.dropFirst(basePath.count + 1))
            files.append((relative, try Data(contentsOf: url)))
        }
        return files.sorted { $0.0 < $1.0 }.map { (relative: $0.0, data: $0.1) }
    }

    /// 查云端打包状态的一次判定结果（refreshStatus 与 pollUntilDone 共用同一套，不许两处各写一份）。
    private enum BuildCheckOutcome {
        case tookDeb            // 最新已完成 run 成功，已走 tryDownloadDeb 取 deb（取没取到它内部已更新状态）
        case failed(String)     // 最新已完成 run 失败，带 conclusion 原文
        case notFound           // 一条 run 都没有
        case inProgress(String) // 一条已完成的都没有，带最新一条未完成 run 的状态
    }

    /// 查一次云端打包状态：逐文件推送会触发一串 run 排队，只看最新一条几乎永远是
    /// queued/in_progress，会错过排在前面、早已打好的 deb。所以优先在一串 run 里找
    /// 最近一条已完成的：success 就取 Release 里的 deb，failure 就按失败收尾；
    /// 一条已完成的都没有，才按最新一条未完成 run 报打包中。
    private func checkBuildOnce(client: GitHubClient, recordID: UUID, owner: String, repo: String) async throws -> BuildCheckOutcome {
        let runs = try await client.recentRuns(owner: owner, repo: repo)
        guard let newest = runs.first else { return .notFound }
        if let completed = runs.first(where: { $0.status == "completed" }) {
            if completed.conclusion == "success" {
                await tryDownloadDeb(recordID: recordID, owner: owner, repo: repo)
                return .tookDeb
            }
            return .failed(completed.conclusion ?? "unknown")
        }
        return .inProgress(newest.status)
    }

    private func pollUntilDone(recordID: UUID, owner: String, repo: String) async {
        guard let client = client() else { return }
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard records.contains(where: { $0.id == recordID }) else { return }
            do {
                switch try await checkBuildOnce(client: client, recordID: recordID, owner: owner, repo: repo) {
                case .tookDeb:
                    return
                case .failed(let conclusion):
                    update(recordID) { $0.buildStatus = "打包失败（\(conclusion)）" }
                    statusText = "云端打包结束了，但没成功：\(conclusion)"
                    return
                case .notFound:
                    update(recordID) { $0.buildStatus = "已推送，还没看到打包任务" }
                case .inProgress(let status):
                    update(recordID) { $0.buildStatus = "打包中（\(status)）" }
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
            switch try await checkBuildOnce(client: client, recordID: record.id, owner: ownerName, repo: repo) {
            case .tookDeb:
                break // 取 deb 的结果 tryDownloadDeb 内部已经更新状态和文案
            case .failed(let conclusion):
                update(record.id) { $0.buildStatus = "打包失败（\(conclusion)）" }
                statusText = "打包失败：\(conclusion)"
            case .notFound:
                update(record.id) { $0.buildStatus = "已推送，还没看到打包任务" }
                statusText = "还没看到打包任务，刚推送的话等一会儿再刷新"
            case .inProgress(let status):
                update(record.id) { $0.buildStatus = "打包中（\(status)）" }
                statusText = "还在打包：\(status)"
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
