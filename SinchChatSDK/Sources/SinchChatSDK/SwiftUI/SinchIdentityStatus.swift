import Foundation

/// Represents the current identity lifecycle state for SwiftUI bindings.
public enum SinchIdentityStatus: Equatable, Sendable {
    case notSet
    case setting
    case set
    case removing
    case failed
}
