import Foundation

/// ⭐⭐ **纯计算工具** —— 站方 JS 的 `java.*` 编解码/摘要类 API 的底座。
///
/// ⚠️ **为什么自己实现 MD5**：`Foundation` **没有** MD5；`CryptoKit`（Apple 平台）
/// **Linux 沙盒没有** ⇒ 核心层必须**纯 Foundation、跨平台** ⇒ 自己写。
///
/// ⭐ 门禁用 **RFC 1321 / FIPS 180 的官方测试向量** ⇒ 写错必红。
public enum Crypto {

    // MARK: - MD5（RFC 1321）

    /// ⭐ **MD5** ⇒ **小写十六进制**（32 位）。
    ///
    /// 站方 `java.md5Encode(str)` = MD5 小写 hex（**125 源里 233 处** ⇒ 用得最多的 API）。
    public static func md5Hex(_ text: String) -> String {
        md5Bytes(Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// MD5 原始字节
    public static func md5Bytes(_ input: [UInt8]) -> [UInt8] {
        // ① 填充：0x80 + 0x00… + 长度(小端 8 字节) ⇒ 总长 ≡ 56 (mod 64)
        var msg = input
        let bitLen = UInt64(input.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(truncatingByte(bitLen >> (8 * UInt64(i)))) }

        // ② 初始向量
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        // ③ 每 64 字节一轮
        var chunkStart = 0
        while chunkStart < msg.count {
            var M = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = chunkStart + j * 4
                M[j] = UInt32(msg[o]) | (UInt32(msg[o + 1]) << 8)
                      | (UInt32(msg[o + 2]) << 16) | (UInt32(msg[o + 3]) << 24)
            }
            var A = a0, B = b0, C = c0, D = d0
            for i in 0..<64 {
                var F: UInt32
                var g: Int
                switch i {
                case 0..<16:  F = (B & C) | (~B & D);      g = i
                case 16..<32: F = (D & B) | (~D & C);      g = (5 * i + 1) % 16
                case 32..<48: F = B ^ C ^ D;               g = (3 * i + 5) % 16
                default:      F = C ^ (B | ~D);            g = (7 * i) % 16
                }
                F = F &+ A &+ md5Table[i] &+ M[g]
                A = D; D = C; C = B
                B = B &+ rotateLeft(F, md5Shifts[i])
            }
            a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
            chunkStart += 64
        }

        // ④ 输出：4 个 32 位小端
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    /// 循环左移
    @inline(__always)
    private static func rotateLeft(_ x: UInt32, _ c: UInt32) -> UInt32 {
        (x << c) | (x >> (32 - c))
    }

    /// ⭐ MD5 的 K 表（`floor(abs(sin(i+1)) * 2^32)`）
    private static let md5Table: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    /// 每轮的位移量
    private static let md5Shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    // MARK: - Base64

    /// ⭐ **Base64 编码**（标准字母表 + `=` 补齐）⇒ `java.base64Encode`
    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// ⭐ **Base64 解码** ⇒ `java.base64Decode`
    ///
    /// ⚠️ **解不了 ⇒ 明确失败（nil）**，不许返回乱码
    /// （乱码 ⇒ 站方 `JSON.parse` 炸 ⇒ 整条规则挂掉）⭐
    public static func base64Decode(_ text: String) -> String? {
        let normalized = b64Normalize(text)
        guard let data = Data(base64Encoded: normalized, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// ⭐⭐⭐ **base64 文本归一化**（轻阅 `reference/js/java-api.js` 的 `b64normalize` **同语义**）
    ///
    /// ⚠️⚠️ **为什么必须有**（2026-10-21 真机栽在这）：
    ///   聚合源（🍅大灰狼）的 `data:` 载荷里有 **`+` 和 `/`**（中文摘要 base64 出来的）
    ///   ⇒ 这个字符串当 URL 走一圈 ⇒ `'+'` 可能被 URL 解码成**空格**、或被转义成 `%2B`
    ///   ⇒ 老解码器「空格直接删掉、非法字符静默跳过」⇒ **解出来是乱码（还不报错！）**
    ///   ⇒ 站方 `JSON.parse(...)` 抛「Unable to parse JSON string」⇒ 整条规则静默失效 ⭐⭐⭐
    ///
    /// ① 百分号转义还原（**只还原成 base64 合法字符的那些**）
    /// ② URL 安全字符（`-` / `_`）⇒ 标准 base64（`+` / `/`）
    /// ③ **空格 ⇒ `+`**（URL 解码把 `+` 变成空格的经典坑）
    public static func b64Normalize(_ text: String) -> String {
        var s = text
        // ① 百分号转义还原（**只还原成 base64 合法字符的那些** ⇒ 其余保持原样）
        s = restorePercentEscapes(s)
        // ② URL 安全字符 ⇒ 标准 base64
        s = s.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // ③ 空格 ⇒ `+`
        s = s.replacingOccurrences(of: " ", with: "+")
        return s
    }

    /// **把 `%XX` 还原成字符**（只还原 base64 合法字符；其余保持原样）
    private static func restorePercentEscapes(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_")
        var out = ""
        out.reserveCapacity(s.count)
        let it = Array(s)
        var i = 0
        while i < it.count {
            if it[i] == "%", i + 2 < it.count,
               let hi = it[i + 1].hexDigitValue, let lo = it[i + 2].hexDigitValue {
                let scalar = UnicodeScalar(hi * 16 + lo)
                if let scalar, allowed.contains(Character(scalar)) {
                    out.append(Character(scalar))
                    i += 3
                    continue
                }
            }
            out.append(it[i])
            i += 1
        }
        return out
    }

    // MARK: - Hex

    /// ⭐ **hex 解码 ⇒ 字符串** ⇒ `java.hexDecodeToString`
    ///
    /// ⚠️⚠️ **站方语义（重要）**：
    /// 「**不是合法 hex 就按 base64 再试一次**」
    /// ⇒ 站方（大灰狼）拿 base64/hex 两种载荷喂它都能解 ⭐
    /// ⇒ 宿主**别盲解**。
    public static func hexDecodeToString(_ text: String) -> String? {
        if let hex = hexDecode(text) { return hex }
        return base64Decode(text)
    }

    /// 严格的 hex 解码（**长度必须是偶数、字符必须合法**）
    public static func hexDecode(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    /// hex 编码（小写）
    public static func hexEncode(_ text: String) -> String {
        Array(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - UUID

    /// ⭐ **随机 UUID**（v4 形状）⇒ `java.randomUUID`
    public static func randomUUID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        // ⚠️ 用 `String(...)` 包一下 —— 否则是 `ArraySlice` 的 description（会变成 "["a", …]"）
        let c = Array(hex)
        return "\(String(c[0...7]))-\(String(c[8...11]))-\(String(c[12...15]))-\(String(c[16...19]))-\(String(c[20...31]))"
    }

    // MARK: - 中文数字

    /// ⭐ **中文数字 ⇒ 阿拉伯数字** ⇒ `java.toNumChapter`
    ///
    /// 站方用法（爱下电子）：
    /// ```js
    /// result.replace(/第([零一二三四五六七八九十百千]+)章/g, java.toNumChapter(result))
    /// ```
    /// ⇒ 把「第X章」换成「第N章」。
    /// ⭐⭐ **文本里的中文数字 ⇒ 批量转成阿拉伯数字**（站方 `java.toNumChapter` 的真实用法）
    ///
    /// 站方写法（爱下电子）：
    /// ```js
    /// result.replace(/第([零一二三四五六七八九十百千]+)章/g, java.toNumChapter(result))
    /// ```
    /// ⇒ 传进来的是**整段文本** ⇒ 所以要**扫描整段、把每个中文数字串转掉**。
    public static func convertChineseNumerals(in text: String) -> String {
        let digitChars: Set<Character> = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let unitChars: Set<Character> = ["十", "百", "千"]
        var out = ""
        var buf = ""
        func flush() {
            if buf.isEmpty { return }
            out += chineseNumeral(buf)
            buf = ""
        }
        for ch in text {
            if digitChars.contains(ch) || unitChars.contains(ch) {
                buf.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    public static func chineseNumeral(_ text: String) -> String {
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        var total = 0
        var section = 0
        var current = 0
        var any = false
        for ch in text {
            if let d = digits[ch] {
                current = d
                any = true
            } else if let u = units[ch] {
                // 「十二」= 10 + 2；「二十」= 20（前面没有数字 ⇒ 补 1）
                section += (current == 0 ? 1 : current) * u
                current = 0
                any = true
            } else {
                return text   // 不是纯中文数字 ⇒ 原样返回
            }
        }
        if !any { return text }
        total = section + current
        return String(total)
    }
}

/// ⚠️ `UInt64` → `UInt8` 的安全截断（位运算需要）
private func truncatingByte(_ v: UInt64) -> UInt8 { UInt8(v & 0xff) }
