import AppKit
import Combine
import Foundation
import os

@MainActor
enum DisplayConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(displayID: CGDirectDisplayID)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }
}

@MainActor
final class VirtualDisplayStore: ObservableObject {
    @Published private(set) var profiles: [VirtualDisplayProfile]
    @Published private(set) var connectionStates: [UUID: DisplayConnectionState]
    @Published private(set) var backendAvailability: VirtualDisplayBackendAvailability
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var shouldShowLaunchAtLoginApproval = false
    @Published private(set) var lastErrorMessage: String?

    private let backend: VirtualDisplayBackend
    private let repository: StatePersisting
    private let launchAtLoginManager: LaunchAtLoginManaging
    private let wakeRetryDelayNanoseconds: UInt64
    private let logger = Logger(subsystem: "com.narumi.VirtualScreen", category: "Store")

    private var persistedState: PersistedState
    private var connections: [UUID: any VirtualDisplayConnection] = [:]
    private var connectionTokens: [UUID: UUID] = [:]
    private var workspaceWakeObserver: NSObjectProtocol?
    private var hasStarted = false
    private var wakeRetryInProgress = false

    init(
        backend: VirtualDisplayBackend,
        repository: StatePersisting,
        launchAtLoginManager: LaunchAtLoginManaging,
        wakeRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.backend = backend
        self.repository = repository
        self.launchAtLoginManager = launchAtLoginManager
        self.wakeRetryDelayNanoseconds = wakeRetryDelayNanoseconds

        let state = repository.load()
        persistedState = state
        profiles = state.profiles
        connectionStates = Dictionary(uniqueKeysWithValues: state.profiles.map { ($0.id, .disconnected) })
        backendAvailability = backend.availability
        launchAtLoginStatus = launchAtLoginManager.status
    }

    convenience init() {
        self.init(
            backend: CoreGraphicsVirtualDisplayBackend(),
            repository: StateRepository(),
            launchAtLoginManager: LaunchAtLoginManager()
        )
    }

    deinit {
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        installWakeObserver()
        configureDefaultLaunchAtLoginIfNeeded()

        guard backendAvailability.isAvailable else {
            if case let .unavailable(reason) = backendAvailability {
                for profile in profiles where profile.desiredConnected {
                    connectionStates[profile.id] = .failed(message: reason)
                }
            }
            return
        }

        for profile in profiles where profile.desiredConnected {
            await connectProfile(id: profile.id, updateDesiredState: false)
        }
    }

    func state(for profileID: UUID) -> DisplayConnectionState {
        connectionStates[profileID] ?? .disconnected
    }

    func profile(id: UUID) -> VirtualDisplayProfile? {
        profiles.first { $0.id == id }
    }

    func needs8KWarning(for resolution: ResolutionPreset) -> Bool {
        resolution.is8K && !persistedState.hasAcknowledged8KWarning
    }

    func acknowledge8KWarning() {
        persistedState.hasAcknowledged8KWarning = true
        save()
    }

    func addDisplay(resolution: ResolutionPreset) async {
        guard backendAvailability.isAvailable else {
            reportError(backendUnavailableMessage())
            return
        }

        let profile = VirtualDisplayProfile(
            name: nextAvailableDisplayName(),
            resolutionID: resolution.id,
            desiredConnected: true
        )
        profiles.append(profile)
        connectionStates[profile.id] = .disconnected
        save()
        await connectProfile(id: profile.id, updateDesiredState: false)
    }

    func connectProfile(id: UUID) async {
        await connectProfile(id: id, updateDesiredState: true)
    }

