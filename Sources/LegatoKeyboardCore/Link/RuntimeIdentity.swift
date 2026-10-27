import Foundation

/// One identity for every process in an app composition. The widgets compile this Foundation-only source too.
public struct RuntimeIdentity: Sendable, Equatable {
    public let appGroupID: String
    public let urlScheme: String
    public let notificationNamespace: String
    public static let groupKey = "LegatoAppGroupID"
    public static let schemeKey = "LegatoURLScheme"
    public static let namespaceKey = "LegatoNotificationNamespace"
    public static let production = RuntimeIdentity(
        appGroupID: "group.de.gruenwald.legato", urlScheme: "legato", notificationNamespace: "de.gruenwald.legato")
    public enum ConfigurationError: Error { case invalidIdentity }
    public static func resolve(info: [String: Any]) throws -> RuntimeIdentity {
        let keys = [groupKey, schemeKey, namespaceKey]
        guard keys.contains(where: { info[$0] != nil }) else { return production }
        guard let group = info[groupKey] as? String,
              let scheme = info[schemeKey] as? String,
              let namespace = info[namespaceKey] as? String,
              group.hasPrefix("group."), validDomain(group), validDomain(namespace),
              scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil
        else { throw ConfigurationError.invalidIdentity }
        return RuntimeIdentity(appGroupID: group, urlScheme: scheme, notificationNamespace: namespace)
    }
    private static func validDomain(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)+$", options: .regularExpression) != nil
    }
    public static let current: RuntimeIdentity = {
        do { return try resolve(info: Bundle.main.infoDictionary ?? [:]) }
        catch { preconditionFailure("Invalid app runtime identity; refusing shared storage and URL access") }
    }()
}
