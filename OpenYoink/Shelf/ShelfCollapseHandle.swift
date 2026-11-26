import SwiftUI

private struct ShelfHideActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    var shelfHideAction: (@MainActor () -> Void)? {
        get { self[ShelfHideActionEnvironmentKey.self] }
        set { self[ShelfHideActionEnvironmentKey.self] = newValue }
    }
}
