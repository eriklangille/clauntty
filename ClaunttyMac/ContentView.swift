import GhosttyKit
import SwiftUI

/// Spike: one terminal. With --host (see SpikeConnection) it's an rtach session
/// over SSH; without, it echoes what you type.
struct ContentView: View {
    @EnvironmentObject private var ghostty: MacGhosttyApp
    @StateObject private var connection = SpikeConnection()

    var body: some View {
        if let app = ghostty.app {
            TerminalPane(app: app, connection: connection)
                .navigationTitle(connection.status)
        } else {
            Text("Ghostty failed to start")
        }
    }
}

private struct TerminalPane: NSViewRepresentable {
    let app: ghostty_app_t
    let connection: SpikeConnection

    func makeNSView(context: Context) -> MacTerminalView {
        let view = MacTerminalView(app: app)
        if let options = SpikeConnection.options {
            // Once the view has its real size, so the session starts at the window's grid.
            DispatchQueue.main.async {
                Task { await connection.connect(options, to: view) }
            }
        } else {
            startLocalEcho(view)
        }
        return view
    }

    func updateNSView(_ view: MacTerminalView, context: Context) {}

    /// What the terminal would send to a program comes straight back as output.
    private func startLocalEcho(_ view: MacTerminalView) {
        view.onInput = { [weak view] data in
            var echoed = Data()
            for byte in data {
                if byte == 0x0d { echoed.append(contentsOf: [0x0d, 0x0a]) }
                else if byte == 0x7f { echoed.append(contentsOf: [0x08, 0x20, 0x08]) }
                else { echoed.append(byte) }
            }
            view?.write(echoed)
        }
        view.write(Data("\u{1b}[1;35mClauntty for macOS\u{1b}[0m · manual IO spike\r\n\r\n$ ".utf8))
    }
}
