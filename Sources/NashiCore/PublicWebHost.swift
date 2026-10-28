import Foundation
import Network

/// Rejects loopback, link-local, private, and other non-routable literal hosts
/// so web downloads cannot target local services or cloud metadata endpoints.
enum PublicWebHost {
    static func allows(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !name.isEmpty else { return false }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") {
            return false
        }
        if let address = IPv4Address(name) { return isPublic(address) }
        if let address = IPv6Address(name) { return isPublic(address) }
        return true
    }

    private static func isPublic(_ address: IPv4Address) -> Bool {
        if address.isLoopback || address.isLinkLocal || address.isMulticast { return false }
        let o = [UInt8](address.rawValue)
        guard o.count == 4 else { return false }
        if o[0] == 0 { return false }
        if o[0] == 10 { return false }
        if o[0] == 100 && (o[1] & 0xC0) == 64 { return false }
        if o[0] == 172 && (o[1] & 0xF0) == 16 { return false }
        if o[0] == 192 && o[1] == 168 { return false }
        if o[0] == 192 && o[1] == 0 && (o[2] == 0 || o[2] == 2) { return false }
        if o[0] == 198 && (o[1] == 18 || o[1] == 19) { return false }
        if o[0] == 198 && o[1] == 51 && o[2] == 100 { return false }
        if o[0] == 203 && o[1] == 0 && o[2] == 113 { return false }
        if o[0] >= 240 { return false }
        return true
    }

    private static func isPublic(_ address: IPv6Address) -> Bool {
        if address.isLoopback || address.isLinkLocal || address.isMulticast { return false }
        let b = [UInt8](address.rawValue)
        guard b.count == 16 else { return false }
        // Unique-local fc00::/7
        if (b[0] & 0xfe) == 0xfc { return false }
        // Unspecified ::
        if b.allSatisfy({ $0 == 0 }) { return false }
        // IPv4-mapped ::ffff:0:0/96 — apply the same IPv4 policy.
        if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff,
           let mapped = IPv4Address("\(b[12]).\(b[13]).\(b[14]).\(b[15])") {
            return isPublic(mapped)
        }
        return true
    }
}
