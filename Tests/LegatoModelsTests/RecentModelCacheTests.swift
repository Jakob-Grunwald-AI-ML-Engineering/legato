import Foundation
import Synchronization
import Testing
@testable import LegatoModels

/// Counts loads per folder and records evictions; the "model" is the folder path with a load number.
private final class Loads: Sendable {
    private let counts = Mutex<[String: Int]>([:])
    private let evicted = Mutex<[String]>([])
    private let failing = Mutex<Set<String>>([])

    func count(_ folder: String) -> Int { counts.withLock { $0[folder, default: 0] } }
    var evictions: [String] { evicted.withLock { $0 } }
    func failNext(_ folder: String) { failing.withLock { _ = $0.insert(folder) } }

    func load(_ folder: String) async throws -> String {
        let n = counts.withLock { $0[folder, default: 0] += 1; return $0[folder]! }
        let shouldFail = failing.withLock { $0.remove(folder) != nil }
        await Task.yield()
        if shouldFail { throw CacheTestError() }
        return "\(folder)#\(n)"
    }

    func evict(_ model: String) { evicted.withLock { $0.append(model) } }
}

private struct CacheTestError: Error {}

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/models/\(name)") }

/// Polls until `condition` holds or a generous 30 s deadline passes (a hang guard, not a speed bound).
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Model cache")
struct ModelCacheTests {
    @Test func theSameFolderLoadsOnce() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String>()
        let first = try await cache.model(at: url("a")) { try await loads.load("a") }
        let second = try await cache.model(at: url("a")) { try await loads.load("a") }
        #expect(first == second)
        #expect(loads.count("a") == 1)
    }

    @Test func concurrentRequestsShareOneLoad() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String>()
        async let one = cache.model(at: url("a")) { try await loads.load("a") }
        async let two = cache.model(at: url("a")) { try await loads.load("a") }
        let (x, y) = try await (one, two)
        #expect(x == y)
        #expect(loads.count("a") == 1)
    }

    @Test func onlyTheMostRecentlyUsedFolderStaysLoaded() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String> { loads.evict($0) }
        _ = try await cache.model(at: url("a")) { try await loads.load("a") }
        _ = try await cache.model(at: url("b")) { try await loads.load("b") }

        #expect(await cache.residentFolders == [url("b").standardizedFileURL.path])
        #expect(await eventually { loads.evictions == ["a#1"] }, "the older model was released: \(loads.evictions)")

        // Going back loads it again; b is the one released now.
        let again = try await cache.model(at: url("a")) { try await loads.load("a") }
        #expect(again == "a#2")
        #expect(await cache.residentFolders == [url("a").standardizedFileURL.path])
        #expect(await eventually { loads.evictions.contains("b#1") })
    }

    @Test func aFailedLoadIsNotCached() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String>()
        loads.failNext("a")
        await #expect(throws: CacheTestError.self) { _ = try await cache.model(at: url("a")) { try await loads.load("a") } }
        #expect(await cache.residentFolders.isEmpty)
        let retry = try await cache.model(at: url("a")) { try await loads.load("a") }
        #expect(retry == "a#2")
    }

    @Test func evictingAFolderReleasesItAndTheNextRequestReloads() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String> { loads.evict($0) }
        _ = try await cache.model(at: url("a")) { try await loads.load("a") }

        await cache.evict(folder: url("a"))

        #expect(await cache.residentFolders.isEmpty)
        #expect(await eventually { loads.evictions == ["a#1"] })
        let again = try await cache.model(at: url("a")) { try await loads.load("a") }
        #expect(again == "a#2")
    }

    @Test func evictingAnotherFolderLeavesTheLoadedOne() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String>()
        _ = try await cache.model(at: url("a")) { try await loads.load("a") }
        await cache.evict(folder: url("b"))
        _ = try await cache.model(at: url("a")) { try await loads.load("a") }
        #expect(loads.count("a") == 1)
    }

    @Test func evictAllEmptiesTheCache() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String> { loads.evict($0) }
        _ = try await cache.model(at: url("a")) { try await loads.load("a") }
        await cache.evictAll()
        #expect(await cache.residentFolders.isEmpty)
        #expect(await eventually { loads.evictions == ["a#1"] })
    }

    @Test func aLargerCapacityKeepsMoreFolders() async throws {
        let loads = Loads()
        let cache = RecentModelCache<String>(capacity: 2)
        for name in ["a", "b", "a", "c", "a"] { _ = try await cache.model(at: url(name)) { try await loads.load(name) } }
        #expect(loads.count("a") == 1, "a was used again in between, so c pushed out b")
        #expect(loads.count("b") == 1)
        #expect(loads.count("c") == 1)
        #expect(Set(await cache.residentFolders) == [url("a").standardizedFileURL.path, url("c").standardizedFileURL.path])
    }
}
