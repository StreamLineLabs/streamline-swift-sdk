import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

func requiredTestValue<T>(
    _ value: @autoclosure () -> T?,
    _ message: @autoclosure () -> String = "Expected a non-nil value",
    file: StaticString = #filePath,
    line: UInt = #line
) -> T {
    do {
        return try XCTUnwrap(value(), message(), file: file, line: line)
    } catch {
        preconditionFailure("Invalid test fixture: \(error)")
    }
}

func testJSONData(
    _ object: Any,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: object)
    } catch {
        XCTFail("Unable to encode test JSON: \(error)", file: file, line: line)
        return Data()
    }
}

final class URLRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

extension URLRequest {
    func decodedJSONBody<T>(
        as _: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        let body = try XCTUnwrap(httpBody, "Expected a JSON request body", file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(
            object as? T,
            "Expected JSON body of type \(T.self)",
            file: file,
            line: line
        )
    }
}
