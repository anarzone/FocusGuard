import Foundation

enum SessionStatus: Int, Codable {
    case active = 0
    case completed = 1
    case abandoned = 2
}
