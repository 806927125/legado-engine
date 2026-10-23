import Foundation

/// ⭐⭐ **Java `SimpleDateFormat` 风格的格式化**（站方 `java.timeFormat` / `timeFormatUTC`）
///
/// **依据**：轻阅参考实现（`reference/js/java-api.js`）的注释 + 125 源真实用法
/// - `java.timeFormat(t)` ⇒ **epoch 毫秒** → `"yyyy-MM-dd HH:mm:ss"`（本地时区）
/// - `java.timeFormatUTC(t, 'yyyy-MM-dd', 8)` ⇒ **epoch 毫秒** + pattern + **时区偏移小时**
///
/// ⚠️⚠️ **Java pattern 大小写敏感**（和 ICU 大体一致，但别混）：
/// | 符号 | 含义 | 两位 |
/// |---|---|---|
/// | `y` | 年 | `yy` |
/// | `M` | **月** | `MM` |
/// | `d` | 日 | `dd` |
/// | `H` | 时（24 小时制）| `HH` |
/// | `m` | **分** | `mm` |
/// | `s` | 秒 | `ss` |
/// | `S` | 毫秒 | `SSS` |
/// | `E` | 星期名 | — |
public enum TimeFormat {

    /// ⭐ **默认格式**（Legado `java.timeFormat` 的默认）
    public static let defaultPattern = "yyyy-MM-dd HH:mm:ss"

    /// ⭐ **格式化**（epoch 毫秒）
    ///
    /// - Parameters:
    ///   - millis: epoch **毫秒**
    ///   - pattern: Java pattern；nil ⇒ 默认格式
    ///   - utcOffsetHours: **时区偏移小时**（如 8 = UTC+8）；nil ⇒ **本地时区**
    public static func format(millis: Int64, pattern: String? = nil,
                              utcOffsetHours: Int? = nil) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        let fmt = DateFormatter()
        // ⚠️ `en_US_POSIX` ⇒ 固定英文/数字 ⇒ 不受宿主语言影响（站方要的就是数字）
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = pattern ?? defaultPattern
        if let tz = utcOffsetHours {
            // ⚠️ `TimeZone(secondsFromGMT:)` ⇒ 固定偏移（不管 DST）⇒ 与 Java 的 `GMT+8` 一致
            fmt.timeZone = TimeZone(secondsFromGMT: tz * 3600) ?? .current
        } else {
            fmt.timeZone = .current
        }
        return fmt.string(from: date)
    }

    /// ⭐ **从站方的实参解析出 epoch 毫秒**。
    ///
    /// ⚠️ 站方常写 `java.timeFormat(java.getString('$.updated')*1000)`
    /// ⇒ 说明**站方那边的时间戳单位是【秒】** ⇒ 乘 1000 变毫秒。
    /// ⇒ 所以入参**按毫秒**处理。
    public static func millis(from value: String) -> Int64? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // 纯数字 ⇒ 直接当毫秒
        if let n = Int64(t) { return n }
        // 其它（日期串）⇒ 交给 DateFormatter 试几种常见格式
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
                    "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd", "MM-dd HH:mm:ss"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            df.timeZone = .current
            if let d = df.date(from: t) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}
