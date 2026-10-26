import Foundation

public enum SpaceResult: Sendable, Equatable {
    case insertSpace
    /// Delete the space before the cursor and insert ". ".
    case replacePreviousSpaceWithPeriodSpace
}

public enum SpaceRules {
    public static let doublePeriodWindow: TimeInterval = 0.4

    public static func spaceTapped(context: TextContext, lastSpaceAt: Date?, now: Date) -> SpaceResult {
        guard let lastSpaceAt, now.timeIntervalSince(lastSpaceAt) <= doublePeriodWindow else { return .insertSpace }
        let chars = Array(context.before.suffix(2))
        guard chars.count == 2, chars[1] == " ", chars[0].isLetter || chars[0].isNumber else { return .insertSpace }
        return .replacePreviousSpaceWithPeriodSpace
    }
}
