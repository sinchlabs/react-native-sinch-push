import Foundation

public struct AvatarPosition: Equatable {
    
    /// An enum representing the horizontal alignment of an `AvatarView`.
    public enum Horizontal {
        
        /// Positions the `AvatarView` on the side closest to the cell's leading edge.
        case left
        
        /// Positions the `AvatarView` on the side closest to the cell's trailing edge.
        case right
        
        case noAvatar

        case notSet
    }
       
    // The horizontal position
    public var horizontal: Horizontal
    
    // MARK: - Initializers
    
    public init(horizontal: Horizontal) {
        self.horizontal = horizontal
     
    }
}

// MARK: - Equatable Conformance

public extension AvatarPosition {

    static func == (lhs: AvatarPosition, rhs: AvatarPosition) -> Bool {
        return lhs.horizontal == rhs.horizontal
    }
}
