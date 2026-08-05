import Foundation

/// An element that decodes to nil instead of throwing.
///
/// Decoding it always succeeds, which is the point: the outer array's index
/// advances even for a row that failed, so the sequence cannot stall.
struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decode a list, dropping rows that fail rather than failing the document.
    ///
    /// `/usage` is decoded whole, under one `try`, by every client. A single
    /// required key missing from a single row of `by_day` would otherwise
    /// throw past the chart, past the snapshot, and blank the entire popover —
    /// over one row of one list. Losing the row loses a bar in a chart, which
    /// is the proportionate failure. See docs/contract.md.
    ///
    /// A row that fails is dropped silently on purpose: the host is the only
    /// thing that can produce one, this is the client's last line of defence,
    /// and there is no screen on which "row 4 of by_day was malformed" is
    /// something to say to the person holding the phone.
    func decodeLossyArrayIfPresent<Element: Decodable>(
        _ type: Element.Type, forKey key: Key
    ) throws -> [Element]? {
        guard let rows = try decodeIfPresent(
            [Failable<Element>].self, forKey: key) else { return nil }
        return rows.compactMap(\.value)
    }
}
