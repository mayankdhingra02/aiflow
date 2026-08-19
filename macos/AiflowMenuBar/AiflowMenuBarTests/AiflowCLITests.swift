import XCTest

@testable import AiflowMenuBar

final class AiflowCommandArgumentTests: XCTestCase {
    func testModelsJSON() {
        XCTAssertEqual(AiflowCommand.modelsJSON.arguments, ["models", "--json"])
    }
}

final class AiflowExecutableLocatorTests: XCTestCase {
    func testPrefersEnvironmentOverrideWhenExecutable() {
        let resolution = AiflowExecutableLocator.resolve(
            environment: ["AIFLOW_CLI_PATH": "/custom/aiflow"],
            isExecutableFile: { $0 == "/custom/aiflow" }
        )

        XCTAssertEqual(resolution?.executableURL.path, "/custom/aiflow")
        XCTAssertEqual(resolution?.argumentPrefix, [])
    }

    func testIgnoresEnvironmentOverrideWhenNotExecutable() {
        let resolution = AiflowExecutableLocator.resolve(
            environment: ["AIFLOW_CLI_PATH": "/missing/aiflow"],
            isExecutableFile: { $0 == AiflowExecutableLocator.knownInstallPath }
        )

        XCTAssertEqual(resolution?.executableURL.path, AiflowExecutableLocator.knownInstallPath)
    }

    func testFallsBackToEnvPathLookupAsLastResort() {
        let resolution = AiflowExecutableLocator.resolve(
            environment: [:],
            isExecutableFile: { $0 == "/usr/bin/env" }
        )

        XCTAssertEqual(resolution?.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(resolution?.argumentPrefix, ["aiflow"])
    }

    func testReturnsNilWhenNothingIsExecutable() {
        XCTAssertNil(
            AiflowExecutableLocator.resolve(environment: [:], isExecutableFile: { _ in false }))
    }
}

final class CodexConfigDecodingTests: XCTestCase {
    func testDecodesModelsJSONOutput() throws {
        let json = """
            {
              "models": [
                {"role": "luna", "model_id": "gpt-5.6-luna"},
                {"role": "terra", "model_id": "gpt-5.6-terra"},
                {"role": "sol", "model_id": "gpt-5.6-sol"}
              ],
              "reasoning_efforts": ["low", "medium", "high", "xhigh"],
              "default_sandbox": "workspace-write"
            }
            """

        let config = try JSONDecoder().decode(CodexConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.models.count, 3)
        XCTAssertEqual(config.model(forRole: "terra")?.modelId, "gpt-5.6-terra")
        XCTAssertEqual(config.models[1].displayName, "Terra")
        XCTAssertEqual(config.reasoningEfforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(config.defaultSandbox, "workspace-write")
    }

    func testDefaultsMatchTheRequestedProduct() {
        XCTAssertEqual(CodexConfig.defaultModelRole, "terra")
        XCTAssertEqual(CodexConfig.defaultReasoningEffort, "medium")
    }

    func testEffortDisplayNames() {
        XCTAssertEqual(displayNameForEffort("low"), "Low")
        XCTAssertEqual(displayNameForEffort("medium"), "Medium")
        XCTAssertEqual(displayNameForEffort("high"), "High")
        XCTAssertEqual(displayNameForEffort("xhigh"), "XHigh")
    }
}
