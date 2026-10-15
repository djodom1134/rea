import Foundation

/// Email-to-MMS gateway from `MobileCarriers/Carriers.txt`
/// (lines of `Name, @gateway, logo`).
public struct MobileCarrier: Hashable, Codable, Sendable {
    public var name: String
    public var gatewayDomain: String
    public var logoFile: String?

    public init(name: String, gatewayDomain: String, logoFile: String?) {
        self.name = name
        self.gatewayDomain = gatewayDomain
        self.logoFile = logoFile
    }

    public static func parseList(_ text: String) -> [MobileCarrier] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            var domain = fields[1]
            if domain.hasPrefix("@") { domain.removeFirst() }
            guard !domain.isEmpty, !domain.contains(" ") else { return nil }
            let logo = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
            return MobileCarrier(name: fields[0], gatewayDomain: domain, logoFile: logo)
        }
    }

    /// The gateway address for a 10-digit North American number, or nil.
    public func address(forPhone phone: String) -> String? {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11 && digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count == 10 else { return nil }
        return "\(digits)@\(gatewayDomain)"
    }
}
