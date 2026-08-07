import Foundation

public enum Owner: Codable, Sendable {
    case outgoing
    case incoming(Agent?)
    case system
}
