import AppKit
import SwiftUI

/// Static forms keep sections and native controls without creating SwiftUI's
/// HostingScrollView. A single AppKit scroll view owns the viewport instead.
struct SettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        SettingsScroll {
            Form { content }
                .formStyle(SettingsStaticFormStyle())
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ColumnsFormStyle shares a minimum label column across the whole form. Long
/// standalone explanations can then exceed the viewport. A vertical layout
/// lets each native labeled control size its own row and wraps explanatory text.
private struct SettingsStaticFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsScroll<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> SettingsNativeScrollView {
        SettingsNativeScrollView(content: hostedContent(environment: context.environment))
    }

    func updateNSView(_ scrollView: SettingsNativeScrollView, context: Context) {
        scrollView.setContent(hostedContent(environment: context.environment))
    }

    private func hostedContent(environment: EnvironmentValues) -> AnyView {
        // A new NSHostingView is a new SwiftUI root. Forward all settings
        // dependencies, locale, accessibility and presentation environment.
        AnyView(content.environment(\.self, environment))
    }
}

struct SettingsScrollDocument: View {
    let content: AnyView
    let viewportWidth: CGFloat?

    var body: some View {
        content.frame(width: viewportWidth, alignment: .topLeading)
    }
}

@MainActor
final class SettingsNativeScrollView: NSScrollView {
    let hostingView: NSHostingView<SettingsScrollDocument>
    private var content: AnyView
    private var documentWidth: CGFloat?

    init(content: AnyView) {
        self.content = content
        hostingView = NSHostingView(rootView: SettingsScrollDocument(content: content, viewportWidth: nil))
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none

        // The document keeps its natural height, while its width follows the
        // viewport. Text therefore wraps on resize without horizontal scrolling.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])
    }

    func setContent(_ content: AnyView) {
        self.content = content
        updateDocument()
    }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        guard width > 0, documentWidth.map({ abs($0 - width) >= 0.5 }) ?? true else { return }
        documentWidth = width
        updateDocument()
    }

    private func updateDocument() {
        // Give SwiftUI the actual width as a layout proposal as well as an
        // AppKit constraint. Its intrinsic height must reflow when resized.
        hostingView.rootView = SettingsScrollDocument(content: content, viewportWidth: documentWidth)
        hostingView.invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { fatalError("Created programmatically") }
}
