import Foundation

/// Reads an Objective-C property that UIKit imports as non-optional but may return nil at runtime.
///
/// `UITextDocumentProxy.documentIdentifier` is one: Swift sees a non-optional `UUID`, and the bridge
/// traps (`_unconditionallyBridgeFromObjectiveC`) on the nil the proxy returns while no field is bound.
/// Calling the getter by selector yields an optional object that is cast conditionally, so it never traps.
public enum NilSafeObjC {
    /// The `UUID` the property `property` returns, or nil when it returns nil or `object` has no such property.
    public static func uuid(_ property: String, of object: any NSObjectProtocol) -> UUID? {
        let getter = Selector(property)
        guard object.responds(to: getter) else { return nil }
        let result: Unmanaged<AnyObject>? = object.perform(getter)
        return result?.takeUnretainedValue() as? UUID
    }
}
