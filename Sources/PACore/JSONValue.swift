import Foundation

/// A small Codable JSON tree, used for JSON Schema definitions and generic payloads.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(Bool.self) {
            // The decoder bridges every nonzero number to Bool, so 0/1 lose their numeric
            // identity here. Parsing JSON text must go through parse(_:), which is exact.
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var intValue: Int? {
        if case .number(let value) = self, value.rounded() == value { Int(value) } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The authoritative text-to-value path. JSONSerialization keeps booleans and numbers
    /// distinct, which Codable-based decoding cannot guarantee.
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return make(object)
    }

    private static func make(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            .null
        case let number as NSNumber:
            // true/false arrive as __NSCFBoolean, whose objCType is "c"; JSON numbers
            // keep a numeric type letter.
            strcmp(number.objCType, "c") == 0 ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            .string(string)
        case let array as [Any]:
            .array(array.map(make))
        case let object as [String: Any]:
            .object(object.mapValues(make))
        default:
            .null
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order keeps request prefixes byte-identical, which helps provider-side prompt caching.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func prettyPrinted() -> String {
        guard let data = try? encoded() else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}

/// Describes one tool parameter. A plain string literal means a string parameter and doubles
/// as its description, which keeps tool definitions short:
///
///     JSONSchema.object(["path": "文件路径", "limit": .int("最多返回的条目数")], required: ["path"])
public struct JSONProperty: ExpressibleByStringLiteral, Sendable {
    public let schema: JSONValue

    public init(stringLiteral description: String) {
        schema = Self.build("string", description: description)
    }

    public init(_ description: String) {
        schema = Self.build("string", description: description)
    }

    public static func string(_ description: String = "") -> JSONProperty {
        JSONProperty(description)
    }

    public static func int(_ description: String = "") -> JSONProperty {
        JSONProperty(schema: build("integer", description: description))
    }

    public static func bool(_ description: String = "") -> JSONProperty {
        JSONProperty(schema: build("boolean", description: description))
    }

    public static func oneOf(_ values: [String], _ description: String = "") -> JSONProperty {
        var schema = build("string", description: description).objectValue ?? [:]
        schema["enum"] = .array(values.map { .string($0) })
        return JSONProperty(schema: .object(schema))
    }

    public static func object(_ properties: [String: JSONProperty], required: [String] = []) -> JSONProperty {
        JSONProperty(schema: JSONSchema.object(properties, required: required))
    }

    private init(schema: JSONValue) {
        self.schema = schema
    }

    private static func build(_ type: String, description: String) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string(type)]
        if !description.isEmpty {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }
}

/// Builders for the JSON Schema objects that describe tool parameters.
public enum JSONSchema {
    public static func object(_ properties: [String: JSONProperty], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties.mapValues(\.schema)),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }
}

