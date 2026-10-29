import Foundation

/// ZIP 读取：解析中央目录（含 ZIP64 兜底）、按条目落盘。
/// store 条目直接复制，deflate 条目走系统 zlib（ZipInflate 桥接）。
/// 安全规则：含 `..` 的路径整条丢弃；跳过 __MACOSX / .DS_Store / AppleDouble / 符号链接；
/// 解开总大小设上限，防 zip 炸弹。文件名按 UTF-8 解（带损容错）。
enum ZipReader {

    private struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localOffset: UInt64
        var externalAttrs: UInt32
        var isDirectory: Bool { name.hasSuffix("/") }
        var isSymlink: Bool { ((externalAttrs >> 16) & 0xF000) == 0xA000 }
    }

    private static let maxTotalUncompressed: UInt64 = 1_000_000_000

    /// 解压 zip 文件到目标目录，返回写出的相对路径（已排序）。
    static func extract(zipAt url: URL, to destination: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: url) else {
            throw GeneratorError.message("zip 文件读不到")
        }
        return try extract(data: data, to: destination)
    }

    static func extract(data: Data, to destination: URL) throws -> [String] {
        let bytes = [UInt8](data)
        let entries = try parseCentralDirectory(bytes)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var written: [String] = []
        var total: UInt64 = 0
        for entry in entries {
            if entry.isDirectory || entry.isSymlink { continue }
            guard let relative = safeRelativePath(entry.name) else { continue }
            total += entry.uncompressedSize
            if total > maxTotalUncompressed {
                throw GeneratorError.message("zip 解开后总大小超过上限，已停止导入")
            }
            let content = try entryData(entry, bytes: bytes)
            if entry.crc != 0, ZipWriter.crc32(content) != entry.crc {
                throw GeneratorError.message("文件校验对不上，zip 可能损坏：\(relative)")
            }
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, options: .atomic)
            let permissions = (entry.externalAttrs >> 16) & 0o777
            if permissions != 0 {
                try? fm.setAttributes([.posixPermissions: Int(permissions)], ofItemAtPath: target.path)
            }
            written.append(relative)
        }
        return written.sorted()
    }

    /// 路径清洗：防穿越 + 去垃圾条目。不合法返回 nil（整条丢弃）。
    private static func safeRelativePath(_ raw: String) -> String? {
        // 反斜杠也按分隔符处理，挡住 Windows 风格的 ..\ 穿越
        let name = raw.replacingOccurrences(of: "\\", with: "/")
        if name.hasPrefix("/") { return nil }
        var parts: [String] = []
        for piece in name.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(piece)
            if part == ".." { return nil }
            if part == "." { continue }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        if parts.contains("__MACOSX") { return nil }
        if let last = parts.last, last == ".DS_Store" || last.hasPrefix("._") { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: - 中央目录解析

    private static func parseCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 22 else {
            throw GeneratorError.message("文件太小，不是有效的 zip")
        }
        // 从尾部找 EOCD（注释最长 65535 字节）
        let floor = max(0, bytes.count - 22 - 65535)
        var eocd: Int? = nil
        var i = bytes.count - 22
        while i >= floor {
            if u32(bytes, i) == 0x06054B50 { eocd = i; break }
            i -= 1
        }
        guard let eocdOffset = eocd else {
            throw GeneratorError.message("zip 结尾记录找不到，可能不是 zip 或已损坏")
        }
        var totalEntries = Int(u16(bytes, eocdOffset + 10))
        var cdOffset = Int(u32(bytes, eocdOffset + 16))
        if totalEntries == 0xFFFF || cdOffset == 0xFFFFFFFF {
            // ZIP64：EOCD 前面紧挨着 locator，真正的计数/偏移在 ZIP64 EOCD 里
            let locator = eocdOffset - 20
            guard locator >= 0, u32(bytes, locator) == 0x07064B50 else {
                throw GeneratorError.message("zip64 记录缺失，zip 可能损坏")
            }
            let zip64Offset = Int(u64(bytes, locator + 8))
            guard zip64Offset + 56 <= bytes.count, u32(bytes, zip64Offset) == 0x06064B50 else {
                throw GeneratorError.message("zip64 记录损坏")
            }
            totalEntries = Int(u64(bytes, zip64Offset + 32))
            cdOffset = Int(u64(bytes, zip64Offset + 48))
        }
        var entries: [Entry] = []
        var cursor = cdOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x02014B50 else {
                throw GeneratorError.message("zip 中央目录损坏")
            }
            let method = u16(bytes, cursor + 10)
            let crc = u32(bytes, cursor + 16)
            var compressed = UInt64(u32(bytes, cursor + 20))
            var uncompressed = UInt64(u32(bytes, cursor + 24))
            let nameLen = Int(u16(bytes, cursor + 28))
            let extraLen = Int(u16(bytes, cursor + 30))
            let commentLen = Int(u16(bytes, cursor + 32))
            let externalAttrs = u32(bytes, cursor + 38)
            var localOffset = UInt64(u32(bytes, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLen + extraLen + commentLen <= bytes.count else {
                throw GeneratorError.message("zip 中央目录损坏")
            }
            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLen)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            // ZIP64 扩展字段：只有对应值是 0xFFFFFFFF 哨兵时才按顺序出现
            if compressed == 0xFFFFFFFF || uncompressed == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                var p = nameStart + nameLen
                let extraEnd = p + extraLen
                while p + 4 <= extraEnd {
                    let tag = u16(bytes, p)
                    let size = Int(u16(bytes, p + 2))
                    let valueStart = p + 4
                    if tag == 0x0001 {
                        var q = valueStart
                        if uncompressed == 0xFFFFFFFF { uncompressed = u64(bytes, q); q += 8 }
                        if compressed == 0xFFFFFFFF { compressed = u64(bytes, q); q += 8 }
                        if localOffset == 0xFFFFFFFF { localOffset = u64(bytes, q); q += 8 }
                    }
                    p = valueStart + size
                }
            }
            entries.append(Entry(name: name, method: method, crc: crc,
                                 compressedSize: compressed, uncompressedSize: uncompressed,
                                 localOffset: localOffset, externalAttrs: externalAttrs))
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func entryData(_ entry: Entry, bytes: [UInt8]) throws -> Data {
        let base = Int(entry.localOffset)
        guard base + 30 <= bytes.count, u32(bytes, base) == 0x04034B50 else {
            throw GeneratorError.message("zip 本地文件头损坏：\(entry.name)")
        }
        let nameLen = Int(u16(bytes, base + 26))
        let extraLen = Int(u16(bytes, base + 28))
        let start = base + 30 + nameLen + extraLen
        let end = start + Int(entry.compressedSize)
        guard start >= 0, end >= start, end <= bytes.count else {
            throw GeneratorError.message("zip 数据范围不对：\(entry.name)")
        }
        let raw = Data(bytes[start..<end])
        switch entry.method {
        case 0:
            return raw
        case 8:
            do {
                let inflated = try TSZipInflate.inflate(raw)
                guard inflated.count == Int(entry.uncompressedSize) else {
                    throw GeneratorError.message("解压大小对不上：\(entry.name)")
                }
                return inflated
            } catch let error as GeneratorError {
                throw error
            } catch {
                throw GeneratorError.message("解压失败（\(entry.name)）：\(error.localizedDescription)")
            }
        default:
            throw GeneratorError.message("不支持的 zip 压缩方式 \(entry.method)：\(entry.name)")
        }
    }

    // MARK: - 小端读取（下标都已由调用方做边界检查）

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 { value |= UInt64(bytes[offset + k]) << (8 * k) }
        return value
    }
}

