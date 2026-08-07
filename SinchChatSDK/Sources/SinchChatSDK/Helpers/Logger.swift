import Foundation

public struct Logger {

    public nonisolated(unsafe) static var environment: Environment = .production

    static func verbose(_ items: Any, file: String = #file, _ function: String = #function, line: Int = #line) {
        custom(level: .verbose, items, file: file, function, line)
    }

    static func debug(_ items: Any, file: String = #file, _ function: String = #function, line: Int = #line) {
        custom(level: .debug, items, file: file, function, line)
    }

    static func info(_ items: Any, file: String = #file, _ function: String = #function, line: Int = #line) {
        custom(level: .info, items, file: file, function, line)
    }

    static func warning(_ items: Any, file: String = #file, _ function: String = #function, line: Int = #line) {
        custom(level: .warning, items, file: file, function, line)
    }

    static func error(_ items: Any, file: String = #file, _ function: String = #function, line: Int = #line) {
        custom(level: .error, items, file: file, function, line)
    }

    static func custom(level: Level, _ items: Any, file: String, _ function: String, _ line: Int) {
        guard shouldShowLog(level) else {
            return
        }
        print("\(level.icon) \(level.name) \(getFileNameFromPath(file)).\(function):\(line)", items, separator: " - ")
    }

    private static func shouldShowLog(_ level: Level) -> Bool {
        if environment == .production {
            if level == .debug || level == .verbose {
                return false
            }
        }
        return true
    }

    private static func getFileNameFromPath(_ line: String) -> String {
        line.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
    }

    enum Level {
        case verbose
        case debug
        case info
        case warning
        case error
    }

    public enum Environment {
        case production
        case development
    }
}

extension Logger.Level {

    var name: String {
        switch self {
        case .verbose:
            return "VERBOSE"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        }
    }

    var icon: String {
        switch self {
        case .verbose: return "🟡"
        case .debug: return "🟢"
        case .info: return "🔵"
        case .warning: return "🟠"
        case .error: return "🔴"
        }
    }
}
