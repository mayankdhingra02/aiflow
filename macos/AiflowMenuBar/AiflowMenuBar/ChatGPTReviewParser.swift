import Foundation

enum ParsedChatGPTReview: Equatable {
    case ship
    case changesRequested(instruction: String)
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

        let instructionIndexes = lines.indices.filter {
            lines[$0] == "## Codex Instruction" || lines[$0] == "Codex Instruction"
        }
        guard !lines.dropFirst().contains(where: {
            $0.hasPrefix("## ") && $0 != "## Verdict" && $0 != "## Codex Instruction"
        }) else {
            throw ChatGPTReviewParserError.malformedHeading
        }
        guard !lines.dropFirst().contains(where: { $0.hasPrefix("#") && !$0.hasPrefix("## ") }) else {
            throw ChatGPTReviewParserError.malformedHeading
        }

        let verdictIndex = verdictIndexes[0]
        let nextHeading = lines.indices.drop(while: { $0 <= verdictIndex }).first {
            lines[$0] == "## Codex Instruction" || lines[$0] == "Codex Instruction"
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
            guard instructionIndexes.isEmpty else {
                throw ChatGPTReviewParserError.malformedHeading
            }
            return .ship
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
        return .changesRequested(instruction: instruction)
    }
}
