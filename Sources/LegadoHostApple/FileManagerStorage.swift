import Foundation
import LegadoCore

/// ⭐ **iOS/macOS 的文件存储**（`FileManager`）—— 宿主服务契约 §S-HOST-04 的参考实现。
///
/// ⚠️ **逻辑路径 ⇒ 物理路径**：引擎给的是「逻辑路径」（如 `cache/cover/1.jpg`），
/// 这里映射到 `root` 目录下的对应位置 ⇒ 引擎不关心宿主把文件放哪。
///
/// ⚠️ **路径穿越防护**：逻辑路径里的 `..` 必须挡住（否则引擎一个规则就能读宿主任意文件）⭐
public final class FileManagerStorage: FileStorage, @unchecked Sendable {

    /// 物理根目录
    public let root: URL
    private let fm: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// ⭐ **逻辑路径 → 物理 URL**（并挡住路径穿越）
    public func url(for path: String) throws -> URL {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { throw SourceError.invalidSource("文件路径为空") }
        guard !p.hasPrefix("/") else {
            throw SourceError.invalidSource("逻辑路径不许以 / 开头：\(path)")
        }
        let parts = p.split(separator: "/").map(String.init)
        guard !parts.contains("..") else {
            throw SourceError.invalidSource("逻辑路径不许含 ..：\(path)")
        }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    public func read(_ path: String) throws -> Data {
        let u = try url(for: path)
        guard fm.fileExists(atPath: u.path) else {
            throw SourceError.invalidSource("文件不存在：\(path)")
        }
        return try Data(contentsOf: u)
    }

    public func write(_ data: Data, to path: String) throws {
        let u = try url(for: path)
        try fm.createDirectory(at: u.deletingLastPathComponent(),
                              withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    public func exists(_ path: String) -> Bool {
        guard let u = try? url(for: path) else { return false }
        return fm.fileExists(atPath: u.path)
    }

    public func remove(_ path: String) throws {
        let u = try url(for: path)
        if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
    }

    public func list(_ directory: String) throws -> [String] {
        let u = try url(for: directory)
        guard fm.fileExists(atPath: u.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: u.path).sorted()
    }
}
