// Run from the repository root in a logged-in macOS desktop session:
// xcrun swiftc -parse-as-library OpenYoink/Settings/SettingsWindowVisibility.swift Scripts/verify-settings-window-lifecycle.swift -o /tmp/openyoink-settings-lifecycle
// /tmp/openyoink-settings-lifecycle
// Briefly opens an owned test window; no OpenYoink preferences or shelf data are read.
import AppKit
import SwiftUI

struct SettingsProbeRoot: View {
    let visibility: SettingsWindowVisibility
    var body: some View {
        ZStack {
            if visibility.displaysContent {
                ScrollView { VStack { ForEach(0..<40) { Text("Setting \($0)") } } }
            } else { Color.clear }
        }
        .frame(minWidth:300,minHeight:240)
        .background { SettingsWindowVisibilityReader(visibility:visibility).frame(width:0,height:0) }
    }
}

@main struct VerifySettingsVisibility {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps:true)
        let visibility=SettingsWindowVisibility()
        let host=NSHostingController(rootView:SettingsProbeRoot(visibility:visibility))
        let window=NSWindow(contentViewController:host)
        window.isReleasedWhenClosed=false
        window.setContentSize(NSSize(width:320,height:260));window.center()
        defer { window.close() }
        func wait() async { try? await Task.sleep(for: .milliseconds(200)) }
        func count(_ view:NSView)->Int { (view is NSScrollView ? 1:0)+view.subviews.reduce(0){$0+count($1)} }
        func check(_ pass:Bool,_ message:String) { if !pass { print("FAIL: \(message) visibility=\(visibility.displaysContent) scrolls=\(count(host.view))");exit(1) };print("PASS: \(message)") }
        Task { @MainActor in
        window.makeKeyAndOrderFront(nil);await wait()
        check(visibility.displaysContent && count(host.view)>0,"opening mounts scrollable settings")
        let frame=window.frame
        window.close();await wait()
        check(!visibility.displaysContent && count(host.view)==0,"closing cached window removes native scroll views")
        window.makeKeyAndOrderFront(nil);await wait()
        check(visibility.displaysContent && count(host.view)>0,"reopening restores content")
        check(window.frame==frame,"window frame survives close and reopen")
        window.close();window.makeKeyAndOrderFront(nil);await wait()
        check(visibility.displaysContent && count(host.view)>0,"rapid close/reopen invalidates queued hiding")
        window.orderOut(nil);await wait()
        check(!visibility.displaysContent && count(host.view)==0,"ordering out also suspends content")
        window.makeKeyAndOrderFront(nil);await wait()
        check(visibility.displaysContent,"ordering back in restores content")
        window.close()
        exit(0)
        }
        app.run()
    }
}
