import SwiftUI
import WebKit

/// A port on the host (`clauntty tab 8000`), forwarded over SSH and shown in a web view,
/// with back, forward, reload and its address above it. That bar is the top of the
/// window, as a pane's title bar is.
struct WebPane: View {
    @EnvironmentObject private var window: WindowState
    @ObservedObject var webTab: WebTab

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            switch webTab.state {
            case .connecting:
                message("Forwarding port \(String(webTab.remotePort.port))…")
            case .connected:
                WebViewContainer(webTab: webTab)
            case .error(let error):
                VStack(spacing: 12) {
                    message(error)
                    Button("Retry") { Task { try? await webTab.startForwarding() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .closed:
                message("Reconnecting…")
            }
        }
        // Here, where it's observed: it changes as pages load
        .navigationTitle(webTab.title)
    }

    private var bar: some View {
        HStack(spacing: 14) {
            if window.sidebar == .detailOnly {
                SidebarToggle()
                    .padding(.leading, SidebarToggle.leading - 14)
            }
            Button { webTab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!webTab.canGoBack)
            Button { webTab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!webTab.canGoForward)
            Button { webTab.reload() } label: { Image(systemName: "arrow.clockwise") }
            Text("localhost\(webTab.urlDisplayString)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if webTab.localPort != webTab.remotePort.port {
                Text("Port \(String(webTab.remotePort.port)) on the host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: PaneHeader.height)
        .background {
            ZStack {
                Rectangle().fill(.bar)
                WindowDragArea {}
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The page, kept on its WebTab so the bar's buttons reach it. Mirrors the phone's.
private struct WebViewContainer: NSViewRepresentable {
    @ObservedObject var webTab: WebTab

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        // Back where it was, if it was reopened
        let path = webTab.lastPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        webView.load(URLRequest(url: URL(string: path, relativeTo: webTab.localURL) ?? webTab.localURL))
        DispatchQueue.main.async { webTab.webView = webView }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(webTab: webTab) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let webTab: WebTab
        private var observations: [NSKeyValueObservation] = []

        init(webTab: WebTab) {
            self.webTab = webTab
        }

        func observe(_ webView: WKWebView) {
            let webTab = webTab
            observations = [
                webView.observe(\.url) { view, _ in
                    Task { @MainActor in
                        webTab.currentURL = view.url
                        webTab.updateLastPath()
                    }
                },
                webView.observe(\.title) { view, _ in Task { @MainActor in webTab.pageTitle = view.title } },
                webView.observe(\.canGoBack) { view, _ in Task { @MainActor in webTab.canGoBack = view.canGoBack } },
                webView.observe(\.canGoForward) { view, _ in Task { @MainActor in webTab.canGoForward = view.canGoForward } },
                webView.observe(\.isLoading) { view, _ in Task { @MainActor in webTab.isLoading = view.isLoading } },
            ]
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            Task { @MainActor in webTab.state = .error(error.localizedDescription) }
        }
    }
}
