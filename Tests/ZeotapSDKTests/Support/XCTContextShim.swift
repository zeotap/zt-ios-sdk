import XCTest

// swift-corelibs-xctest (Linux) has no `XCTContext` / `XCTActivity`; the conformance runners wrap
// each vector case in `XCTContext.runActivity(named:)` so Xcode's report groups failures by case
// id. On Linux the activity is just a named scope — the block runs inline and assertion messages
// already carry the case id.
#if !canImport(ObjectiveC)
protocol XCTActivity {
    var name: String { get }
}

enum XCTContext {
    private struct Activity: XCTActivity {
        let name: String
    }

    static func runActivity<Result>(named name: String, block: (any XCTActivity) throws -> Result) rethrows -> Result {
        try block(Activity(name: name))
    }
}
#endif
