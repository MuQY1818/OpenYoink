import OSLog

enum Log {
    static func make(category: String) -> Logger {
        Logger(subsystem: "com.weijue.OpenYoink", category: category)
    }
}
