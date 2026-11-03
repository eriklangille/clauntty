import SwiftUI

#if os(iOS)
/// The terminal's dictation (`SpeechManager`, on the phone) in a text box (a review's, the
/// chat's), as its mic works: tap to start and again to stop, or hold and talk. The words go
/// after what's typed. Until the model is downloaded it isn't there, or, with `offersDownload`,
/// it's there and a tap offers the download as the terminal's mic does.
struct DictationButton: View {
    @Binding var text: String
    /// Recording for this box (not another's, or the terminal's); the box glows
    @Binding var recording: Bool
    let colors: ReviewColors
    var offersDownload = false
    var size: CGFloat = 15
    @ObservedObject private var speech = SpeechManager.shared
    @State private var transcribing = false
    @State private var pressed = false
    /// Held past this, it records until let go
    @State private var hold: Task<Void, Never>?
    @State private var holding = false

    var body: some View {
        if speech.modelState != .ready, offersDownload {
            Button {
                NotificationCenter.default.post(name: .promptSpeechModelDownload, object: nil)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(colors.dim)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate")
        } else if speech.modelState == .ready {
            Group {
                if transcribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(recording ? Color(uiColor: .systemBlue) : colors.dim)
                }
            }
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in press() }.onEnded { _ in release() })
            .accessibilityLabel(recording ? "Stop dictation" : "Dictate")
            .onDisappear {
                if recording { speech.stopRecordingWithoutTranscription() }
                recording = false
            }
        }
    }

    private func press() {
        guard !pressed else { return }
        pressed = true
        guard !speech.isRecording, !transcribing else { return }
        hold = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            holding = true
            start()
        }
    }

    private func release() {
        pressed = false
        hold?.cancel()
        hold = nil
        if holding {
            holding = false
            stop()
        } else if recording {
            stop()
        } else if !speech.isRecording && !transcribing {
            start()
        }
    }

    private func start() {
        speech.startRecording()
        guard speech.isRecording else { return }
        recording = true
        Haptic.dictationStart.play()
    }

    private func stop() {
        guard recording else { return }
        recording = false
        transcribing = true
        Task {
            defer { transcribing = false }
            guard let words = await speech.stopRecording()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !words.isEmpty else { return }
            if let last = text.last, !last.isWhitespace { text += " " }
            text += words
        }
    }
}
#endif
