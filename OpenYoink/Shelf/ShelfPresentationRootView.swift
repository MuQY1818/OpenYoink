import AppKit
import SwiftUI

struct ShelfPresentationRootView: View {
    let presentationStyle: ShelfPresentationStyle
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if presentationStyle == .island {
                IslandRootView(
                    onPerformRecovery: onPerformRecovery,
                    onOpenSettings: onOpenSettings
                )
            } else {
                ShelfView()
            }
        }
    }
}
