import Foundation

struct StableDisplayIdentity: Equatable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    init(profileID: UUID) {
        let bytes = withUnsafeBytes(of: profileID.uuid) { Array($0) }
        vendorID = 0x4E52 // "NR"
        productID = Self.fnv1a(bytes: bytes + [0x50, 0x52, 0x4F, 0x44])
        serialNumber = Self.fnv1a(bytes: bytes + [0x53, 0x45, 0x52, 0x49])
    }

    private static func fnv1a(bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in bytes {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return value == 0 ? 1 : value
    }
}
