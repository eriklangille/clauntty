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
                // A newer review from the same agent replaces the older one: it changed the
                // code and sent it again, and the old diff is out of date
                let older = self.reviews.filter { self.samePane($0, review) }
                if let newest = older.max(by: { Self.madeAt($0.id) < Self.madeAt($1.id) }),
                   Self.madeAt(newest.id) > Self.madeAt(review.id) {
                    // Came in late (two found on connect): the one already here is newer
                    self.replace(review)
                    return
                }
                older.forEach(self.replace)
                #if os(iOS)
                // The phone shows it now only if its pane is on screen; else it waits on its
                // window's tile for a tap, rather than covering what the user is doing (or
                // whenever they next come to that pane)
                if !self.isOnScreen(review), self.workspace(of: review) != nil {
                    self.hiddenReviews.insert(review.id)
                }
                #endif
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

    /// Look for waiting reviews on every connected host, once each
    func checkReviewsOnHosts() {
        var hosts: Set<UUID> = []
        for session in sessions where session.sshConnection != nil && session.rtachSessionId != nil {
            guard hosts.insert(session.connectionConfig.id).inserted else { continue }
            checkReviews(for: session)
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

    /// Done with a review: it was answered
    func closeReview(_ review: Review) {
        forget(review)
    }

    /// Close a review for now: it waits, unanswered, on the host too
    func hideReview(_ review: Review) {
        hiddenReviews.insert(review.id)
        if openedReview == review.id { openedReview = nil }
    }

    func showReview(_ id: String) {
        hiddenReviews.remove(id)
    }

    /// The review to show on the phone: one opened from its tile, else the oldest not
    /// closed for now. One that arrived while its pane wasn't on screen starts closed for
    /// now, waiting on its workspace's window (`reviews(in:)`).
    var shownReview: Review? {
        if let id = openedReview, let review = reviews.first(where: { $0.id == id }) { return review }
        return reviews.first { !hiddenReviews.contains($0.id) }
    }

    /// The phone's: a workspace's reviews, for its window's tile (those not shown)
    func reviews(in workspace: UUID) -> [Review] {
        let shown = shownReview?.id
        return reviews.filter { $0.id != shown && self.workspace(of: $0) == workspace }
    }

    /// Open a review from its window's tile
    func openReview(_ review: Review) {
        hiddenReviews.remove(review.id)
        openedReview = review.id
    }

    /// The pane that asked for the review is on screen
    private func isOnScreen(_ review: Review) -> Bool {
        let host = sessions.first { $0.id == review.sessionId }?.connectionConfig.id
        return sessions.contains { session in
            session.rtachSessionId == review.pane && (host == nil || session.connectionConfig.id == host)
                && (session.id == activeSessionId || shownTogether.contains(session.id))
        }
    }

    /// The workspace of the pane that asked for a review, if the app has it
    func workspace(of review: Review) -> UUID? {
        let host = sessions.first { $0.id == review.sessionId }?.connectionConfig.id
        return sessions.first { $0.rtachSessionId == review.pane && (host == nil || $0.connectionConfig.id == host) }?.groupId
    }

    /// The Mac's: a workspace's oldest review not closed for now, there when the workspace
    /// is on screen (one whose workspace the app doesn't have goes with the one shown)
    func shownReview(in workspace: UUID) -> Review? {
        reviews.first { review in
            guard !hiddenReviews.contains(review.id) else { return false }
            let home = self.workspace(of: review)
            return home == workspace || home == nil
        }
    }

    /// Close a review without answering it: the waiting command says so and exits
    func dismissReview(_ review: Review) {
        forget(review)
        guard let session = try? reviewSession(review) else { return }
        Task { await session.dismissReview(id: review.id) }
    }

    /// The user closed a review (its X): gone if they wrote nothing in it, as images go;
    /// else closed for now, to finish later. The review on screen knows which
    /// (`reviewClosers`).
    func closeByUser(_ review: Review) {
        // Not on screen to ask: kept, rather than lose what might be written
        if let close = reviewClosers[review.id] { close() } else { hideReview(review) }
    }

    /// Done with by a newer review from the same agent: its waiting command prints so
    /// and exits (nothing is typed into the pane when that command is gone)
    private func replace(_ review: Review) {
        forget(review)
        guard let session = try? reviewSession(review) else { return }
        let report = "Review of \"\(review.title)\": replaced by a newer review"
        Task { _ = try? await session.sendReviewReply(id: review.id, report: report) }
    }

    private func forget(_ review: Review) {
        reviews.removeAll { $0.id == review.id }
        hiddenReviews.remove(review.id)
        if openedReview == review.id { openedReview = nil }
    }

    /// From the same pane on the same host
    private func samePane(_ a: Review, _ b: Review) -> Bool {
        guard !a.pane.isEmpty, a.pane == b.pane else { return false }
        let host = { (r: Review) in self.sessions.first { $0.id == r.sessionId }?.connectionConfig.id }
        return host(a) == host(b)
    }

    /// When a review was made: its id starts with the unix time in ms
    private static func madeAt(_ id: String) -> Int64 {
        Int64(id.split(separator: "-").first ?? "") ?? 0
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
