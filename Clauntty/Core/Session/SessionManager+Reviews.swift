import Foundation
import os.log

/// Reviews from `clauntty review` (Review.swift): downloaded when rtach says
/// one was made or the app finds one waiting as it connects, shown one at a time, and
/// answered by handing the user's comments to the command waiting on the host, or by
/// typing them into the agent's pane when that command is gone.
extension SessionManager {
    /// Bundles bigger than this aren't shown
    static let maxReviewBytes = 64 * 1024 * 1024

    func handleReviewRequest(from session: Session, id: String) {
        guard reviewIdsSeen.insert(id).inserted else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                // Relative: commands start in the home directory, and downloadFile quotes
                // the path, so `~` wouldn't expand
                let data = try await session.downloadFile(".clauntty/reviews/\(id).json", maxBytes: Self.maxReviewBytes)
                // Gone meanwhile (answered elsewhere, or the command was stopped)
                guard !data.isEmpty else { return }
                let host = self.hostName(of: session)
                let sessionId = session.id
                // Decoding and highlighting every file takes a moment for a big change
                let review = try await Task.detached(priority: .userInitiated) {
                    Review(bundle: try ReviewBundle.decode(data), sessionId: sessionId, host: host)
                }.value
                Logger.clauntty.debugOnly("SessionManager: review \(id) with \(review.files.count) file(s)")
                self.reviews.append(review)
            } catch {
                Logger.clauntty.warning("SessionManager: review \(id) failed to load: \(error.localizedDescription)")
                // Retried on the next connect, unless it can't ever work
                if (error as? SessionError) != .fileTooLarge, !(error is DecodingError) {
                    self.reviewIdsSeen.remove(id)
                }
            }
        }
    }

    /// Show reviews left waiting on the session's host: made while the app was away
    func checkReviews(for session: Session) {
        Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            do {
                let ids = try await session.listReviews()
                for id in ids { self?.handleReviewRequest(from: session, id: id) }
            } catch {
                Logger.clauntty.warning("SessionManager: review check failed: \(error.localizedDescription)")
            }
        }
    }

    /// Send the user's comments (none: it looks good). Returns what to tell the user
    /// when it went somewhere other than the waiting command. The review stays in
    /// `reviews` for the caller to close once the user has seen that.
    func sendReview(_ review: Review, note: String, comments: [ReviewUserComment]) async throws -> String? {
        let report = ReviewReply.report(title: review.title, note: note, comments: comments)
        let session = try reviewSession(review)
        let result = try await session.sendReviewReply(id: review.id, report: report)
        Logger.clauntty.debugOnly("SessionManager: review \(review.id) reply \(result.rawValue)")
        var message: String?
        switch result {
        case .delivered:
            break
        case .answered:
            message = "This review was already closed."
        case .gone:
            // Nobody waiting (the agent stopped the command): the agent's pane gets it
            try await typeIntoPane(review.pane, text: report, on: session)
            message = "The review command had stopped, so the comments were typed into the agent's pane."
        }
        return message
    }

    /// Stop showing a review, leaving it on the host (it shows again next launch)
    func closeReview(_ review: Review) {
        reviews.removeAll { $0.id == review.id }
    }

    /// Close a review without answering it: the waiting command says so and exits
    func dismissReview(_ review: Review) {
        reviews.removeAll { $0.id == review.id }
        guard let session = try? reviewSession(review) else { return }
        Task { await session.dismissReview(id: review.id) }
    }

    /// A connected session on the review's host: the one it came through, else another
    private func reviewSession(_ review: Review) throws -> Session {
        if let session = sessions.first(where: { $0.id == review.sessionId }), session.sshConnection != nil {
            return session
        }
        let host = sessions.first { $0.id == review.sessionId }?.connectionConfig.id
        if let other = sessions.first(where: { $0.connectionConfig.id == host && $0.sshConnection != nil }) {
            return other
        }
        throw SessionError.notConnected
    }

    /// Type text into a pane as a paste, then Return, as the voice agent sends a prompt
    private func typeIntoPane(_ pane: String, text: String, on host: Session) async throws {
        guard !pane.isEmpty,
              let target = sessions.first(where: { $0.rtachSessionId == pane && $0.connectionConfig.id == host.connectionConfig.id })
        else { throw SessionError.notConnected }
        if !target.hasAttachedChannel { try await reconnect(session: target) }
        // Bracketed, so Claude Code takes it as text; escapes dropped so it can't end the paste
        let paste = "\u{1B}[200~" + text.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~"
        target.sendData(Data(paste.utf8))
        try? await Task.sleep(for: .milliseconds(150))
        target.sendData(Data("\r".utf8))
    }

    private func hostName(of session: Session) -> String {
        session.connectionConfig.name.isEmpty ? session.connectionConfig.host : session.connectionConfig.name
    }
}
