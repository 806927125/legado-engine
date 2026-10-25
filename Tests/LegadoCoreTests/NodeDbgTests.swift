import Foundation
import XCTest
@testable import LegadoCore

final class NodeDbgTests: XCTestCase {
    func testDbg() throws {
        try XCTSkipUnless(NodeJSExecutor.isAvailable, "no node")
        let js = try NodeJSExecutor()
        print("DBG init ok")
        let lib = "var host=[1]; function getArguments(){ return {tab:'小说'}; }"
        _ = try js.runGlobal(lib, context: JSRunContext(base: .page(""), baseUrl: "https://x"))
        print("DBG runGlobal ok")
        let r = try js.run("getArguments()", context: JSRunContext(base: .page(""), baseUrl: "https://x"))
        print("DBG run 结果 =", r.scalarString)
        let r2 = try js.run("typeof getArguments", context: JSRunContext(base: .page(""), baseUrl: "https://x"))
        print("DBG typeof =", r2.scalarString)
    }
}
