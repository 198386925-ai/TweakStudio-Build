import Foundation

/// assets/defaults.json 的镜像，原包默认值第一版不改。
struct TweakDefaults: Codable {
    var author: String
    var class_prefix: String
    var package_prefix: String
    var section: String
    var version: String
    var sdk_version: String
    var minimum_ios: String
    var repository_url: String
    var telegram_url: String
    var telegram_fallback: String
    var qq_url: String

    static func loadFromBundle() throws -> TweakDefaults {
        guard let url = Bundle.main.url(forResource: "defaults", withExtension: "json", subdirectory: "Templates") else {
            throw GeneratorError.message("App 模板缺失：Templates/defaults.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TweakDefaults.self, from: data)
    }
}

/// 表单输入
struct TweakInput: Codable, Equatable {
    var name: String = ""            // 英文名 PascalCase，如 TouchTrail
    var slug: String = ""            // 小写标识，必须等于 name.lowercased()（create.py 规则）
    var displayName: String = ""     // 中文名，可空则用英文名
    var descriptionText: String = "" // 简单介绍，可空则用显示名
    var bundle: String = ""          // 要改哪个 App 的 Bundle ID，空则 com.apple.springboard
    var minimumIOS: String = ""      // 最低 iOS，空则 defaults 的 14.0
    var preferences: Bool = false
    var slider: Bool = false

    var resolvedBundle: String { bundle.isEmpty ? "com.apple.springboard" : bundle }
}

/// 一条历史记录：一个生成过的插件
struct TweakRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var input: TweakInput
    /// Documents/TweakStudio/Projects/ 下的目录名
    var folderName: String
    /// 工程 zip 文件名（在记录目录内）
    var zipName: String
    /// GitHub 仓库，如 owner/tweakstudio-touchtrail，未推送为 nil
    var repoFullName: String? = nil
    /// 打包状态文字（未推送/已推送/打包中/打包成功/打包失败+原因）
    var buildStatus: String = "未推送"
    /// 下载回来的 deb 文件名，未下载为 nil
    var debName: String? = nil
    /// 最近一次检查/生成的问题列表
    var problems: [String] = []

    var displayName: String {
        input.displayName.isEmpty ? input.name : input.displayName
    }
}

enum GeneratorError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
