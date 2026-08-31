import AppKit
import ColorSync
import CoreGraphics
import Foundation

struct DisplayMirrorSource: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

enum DisplayUUID {
    static func uuid(for displayID: CGDirectDisplayID) -> UUID? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let displayUUID = unmanagedUUID.takeRetainedValue()
        let value = CFUUIDCreateString(nil, displayUUID) as String
        return UUID(uuidString: value)
    }

    static func displayID(for uuid: UUID) -> CGDirectDisplayID? {
        guard let displayUUID = CFUUIDCreateFromString(nil, uuid.uuidString as CFString) else {
            return nil
        }
        let displayID = CGDisplayGetDisplayIDFromUUID(displayUUID)
        return displayID == kCGNullDirectDisplay ? nil : displayID
    }
}

@MainActor
protocol DisplayMirroringManaging: AnyObject {
    func availableSources(excluding displayIDs: Set<CGDirectDisplayID>) throws -> [DisplayMirrorSource]
    func mirrorSourceID(for targetDisplayID: CGDirectDisplayID) -> UUID?
    func setMirror(targetDisplayID: CGDirectDisplayID, sourceID: UUID?) throws
}

enum DisplayMirroringError: LocalizedError, Equatable, Sendable {
    case displayListFailed(Int32)
    case targetUnavailable
    case sourceUnavailable
    case configurationFailed(Int32)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .displayListFailed(code):
            return String(
                format: String(localized: "error.displayList", defaultValue: "Could not list displays (CoreGraphics error %d)."),
                code
            )
        case .targetUnavailable:
            return String(localized: "error.mirrorTargetUnavailable", defaultValue: "The virtual display is no longer available.")
        case .sourceUnavailable:
            return String(localized: "error.mirrorSourceUnavailable", defaultValue: "The selected source display is not available.")
        case let .configurationFailed(code):
            return String(
                format: String(localized: "error.mirroring", defaultValue: "Could not update display mirroring (CoreGraphics error %d)."),
                code
            )
        case .verificationFailed:
            return String(localized: "error.mirrorVerification", defaultValue: "macOS did not apply the requested display mirroring setting.")
        }
    }
}

@MainActor
final class DisplayMirroringManager: DisplayMirroringManaging {
    func availableSources(excluding displayIDs: Set<CGDirectDisplayID>) throws -> [DisplayMirrorSource] {
        let candidates = try onlineDisplayIDs()
            .filter {
                !displayIDs.contains($0) &&
                    CGDisplayVendorNumber($0) != StableDisplayIdentity.virtualDisplayVendorID
            }
            .compactMap { displayID -> (UUID, String, CGDirectDisplayID)? in
                guard let uuid = DisplayUUID.uuid(for: displayID) else { return nil }
                return (uuid, displayName(for: displayID), displayID)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.2 < rhs.2 }
                return lhs.1.localizedStandardCompare(rhs.1) == .orderedAscending
            }

        let nameCounts = Dictionary(grouping: candidates, by: { $0.1 }).mapValues(\.count)
        var nameIndexes: [String: Int] = [:]

        return candidates.map { uuid, name, _ in
            guard nameCounts[name, default: 0] > 1 else {
                return DisplayMirrorSource(id: uuid, name: name)
            }
            let index = nameIndexes[name, default: 0] + 1
            nameIndexes[name] = index
            let numberedName = String(
                format: String(localized: "display.numberedName", defaultValue: "%@ (%d)"),
                name,
                index
            )
            return DisplayMirrorSource(id: uuid, name: numberedName)
        }
    }

    func mirrorSourceID(for targetDisplayID: CGDirectDisplayID) -> UUID? {
        let sourceDisplayID = CGDisplayMirrorsDisplay(targetDisplayID)
        guard sourceDisplayID != kCGNullDirectDisplay else { return nil }
        return DisplayUUID.uuid(for: sourceDisplayID)
    }

    func setMirror(targetDisplayID: CGDirectDisplayID, sourceID: UUID?) throws {
        guard CGDisplayIsOnline(targetDisplayID) != 0 else {
            throw DisplayMirroringError.targetUnavailable
        }

        let sourceDisplayID: CGDirectDisplayID
        if let sourceID {
            guard let resolvedDisplayID = DisplayUUID.displayID(for: sourceID),
                  CGDisplayIsOnline(resolvedDisplayID) != 0,
                  resolvedDisplayID != targetDisplayID else {
                throw DisplayMirroringError.sourceUnavailable
            }
            sourceDisplayID = resolvedDisplayID
        } else {
            sourceDisplayID = kCGNullDirectDisplay
        }

        guard CGDisplayMirrorsDisplay(targetDisplayID) != sourceDisplayID else { return }

        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else {
            throw DisplayMirroringError.configurationFailed(beginError.rawValue)
        }

        let configureError = CGConfigureDisplayMirrorOfDisplay(
            configuration,
            targetDisplayID,
            sourceDisplayID
        )
        guard configureError == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayMirroringError.configurationFailed(configureError.rawValue)
        }

        let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completeError == .success else {
            throw DisplayMirroringError.configurationFailed(completeError.rawValue)
        }

        guard CGDisplayMirrorsDisplay(targetDisplayID) == sourceDisplayID else {
            throw DisplayMirroringError.verificationFailed
        }
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = CGGetOnlineDisplayList(0, nil, &count)
        guard countError == .success else {
            throw DisplayMirroringError.displayListFailed(countError.rawValue)
        }
        guard count > 0 else { return [] }

        var displayIDs = Array(repeating: kCGNullDirectDisplay, count: Int(count))
        let listError = CGGetOnlineDisplayList(count, &displayIDs, &count)
        guard listError == .success else {
            throw DisplayMirroringError.displayListFailed(listError.rawValue)
        }
        return Array(displayIDs.prefix(Int(count)))
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[screenNumberKey] as? NSNumber else { return false }
            return number.uint32Value == displayID
        }) {
            return screen.localizedName
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            return String(localized: "display.builtInName", defaultValue: "Built-in Display")
        }
        return String(localized: "display.externalName", defaultValue: "External Display")
    }
}
