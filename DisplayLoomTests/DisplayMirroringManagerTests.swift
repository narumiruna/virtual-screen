import CoreGraphics
import XCTest

@testable import DisplayLoom

@MainActor
final class DisplayMirroringManagerTests: XCTestCase {
  func testMainDisplayUUIDResolvesToCurrentDisplayID() throws {
    let displayID = CGMainDisplayID()
    let uuid = try XCTUnwrap(DisplayUUID.uuid(for: displayID))

    XCTAssertEqual(DisplayUUID.displayID(for: uuid), displayID)
  }

  func testAvailableSourcesExcludesProvidedDisplayIDs() throws {
    let displayID = CGMainDisplayID()
    let uuid = try XCTUnwrap(DisplayUUID.uuid(for: displayID))
    let manager = DisplayMirroringManager()

    let sources = try manager.availableSources(excluding: [displayID])

    XCTAssertFalse(sources.contains(where: { $0.id == uuid }))
  }

  func testAvailableSourcesExcludeDisplayLoomVendor() throws {
    let manager = DisplayMirroringManager()

    let sources = try manager.availableSources(excluding: [])

    for source in sources {
      let displayID = try XCTUnwrap(DisplayUUID.displayID(for: source.id))
      XCTAssertNotEqual(
        CGDisplayVendorNumber(displayID),
        StableDisplayIdentity.virtualDisplayVendorID
      )
    }
  }
}
