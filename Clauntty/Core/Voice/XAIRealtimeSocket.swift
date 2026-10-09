import Foundation
import os.log

/// WebSocket to xAI's realtime voice API. Events are JSON objects in both directions,
/// in the OpenAI Realtime style (same events switchboard uses). Callbacks run on main.
final class XAIRealtimeSocket: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    /// Called once, with a reason the user can read
    var onClose: ((String) -> Void)?

    private let request: URLRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(apiKey: String, model: String) {
        var request = URLRequest(url: URL(string: "wss://api.x.ai/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        self.request = request
        super.init()
    }

    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        // Audio deltas are small, but leave room for long transcripts
        task.maximumMessageSize = 4 * 1024 * 1024
        self.session = session
        self.task = task
        task.resume()
    }

    /// Safe to call from any thread
    func send(_ event: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                Logger.clauntty.verbose("XAIRealtimeSocket: send failed: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    // MARK: - Receiving

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = text.data(using: .utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    if let data, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onEvent?(event)
                    }
                    self.receive()
                case .failure(let error):
                    self.finish(reason: self.describe(error))
                }
            }
        }
    }

    private func finish(reason: String) {
        guard !closed else { return }
        close()
        onClose?(reason)
    }

    private func describe(_ error: Error) -> String {
        if let response = task?.response as? HTTPURLResponse ?? lastResponse, response.statusCode >= 400 {
            switch response.statusCode {
            case 400, 401, 403: return "xAI refused the connection (HTTP \(response.statusCode)). Check the API key in Settings."
            case 429: return "xAI rate limit or out of credits (HTTP 429)"
            default: return "xAI refused the connection (HTTP \(response.statusCode))"
            }
        }
        return "Connection lost: \(error.localizedDescription)"
    }

    /// The handshake response, kept for describing a failed upgrade
    private var lastResponse: HTTPURLResponse?

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !closed else { return }
        voiceTrace("socket open")
        onOpen?()
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        voiceTrace("socket closed by server, code=\(closeCode.rawValue) \(text)")
        finish(reason: text.isEmpty ? "xAI closed the connection (code \(closeCode.rawValue))" : "xAI closed the connection: \(text)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastResponse = task.response as? HTTPURLResponse
        guard let error else { return }
        voiceTrace("socket failed: \(error.localizedDescription)")
        finish(reason: describe(error))
    }
}
