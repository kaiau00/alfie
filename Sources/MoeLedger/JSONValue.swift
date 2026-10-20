import Foundation

/// Any JSON value, kept whole.
///
/// A record body is decoded into this rather than into a per-kind struct so
/// that a record written by a newer version — a kind this build has never
/// heard of, or a field added to a kind it has — survives a read/write cycle
/// with nothing dropped. An older reader that silently discarded fields would
/// re-hash to a different id and split the ledger in two.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// An integer, and only an integer: a `bytes` of `4211.0` is a record
    /// somebody else wrote, and reading it as 4211 would let a document
    /// through that a stricter reader refuses.
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    // MARK: Bridging to JSONSerialization

    /// The Foundation object this value serialises as. `NSNull` rather than
    /// `nil` so a key with a null value keeps its place in the canonical form.
    public var anyValue: Any {
        switch self {
        case .null:             return NSNull()
        case .bool(let b):      return b
        case .int(let i):       return i
        case .double(let d):    return d
        case .string(let s):    return s
        case .array(let a):     return a.map(\.anyValue)
        case .object(let o):    return o.mapValues(\.anyValue)
        }
    }

    /// Nil for anything `JSONSerialization` can hand back that is not JSON
    /// (it cannot, today) — so a malformed record is skipped, never fatal.
    public init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // NSNumber erases the difference between 1, 1.0 and true; the
            // objCType is the only thing that still knows, and getting this
            // wrong would change the canonical bytes and so the record id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f" {
                self = .double(n.doubleValue)
            } else { self = .int(n.intValue) }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for element in a {
                guard let v = JSONValue(any: element) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                guard let value = JSONValue(any: v) else { return nil }
                out[k] = value
            }
            self = .object(out)
        default:
            return nil
        }
    }

    // MARK: Building

    public static func of(_ pairs: [String: JSONValue?]) -> JSONValue {
        .object(pairs.compactMapValues { $0 })
    }
}
