// Run from the repository root in a logged-in macOS desktop session:
// xcrun swiftc -parse-as-library OpenYoink/Settings/SettingsScroll.swift Scripts/verify-settings-scroll.swift -o /tmp/openyoink-settings-scroll
// /tmp/openyoink-settings-scroll
// Briefly opens an owned test window; no OpenYoink preferences or shelf data are read.
import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class EnvProbe {
    var count = 2
    var text = "Short text"
}

struct EnvContent: View {
    @Environment(EnvProbe.self) private var model
    @Environment(\.locale) private var locale
    var body: some View {
        let _ = print("ENV_READ count=\(model.count) locale=\(locale.identifier)")
        Section("Environment check") {
            Text(model.text).fixedSize(horizontal: false, vertical: true)
            ForEach(0..<model.count, id: \.self) { index in
                LabeledContent("Row \(index)", value: "Value \(index)")
            }
        }
    }
}

@MainActor func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@main struct IntegrationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = EnvProbe()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 540, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Owned SettingsScroll Integration Probe"
        window.contentView = NSHostingView(rootView: SettingsForm { EnvContent() }
            .environment(model).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderFront(nil)
        var initialHeight: CGFloat = 0
        var fullWidthHeight: CGFloat = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL \(message)"); fflush(stdout); exit(1) }
            checks += 1
            print("PASS \(message)")
        }
        func scroll() -> SettingsNativeScrollView {
            window.contentView!.layoutSubtreeIfNeeded()
            let scrolls = descendants(window.contentView!).compactMap { $0 as? NSScrollView }
            check(scrolls.count == 1, "one native scroll, no nested SwiftUI HostingScrollView")
            guard let scroll = scrolls[0] as? SettingsNativeScrollView else { fatalError("Wrong scroll class") }
            return scroll
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let native = scroll()
            check(native.contentView.bounds.origin == .zero, "starts at top")
            initialHeight = native.hostingView.frame.height
            print("MEASURE initial=\(native.hostingView.frame)")
            model.count = 40
            model.text = String(repeating: "A long explanatory sentence that should wrap within the viewport. ", count: 12)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let native = scroll()
            fullWidthHeight = native.hostingView.frame.height
            print("MEASURE expanded=\(native.hostingView.frame)")
            check(fullWidthHeight > initialHeight + 200, "observable environment update changes natural document height")
            check(fullWidthHeight > native.contentSize.height, "long content overflows vertically")
            var proposed = native.contentView.bounds
            proposed.origin.y = 100000
            native.contentView.scroll(to: native.contentView.constrainBoundsRect(proposed).origin)
            native.reflectScrolledClipView(native.contentView)
            check(native.contentView.bounds.origin.y > 100, "scrolls to bottom")
            native.contentView.scroll(to: .zero)
            native.reflectScrolledClipView(native.contentView)
            check(native.contentView.bounds.origin == .zero, "scrolls back to top")
            window.setContentSize(NSSize(width: 340, height: 340))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let native = scroll()
            print("MEASURE narrow=\(native.hostingView.frame)")
            check(abs(native.hostingView.frame.width - native.contentSize.width) < 1, "document follows viewport width")
            check(native.hostingView.frame.height > fullWidthHeight, "text reflows into taller document on resize")
            model.count = 1
            model.text = "Short again"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let native = scroll()
            print("MEASURE contracted=\(native.hostingView.frame)")
            check(native.hostingView.frame.height < fullWidthHeight, "document shrinks after content update")
            check(native.contentView.bounds.origin == .zero, "short content remains top aligned")
            print("RESULT checks=\(checks) passed")
            window.close()
            fflush(stdout)
            exit(0)
        }
        app.run()
    }
}
