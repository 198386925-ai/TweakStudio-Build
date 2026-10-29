import Foundation

/// 仅用 Foundation 的 ZIP 打包器（store 存储，不压缩），供工程 zip 分享使用。
enum ZipWriter {

    private static let crcTable: [UInt32] = (0..<256).map { seed -> UInt32 in
        var c = UInt32(seed)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (dosTime, dosDate)
    }

    /// 把目录打包成 zip。entries 按相对路径排序，Unix 权限写进 external attributes（保住 build.sh 可执行位）。
    static func writeZip(of directory: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw GeneratorError.message("无法读取工程目录")
        }
        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.dropFirst(directory.path.count + 1)
            files.append((String(relative), url))
        }
        files.sort { $0.relative < $1.relative }

        var out = Data()
        var central = Data()
        for file in files {
            let data = try Data(contentsOf: file.url)
            let nameData = Data(file.relative.utf8)
            let crc = crc32(data)
            let attrs = try fm.attributesOfItem(atPath: file.url.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? Date()
            let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            let (dosTime, dosDate) = dosDateTime(mtime)
            let localOffset = UInt32(out.count)

            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(20))            // version needed
            local.appendLE(UInt16(0x0800))        // UTF-8 filename flag
            local.appendLE(UInt16(0))             // store
            local.appendLE(dosTime)
            local.appendLE(dosDate)
            local.appendLE(crc)
            local.appendLE(UInt32(data.count))
            local.appendLE(UInt32(data.count))
            local.appendLE(UInt16(nameData.count))
            local.appendLE(UInt16(0))
            out.append(local)
            out.append(nameData)
            out.append(data)

            var dir = Data()
            dir.appendLE(UInt32(0x02014b50))
            dir.appendLE(UInt16(20))              // version made by (low byte)
            dir.appendLE(UInt16(20))
            dir.appendLE(UInt16(0x0800))
            dir.appendLE(UInt16(0))
            dir.appendLE(dosTime)
            dir.appendLE(dosDate)
            dir.appendLE(crc)
            dir.appendLE(UInt32(data.count))
            dir.appendLE(UInt32(data.count))
            dir.appendLE(UInt16(nameData.count))
            dir.appendLE(UInt16(0))               // extra
            dir.appendLE(UInt16(0))               // comment
            dir.appendLE(UInt16(0))               // disk
            dir.appendLE(UInt16(0))               // internal attrs
            dir.appendLE(UInt32((permissions & 0xFFFF) << 16))
            dir.appendLE(localOffset)
            central.append(dir)
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(files.count))
        end.appendLE(UInt16(files.count))
        end.appendLE(UInt32(central.count))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        out.append(end)
        try out.write(to: destination, options: .atomic)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }
}
