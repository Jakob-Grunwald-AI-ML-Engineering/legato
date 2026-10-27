import Foundation
import Testing
@testable import LegatoKeyboardCore

struct RuntimeIdentityTests {
    private let isolated: [String: Any] = [
        "LegatoAppGroupID": "group.de.gruenwald.legato.ane-spike",
        "LegatoURLScheme": "anecleanup39",
        "LegatoNotificationNamespace": "de.gruenwald.legato.ane-spike",
    ]
    @Test func absentConfigurationKeepsExactProductionIdentity() throws {
        let identity = try RuntimeIdentity.resolve(info: [:])
        #expect(identity.appGroupID == "group.de.gruenwald.legato")
        #expect(identity.urlScheme == "legato")
        #expect(identity.notificationNamespace == "de.gruenwald.legato")
    }
    @Test func explicitIdentityUsesOnlyIsolatedNamespace() throws {
        let identity = try RuntimeIdentity.resolve(info: isolated)
        #expect(identity.appGroupID == "group.de.gruenwald.legato.ane-spike")
        #expect(identity.urlScheme == "anecleanup39")
        #expect(identity.notificationNamespace == "de.gruenwald.legato.ane-spike")
    }
    @Test func partialOrMalformedIdentityFailsClosed() {
        for info: [String: Any] in [
            ["LegatoAppGroupID": "group.de.gruenwald.legato.ane-spike"],
            isolated.merging(["LegatoURLScheme": "legato://bad"]) { _, new in new },
            isolated.merging(["LegatoNotificationNamespace": ""]) { _, new in new },
            isolated.merging(["LegatoAppGroupID": 39]) { _, new in new },
        ] {
            #expect(throws: RuntimeIdentity.ConfigurationError.self) { try RuntimeIdentity.resolve(info: info) }
        }
    }
    @Test func isolatedKeyboardURLRoundTripsAndRejectsProductionURL() throws {
        let identity = try RuntimeIdentity.resolve(info: isolated)
        let url = KeyboardURL.make(command: .arm, requestID: "fixture-39", identity: identity)
        #expect(url.absoluteString == "anecleanup39://keyboard?cmd=arm&req=fixture-39")
        #expect(KeyboardURL.parse(url, identity: identity)?.requestID == "fixture-39")
        #expect(KeyboardURL.parse(url, identity: .production) == nil)
        #expect(KeyboardURL.parse(URL(string: "legato://keyboard?cmd=arm&req=fixture-39")!, identity: identity) == nil)
    }
    @Test func isolatedStorageDoesNotTouchProductionSentinel() throws {
        let identity = try RuntimeIdentity.resolve(info: isolated)
        let production = MemoryLinkStore()
        let spike = MemoryLinkStore()
        let stores = ["group.de.gruenwald.legato": production, "group.de.gruenwald.legato.ane-spike": spike]
        production.set(Data("production sentinel".utf8), forKey: "link.host")
        let selected = try #require(stores[identity.appGroupID])
        selected.set(Data("spike state".utf8), forKey: "link.host")
        #expect(production.data(forKey: "link.host") == Data("production sentinel".utf8))
        #expect(spike.data(forKey: "link.host") == Data("spike state".utf8))
    }
}
