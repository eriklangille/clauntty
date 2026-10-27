import SwiftUI
import QuartzCore
import os.log
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// How smooth the review is, measured: with `CLAUNTTY_REVIEW_PERF` set, a display link counts
/// the frames the main thread delivers, and every five seconds the log gets frames per second,
/// the longest gap and how many frames were late (`log show --predicate 'eventMessage CONTAINS
/// "review frames"'`). `CLAUNTTY_REVIEW_PERF=scroll` also scrolls the page by itself at a steady
/// speed, as a trackpad would, back and forth. Off otherwise.
@MainActor
final class FrameMonitor: NSObject {
    static let shared: FrameMonitor? = {
        guard let mode = ProcessInfo.processInfo.environment["CLAUNTTY_REVIEW_PERF"] else { return nil }
        return FrameMonitor(autoScroll: mode == "scroll")
    }()

    let autoScroll: Bool
    /// Moves the page to a scroll offset (set by the review, iOS 18/macOS 15)
    var scrollTo: ((CGFloat) -> Void)?
    /// How tall the page is, to turn around at its end
    var pageHeight: CGFloat = 0

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var worst: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var y: CGFloat = 0
    private var direction: CGFloat = 1
    /// Points a second
    private let speed: CGFloat = 2400

    private init(autoScroll: Bool) {
        self.autoScroll = autoScroll
    }

    func start() {
        guard link == nil else { return }
        #if canImport(UIKit)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #else
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        started = CACurrentMediaTime()
        last = started
    }

    /// Move the page the way a trackpad does: its scroll view directly, not through SwiftUI.
    /// On the phone, through SwiftUI (`scrollTo`).
    private func step(by distance: CGFloat) {
        #if canImport(AppKit)
        guard let scroll = pageScrollView(), let document = scroll.documentView else { return }
        let height = document.frame.height - scroll.contentView.bounds.height
        guard height > 0 else { return }
        y = scroll.contentView.bounds.origin.y + direction * distance
        if y > height { y = height; direction = -1 }
        if y < 0 { y = 0; direction = 1 }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        #else
        guard let scrollTo, pageHeight > 0 else { return }
        y += direction * distance
        if y > pageHeight { y = pageHeight; direction = -1 }
        if y < 0 { y = 0; direction = 1 }
        scrollTo(y)
        #endif
    }

    #if canImport(AppKit)
    private weak var found: NSScrollView?

    /// The review's page: the window's tallest scroll view
    private func pageScrollView() -> NSScrollView? {
        if let found, found.window != nil { return found }
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        let views = NSApp.windows.compactMap(\.contentView).flatMap(all)
        found = views.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        return found
    }
    #endif

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = now - last
        last = now
        frames += 1
        worst = max(worst, gap)
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 && gap > interval * 1.5 { late += 1 }

        if autoScroll { step(by: speed * CGFloat(min(gap, 0.1))) }

        if now - started >= 5 {
            let fps = Double(frames) / (now - started)
            Logger.clauntty.warning("review frames: \(Int(fps.rounded())) fps, worst \(Int(self.worst * 1000)) ms, \(self.late) late of \(self.frames)")
            frames = 0; late = 0; worst = 0; started = now
        }
    }
}
