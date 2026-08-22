import Foundation

struct VirtualDisplayProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var resolutionID: String
    var desiredConnected: Bool

    init(
        id: UUID = UUID(),
        name: String,
        resolutionID: String,
        desiredConnected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.resolutionID = resolutionID
        self.desiredConnected = desiredConnected
    }

    var resolution: ResolutionPreset? {
        ResolutionPreset.preset(withID: resolutionID)
    }
}
