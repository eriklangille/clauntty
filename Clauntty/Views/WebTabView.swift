import SwiftUI
import WebKit

/// View displaying a forwarded web port
struct WebTabView: View {
    @ObservedObject var webTab: WebTab
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            WebToolbar(
                webTab: webTab,
                onBack: { webView?.goBack() },
                onForward: { webView?.goForward() },
                onRefresh: { webView?.reload() }
            )

            // Content
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
    }
}

// MARK: - Web Toolbar

struct WebToolbar: View {
    @ObservedObject var webTab: WebTab
    var onBack: () -> Void
    var onForward: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(webTab.state != .connected)

            // Forward button
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(webTab.state != .connected)

            // URL display
            HStack(spacing: 6) {
                if webTab.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                }

                Text("localhost:\(String(webTab.localPort))")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))
            .cornerRadius(8)

            // Refresh button
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(webTab.state != .connected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Load the URL
        let request = URLRequest(url: url)
        webView.load(request)

        // Store reference
        DispatchQueue.main.async {
            self.webViewBinding = webView
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

        init(webTab: WebTab) {
            self.webTab = webTab
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
            let connection = SSHConnection(
                host: "localhost",
                port: 22,
                username: "test",
                authMethod: .password,
                connectionId: UUID()
            )
            _webTab = StateObject(wrappedValue: WebTab(remotePort: port, sshConnection: connection))
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
