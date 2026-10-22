import SwiftUI
import WebKit

/// A port on the host (`clauntty tab 8000`), forwarded over SSH and shown in a web view,
/// with back, forward, reload and its address (to edit) above it. That bar is the top of the
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
                    .padding(.leading, window.toggleLeading - 14)
            }
            Button { webTab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!webTab.canGoBack)
            Button { webTab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!webTab.canGoForward)
            Button { webTab.reload() } label: { Image(systemName: "arrow.clockwise") }
            AddressField(webTab: webTab)
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
            if webTab.localPort != webTab.remotePort.port {
                Text("Port \(String(webTab.remotePort.port)) on the host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: window.titleBarHeight)
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

/// The page's address, to edit: Return goes there, Escape puts it back. A path, or this
/// page's own `localhost:PORT`, loads here; another port on localhost opens that port as
/// its own page on the host (as `clauntty tab` does); anything else loads as it is.
private struct AddressField: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("localhost:\(String(webTab.localPort))/", text: $text)
            .textFieldStyle(.plain)
            .font(.callout.monospaced())
            .foregroundStyle(editing ? .primary : .secondary)
            .focused($editing)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.primary.opacity(editing ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 6))
            .onSubmit { go(text); editing = false }
            .onExitCommand { text = shown; editing = false }
            // The page's address as it changes, unless you're typing over it
            .onChange(of: webTab.currentURL, initial: true) { _, _ in if !editing { text = shown } }
            .onChange(of: editing) { _, now in if !now { text = shown } }
    }

    private var shown: String { "localhost\(webTab.urlDisplayString)" }

    private func go(_ input: String) {
        var address = input.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        let scheme = address.range(of: "://").map { String(address[..<$0.lowerBound]) }
        if let range = address.range(of: "://") { address = String(address[range.upperBound...]) }
        // localhost or 127.0.0.1, with a port or not: this host's ports
        for local in ["localhost", "127.0.0.1"] where address == local || address.hasPrefix(local + ":") || address.hasPrefix(local + "/") {
            address = String(address.dropFirst(local.count))
            break
        }
        if address.hasPrefix(":") {
            let digits = address.dropFirst().prefix { $0.isNumber }
            let path = String(address.dropFirst(1 + digits.count))
            guard let port = Int(digits) else { return }
            if port == webTab.localPort || port == webTab.remotePort.port {
                webTab.navigate(to: path.isEmpty ? "/" : path)
            } else {
                open(port, path: path)
            }
        } else if address.hasPrefix("/") || !address.contains(".") {
            webTab.navigate(to: address)
        } else if let url = URL(string: "\(scheme ?? "https")://\(address)") {
            webTab.webView?.load(URLRequest(url: url))
        }
    }

    /// Another port on the host, as its own page in the same workspace, at `path`
    private func open(_ port: Int, path: String) {
        let remote = RemotePort(id: port, port: port, process: nil, address: "127.0.0.1")
        let workspace = webTab.workspaceId
        Task {
            guard let page = try? await sessionManager.openPortInTab(remote, config: webTab.connectionConfig,
                                                                     workspace: workspace) else { return }
            guard !path.isEmpty, path != "/" else { return }
            // Loaded already (an open page), or loads it when it's first shown
            page.lastPath = path
            if page.webView != nil { page.navigate(to: path) }
        }
    }
}

/// Each page's web view, kept while the page is open: shown again after a terminal (or
/// another page), it's as it was, not loaded again
@MainActor
enum WebViews {
    fileprivate static var kept: [UUID: (view: WKWebView, coordinator: WebViewContainer.Coordinator)] = [:]

    static func prune(keeping ids: Set<UUID>) {
        for id in kept.keys where !ids.contains(id) {
            kept[id]?.view.removeFromSuperview()
            kept[id] = nil
        }
    }
}

/// The page, kept on its WebTab so the bar's buttons reach it. Mirrors the phone's.
private struct WebViewContainer: NSViewRepresentable {
    @ObservedObject var webTab: WebTab

    func makeNSView(context: Context) -> WKWebView {
        if let kept = WebViews.kept[webTab.id] {
            // Forwarded again since (a reconnect) on another local port: the page there
            if kept.view.url?.port != webTab.localPort { load(kept.view) }
            return kept.view
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        load(webView)
        WebViews.kept[webTab.id] = (webView, context.coordinator)
        DispatchQueue.main.async { webTab.webView = webView }
        return webView
    }

    /// Back where it was, if it was reopened
    private func load(_ webView: WKWebView) {
        let path = webTab.lastPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        webView.load(URLRequest(url: URL(string: path, relativeTo: webTab.localURL) ?? webTab.localURL))
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    // The kept view's, which observes it still
    func makeCoordinator() -> Coordinator { WebViews.kept[webTab.id]?.coordinator ?? Coordinator(webTab: webTab) }

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
