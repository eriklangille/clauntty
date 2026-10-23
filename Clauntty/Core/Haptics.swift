#if canImport(UIKit)
import UIKit
#endif

/// Every haptic in the app, named for what happened. What each one feels like is decided
/// here, in one switch, so they stay apart: single taps for what the user does, iOS's
/// notification patterns (several pulses) only for what happens to them, an agent
/// finishing or needing them, so those can't be mistaken for a gesture's taps.
/// Nothing on the Mac.
@MainActor
enum Haptic {
    // What the user does

    /// Moving between windows, panes and pages; a moved window dropped
    case navigate
    /// What's under the finger changing as it slides: rail dots, menu rows, a moved
    /// window passing another
    case scrub
    /// Held long enough to pick something up: a window to move, a menu held open
    case lift
    /// A long press starting to select text
    case selectStart
    /// A selection handle picked up
    case handleGrab
    /// A drag held at the top or bottom edge: the program starts scrolling
    case edgeScrollStart
    /// Out of the edge again: the scrolling stops
    case edgeScrollStop
    /// Copied to the clipboard (a program's copy on release of a drag)
    case copied
    /// An image or video saved to Photos
    case saved
    /// Dictation starting from the key bar
    case dictationStart
    /// A voice session starting or ending
    case voiceSession

    // What happens to the user

    /// Another window's agent finished
    case agentFinished
    /// Another window's agent needs the user
    case agentNeedsYou
    /// Images from `clauntty show` arrived in a window
    case imagesArrived

    func play() {
        #if canImport(UIKit)
        switch self {
        case .navigate, .handleGrab, .imagesArrived:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .scrub:
            UISelectionFeedbackGenerator().selectionChanged()
        case .lift, .selectStart, .dictationStart, .voiceSession:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .edgeScrollStart:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .edgeScrollStop:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .copied, .saved:
            // Click-click: two light taps
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case .agentFinished:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .agentNeedsYou:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
    }
}
