import XCTest
@testable import LegadoCore

final class ZZProbeJavaTests: XCTestCase {
    func testProbe() throws {
        var src: [String: Any] = [
            "bookSourceName": "probe",
            "bookSourceUrl": "https://example.test",
        ]
        let data = try JSONSerialization.data(withJSONObject: src)
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let eng = SourceEngine(source: source, fetcher: PageFetcher(transport: FailingTransport()))
        var okList: [String] = []
        var badList: [String] = []
        for e in JSHostAPI.all where e.object == "java" && e.kind == .method {
            let name = e.name
            do {
                let v = eng.engineJava(name, [.string("")], .page(""))
                if v == nil { badList.append("\(name)  ⇒ 返回 nil（落回宿主）") }
                else { okList.append(name) }
            } catch {
                badList.append("\(name)  ⇒ 抛错：\(error)")
            }
        }
        print("===PROBE-OK=== \(okList.count): \(okList.sorted().joined(separator: ", "))")
        for b in badList.sorted() { print("===PROBE-BAD=== \(b)") }
    }
}
