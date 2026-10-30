import Foundation

public struct BridgeCommand: Decodable, Equatable {
    public var id: String
    public var command: String
    public var args: [String] = []

    public init(id: String, command: String, args: [String] = []) {
        self.id = id
        self.command = command
        self.args = args
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, command, args }

    public static func decode(_ data: Data) -> BridgeCommand? { try? JSONDecoder().decode(BridgeCommand.self, from: data) }
}

