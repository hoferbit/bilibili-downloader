import Foundation

/// 轻量的 JSON 访问器，B 站接口字段多且形态不一，用下标取值比定义一堆 Decodable 更省事。
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return JSON(nil) }
        return JSON(a[index])
    }

    public var isNull: Bool { raw == nil || raw is NSNull }

    public var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    public var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    public var int64: Int64? {
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s) }
        return nil
    }

    public var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    public var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    public var array: [JSON] {
        (raw as? [Any])?.map(JSON.init) ?? []
    }

    public var stringArray: [String] {
        array.compactMap(\.string)
    }
}