    func disconnectProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].desiredConnected = false
        connectionTokens[id] = nil
        let connection = connections.removeValue(forKey: id)
        connection?.invalidate()
        connectionStates[id] = .disconnected
        save()
        logger.info("Disconnected virtual display \(id.uuidString, privacy: .public)")
    }

    func setResolution(_ resolution: ResolutionPreset, for profileID: UUID) async {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard profiles[index].resolutionID != resolution.id else { return }

        if let connection = connections[profileID] {
            do {
                try await backend.setResolution(resolution, for: connection)
                profiles[index].resolutionID = resolution.id
                connectionStates[profileID] = .connected(displayID: connection.displayID)
                save()
            } catch {
                reportError(VirtualDisplayBackendError.from(error).localizedDescription)
            }
            return
        }

        profiles[index].resolutionID = resolution.id
        save()

        if case .connecting = state(for: profileID), profiles[index].desiredConnected {
            await connectProfile(id: profileID, updateDesiredState: false)
        }
    }

    func renameProfile(id: UUID, to proposedName: String) async {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            reportError(String(localized: "error.emptyName", defaultValue: "The display name cannot be empty."))
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[index].name != name else { return }

        profiles[index].name = String(name.prefix(64))
        let shouldReconnect = profiles[index].desiredConnected && connections[id] != nil
        save()

        if shouldReconnect {
            connectionTokens[id] = nil
            connections.removeValue(forKey: id)?.invalidate()
            connectionStates[id] = .disconnected
            await connectProfile(id: id, updateDesiredState: false)
        }
    }

    func removeProfile(id: UUID) {
        connectionTokens[id] = nil
        connections.removeValue(forKey: id)?.invalidate()
        connectionStates[id] = nil
        profiles.removeAll { $0.id == id }
        save()
        logger.info("Removed virtual display \(id.uuidString, privacy: .public)")
    }

    func retryDesiredConnectionsAfterWake() async {
        guard !wakeRetryInProgress else { return }
        wakeRetryInProgress = true
        defer { wakeRetryInProgress = false }

        if wakeRetryDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: wakeRetryDelayNanoseconds)
        }

        for profile in profiles where profile.desiredConnected {
            if let connection = connections[profile.id], !connection.isValid {
                connectionTokens[profile.id] = nil
                connections[profile.id] = nil
                connection.invalidate()
                connectionStates[profile.id] = .disconnected
            }
            if connections[profile.id] == nil {
                await connectProfile(id: profile.id, updateDesiredState: false)
            }
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginStatus = launchAtLoginManager.status
        if enabled && launchAtLoginStatus == .requiresApproval {
            shouldShowLaunchAtLoginApproval = true
            return
        }
        if enabled && launchAtLoginStatus == .enabled { return }
        if !enabled && launchAtLoginStatus == .disabled { return }

        do {
            if enabled {
                try launchAtLoginManager.register()
            } else {
                try launchAtLoginManager.unregister()
            }
            launchAtLoginStatus = launchAtLoginManager.status
            if launchAtLoginStatus == .requiresApproval {
                shouldShowLaunchAtLoginApproval = true
            }
        } catch {
            launchAtLoginStatus = launchAtLoginManager.status
            reportError(
                String(
                    format: String(localized: "error.loginItem", defaultValue: "Could not update Launch at Login: %@"),
                    error.localizedDescription
                )
            )
        }
    }

    func openLoginItemSettings() {
        launchAtLoginManager.openSystemSettings()
    }

    func clearLaunchAtLoginApprovalNotice() {
        shouldShowLaunchAtLoginApproval = false
    }

    func takeLastErrorMessage() -> String? {
        defer { lastErrorMessage = nil }
        return lastErrorMessage
    }

    private func connectProfile(id: UUID, updateDesiredState: Bool) async {
        guard backendAvailability.isAvailable else {
            reportError(backendUnavailableMessage())
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              let resolution = profiles[index].resolution else {
            reportError(String(localized: "error.invalidConfiguration", defaultValue: "The virtual display configuration is invalid."))
            return
        }

        if updateDesiredState {
            profiles[index].desiredConnected = true
            save()
        }

        connectionTokens[id] = nil
        connections.removeValue(forKey: id)?.invalidate()
        let token = UUID()
        connectionTokens[id] = token
        connectionStates[id] = .connecting
        let profile = profiles[index]

        do {
            let connection = try await backend.connect(
                profile: profile,
                resolution: resolution,
                terminationHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleTermination(profileID: id, token: token)
                    }
                }
            )

            guard connectionTokens[id] == token,
                  let currentProfile = profiles.first(where: { $0.id == id }),
                  currentProfile.desiredConnected else {
                connection.invalidate()
                return
            }

            connections[id] = connection
            connectionStates[id] = .connected(displayID: connection.displayID)
            logger.info("Virtual display \(id.uuidString, privacy: .public) is connected")
        } catch {
            guard connectionTokens[id] == token else { return }
            connections[id] = nil
            let mappedError = VirtualDisplayBackendError.from(error)
            connectionStates[id] = .failed(message: mappedError.localizedDescription)
            reportError(mappedError.localizedDescription)
        }
    }

    private func handleTermination(profileID: UUID, token: UUID) {
        guard connectionTokens[profileID] == token else { return }
        connectionTokens[profileID] = nil
        connections[profileID] = nil
        let message = String(localized: "error.unexpectedTermination", defaultValue: "The virtual display was disconnected by macOS.")
        connectionStates[profileID] = .failed(message: message)
        reportError(message)
        logger.error("Virtual display \(profileID.uuidString, privacy: .public) terminated unexpectedly")
    }

    private func configureDefaultLaunchAtLoginIfNeeded() {
        guard !persistedState.hasAttemptedLoginItemRegistration else {
            launchAtLoginStatus = launchAtLoginManager.status
            return
        }

        persistedState.hasAttemptedLoginItemRegistration = true
        save()

        launchAtLoginStatus = launchAtLoginManager.status
        if launchAtLoginStatus == .enabled {
            return
        }
        if launchAtLoginStatus == .requiresApproval {
            shouldShowLaunchAtLoginApproval = true
            return
        }

        do {
            try launchAtLoginManager.register()
            launchAtLoginStatus = launchAtLoginManager.status
            if launchAtLoginStatus == .requiresApproval {
                shouldShowLaunchAtLoginApproval = true
            }
        } catch {
            launchAtLoginStatus = launchAtLoginManager.status
            reportError(
                String(
                    format: String(localized: "error.loginItem", defaultValue: "Could not update Launch at Login: %@"),
                    error.localizedDescription
                )
            )
        }
    }

    private func installWakeObserver() {
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.retryDesiredConnectionsAfterWake()
            }
        }
    }

    private func nextAvailableDisplayName() -> String {
        let baseName = String(localized: "display.defaultName", defaultValue: "Virtual Screen")
        let existingNames = Set(profiles.map(\.name))
        var number = 1
        while existingNames.contains("\(baseName) \(number)") {
            number += 1
        }
        return "\(baseName) \(number)"
    }

    private func backendUnavailableMessage() -> String {
        if case let .unavailable(reason) = backendAvailability { return reason }
        return String(localized: "error.apiUnavailable", defaultValue: "This version of macOS does not provide the required virtual display API.")
    }

    private func reportError(_ message: String) {
        lastErrorMessage = message
        logger.error("\(message, privacy: .public)")
    }

    private func save() {
        persistedState.version = PersistedState.currentVersion
        persistedState.profiles = profiles
        repository.save(persistedState)
    }
}
