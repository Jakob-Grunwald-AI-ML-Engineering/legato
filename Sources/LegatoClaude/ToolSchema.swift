import Foundation

public struct ToolSchema: Codable, Sendable {
    public let name: String
    public let description: String
    public let strict: Bool = true
    public let eager_input_streaming: Bool = true
    public let input_schema: Schema
    public init(name: String, description: String, properties: [String: Schema], required: [String]) {
        self.name = name; self.description = description
        input_schema = Schema(type: "object", properties: properties, required: required, additionalProperties: false)
    }
    public final class Schema: Codable, Sendable {
        public let type: String
        public let properties: [String: Schema]?
        public let required: [String]?
        public let additionalProperties: Bool?
        public let items: Schema?
        public let enumValues: [String]?
        private enum CodingKeys: String, CodingKey {
            case type, properties, required, additionalProperties, items
            case enumValues = "enum"
        }
        public init(type: String, properties: [String: Schema]? = nil, required: [String]? = nil,
                    additionalProperties: Bool? = nil, items: Schema? = nil, enumValues: [String]? = nil) {
            self.type = type; self.properties = properties; self.required = required
            self.additionalProperties = additionalProperties; self.items = items; self.enumValues = enumValues
        }
    }
}