/// 导入现成工程时的定位与解析：找工程根、读 control、清洗仓库标识。
enum ProjectImporter {

    /// 在解压目录里定位工程根：根目录本身，或自动剥掉一层包裹文件夹。
    /// 找不到齐了 Makefile + control 的目录时，抛错并写清缺哪个文件。
    static func locateRoot(in extractedDir: URL) throws -> URL {
        let fm = FileManager.default
        func has(_ dir: URL, _ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        func hasBoth(_ dir: URL) -> Bool { has(dir, "Makefile") && has(dir, "control") }
        if hasBoth(extractedDir) { return extractedDir }
        let children = (try? fm.contentsOfDirectory(at: extractedDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let dirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let complete = dirs.filter { hasBoth($0) }
        if complete.count == 1 { return complete[0] }
        if complete.count > 1 {
            throw GeneratorError.message("zip 里有多个像插件工程的目录，没法自动判断用哪个")
        }
        // 没齐的：拿最像工程的那个目录报缺什么（根目录优先，其次唯一的下层目录）
        var reference = extractedDir
        if !has(extractedDir, "Makefile"), !has(extractedDir, "control"), dirs.count == 1 {
            reference = dirs[0]
        }
        var missing: [String] = []
        if !has(reference, "Makefile") { missing.append("Makefile") }
        if !has(reference, "control") { missing.append("control") }
        throw GeneratorError.message("导入的工程缺 \(missing.joined(separator: " 和 ")) 文件，不是完整的插件工程 zip")
    }

    /// 解析 Debian control 字段（与 Generator.doctor 同口径：行首字段、冒号后取值）。
    static func parseControl(at projectDir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: projectDir.appendingPathComponent("control")),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    /// 仓库名片段：优先 control 的 Package 最后一段清洗，取不到用备选名清洗，再不行用 "imported"。
    static func repoSlug(package: String?, fallback: String) -> String {
        if let package, let last = package.split(separator: ".").last.map(String.init) {
            let cleaned = cleanSlug(last)
            if !cleaned.isEmpty { return cleaned }
        }
        let cleaned = cleanSlug(fallback)
        return cleaned.isEmpty ? "imported" : cleaned
    }

    /// 清洗成 GitHub 仓库名可用的片段：小写，只留 a-z 0-9 - _ .，其余转连字符并折叠。
    static func cleanSlug(_ raw: String) -> String {
        var out: [Character] = []
        for ch in raw.lowercased() {
            let valid = ch.isASCII && ch.asciiValue.map {
                ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 || $0 == 46
            } == true
            if valid {
                if ch == "-", out.last == "-" { continue }
                out.append(ch)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        var text = String(out).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if text.count > 64 { text = String(text.prefix(64)) }
        return text
    }
}
