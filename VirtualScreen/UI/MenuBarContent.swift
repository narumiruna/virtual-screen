import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: VirtualDisplayStore

    var body: some View {
        Group {
            if case let .unavailable(reason) = store.backendAvailability {
                Text(reason)
            }

            if store.profiles.isEmpty {
                Text("menu.noDisplays")
            } else {
                ForEach(store.profiles) { profile in
                    profileMenu(profile)
                }
            }

            Divider()
            addDisplayMenu
            Divider()

            Toggle(
                "menu.launchAtLogin",
                isOn: Binding(
                    get: { store.launchAtLoginStatus == .enabled },
                    set: updateLaunchAtLogin
                )
            )
            .disabled(store.launchAtLoginStatus == .unavailable)

            Button("menu.about") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }

            Divider()

            Button("menu.quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            presentPendingMessages()
        }
    }

    @ViewBuilder
    private func profileMenu(_ profile: VirtualDisplayProfile) -> some View {
        let state = store.state(for: profile.id)
        Menu {
            Button(statusText(for: state)) {}
                .disabled(true)

            if state.isConnected || state.isBusy {
                Button("menu.disconnect") {
                    store.disconnectProfile(id: profile.id)
                }
                .disabled(state.isBusy)
            } else {
                Button("menu.connect") {
                    Task {
                        await store.connectProfile(id: profile.id)
                        presentStoreErrorIfNeeded()
                    }
                }
            }

            resolutionMenu(for: profile, state: state)

            Divider()

            Button("menu.rename") {
                guard let name = DialogPresenter.requestName(currentName: profile.name) else { return }
                Task {
                    await store.renameProfile(id: profile.id, to: name)
                    presentStoreErrorIfNeeded()
                }
            }
            .disabled(state.isBusy)

            Button("menu.remove") {
                if state.isConnected && !DialogPresenter.confirmRemoval(name: profile.name) {
                    return
                }
                store.removeProfile(id: profile.id)
            }
            .disabled(state.isBusy)
        } label: {
            Label(profileLabel(profile), systemImage: statusSymbol(for: state))
        }
    }

    private func resolutionMenu(
        for profile: VirtualDisplayProfile,
        state: DisplayConnectionState
    ) -> some View {
        Menu("menu.resolution") {
            ForEach(DisplayAspectRatio.allCases) { aspectRatio in
                Menu(aspectRatio.localizedName) {
                    ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
                        Button {
                            selectResolution(preset, for: profile.id)
                        } label: {
                            if profile.resolutionID == preset.id {
                                Label(preset.displayName, systemImage: "checkmark")
                            } else {
                                Text(preset.displayName)
                            }
                        }
                    }
                }
            }
        }
        .disabled(state.isBusy)
    }

    private var addDisplayMenu: some View {
        Menu("menu.addDisplay") {
            ForEach(DisplayAspectRatio.allCases) { aspectRatio in
                Menu(aspectRatio.localizedName) {
                    ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
                        Button(preset.displayName) {
                            addDisplay(preset)
                        }
                    }
                }
            }
        }
        .disabled(!store.backendAvailability.isAvailable)
    }

    private func addDisplay(_ resolution: ResolutionPreset) {
        guard approve8KIfNeeded(resolution) else { return }
        Task {
            await store.addDisplay(resolution: resolution)
            presentStoreErrorIfNeeded()
        }
    }

    private func selectResolution(_ resolution: ResolutionPreset, for profileID: UUID) {
        guard approve8KIfNeeded(resolution) else { return }
        Task {
            await store.setResolution(resolution, for: profileID)
            presentStoreErrorIfNeeded()
        }
    }

    private func approve8KIfNeeded(_ resolution: ResolutionPreset) -> Bool {
        guard store.needs8KWarning(for: resolution) else { return true }
        guard DialogPresenter.confirm8K() else { return false }
        store.acknowledge8KWarning()
        return true
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        store.setLaunchAtLoginEnabled(enabled)
        if store.shouldShowLaunchAtLoginApproval {
            DialogPresenter.showLaunchAtLoginApproval {
                store.openLoginItemSettings()
            }
            store.clearLaunchAtLoginApprovalNotice()
        }
        presentStoreErrorIfNeeded()
    }

    private func presentPendingMessages() {
        if store.shouldShowLaunchAtLoginApproval {
            DialogPresenter.showLaunchAtLoginApproval {
                store.openLoginItemSettings()
            }
            store.clearLaunchAtLoginApprovalNotice()
        }
        presentStoreErrorIfNeeded()
    }

    private func presentStoreErrorIfNeeded() {
        guard let message = store.takeLastErrorMessage() else { return }
        DialogPresenter.showError(message)
    }

    private func profileLabel(_ profile: VirtualDisplayProfile) -> String {
        let resolutionName = profile.resolution?.displayName ?? profile.resolutionID
        return "\(profile.name) — \(resolutionName)"
    }

    private func statusText(for state: DisplayConnectionState) -> String {
        switch state {
        case .disconnected:
            return String(localized: "status.disconnected", defaultValue: "Disconnected")
        case .connecting:
            return String(localized: "status.connecting", defaultValue: "Connecting…")
        case let .connected(displayID):
            return String(
                format: String(localized: "status.connected", defaultValue: "Connected (Display ID %u)"),
                displayID
            )
        case let .failed(message):
            return String(
                format: String(localized: "status.failed", defaultValue: "Disconnected: %@"),
                message
            )
        }
    }

    private func statusSymbol(for state: DisplayConnectionState) -> String {
        switch state {
        case .connected: return "display"
        case .connecting: return "ellipsis.circle"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "display.slash"
        }
    }
}
