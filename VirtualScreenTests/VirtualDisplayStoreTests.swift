import XCTest

@testable import VirtualScreen

@MainActor
final class VirtualDisplayStoreTests: XCTestCase {
  func testAddConnectsAndPersistsProfile() async {
    let environment = makeEnvironment()
    let preset = ResolutionPreset.preset(withID: "1920x1080")!

    await environment.store.addDisplay(resolution: preset)

    XCTAssertEqual(environment.store.profiles.count, 1)
    XCTAssertEqual(environment.store.profiles[0].name, "Display Loom 1")
    XCTAssertEqual(environment.store.profiles[0].resolutionID, preset.id)
    XCTAssertTrue(environment.store.profiles[0].desiredConnected)
    XCTAssertTrue(environment.store.state(for: environment.store.profiles[0].id).isConnected)
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testMultipleDisplaysOperateIndependently() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1200")!)
    let first = environment.store.profiles[0]
    let second = environment.store.profiles[1]

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "3840x2400")!,
      for: second.id
    )

    XCTAssertEqual(environment.store.profile(id: first.id)?.resolutionID, "1920x1080")
    XCTAssertEqual(environment.store.profile(id: second.id)?.resolutionID, "3840x2400")
    XCTAssertEqual(environment.backend.resolutionRequests.count, 1)
    XCTAssertEqual(environment.backend.resolutionRequests[0].0, "3840x2400")
    XCTAssertTrue(environment.store.state(for: first.id).isConnected)
    XCTAssertTrue(environment.store.state(for: second.id).isConnected)
  }

  func testDisconnectReconnectRenameAndRemove() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstConnection = environment.backend.connections[profileID]!

    environment.store.disconnectProfile(id: profileID)
    XCTAssertTrue(firstConnection.invalidated)
    XCTAssertEqual(environment.store.state(for: profileID), .disconnected)
    XCTAssertFalse(environment.store.profile(id: profileID)!.desiredConnected)

    await environment.store.connectProfile(id: profileID)
    let secondConnection = environment.backend.connections[profileID]!
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)

    await environment.store.renameProfile(id: profileID, to: "Studio")
    XCTAssertTrue(secondConnection.invalidated)
    XCTAssertEqual(environment.store.profile(id: profileID)?.name, "Studio")
    XCTAssertEqual(environment.backend.connectRequests.last?.0.name, "Studio")

    let latestConnection = environment.backend.connections[profileID]!
    environment.store.removeProfile(id: profileID)
    XCTAssertTrue(latestConnection.invalidated)
    XCTAssertTrue(environment.store.profiles.isEmpty)
    XCTAssertTrue(environment.repository.state.profiles.isEmpty)
  }

  func testConnectedResolutionChangeRollsBackOnFailure() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.backend.setResolutionError = VirtualDisplayBackendError.modeSwitchFailed

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "3840x2160")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "1920x1080")
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  func testDisconnectedResolutionChangeIsSavedWithoutBackendCall() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.store.disconnectProfile(id: profileID)

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "2560x1440")
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertEqual(environment.store.state(for: profileID), .disconnected)
  }

  func testStartRestoresOnlyDesiredConnections() async {
    let desired = VirtualDisplayProfile(
      name: "Desired", resolutionID: "1920x1080", desiredConnected: true)
    let disabled = VirtualDisplayProfile(
      name: "Disabled", resolutionID: "1920x1200", desiredConnected: false)
    let repository = MemoryStateRepository(
      state: PersistedState(
        profiles: [desired, disabled],
        hasAttemptedLoginItemRegistration: true
      )
    )
    let backend = FakeVirtualDisplayBackend()
    let loginManager = FakeLaunchAtLoginManager()
    let mirroringManager = FakeDisplayMirroringManager()
    let store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: loginManager,
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )

    await store.start()

    XCTAssertEqual(backend.connectRequests.map(\.0.id), [desired.id])
    XCTAssertTrue(store.state(for: desired.id).isConnected)
    XCTAssertEqual(store.state(for: disabled.id), .disconnected)
    XCTAssertEqual(loginManager.registerCallCount, 0)
  }

  func testTerminationUpdatesStateAndWakeRetriesOnce() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id

    environment.backend.terminate(profileID: profileID)
    await Task.yield()
    await Task.yield()

    guard case .failed = environment.store.state(for: profileID) else {
      return XCTFail("Expected a failed state after termination")
    }
    let requestCountAfterTermination = environment.backend.connectRequests.count

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(environment.backend.connectRequests.count, requestCountAfterTermination + 1)
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
  }

  func testWakeReconnectsAnInvalidHandleWithoutTerminationCallback() async {
    let environment = makeEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstConnection = environment.backend.connections[profileID]!
    firstConnection.invalidate()
    let initialRequestCount = environment.backend.connectRequests.count

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(environment.backend.connectRequests.count, initialRequestCount + 1)
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
    XCTAssertFalse(environment.backend.connections[profileID] === firstConnection)
  }

  func testConnectFailureKeepsDesiredProfileForRetry() async {
    let environment = makeEnvironment()
    environment.backend.connectError = VirtualDisplayBackendError.creationFailed

    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)

    let profile = environment.store.profiles[0]
    XCTAssertTrue(profile.desiredConnected)
    guard case .failed = environment.store.state(for: profile.id) else {
      return XCTFail("Expected failed state")
    }
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  func test8KWarningAcknowledgementPersists() {
    let environment = makeEnvironment()
    let eightK = ResolutionPreset.preset(withID: "7680x4320")!

    XCTAssertTrue(environment.store.needs8KWarning(for: eightK))
    environment.store.acknowledge8KWarning()

    XCTAssertFalse(environment.store.needs8KWarning(for: eightK))
    XCTAssertTrue(environment.repository.state.hasAcknowledged8KWarning)
  }

  func testFirstStartRegistersLoginItemOnlyOnce() async {
    let environment = makeEnvironment()

    await environment.store.start()
    await environment.store.start()

    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    XCTAssertTrue(environment.repository.state.hasAttemptedLoginItemRegistration)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .enabled)
  }

  func testLoginItemApprovalStateIsExposed() async {
    let environment = makeEnvironment()
    environment.loginManager.status = .requiresApproval

    await environment.store.start()

    XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
    environment.store.openLoginItemSettings()
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 1)
    environment.store.clearLaunchAtLoginApprovalNotice()
    XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
  }

  func testSelectingAndClearingMirrorSourcePersistsOnlySuccessfulChanges() async {
    let environment = makeEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let targetDisplayID = environment.backend.connections[profileID]!.displayID

    environment.store.setMirrorSource(source.id, for: profileID)

    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profileID], source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)
    )
    XCTAssertEqual(environment.repository.state.profiles[0].mirrorSourceID, source.id)

    environment.mirroringManager.setMirrorError = DisplayMirroringError.configurationFailed(1)
    environment.store.setMirrorSource(UUID(), for: profileID)

    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profileID], source.id)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())

    environment.mirroringManager.setMirrorError = nil
    environment.mirroringManager.onMirrorChange = {
      environment.store.handleDisplayReconfiguration()
    }
    environment.store.setMirrorSource(nil, for: profileID)

    XCTAssertNil(environment.store.profile(id: profileID)?.mirrorSourceID)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profileID])
    XCTAssertNil(environment.mirroringManager.mirrorSourceID(for: targetDisplayID))
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: nil)
    )
  }

  func testStartRestoresPersistedMirrorAfterConnecting() async {
    let source = makeMirrorSource()
    let profile = VirtualDisplayProfile(
      name: "Mirrored",
      resolutionID: "1920x1080",
      mirrorSourceID: source.id
    )
    let repository = MemoryStateRepository(
      state: PersistedState(
        profiles: [profile],
        hasAttemptedLoginItemRegistration: true
      )
    )
    let backend = FakeVirtualDisplayBackend()
    let mirroringManager = FakeDisplayMirroringManager()
    mirroringManager.sources = [source]
    let store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: FakeLaunchAtLoginManager(),
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )

    await store.start()

    let targetDisplayID = backend.connections[profile.id]!.displayID
    XCTAssertEqual(
      mirroringManager.mirrorRequests,
      [MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)]
    )
    XCTAssertTrue(store.isMirroring(profileID: profile.id))
    XCTAssertTrue(mirroringManager.excludedDisplayIDSets.contains([targetDisplayID]))
  }

  func testRestoreFailureExposesActualStateAndClearsAfterRetry() async {
    let source = makeMirrorSource()
    let profile = VirtualDisplayProfile(
      name: "Mirrored",
      resolutionID: "1920x1080",
      mirrorSourceID: source.id
    )
    let repository = MemoryStateRepository(
      state: PersistedState(
        profiles: [profile],
        hasAttemptedLoginItemRegistration: true
      )
    )
    let backend = FakeVirtualDisplayBackend()
    let mirroringManager = FakeDisplayMirroringManager()
    mirroringManager.sources = [source]
    mirroringManager.setMirrorError = DisplayMirroringError.configurationFailed(1)
    let store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: FakeLaunchAtLoginManager(),
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )

    await store.start()

    XCTAssertEqual(store.profile(id: profile.id)?.mirrorSourceID, source.id)
    XCTAssertNil(store.activeMirrorSourceIDs[profile.id])
    XCTAssertTrue(store.hasMirrorRestoreFailure(profileID: profile.id))

    mirroringManager.setMirrorError = nil
    store.handleDisplayReconfiguration()

    XCTAssertEqual(store.activeMirrorSourceIDs[profile.id], source.id)
    XCTAssertFalse(store.hasMirrorRestoreFailure(profileID: profile.id))
  }

  func testReconnectUsesNewTargetAndKeepsDesiredMirrorSource() async {
    let environment = makeEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstTarget = environment.backend.connections[profileID]!.displayID
    environment.store.setMirrorSource(source.id, for: profileID)

    environment.store.disconnectProfile(id: profileID)
    await environment.store.connectProfile(id: profileID)

    let secondTarget = environment.backend.connections[profileID]!.displayID
    XCTAssertNotEqual(secondTarget, firstTarget)
    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.suffix(2),
      [
        MirrorRequest(targetDisplayID: firstTarget, sourceID: nil),
        MirrorRequest(targetDisplayID: secondTarget, sourceID: source.id),
      ]
    )
  }

  func testUnavailableSourceRestoresWhenItReappearsWithoutReentrantLoop() async {
    let source = makeMirrorSource()
    let profile = VirtualDisplayProfile(
      name: "Mirrored",
      resolutionID: "1920x1080",
      mirrorSourceID: source.id
    )
    let repository = MemoryStateRepository(
      state: PersistedState(
        profiles: [profile],
        hasAttemptedLoginItemRegistration: true
      )
    )
    let backend = FakeVirtualDisplayBackend()
    let mirroringManager = FakeDisplayMirroringManager()
    let store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: FakeLaunchAtLoginManager(),
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )
    await store.start()
    XCTAssertTrue(mirroringManager.mirrorRequests.isEmpty)
    XCTAssertEqual(store.profile(id: profile.id)?.mirrorSourceID, source.id)
    XCTAssertFalse(store.hasMirrorRestoreFailure(profileID: profile.id))

    mirroringManager.sources = [source]
    mirroringManager.onMirrorChange = { store.handleDisplayReconfiguration() }
    store.handleDisplayReconfiguration()

    let targetDisplayID = backend.connections[profile.id]!.displayID
    XCTAssertEqual(
      mirroringManager.mirrorRequests,
      [MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)]
    )
    XCTAssertTrue(store.isMirroring(profileID: profile.id))
  }

  func testWakeRestoresMirrorIfSystemClearedIt() async {
    let environment = makeEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let targetDisplayID = environment.backend.connections[profileID]!.displayID
    environment.store.setMirrorSource(source.id, for: profileID)
    environment.mirroringManager.simulateActualMirror(
      targetDisplayID: targetDisplayID, sourceID: nil)

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)
    )
    XCTAssertTrue(environment.store.isMirroring(profileID: profileID))
  }

  func testDisconnectRemoveAndTerminationClearActualMirror() async {
    let source = makeMirrorSource()

    let disconnectEnvironment = makeEnvironment()
    disconnectEnvironment.mirroringManager.sources = [source]
    await disconnectEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let disconnectedID = disconnectEnvironment.store.profiles[0].id
    let disconnectedTarget = disconnectEnvironment.backend.connections[disconnectedID]!.displayID
    disconnectEnvironment.store.setMirrorSource(source.id, for: disconnectedID)
    disconnectEnvironment.store.disconnectProfile(id: disconnectedID)
    XCTAssertEqual(
      disconnectEnvironment.store.profile(id: disconnectedID)?.mirrorSourceID, source.id)
    XCTAssertEqual(
      disconnectEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: disconnectedTarget, sourceID: nil)
    )

    let removeEnvironment = makeEnvironment()
    removeEnvironment.mirroringManager.sources = [source]
    await removeEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let removedID = removeEnvironment.store.profiles[0].id
    let removedTarget = removeEnvironment.backend.connections[removedID]!.displayID
    removeEnvironment.store.setMirrorSource(source.id, for: removedID)
    removeEnvironment.store.removeProfile(id: removedID)
    XCTAssertEqual(
      removeEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: removedTarget, sourceID: nil)
    )
    XCTAssertTrue(removeEnvironment.repository.state.profiles.isEmpty)

    let terminationEnvironment = makeEnvironment()
    terminationEnvironment.mirroringManager.sources = [source]
    await terminationEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let terminatedID = terminationEnvironment.store.profiles[0].id
    let terminatedTarget = terminationEnvironment.backend.connections[terminatedID]!.displayID
    terminationEnvironment.store.setMirrorSource(source.id, for: terminatedID)
    terminationEnvironment.backend.terminate(profileID: terminatedID)
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(
      terminationEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: terminatedTarget, sourceID: nil)
    )
    XCTAssertNil(terminationEnvironment.store.activeMirrorSourceIDs[terminatedID])
  }

  func testResolutionChangeIsRejectedWhileMirroring() async {
    let environment = makeEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.store.setMirrorSource(source.id, for: profileID)

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "1920x1080")
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  private func makeMirrorSource() -> DisplayMirrorSource {
    DisplayMirrorSource(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Studio Display"
    )
  }

  private func makeEnvironment() -> (
    store: VirtualDisplayStore,
    backend: FakeVirtualDisplayBackend,
    repository: MemoryStateRepository,
    loginManager: FakeLaunchAtLoginManager,
    mirroringManager: FakeDisplayMirroringManager
  ) {
    let backend = FakeVirtualDisplayBackend()
    let repository = MemoryStateRepository()
    let loginManager = FakeLaunchAtLoginManager()
    let mirroringManager = FakeDisplayMirroringManager()
    let store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: loginManager,
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )
    return (store, backend, repository, loginManager, mirroringManager)
  }
}
