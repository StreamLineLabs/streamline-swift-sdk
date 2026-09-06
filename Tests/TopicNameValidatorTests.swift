@testable import StreamlineSDK
import XCTest

final class TopicNameValidatorTests: XCTestCase {
    // MARK: - Valid Names

    func testValidSimpleName() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("events"))
    }

    func testValidNameWithDots() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("my.topic.name"))
    }

    func testValidNameWithUnderscores() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("my_topic_name"))
    }

    func testValidNameWithHyphens() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("my-topic-name"))
    }

    func testValidNameWithMixedCharacters() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("My-Topic_v2.0"))
    }

    func testValidSingleCharacter() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("a"))
    }

    func testValidNumericName() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("12345"))
    }

    func testValidMaxLengthName() throws {
        let name = String(repeating: "a", count: TopicNameValidator.maxLength)
        XCTAssertNoThrow(try TopicNameValidator.validate(name))
    }

    // MARK: - Empty Name

    func testEmptyNameThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("")) { error in
            guard case let StreamlineError.configurationError(msg) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(msg.contains("empty"))
        }
    }

    // MARK: - Length

    func testExceedsMaxLengthThrows() {
        let name = String(repeating: "a", count: TopicNameValidator.maxLength + 1)
        XCTAssertThrowsError(try TopicNameValidator.validate(name)) { error in
            guard case let StreamlineError.configurationError(msg) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(msg.contains("max length"))
        }
    }

    // MARK: - Reserved Names

    func testDotNameThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate(".")) { error in
            guard case let StreamlineError.configurationError(msg) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(msg.contains("'.' or '..'"))
        }
    }

    func testDoubleDotNameThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("..")) { error in
            guard case let StreamlineError.configurationError(msg) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(msg.contains("'.' or '..'"))
        }
    }

    func testTripleDotIsValid() throws {
        XCTAssertNoThrow(try TopicNameValidator.validate("..."))
    }

    // MARK: - Invalid Characters

    func testSpaceThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("my topic")) { error in
            guard case let StreamlineError.configurationError(msg) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(msg.contains("invalid characters"))
        }
    }

    func testSlashThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("my/topic")) { error in
            guard case StreamlineError.configurationError = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
        }
    }

    func testAtSignThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("topic@name")) { error in
            guard case StreamlineError.configurationError = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
        }
    }

    func testUnicodeLetterThrows() {
        XCTAssertThrowsError(try TopicNameValidator.validate("topicé")) { error in
            guard case StreamlineError.configurationError = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
        }
    }

    // MARK: - Error Code

    func testErrorCodeIsConfiguration() {
        do {
            try TopicNameValidator.validate("")
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error.errorCode, .configuration)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Max Length Constant

    func testMaxLengthIs249() {
        XCTAssertEqual(TopicNameValidator.maxLength, 249)
    }
}
