import XCTest
@testable import StreamlineSDK

final class TelemetryTests: XCTestCase {

    // MARK: - TelemetrySpan

    func testSpanSetAttribute() {
        let span = TelemetrySpan(name: "test", topic: "events", operation: "produce")
        span.setAttribute("key1", value: "value1")
        span.setAttribute("key2", value: "value2")
        XCTAssertEqual(span.attributes["key1"], "value1")
        XCTAssertEqual(span.attributes["key2"], "value2")
    }

    func testSpanSetError() {
        let span = TelemetrySpan(name: "test", topic: "events", operation: "produce")
        XCTAssertFalse(span.hasError)
        span.setError(StreamlineError.timeout)
        XCTAssertTrue(span.hasError)
    }

    func testSpanElapsed() {
        let span = TelemetrySpan(name: "test", topic: "", operation: "")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(span.elapsed, 0.04)
    }

    // MARK: - NoOpTelemetry

    func testNoOpTelemetryStartsSpan() {
        let telemetry = NoOpTelemetry()
        let span = telemetry.startSpan(topic: "events", operation: "produce")
        XCTAssertEqual(span.topic, "events")
        XCTAssertEqual(span.operation, "produce")
        span.setAttribute("key", value: "val")
        telemetry.endSpan(span)
    }

    // MARK: - ConsoleTelemetry

    func testConsoleTelemetryLifecycle() {
        let telemetry = ConsoleTelemetry()
        let span = telemetry.startSpan(topic: "orders", operation: "consume")
        XCTAssertEqual(span.topic, "orders")
        XCTAssertEqual(span.operation, "consume")
        telemetry.endSpan(span)
    }

    func testConsoleTelemetryErrorSpan() {
        let telemetry = ConsoleTelemetry()
        let span = telemetry.startSpan(topic: "test", operation: "produce")
        span.setError(StreamlineError.connectionFailed("test"))
        telemetry.endSpan(span, error: "test error")
    }

    // MARK: - TraceContext

    func testGenerateTraceparent() {
        let tp = TraceContext.generateTraceparent()
        let parts = tp.split(separator: "-")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "00")
        XCTAssertEqual(parts[3], "01")
        XCTAssertEqual(parts[1].count, 32)
        XCTAssertEqual(parts[2].count, 16)
    }

    func testParseTraceparent() {
        let tp = "00-abcdef0123456789abcdef0123456789-0123456789abcdef-01"
        let result = TraceContext.parseTraceparent(tp)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.version, "00")
        XCTAssertEqual(result?.traceId, "abcdef0123456789abcdef0123456789")
        XCTAssertEqual(result?.spanId, "0123456789abcdef")
        XCTAssertEqual(result?.traceFlags, "01")
    }

    func testParseInvalidTraceparent() {
        XCTAssertNil(TraceContext.parseTraceparent("invalid"))
        XCTAssertNil(TraceContext.parseTraceparent("01-abc-def-01"))
    }

    // MARK: - Protocol Extension

    func testTelemetryProtocolStartSpanWithAttributes() {
        let telemetry = ConsoleTelemetry()
        let span = telemetry.startSpan("test.op", attributes: [
            "messaging.system": "streamline",
            "messaging.destination.name": "my-topic",
            "messaging.operation": "produce",
        ])
        XCTAssertEqual(span.topic, "my-topic")
        XCTAssertEqual(span.operation, "produce")
        XCTAssertEqual(span.attributes["messaging.system"], "streamline")
        telemetry.endSpan(span)
    }

    func testTelemetryProtocolTraceparent() {
        let telemetry: Telemetry = NoOpTelemetry()
        let tp = telemetry.traceparent()
        XCTAssertNotNil(tp)
    }

    // MARK: - TelemetryAttributes

    func testProduceAttributes() {
        let attrs = TelemetryAttributes.produceAttributes(topic: "events", key: "user-123")
        XCTAssertEqual(attrs["messaging.system"], "streamline")
        XCTAssertEqual(attrs["messaging.destination.name"], "events")
        XCTAssertEqual(attrs["messaging.operation"], "produce")
        XCTAssertEqual(attrs["messaging.message.key"], "user-123")
    }

    func testProduceAttributesWithoutKey() {
        let attrs = TelemetryAttributes.produceAttributes(topic: "logs")
        XCTAssertNil(attrs["messaging.message.key"])
    }

    func testConsumeAttributes() {
        let attrs = TelemetryAttributes.consumeAttributes(topic: "orders", groupId: "svc")
        XCTAssertEqual(attrs["messaging.consumer.group.name"], "svc")
        XCTAssertEqual(attrs["messaging.operation"], "consume")
    }

    func testProcessAttributes() {
        let attrs = TelemetryAttributes.processAttributes(topic: "events", offset: 42, partition: 3)
        XCTAssertEqual(attrs["messaging.message.offset"], "42")
        XCTAssertEqual(attrs["messaging.destination.partition.id"], "3")
        XCTAssertEqual(attrs["messaging.operation"], "process")
    }

    // MARK: - TracedClient

    func testTracedClientState() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        let traced = TracedClient(client: client, telemetry: NoOpTelemetry())
        XCTAssertEqual(traced.state, .disconnected)
    }

    func testTracedClientTransactionsFailClosed() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        let traced = TracedClient(client: client, telemetry: ConsoleTelemetry())
        XCTAssertThrowsError(try traced.beginTransaction())
        XCTAssertThrowsError(try traced.commitTransaction())
        XCTAssertThrowsError(try traced.abortTransaction())
    }

    func testTracedClientBeginTransactionReportsUnsupported() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        let traced = TracedClient(client: client, telemetry: NoOpTelemetry())
        XCTAssertThrowsError(try traced.beginTransaction()) { error in
            guard let streamlineError = error as? StreamlineError,
                  case .transaction(let message) = streamlineError
            else {
                return XCTFail("Expected transaction error")
            }
            XCTAssertTrue(message.contains("unsupported"))
        }
    }

    // MARK: - TracedAdminClient

    func testTracedAdminClientCreation() {
        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!)
        let _ = TracedAdminClient(admin: admin, telemetry: NoOpTelemetry())
    }

    // MARK: - Thread Safety

    func testSpanConcurrentAttributeAccess() {
        let span = TelemetrySpan(name: "concurrent", topic: "t", operation: "op")
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 100

        for i in 0..<100 {
            DispatchQueue.global().async {
                span.setAttribute("key-\(i)", value: "val-\(i)")
                _ = span.attributes
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(span.attributes.count, 100)
    }
}
