import Foundation

/// Decodes a JSON value that is usually a string but occasionally a number
/// (e.g. Codex `credits.balance` is a string like "0" / "766.76", but we don't
/// want a schema drift to a numeric type to break the whole parse).
public struct FlexibleString: Decodable, Sendable, Hashable {
    public let value: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let d = try? c.decode(Double.self) {
            // Print integers without a trailing ".0".
            value = d == d.rounded() ? String(Int(d)) : String(d)
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else {
            value = nil
        }
    }
}
