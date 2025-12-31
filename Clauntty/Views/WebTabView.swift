import SwiftUI
import WebKit

/// View displaying a forwarded web port
struct WebTabView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab
    @State private var webView: WKWebView?

    /// Whether this web tab is currently active
    private var isActive: Bool {
        sessionManager.activeTab == .web(webTab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content (toolbar removed - now in expanded tab bar)
            switch webTab.state {
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Connecting to port \(webTab.remotePort.port)...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

            case .connected:
                WebViewContainer(
                    url: webTab.localURL,
                    webTab: webTab,
                    webViewBinding: $webView
                )

            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Connection Error")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            try? await webTab.startForwarding()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

            case .closed:
                Text("Tab closed")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .onAppear {
            // Dismiss terminal keyboard when web tab appears
            if isActive {
                dismissKeyboard()
            }
        }
        .onChange(of: isActive) { wasActive, nowActive in
            // Dismiss keyboard when web tab becomes active (switching from terminal)
            if nowActive {
                dismissKeyboard()
            }
            // Capture screenshot when switching away from this tab
            if wasActive && !nowActive {
                captureScreenshot()
            }
        }
    }

    /// Capture screenshot of the web view for tab selector
    private func captureScreenshot() {
        guard let webView = webView else { return }

        Task {
            let config = WKSnapshotConfiguration()
            if let screenshot = try? await webView.takeSnapshot(configuration: config) {
                webTab.cachedScreenshot = screenshot
            }
        }
    }

    /// Dismiss keyboard
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - WKWebView Container

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var webTab: WebTab
    @Binding var webViewBinding: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Add pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // Observe URL changes via KVO
        context.coordinator.observeURL(webView: webView)

        // Load the URL
        let request = URLRequest(url: url)
        webView.load(request)

        // Store references
        DispatchQueue.main.async {
            self.webViewBinding = webView
            self.webTab.webView = webView
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if URL changed significantly
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(webTab: webTab)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let webTab: WebTab
        private var urlObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private weak var webView: WKWebView?

        init(webTab: WebTab) {
            self.webTab = webTab
        }

        @objc func handleRefresh(_ refreshControl: UIRefreshControl) {
            webView?.reload()
            // End refreshing after a short delay (will also end when page finishes loading)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                refreshControl.endRefreshing()
            }
        }

        func observeURL(webView: WKWebView) {
            self.webView = webView
            // Observe URL changes (catches SPA navigation, hash changes, etc.)
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.currentURL = webView.url
                }
            }

            // Observe title changes
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.pageTitle = webView.title
                }
            }

            // Observe back/forward navigation state
            canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.canGoBack = webView.canGoBack
                }
            }

            canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.canGoForward = webView.canGoForward
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                webTab.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                webTab.isLoading = false
                webTab.pageTitle = webView.title
                webTab.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                webTab.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                webTab.isLoading = false
                // Don't show error for cancelled requests
                if (error as NSError).code != NSURLErrorCancelled {
                    webTab.state = .error(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @StateObject var webTab: WebTab

        init() {
            let port = RemotePort(id: 3000, port: 3000, process: "node", address: "127.0.0.1")
            let config = SavedConnection(
                name: "Test",
                host: "localhost",
                port: 22,
                username: "test",
                authMethod: .password
            )
            let connection = SSHConnection(
                host: "localhost",
                port: 22,
                username: "test",
                authMethod: .password,
                connectionId: config.id
            )
            _webTab = StateObject(wrappedValue: WebTab(remotePort: port, connectionConfig: config, sshConnection: connection))
        }

        var body: some View {
            WebTabView(webTab: webTab)
                .onAppear {
                    webTab.state = .connected
                }
        }
    }

    return PreviewWrapper()
}
