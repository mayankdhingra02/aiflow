import Foundation

struct ChatGPTReviewExecutionRecommendation: Equatable {
    let modelRole: String
    let effort: String
}

enum ParsedChatGPTReview: Equatable {
    case ship
    case changesRequested(
        instruction: String,
        executionRecommendation: ChatGPTReviewExecutionRecommendation?
    )
}

enum ChatGPTReviewParserError: Error, Equatable {
    case oversized
    case malformedHeading
    case missingVerdict
    case duplicateVerdict
    case unknownVerdict
    case contradictoryVerdict
    case missingInstruction
    case oversizedInstruction
    case malformedExecution
}

enum ChatGPTReviewParser {
    static let maximumInstructionUTF8Bytes = 16 * 1024

    static func parse(_ review: ChatGPTReview) throws -> ParsedChatGPTReview {
        guard review.assistantMessage.lengthOfBytes(using: .utf8)
            <= ChatGPTReview.maximumAssistantMessageUTF8Bytes else {
            throw ChatGPTReviewParserError.oversized
        }

        let lines = review.assistantMessage
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard lines.first == "# Implementation Review" || lines.first == "Implementation Review" else {
            throw ChatGPTReviewParserError.malformedHeading
        }

        let verdictIndexes = lines.indices.filter {
            lines[$0] == "## Verdict" || lines[$0] == "Verdict"
        }
        guard verdictIndexes.count == 1 else {
            throw verdictIndexes.isEmpty
                ? ChatGPTReviewParserError.missingVerdict
                : ChatGPTReviewParserError.duplicateVerdict
        }

        let executionIndexes = lines.indices.filter { isExecutionHeading(lines[$0]) }
        let instructionIndexes = lines.indices.filter { isInstructionHeading(lines[$0]) }
        guard !lines.dropFirst().contains(where: {
            $0.hasPrefix("## ") && !isKnownHeading($0)
        }) else {
            throw ChatGPTReviewParserError.malformedHeading
        }
        guard !lines.dropFirst().contains(where: { $0.hasPrefix("#") && !$0.hasPrefix("## ") }) else {
            throw ChatGPTReviewParserError.malformedHeading
        }

        let verdictIndex = verdictIndexes[0]
        let nextHeading = lines.indices.drop(while: { $0 <= verdictIndex }).first {
            isExecutionHeading(lines[$0]) || isInstructionHeading(lines[$0])
        }
        let verdictEnd = nextHeading ?? lines.count
        let verdictLines = lines[(verdictIndex + 1)..<verdictEnd]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard verdictLines.count == 1 else {
            throw ChatGPTReviewParserError.contradictoryVerdict
        }

        let verdict = verdictLines[0]
        guard verdict == "SHIP" || verdict == "CHANGES_REQUESTED" else {
            if verdict.contains("SHIP") || verdict.contains("CHANGES_REQUESTED") {
                throw ChatGPTReviewParserError.contradictoryVerdict
            }
            throw ChatGPTReviewParserError.unknownVerdict
        }

        if verdict == "SHIP" {
            guard executionIndexes.isEmpty, instructionIndexes.isEmpty else {
                throw ChatGPTReviewParserError.malformedHeading
            }
            return .ship
        }

        guard executionIndexes.count <= 1 else {
            throw ChatGPTReviewParserError.malformedHeading
        }
        guard instructionIndexes.count == 1 else {
            throw instructionIndexes.isEmpty
                ? ChatGPTReviewParserError.missingInstruction
                : ChatGPTReviewParserError.malformedHeading
        }
        let instructionIndex = instructionIndexes[0]
        guard instructionIndex > verdictIndex else {
            throw ChatGPTReviewParserError.malformedHeading
        }

        let recommendation: ChatGPTReviewExecutionRecommendation?
        if let executionIndex = executionIndexes.first {
            guard verdictIndex < executionIndex, executionIndex < instructionIndex else {
                throw ChatGPTReviewParserError.malformedHeading
            }
            recommendation = try parseExecution(
                Array(lines[(executionIndex + 1)..<instructionIndex])
            )
        } else {
            recommendation = nil
        }

        let instruction = lines[(instructionIndex + 1)..<lines.count]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            throw ChatGPTReviewParserError.missingInstruction
        }
        guard !instruction.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.hasPrefix("#") }) else {
            throw ChatGPTReviewParserError.malformedHeading
        }
        guard instruction.lengthOfBytes(using: .utf8) <= maximumInstructionUTF8Bytes else {
            throw ChatGPTReviewParserError.oversizedInstruction
        }
        return .changesRequested(
            instruction: instruction,
            executionRecommendation: recommendation
        )
    }

    private static func isKnownHeading(_ line: String) -> Bool {
        line == "## Verdict" || line == "Verdict" || isExecutionHeading(line)
            || isInstructionHeading(line)
    }

    private static func isExecutionHeading(_ line: String) -> Bool {
        line == "## Codex Execution" || line == "Codex Execution"
    }

    private static func isInstructionHeading(_ line: String) -> Bool {
        line == "## Codex Instruction" || line == "Codex Instruction"
    }

    private static func parseExecution(
        _ rawLines: [String]
    ) throws -> ChatGPTReviewExecutionRecommendation {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 2,
              let modelRole = executionValue(in: lines[0], key: "Model:"),
              let effort = executionValue(in: lines[1], key: "Reasoning:") else {
            throw ChatGPTReviewParserError.malformedExecution
        }
        return ChatGPTReviewExecutionRecommendation(modelRole: modelRole, effort: effort)
    }

    private static func executionValue(in line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let value = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.lengthOfBytes(using: .utf8) <= 64,
              !value.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return value
    }
}
