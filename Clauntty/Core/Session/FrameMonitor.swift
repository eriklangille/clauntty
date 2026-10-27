import Foundation
import QuartzCore
import os.log

/// How smooth the review is, measured: with `CLAUNTTY_REVIEW_PERF` set, a timer on the main
/// run loop notes every gap between its ticks, and every five seconds the log gets the
/// longest stall and how many went over 50 and 100 ms (`log show --predicate 'eventMessage
/// CONTAINS "review frames"'`). Off otherwise.
@MainActor
final class FrameMonitor {
    static let shared: FrameMonitor? = ProcessInfo.processInfo.environment["CLAUNTTY_REVIEW_PERF"] == nil ? nil : FrameMonitor()

    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var worst: Double = 0
    private var over50 = 0
    private var over100 = 0
    private var ticks = 0
    private var started = CACurrentMediaTime()

    func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        started = last
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let gap = now - last
        last = now
        ticks += 1
        worst = max(worst, gap)
        if gap > 0.05 { over50 += 1 }
        if gap > 0.1 { over100 += 1 }
        if now - started >= 5 {
            Logger.clauntty.warning("review frames: worst \(Int(self.worst * 1000)) ms, \(self.over50) over 50 ms, \(self.over100) over 100 ms, \(self.ticks) ticks")
            worst = 0; over50 = 0; over100 = 0; ticks = 0; started = now
        }
    }
}
