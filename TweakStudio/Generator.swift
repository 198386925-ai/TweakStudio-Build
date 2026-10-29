import Foundation

/// create.py 的 Swift 移植：占位符替换、文件名改名、二进制原样复制、包含条件与 doctor 静态检查都与原脚本一致。
/// App bundle 里的模板存放布局有一处不同：原 github-actions 组的 .github/workflows/build.yml
/// 在 bundle 里存为 Templates/github-workflow/build.yml（避开 bundle 内隐藏目录），生成输出路径完全相同。
enum Generator {

    static let tokenPattern = "__[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*__"
    static let binarySuffixes: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".ico", ".icns", ".pdf", ".ttf", ".otf", ".car"]

    // MARK: - 小工具（对应 create.py 的 one_line / objc / substitute）

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "^\(pattern)$", options: .regularExpression) != nil
    }

    static func oneLine(_ value: String, _ label: String) throws -> String {
        if value.isEmpty || value.contains("\n") || value.contains("\r") || value.contains("\0") {
            throw GeneratorError.message("\(label)必须是一行非空文字")
        }
        return value
    }

    static func objcEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func substitute(_ text: String, _ values: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: tokenPattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            guard let replacement = values[token] else {
                throw GeneratorError.message("模板里有不认识的占位符：\(token)")
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func containsToken(_ text: String) -> Bool {
        text.range(of: tokenPattern, options: .regularExpression) != nil
    }

    // MARK: - 校验（对应 project_values，UI 检查和生成共用）

    static func validate(input: TweakInput, defaults: TweakDefaults) -> [String] {
        var problems: [String] = []
        let name = input.name
        if !matches(name, "[A-Z][A-Za-z0-9]*") {
            problems.append("英文名必须是 PascalCase（大写开头、只有字母数字），例如 TouchTrail")
        }
        let slug = input.slug.isEmpty ? name.lowercased() : input.slug
        if !matches(slug, "[a-z][a-z0-9]*") {
            problems.append("小写标识必须以小写字母开头、只有小写字母和数字")
        }
        if slug != name.lowercased() {
            problems.append("小写标识必须等于英文名的小写（原模板规则，防止命名漂移）")
        }
        if input.slider && !input.preferences {
            problems.append("滑条需要设置面板：打开滑条前先打开设置面板开关")
        }
        if !matches(defaults.class_prefix, "[A-Z][A-Za-z0-9]*") {
            problems.append("模板 defaults 的 class_prefix 不合法")
        }
        let domain = defaults.package_prefix + "." + slug
        if !matches(domain, "[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+") || !matches(input.resolvedBundle, "[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+") {
            problems.append("包名或目标 App 的 Bundle ID 格式不对（需要 a.b.c 这种点分格式）")
        }
        if !matches(defaults.sdk_version, "\\d+\\.\\d+(?:\\.\\d+)?") {
            problems.append("模板 defaults 的 sdk_version 不合法")
        }
        let minimum = input.minimumIOS.isEmpty ? defaults.minimum_ios : input.minimumIOS
        if !matches(minimum, "\\d+\\.\\d+(?:\\.\\d+)?") {
            problems.append("最低 iOS 版本格式不对，例如 14.0")
        } else if let major = Int(minimum.split(separator: ".").first ?? ""), major < 14 {
            problems.append("原模板只支持 iOS 14 以上，低于 14 需要另外适配（不在第一版内）")
        }
        if !defaults.repository_url.hasPrefix("https://") {
            problems.append("模板 defaults 的 repository_url 必须用 https://")
        }
        if !matches(defaults.version, "\\d[A-Za-z0-9.+:-]*") {
            problems.append("模板 defaults 的 version 不是合法的 Debian 版本")
        }
        return problems
    }

    // MARK: - values（对应 project_values 的 values 字典）

    struct Prepared {
        var values: [String: String]
        var manifest: [String: Any]
        var slug: String
        var prefix: String
        var domain: String
    }

    static func prepare(input: TweakInput, defaults: TweakDefaults, templatesDir: URL) throws -> Prepared {
        let problems = validate(input: input, defaults: defaults)
        if let first = problems.first { throw GeneratorError.message(first) }
        let slug = input.slug.isEmpty ? input.name.lowercased() : input.slug
        let display = try oneLine(input.displayName.isEmpty ? input.name : input.displayName, "显示名")
        let description = try oneLine(input.descriptionText.isEmpty ? display : input.descriptionText, "简单介绍")
        let prefix = defaults.class_prefix + input.name
        let symbol = defaults.class_prefix.lowercased() + "_" + slug
        let domain = defaults.package_prefix + "." + slug
        let minimum = input.minimumIOS.isEmpty ? defaults.minimum_ios : input.minimumIOS
        let major = Int(minimum.split(separator: ".").first ?? "14") ?? 14
        let jbMinimum = major >= 15 ? minimum : "15.0"
        var repository = try oneLine(defaults.repository_url, "源地址")
        while repository.hasSuffix("/") { repository.removeLast() }

        var values: [String: String] = [
            "__NAME__": input.name,
            "__SLUG__": slug,
            "__PREFIX__": prefix,
            "__SYMBOL__": symbol,
            "__DOMAIN__": domain,
            "__BUNDLE__": input.resolvedBundle,
            "__SDK_VERSION__": defaults.sdk_version,
            "__MIN_IOS__": minimum,
            "__JB_MIN_IOS__": jbMinimum,
            "__DISPLAY__": display,
            "__DESCRIPTION__": description,
            "__AUTHOR__": defaults.author,
            "__SECTION__": defaults.section,
            "__VERSION__": defaults.version,
            "__REPOSITORY__": repository,
            "__TELEGRAM__": defaults.telegram_url,
            "__TELEGRAM_FALLBACK__": defaults.telegram_fallback,
            "__QQ__": defaults.qq_url,
            "__DEFAULT_ENABLED__": input.preferences ? "NO" : "YES",
            "__SUBPROJECTS__": input.preferences ? "SUBPROJECTS += \(prefix)Prefs\ninclude $(THEOS_MAKE_PATH)/aggregate.mk" : "",
            "__DEPENDS__": input.preferences ? "mobilesubstrate, preferenceloader" : "mobilesubstrate",
            "__SLIDER_PROTOCOL__": input.slider ? " <\(prefix)SliderCellHandler>" : "",
            "__SLIDER_IMPORT__": input.slider ? "#import \"\(prefix)SliderCell.h\"" : "",
            "__SLIDER_METHODS__": "",
            "__SLIDER_PLIST__": "",
        ]
        // CI 标题：create.py 用 json.dumps 生成，正好是一个带引号的 JSON 字符串
        let titleObject: [String] = [display + " v${{ steps.bump.outputs.package_version }}"]
        if let titleData = try? JSONSerialization.data(withJSONObject: titleObject, options: []),
           let titleJSON = String(data: titleData, encoding: .utf8) {
            values["__CI_RELEASE_TITLE__"] = String(titleJSON.dropFirst().dropLast())
        }
        if input.slider {
            let controllerURL = templatesDir.appendingPathComponent("slider/controller.inc")
            let specifierURL = templatesDir.appendingPathComponent("slider/specifier.inc")
            let controllerRaw = try String(contentsOf: controllerURL, encoding: .utf8)
            let specifierRaw = try String(contentsOf: specifierURL, encoding: .utf8)
            values["__SLIDER_METHODS__"] = try substitute(controllerRaw, values)
            values["__SLIDER_PLIST__"] = try substitute(specifierRaw, values)
        }
        let manifest: [String: Any] = [
            "schema": 1, "name": input.name, "id": slug, "display_name": display,
            "class_prefix": prefix, "symbol_prefix": symbol, "package": domain,
            "bundle": input.resolvedBundle, "sdk_version": defaults.sdk_version,
            "minimum_ios": minimum, "preferences": input.preferences, "slider": input.slider,
            "github_actions": true,
        ]
        return Prepared(values: values, manifest: manifest, slug: slug, prefix: prefix, domain: domain)
    }

    // MARK: - 渲染（对应 render_group + generate）

    /// 返回生成出的文件相对路径列表。destination 必须不存在（与 create.py 一致，拒绝覆盖）。
    static func generate(input: TweakInput, defaults: TweakDefaults, destination: URL) throws -> [String] {
        guard let templatesDir = Bundle.main.url(forResource: "Templates", withExtension: nil) else {
            throw GeneratorError.message("App 模板缺失：Templates")
        }
        let prepared = try prepare(input: input, defaults: defaults, templatesDir: templatesDir)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw GeneratorError.message("输出目录已存在，拒绝覆盖")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var groups: [(dir: URL, outputPrefix: String)] = [
            (templatesDir.appendingPathComponent("base"), ""),
            (templatesDir.appendingPathComponent("github-workflow"), ".github/workflows"),
        ]
        if input.preferences { groups.append((templatesDir.appendingPathComponent("preferences"), "")) }
        if input.slider { groups.append((templatesDir.appendingPathComponent("slider"), "")) }

        var seen = Set<String>()
        var written: [String] = []
        do {
            for group in groups {
                let produced = try renderGroup(groupDir: group.dir, outputPrefix: group.outputPrefix,
                                               values: prepared.values, stage: destination, seen: &seen)
                written.append(contentsOf: produced)
            }
            let manifestData = try JSONSerialization.data(withJSONObject: prepared.manifest, options: [.prettyPrinted, .sortedKeys])
            var manifestText = String(data: manifestData, encoding: .utf8) ?? "{}"
            manifestText += "\n"
            let manifestURL = destination.appendingPathComponent("tweak.json")
            try manifestText.write(to: manifestURL, atomically: true, encoding: .utf8)
            written.append("tweak.json")
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return written.sorted()
    }

    private static func renderGroup(groupDir: URL, outputPrefix: String, values: [String: String],
                                    stage: URL, seen: inout Set<String>) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: groupDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw GeneratorError.message("模板组缺失：\(groupDir.lastPathComponent)")
        }
        var sources: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { sources.append(url) }
        }
        sources.sort { $0.path < $1.path }
        var produced: [String] = []
        for source in sources {
            if source.pathExtension == "inc" { continue }
            let relativeRaw = source.path.dropFirst(groupDir.path.count + 1)
            let substituted = try substitute(String(relativeRaw), values)
            let relative = outputPrefix.isEmpty ? substituted : outputPrefix + "/" + substituted
            if seen.contains(relative) { throw GeneratorError.message("模板输出重名：\(relative)") }
            seen.insert(relative)
            let output = stage.appendingPathComponent(relative)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let suffix = "." + source.pathExtension.lowercased()
            if binarySuffixes.contains(suffix) {
                try fm.copyItem(at: source, to: output)
            } else {
                let raw = try String(contentsOf: source, encoding: .utf8)
                var replacements = values
                if source.pathExtension.lowercased() == "plist" {
                    replacements = Dictionary(uniqueKeysWithValues: values.map { pair in
                        (pair.key, pair.key == "__SLIDER_PLIST__" ? pair.value : xmlEscape(pair.value))
                    })
                } else if ["h", "m", "xm"].contains(source.pathExtension.lowercased()) {
                    replacements = Dictionary(uniqueKeysWithValues: values.map { pair in
                        (pair.key, ["__SLIDER_IMPORT__", "__SLIDER_METHODS__"].contains(pair.key) ? pair.value : objcEscape(pair.value))
                    })
                }
                let result = try substitute(raw, replacements)
                if containsToken(result) {
                    throw GeneratorError.message("生成后仍有未替换占位符：\(relative)")
                }
                try result.write(to: output, atomically: true, encoding: .utf8)
            }
            if output.pathExtension == "sh" {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            }
            produced.append(relative)
        }
        return produced
    }

    // MARK: - 静态检查（对应 doctor.py 的核心检查，简化了命名空间正则扫描之外的项并注明）

    static func doctor(projectDir: URL, input: TweakInput, defaults: TweakDefaults) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        guard let templatesDir = Bundle.main.url(forResource: "Templates", withExtension: nil),
              let prepared = try? prepare(input: input, defaults: defaults, templatesDir: templatesDir) else {
            return ["工程信息不合法，没法检查"]
        }
        let prefix = prepared.prefix
        let metaURL = projectDir.appendingPathComponent("tweak.json")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
              (meta["schema"] as? Int) == 1 else {
            return ["缺 tweak.json 或版本不对"]
        }
        if (meta["slider"] as? Bool) == true && (meta["preferences"] as? Bool) != true {
            problems.append("tweak.json 里 slider 需要 preferences")
        }
        var required = [
            "control", "Makefile", "build.sh", "\(prefix)Build.mk", "\(prefix).plist",
            "Hooks/\(prefix)Main.xm", "Headers/\(prefix)Private.h",
            "Sources/\(prefix)Config.h", "Sources/\(prefix)Config.m",
            "Sources/\(prefix)Preferences.h", "Sources/\(prefix)Paths.h",
            ".github/workflows/build.yml",
        ]
        if input.preferences {
            required += [
                "\(prefix)Prefs/Makefile", "\(prefix)Prefs/\(prefix)RootListController.h",
                "\(prefix)Prefs/\(prefix)RootListController.m",
                "\(prefix)Prefs/Resources/Info.plist", "\(prefix)Prefs/Resources/\(prefix)Root.plist",
                "layout/Library/PreferenceLoader/Preferences/\(prefix)Prefs.plist",
            ]
        }
        if input.slider {
            required += ["\(prefix)Prefs/\(prefix)SliderCell.h", "\(prefix)Prefs/\(prefix)SliderCell.m"]
        }
        for name in required where !fm.fileExists(atPath: projectDir.appendingPathComponent(name).path) {
            problems.append("缺文件：\(name)")
        }
        // control 对照
        if let control = try? String(contentsOf: projectDir.appendingPathComponent("control"), encoding: .utf8) {
            var fields: [String: String] = [:]
            for line in control.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
            }
            if fields["Package"] != prepared.domain { problems.append("control 里的 Package 和 tweak.json 对不上") }
            if input.preferences && !(fields["Depends"] ?? "").contains("preferenceloader") {
                problems.append("有设置面板但 control 依赖里缺 preferenceloader")
            }
        }
        // 未替换占位符扫描 + plist 可解析
        let textExtensions: Set<String> = ["m", "h", "xm", "plist", "mk", "sh", "json", "yml"]
        if let enumerator = fm.enumerator(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                let relative = String(url.path.dropFirst(projectDir.path.count + 1))
                if relative == "tweak.json" { continue }
                let ext = url.pathExtension.lowercased()
                guard textExtensions.contains(ext) || ["Makefile", "control"].contains(url.lastPathComponent) else { continue }
                guard let raw = try? Data(contentsOf: url), let text = String(data: raw, encoding: .utf8) else {
                    problems.append("\(relative)：不是 UTF-8 文本")
                    continue
                }
                if text.hasPrefix("\u{FEFF}") { problems.append("\(relative)：带 UTF-8 BOM") }
                if containsToken(text) { problems.append("\(relative)：还有未替换的占位符") }
                if ext == "plist" {
                    if (try? PropertyListSerialization.propertyList(from: raw, format: nil)) == nil {
                        problems.append("\(relative)：plist 解析失败")
                    }
                }
                if ext == "sh" && text.contains("\r\n") { problems.append("\(relative)：脚本必须是 LF 换行") }
            }
        }
        // 注入过滤器
        let filterURL = projectDir.appendingPathComponent("\(prefix).plist")
        if let data = try? Data(contentsOf: filterURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
           let filter = plist["Filter"] as? [String: Any],
           let bundles = filter["Bundles"] as? [String] {
            if !bundles.contains(input.resolvedBundle) { problems.append("注入过滤器和目标 Bundle 对不上") }
            if bundles != ["com.apple.springboard"] { problems.append("提醒：目标不是默认 SpringBoard，示例 Hook 需要按目标 App 改（静态检查过不等于真机可用）") }
        } else {
            problems.append("注入过滤器 plist 无效")
        }
        // 设置面板入口一致性
        if input.preferences {
            func plistDict(_ relative: String) -> [String: Any]? {
                guard let data = try? Data(contentsOf: projectDir.appendingPathComponent(relative)) else { return nil }
                return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            }
            let entry = plistDict("layout/Library/PreferenceLoader/Preferences/\(prefix)Prefs.plist")?["entry"] as? [String: Any]
            let info = plistDict("\(prefix)Prefs/Resources/Info.plist")
            if (entry?["bundle"] as? String) != "\(prefix)Prefs" || (entry?["detail"] as? String) != "\(prefix)RootListController" {
                problems.append("PreferenceLoader 入口的 bundle/控制器对不上")
            }
            if (info?["NSPrincipalClass"] as? String) != (entry?["detail"] as? String) ||
               (info?["CFBundleIdentifier"] as? String) != prepared.domain + ".preferences" {
                problems.append("设置面板 Info.plist 身份对不上")
            }
            if input.slider, let root = plistDict("\(prefix)Prefs/Resources/\(prefix)Root.plist"),
               let items = root["items"] as? [[String: Any]] {
                if !items.contains(where: { ($0["cellClass"] as? String) == "\(prefix)SliderCell" }) {
                    problems.append("滑条没有对应的 plist 开关项")
                }
            }
        }
        return problems
    }
}
