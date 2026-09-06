import Foundation

/// Validates Kafka-compatible topic names according to the protocol specification.
///
/// Rules:
/// - Must not be empty.
/// - Maximum 249 characters.
/// - Only alphanumeric characters, `.`, `_`, and `-` are allowed.
/// - Must not be `"."` or `".."`.
public enum TopicNameValidator {
    /// Maximum allowed length for a topic name.
    public static let maxLength = 249

    /// Validates the given topic name and throws ``StreamlineError/configurationError(_:)``
    /// if the name violates any Kafka topic naming rule.
    public static func validate(_ topic: String) throws {
        guard !topic.isEmpty else {
            throw StreamlineError.configurationError("Topic name must not be empty")
        }
        guard topic.count <= maxLength else {
            throw StreamlineError.configurationError(
                "Topic name exceeds max length of \(maxLength)"
            )
        }
        guard topic != ".", topic != ".." else {
            throw StreamlineError.configurationError(
                "Topic name must not be '.' or '..'"
            )
        }
        guard topic.allSatisfy({ $0.isASCIILetterOrDigit || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw StreamlineError.configurationError(
                "Topic name contains invalid characters: \(topic)"
            )
        }
    }
}

// MARK: - Character Helpers

private extension Character {
    /// Returns `true` for ASCII letters (a-z, A-Z) and digits (0-9).
    /// Unlike `Character.isLetter`, this excludes Unicode letters such as accented characters.
    var isASCIILetterOrDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return (ascii >= 0x30 && ascii <= 0x39) // 0-9
            || (ascii >= 0x41 && ascii <= 0x5A) // A-Z
            || (ascii >= 0x61 && ascii <= 0x7A) // a-z
    }
}
