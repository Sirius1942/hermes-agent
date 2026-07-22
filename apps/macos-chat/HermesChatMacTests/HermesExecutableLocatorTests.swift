import XCTest
@testable import HermesChatMac

final class HermesExecutableLocatorTests: XCTestCase {
    func testPreferredPathIsFirstAndCandidatesAreUnique() {
        let home = URL(fileURLWithPath: "/Users/test")
        let candidates = HermesExecutableLocator.candidates(
            preferredPath: "/custom/hermes",
            environment: ["PATH": "/bin:/custom"],
            homeDirectory: home
        )
        XCTAssertEqual(candidates.first?.path, "/custom/hermes")
        XCTAssertEqual(Set(candidates.map(\.path)).count, candidates.count)
        XCTAssertTrue(candidates.map(\.path).contains("/Users/test/.local/bin/hermes"))
        XCTAssertTrue(candidates.map(\.path).contains("/opt/homebrew/bin/hermes"))
    }

    func testReturnsNilWhenNoCandidateIsExecutable() {
        let found = HermesExecutableLocator.locate(
            preferredPath: "/missing/hermes",
            environment: ["PATH": "/empty"],
            homeDirectory: URL(fileURLWithPath: "/missing-home"),
            fileManager: NoExecutableFileManager()
        )
        XCTAssertNil(found)
    }
}

private final class NoExecutableFileManager: FileManager {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
