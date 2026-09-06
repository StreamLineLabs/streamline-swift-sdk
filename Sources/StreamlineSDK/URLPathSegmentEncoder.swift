import Foundation

enum URLPathSegmentEncoder {
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )

    static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            if unreserved.contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
