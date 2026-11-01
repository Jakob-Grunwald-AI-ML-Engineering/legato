import Foundation
import LegatoSoniox

/// One held Soniox connection: authenticated and upgraded, no start request (Soniox bills streams, not held
/// connections), kept alive by keepalive. A take sends the start request and its audio on it.
/// A quiet drop reconnects in the background with backoff; a missing or rejected key stops retrying
/// (the next take then connects visibly and reports it).
@MainActor final class WarmStream {
    typealias Connect = @MainActor (_ onDrop: @escaping @Sendable () async -> Void) async throws -> SonioxClient
    private let connect: Connect
    private let now: @MainActor () -> Double
    private var client: SonioxClient?
    private var clientID: UUID?
    private var pending: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0
    private var closed = false
    /// Host uptime when the current stream finished connecting.
    private(set) var liveSince: Double?
    /// Reconnects after a drop, for diagnostics.
    private(set) var reconnects = 0

    init(connect: @escaping Connect, now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.connect = connect; self.now = now
    }
    var isLive: Bool { client != nil }
    var isConnecting: Bool { pending != nil }

    func warm() {
        guard !closed, client == nil, pending == nil, retry == nil else { return }
        let id = UUID()
        pending = Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await connect({ [weak self] in await self?.dropped(id) })
                pending = nil
                guard !closed else { await created.close(); return }
                // A drop during the connect reached no slot yet: reconnect now.
                guard await created.isOpen else { reconnects += 1; warm(); return }
                client = created; clientID = id; liveSince = now(); failures = 0
            } catch {
                pending = nil
                guard !closed else { return }
                failures += 1
                if let failure = error as? SonioxError, [.missingKey, .provider(401), .provider(402)].contains(failure) { return }
                scheduleRetry()
            }
        }
    }
    /// The live stream for a take (awaiting a connect in flight); the slot is empty afterwards.
    func take() async -> SonioxClient? {
        let value = await current()
        client = nil; clientID = nil; liveSince = nil
        return value
    }
    /// The live stream, kept in the slot (the dictation route reuses one stream across taps).
    func current() async -> SonioxClient? {
        if client == nil, let pending { await pending.value }
        guard let client, await client.isOpen else { return nil }
        return client
    }
    func close() async {
        closed = true
        pending?.cancel(); pending = nil; retry?.cancel(); retry = nil
        let value = client
        client = nil; clientID = nil; liveSince = nil
        await value?.close()
    }
    private func dropped(_ id: UUID) {
        guard id == clientID, !closed else { return }
        client = nil; clientID = nil; liveSince = nil; reconnects += 1
        warm()
    }
    private func scheduleRetry() {
        let delay = min(30, pow(2, Double(min(failures, 6) - 1)))
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            retry = nil; warm()
        }
    }
}
