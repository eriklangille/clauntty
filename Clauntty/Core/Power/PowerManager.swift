import UIKit
import Combine
import os.log

/// Power mode for battery optimization
enum PowerMode: Int32 {
    case normal = 0      // Full responsiveness (10ms coalescing)
    case lowPower = 1    // Battery saver (30ms coalescing)
}

/// Manages power-aware rendering for battery optimization.
/// Monitors iOS battery state, Low Power Mode, and thermal state.
@MainActor
final class PowerManager: ObservableObject {
    static let shared = PowerManager()

    @Published private(set) var currentMode: PowerMode = .normal
    @Published private(set) var batteryLevel: Float = 1.0
    @Published private(set) var isCharging: Bool = true
    @Published private(set) var isLowPowerModeEnabled: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    /// User preference for aggressive battery saving
    @Published var batterySaverEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(batterySaverEnabled, forKey: "batterySaverEnabled")
            recalculatePowerMode()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Load saved preference
        batterySaverEnabled = UserDefaults.standard.bool(forKey: "batterySaverEnabled")
        setupMonitoring()
    }

    private func setupMonitoring() {
        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Initial state
        updateBatteryState()
        updateLowPowerMode()
        updateThermalState()

        // Battery level/state notifications
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateBatteryState() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateBatteryState() }
            .store(in: &cancellables)

        // Low Power Mode notification
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLowPowerMode() }
            .store(in: &cancellables)

        // Thermal state notification
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateThermalState() }
            .store(in: &cancellables)
    }

    private func updateBatteryState() {
        batteryLevel = UIDevice.current.batteryLevel
        isCharging = UIDevice.current.batteryState == .charging ||
                     UIDevice.current.batteryState == .full
        recalculatePowerMode()
    }

    private func updateLowPowerMode() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        recalculatePowerMode()
    }

    private func updateThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        recalculatePowerMode()
    }

    func recalculatePowerMode() {
        let newMode: PowerMode

        // User toggle overrides everything
        if batterySaverEnabled {
            newMode = .lowPower
        }
        // Thermal pressure takes precedence
        else if thermalState == .serious || thermalState == .critical {
            newMode = .lowPower
        }
        // System Low Power Mode
        else if isLowPowerModeEnabled {
            newMode = .lowPower
        }
        // Charging = always normal
        else if isCharging {
            newMode = .normal
        }
        // Battery level threshold (< 20% = low power)
        else if batteryLevel >= 0 && batteryLevel < 0.20 {
            newMode = .lowPower
        } else {
            newMode = .normal
        }

        if newMode != currentMode {
            Logger.clauntty.debugOnly("PowerManager: mode changed \(String(describing: self.currentMode)) -> \(String(describing: newMode))")
            currentMode = newMode
        }
    }

    /// Debug description of current state
    var debugDescription: String {
        let batteryPct = batteryLevel >= 0 ? "\(Int(batteryLevel * 100))%" : "unknown"
        let charging = isCharging ? "charging" : "unplugged"
        let thermal = String(describing: thermalState)
        let lowPower = isLowPowerModeEnabled ? "LPM" : ""
        let userSaver = batterySaverEnabled ? "USER_SAVER" : ""

        return "PowerManager: \(currentMode) battery=\(batteryPct) \(charging) thermal=\(thermal) \(lowPower) \(userSaver)"
    }
}
