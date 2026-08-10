import XCTest
@testable import CodexCompanionCore

final class CodexRateLimitParserTests: XCTestCase {
    func testExplicitExecutablePathResolvesWithoutShellPath() {
        XCTAssertEqual(
            CodexAppServerClient.resolveExecutable("/bin/echo", environment: [:])?.path,
            "/bin/echo"
        )
    }

    func testParserPrefersCodexBucketAndMapsByDuration() throws {
        let data = Data("""
        {
          "id":2,
          "result":{
            "rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1}},
            "rateLimitsByLimitId":{
              "other":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":2}},
              "codex":{
                "primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":200},
                "secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":100}
              }
            }
          }
        }
        """.utf8)

        let snapshot = try CodexRateLimitParser.parseResponse(data, updatedAt: 50)

        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 60)
        XCTAssertEqual(snapshot.weekRemainingPercent, 73)
        XCTAssertEqual(snapshot.fiveHourResetsAt, 100)
        XCTAssertEqual(snapshot.weekResetsAt, 200)
    }

    func testParserLeavesUnavailableFiveHourWindowNil() throws {
        let data = Data("""
        {
          "id":2,
          "result":{"rateLimits":{"primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":200}}}
        }
        """.utf8)

        let snapshot = try CodexRateLimitParser.parseResponse(data, updatedAt: 50)

        XCTAssertNil(snapshot.fiveHourRemainingPercent)
        XCTAssertEqual(snapshot.weekRemainingPercent, 73)
    }
}
