import SwiftUI
import os.log

struct ContentView: View {
  @EnvironmentObject var connectionStore: ConnectionStore
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var sessionManager: SessionManager

  @State private var showingNewTabSheet = false
  @State private var showingFullTabSelector = false
  @State private var portsSheetSession: Session?
  @State private var hasCheckedAutoConnect = false
  @State private var showingSpeechModelDownload = false

  var body: some View {
    NavigationStack {
      if sessionManager.hasSessions {
        // Show tabs + content when there are active sessions or web tabs
        // Tab bar overlays terminal content with transparent background
        GeometryReader { geometry in
          ZStack(alignment: .top) {
            // Terminal tabs (full screen, with top padding for tab bar)
            ForEach(sessionManager.sessions) { session in
              let tab = SessionManager.ActiveTab.terminal(session.id)
              let isActive = sessionManager.activeTab == tab

              TerminalView(session: session, isTabSelectorPresented: showingFullTabSelector)
                .safeAreaInset(edge: .top) {
                  Color.clear.frame(height: 48)  // Tab bar height
                }
                .offset(x: isActive ? 0 : geometry.size.width)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .transition(.identity)
                .animation(nil, value: sessionManager.sessions.count)
                .animation(nil, value: sessionManager.activeTab)
            }

            // Web tabs (full screen, with top padding for tab bar)
            ForEach(sessionManager.webTabs) { webTab in
              let tab = SessionManager.ActiveTab.web(webTab.id)
              let isActive = sessionManager.activeTab == tab

              WebTabView(webTab: webTab)
                .safeAreaInset(edge: .top) {
                  Color.clear.frame(height: 48)  // Tab bar height
                }
                .offset(x: isActive ? 0 : geometry.size.width)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .transition(.identity)
                .animation(nil, value: sessionManager.webTabs.count)
                .animation(nil, value: sessionManager.activeTab)
            }

            // Tab bar overlay at top
            VStack(spacing: 0) {
              LiquidGlassTabBarRepresentable(
                onNewTab: { showingNewTabSheet = true },
                onShowTabSelector: {
                  Logger.clauntty.info("[TAB_SELECTOR] onShowTabSelector callback FIRED")
                  // Force dismiss keyboard at window level (most aggressive)
                  Logger.clauntty.info("[TAB_SELECTOR] Forcing keyboard dismiss via endEditing")
                  UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .forEach { $0.endEditing(true) }

                  // Also post notification to hide accessory bars
                  NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)

                  showingFullTabSelector = true
                },
                onShowPorts: { session in
                  Logger.clauntty.debugOnly(
                    "ContentView: onShowPorts called for session \(session.id.uuidString.prefix(8))"
                  )
                  portsSheetSession = session
                },
                sessionStatesHash: sessionManager.sessionStateVersion
              )
              .frame(height: 48)
              Spacer()
            }
          }
        }
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
        .fullScreenCover(isPresented: $showingFullTabSelector) {
          FullTabSelector(
            onDismiss: { showingFullTabSelector = false },
            onNewTab: {
              // Show new tab sheet after a brief delay to let the full cover dismiss
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showingNewTabSheet = true
              }
            }
          )
        }
        .sheet(item: $portsSheetSession) { session in
          PortsSheetView(session: session, onDismiss: { portsSheetSession = nil })
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
                let session = sessionManager.createSession(for: connection)
                sessionsToConnect.append(session)
              }

            case .newSession:
              // Create a new session
              Logger.clauntty.debugOnly("Auto-connect: creating new session")
              let session = sessionManager.createSession(for: connection)
              sessionsToConnect.append(session)

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
            let session = sessionManager.createSession(for: connection)
            sessionsToConnect.append(session)
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
        lastConnected: existing?.lastConnected
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
