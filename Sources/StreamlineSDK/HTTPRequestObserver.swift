import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

typealias HTTPRequestObserver = @Sendable (URLRequest) -> Void
