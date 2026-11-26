import Foundation

/// Shared locations inside the app's sandbox container.
enum AppPaths {
    /// True when the app was launched by the UI-test runner.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["OPENYOINK_UI_TESTING"] == "1"
    }

    /// `Application Support/OpenYoink` inside the sandbox container.
    ///
    /// UI automation launches the real app process, so all file mutations are
    /// redirected to a fixed temporary directory that is wiped on each launch.
    static func applicationSupport() -> URL {
        if isUITesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkUITests", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenYoink", isDirectory: true)
    }

    /// App-owned copies of dropped content (promises, images, managed moves).
    static func materialized(in support: URL = applicationSupport()) -> URL {
        support.appendingPathComponent("Materialized", isDirectory: true)
    }
}
