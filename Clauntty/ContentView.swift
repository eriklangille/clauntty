import SwiftUI
import os.log

struct ContentView: View {
  @EnvironmentObject var connectionStore: ConnectionStore
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var sessionManager: SessionManager

  @State private var showingNewTabSheet = false
  /// Debug: the voice button starts a pretend session (no xAI), to work on its look
  @AppStorage("fakeVoice") private var fakeVoice = false
  @State private var portsSheetSession: Session?
  @State private var hasCheckedAutoConnect = false
  @State private var showingSpeechModelDownload = false
  @State private var showingVoiceSession = false
  @State private var showingVoiceSettings = false

  var body: some View {
    NavigationStack {
      if sessionManager.hasSessions {
        // Every workspace a window onto its terminal (agent view)
        AgentSwitcherView(
          onNewTab: { showingNewTabSheet = true },
          onVoice: handleVoiceTapped,
          onPorts: { session in portsSheetSession = session }
        )
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingNewTabSheet) {
          NavigationStack {
            ConnectionListView()
              .navigationTitle("New Tab")
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("Cancel") {
                    showingNewTabSheet = false
                  }
                }
              }
          }
        }
        .sheet(isPresented: $showingVoiceSettings) {
          VoiceSettingsSheet()
        }
        // The voice session from the voice button (while typing, the key bar has it)
        .sheet(isPresented: $showingVoiceSession) {
          VoiceSessionSheet()
        }
        .sheet(item: $portsSheetSession) { session in
          PortsSheetView(config: session.connectionConfig, onDismiss: { portsSheetSession = nil })
            .environmentObject(sessionManager)
        }
        .onChange(of: sessionManager.sessions.count) { oldCount, newCount in
          // Dismiss sheet when a new session is added
          if newCount > oldCount {
            showingNewTabSheet = false
          }
        }
        .onChange(of: sessionManager.webTabs.count) { oldCount, newCount in
          // Dismiss sheet when a new web tab is added
          if newCount > oldCount {
            showingNewTabSheet = false
          }
        }
      } else {
        // Show connection list when no sessions
        ConnectionListView()
      }
    }
    .fullScreenCover(item: $sessionManager.imageViewer) { _ in
      // Images from `clauntty show` on a remote host
      ImageViewerView(content: $sessionManager.imageViewer)
    }
    .onAppear {
      checkAutoConnect()
    }
    .onReceive(NotificationCenter.default.publisher(for: .promptSpeechModelDownload)) { _ in
      showingSpeechModelDownload = true
    }
    .alert("Download Speech Model?", isPresented: $showingSpeechModelDownload) {
      Button("Download") {
        Task {
          await SpeechManager.shared.downloadModel()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will download approximately 800 MB of data for on-device speech recognition. The model runs entirely on your device for privacy.")
    }
    .alert(
      "Allow Code Signing on \(sessionManager.spawndOffer?.hostName ?? "This Mac")?",
      isPresented: Binding(
        get: { sessionManager.spawndOffer != nil },
        set: { if !$0 { sessionManager.spawndOffer = nil } }
      ),
      presenting: sessionManager.spawndOffer
    ) { offer in
      Button("Install") {
        Task { await sessionManager.installSpawnd(offer) }
      }
      Button("Not Now", role: .cancel) {}
    } message: { _ in
      Text("Sessions started from Clauntty can't use this Mac's login keychain, so code signing (Xcode builds) fails in them. Install a small helper so new sessions start in the desktop session? Remove it anytime with `rtach spawnd uninstall`.")
    }
    .alert(
      "Workspace",
      isPresented: Binding(
        get: { sessionManager.workspaceMessage != nil },
        set: { if !$0 { sessionManager.workspaceMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(sessionManager.workspaceMessage ?? "")
    }
    .alert(
      "Code Signing Helper",
      isPresented: Binding(
        get: { sessionManager.spawndMessage != nil },
        set: { if !$0 { sessionManager.spawndMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(sessionManager.spawndMessage ?? "")
    }
  }

  /// Voice button: set up a key first, start a session, or open the session sheet
  private func handleVoiceTapped() {
    let agent = VoiceAgent.shared
    if agent.isActive {
      showingVoiceSession.toggle()
    } else if fakeVoice {
      #if DEBUG
      agent.startFake(sessionManager: sessionManager)
      #endif
    } else if !VoiceSettings.hasAPIKey {
      showingVoiceSettings = true
    } else {
      agent.start(sessionManager: sessionManager)
    }
  }

  /// Check for --connect <name> and --tabs launch arguments
  private func checkAutoConnect() {
    guard !hasCheckedAutoConnect else { return }
    hasCheckedAutoConnect = true

    _ = seedConnectionFromLaunchArgsIfNeeded()

    guard let connectionName = LaunchArgs.autoConnectName() else { return }

    Logger.clauntty.debugOnly("Auto-connect requested for: \(connectionName)")

    // Find connection by name (case-insensitive)
    guard
      let connection = connectionStore.connections.first(where: {
        $0.name.lowercased() == connectionName.lowercased()
          || $0.host.lowercased() == connectionName.lowercased()
      })
    else {
      let available = connectionStore.connections.map { "\($0.name) (\($0.host))" }.joined(
        separator: ", ")
      Logger.clauntty.error(
        "Auto-connect: connection '\(connectionName)' not found. Available: \(available)")
      return
    }

    Logger.clauntty.debugOnly(
      "Auto-connect: found connection \(connection.name) (\(connection.host))")

    // Check for multi-tab specs
    let tabSpecs = LaunchArgs.tabSpecs()

    Task {
      do {
        // First, establish SSH and deploy rtach, then sync sessions
        // This only discovers sessions and creates tabs - does NOT connect them
        Logger.clauntty.debugOnly("Auto-connect: establishing SSH and syncing sessions...")
        if let result = try await sessionManager.connectAndListSessions(for: connection) {
          await sessionManager.syncSessionsWithServer(config: connection, deployer: result.deployer)
        }

        // Get persisted tabs for this connection (including newly synced ones)
        let serverTabs = sessionManager.sessions.filter { $0.connectionConfig.id == connection.id }
        Logger.clauntty.debugOnly(
          "Auto-connect: found \(serverTabs.count) tabs for \(connection.name)")

        // Track which sessions to actually connect (lazy - only connect what's needed)
        var sessionsToConnect: [Session] = []

        if let specs = tabSpecs {
          // Multi-tab mode - only connect specified tabs
          Logger.clauntty.debugOnly("Auto-connect: processing \(specs.count) tab specs")

          for spec in specs {
            switch spec {
            case .existing(let index):
              // Select existing persisted tab by index (for this server)
              if index < serverTabs.count {
                let session = serverTabs[index]
                Logger.clauntty.debugOnly(
                  "Auto-connect: will connect existing tab \(index): \(session.id.uuidString.prefix(8))"
                )
                sessionsToConnect.append(session)
              } else {
                Logger.clauntty.warning(
                  "Auto-connect: tab index \(index) out of range (have \(serverTabs.count) tabs), creating new"
                )
                if let session = await sessionManager.openTerminal(on: connection) {
                  sessionsToConnect.append(session)
                }
              }

            case .newSession:
              // Create a new session
              Logger.clauntty.debugOnly("Auto-connect: creating new session")
              if let session = await sessionManager.openTerminal(on: connection) {
                sessionsToConnect.append(session)
              }

            case .port(let portNum):
              // Port forward - create web tab
              Logger.clauntty.debugOnly("Auto-connect: forwarding port \(portNum)")
              let remotePort = RemotePort(
                id: portNum, port: portNum, process: nil, address: "127.0.0.1")
              _ = try await sessionManager.createWebTab(for: remotePort, config: connection)
            }
          }
        } else {
          // No tab specs - connect first existing tab or create new
          if let existingTab = serverTabs.first {
            Logger.clauntty.debugOnly(
              "Auto-connect: will connect existing tab \(existingTab.id.uuidString.prefix(8))")
            sessionsToConnect.append(existingTab)
          } else {
            Logger.clauntty.debugOnly("Auto-connect: no existing tabs, creating new session")
            if let session = await sessionManager.openTerminal(on: connection) {
              sessionsToConnect.append(session)
            }
          }
        }

        // Only connect the LAST session (which becomes active)
        // Other sessions stay disconnected - lazy reconnect when user switches to them
        if let activeSession = sessionsToConnect.last {
          Logger.clauntty.debugOnly(
            "Auto-connect: connecting active session \(activeSession.id.uuidString.prefix(8)) (lazy mode: \(sessionsToConnect.count - 1) others disconnected)"
          )
          try await sessionManager.connect(
            session: activeSession, rtachSessionId: activeSession.rtachSessionId)
          sessionManager.switchTo(activeSession)
        }

        Logger.clauntty.debugOnly(
          "Auto-connect: connected 1 session, \(sessionsToConnect.count - 1) waiting for lazy reconnect"
        )

        // Save persistence after all changes
        sessionManager.savePersistence()
      } catch {
        Logger.clauntty.error("Auto-connect failed: \(error.localizedDescription)")
      }
    }
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Optional launch-time profile seeding.
  /// This is idempotent: same flags update an existing matching profile instead of creating duplicates.
  @discardableResult
  private func seedConnectionFromLaunchArgsIfNeeded() -> SavedConnection? {
    switch LaunchArgs.seedConnectionSpec() {
    case .none:
      return nil
    case .invalid(let reason):
      Logger.clauntty.error("Seed connection args invalid: \(reason)")
      return nil
    case .spec(let spec):
      let normalizedName = normalized(spec.name)
      let normalizedHost = normalized(spec.host)
      let normalizedUser = normalized(spec.username)

      let existingByName = connectionStore.connections.first {
        normalized($0.name) == normalizedName
      }
      let existingByEndpoint = connectionStore.connections.first {
        normalized($0.host) == normalizedHost
          && normalized($0.username) == normalizedUser
          && $0.port == spec.port
      }
      let existing = existingByName ?? existingByEndpoint

      let authMethod: AuthMethod
      let authLabel: String
      switch spec.authMethod {
      case .password:
        authMethod = .password
        authLabel = "password"
      case .sshKey(let keyId):
        authMethod = .sshKey(keyId: keyId)
        authLabel = "sshKey:\(keyId)"
      }

      let seeded = SavedConnection(
        id: existing?.id ?? UUID(),
        name: spec.name,
        host: spec.host,
        port: spec.port,
        username: spec.username,
        authMethod: authMethod,
        lastConnected: existing?.lastConnected,
        useTailscale: spec.useTailscale
      )

      if existing != nil {
        connectionStore.update(seeded)
      } else {
        connectionStore.add(seeded)
      }

      if case .password = spec.authMethod {
        if let password = spec.password {
          do {
            try KeychainHelper.savePassword(for: seeded.id, password: password)
          } catch {
            Logger.clauntty.error("Seed connection: failed to save password to keychain: \(error)")
          }
        } else {
          Logger.clauntty.warning(
            "Seed connection: auth=password but CLAUNTTY_SEED_PASSWORD not provided")
        }
      }

      let action = existing == nil ? "created" : "updated"
      Logger.clauntty.info(
        "Seed connection: \(action) '\(seeded.name)' (\(seeded.username)@\(seeded.host):\(seeded.port), auth=\(authLabel))"
      )
      return seeded
    }
  }

}

#Preview {
  ContentView()
    .environmentObject(ConnectionStore())
    .environmentObject(AppState())
    .environmentObject(SessionManager())
}
