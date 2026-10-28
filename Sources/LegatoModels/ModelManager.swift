import Foundation

/// Owns the model catalog's state on this device: install, cancel, delete, storage and selection.
///
/// Nothing downloads implicitly. Reading state, listing or constructing the manager never calls an
/// installer's `install` or `warm`; only ``install(_:)`` and ``select(_:role:)`` start one.
///
/// One download runs per model however many callers ask for it. Callers watch it through their own
/// `AsyncStream`; dropping a stream never cancels the download, only ``cancel(_:)`` (or ``delete(_:)``)
/// does.
public actor ModelManager {
    public let root: URL
    public let catalog: [ModelDescriptor]
    private let descriptors: [String: ModelDescriptor]
    private let installers: [String: any ModelInstaller]
    private let selection: SelectionStore
    private let onWillDelete: (@Sendable (_ id: String, _ folder: URL) async -> Void)?
    private let onDelete: (@Sendable (_ id: String, _ folder: URL) async -> Void)?

    /// In-flight (downloading, warming) and failed states. Installed and not installed are read from disk.
    private var transient: [String: ModelState] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    /// Reserved before resource-release hooks suspend. Installs join the deletion before touching disk.
    private var deletions: [String: Task<Void, Never>] = [:]
    private var subscribers: [String: [UUID: Subscriber]] = [:]
    /// The model each role is currently being switched to, so a later pick supersedes an earlier one.
    private var pending: [ModelRole: String] = [:]

    private struct Subscriber {
        let continuation: AsyncStream<ModelState>.Continuation
        /// Install streams end with the install; event streams stay open.
        let finishOnTerminal: Bool
        /// Who waits on an install stream: a caller of ``install(_:)``, or a ``select(_:role:superseding:)``
        /// for a role. Nil for an event stream (it watches, it does not want the install).
        let owner: Owner?
    }

    private enum Owner: Equatable {
        case caller
        case select(ModelRole)
    }

    /// - Parameters:
    ///   - root: the storage root every installer writes under.
    ///   - catalog: the models on offer.
    ///   - installers: one installer per catalog model, keyed by ``ModelDescriptor/id``. A model without
    ///     an installer cannot be installed.
    ///   - selection: where the picked model per role persists.
    ///   - onWillDelete: settles resource users before files are removed by a delete or cancelled
    ///     install. The model stays reserved until both hooks finish. Hooks may inspect state, but
    ///     must not wait for an install/delete of the same model from inside its own deletion.
    ///   - onDelete: called after a delete or cancelled install removed the folder, so in-memory cache
    ///     owners can relinquish retained copies. The manager itself keeps no loaded models.
    public init(
        root: URL,
        catalog: [ModelDescriptor],
        installers: [String: any ModelInstaller],
        selection: SelectionStore,
        onDelete: (@Sendable (_ id: String, _ folder: URL) async -> Void)? = nil,
        onWillDelete: (@Sendable (_ id: String, _ folder: URL) async -> Void)? = nil
    ) {
        self.root = root
        self.catalog = catalog
        self.descriptors = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.installers = installers
        self.selection = selection
        self.onWillDelete = onWillDelete
        self.onDelete = onDelete
    }

    // MARK: state

    /// The model's state now. Never starts an install.
    public func state(of id: String) async -> ModelState {
        if deletions[id] != nil { return .notInstalled }
        if let current = transient[id] { return current }
        guard let installer = installers[id] else { return .notInstalled }
        let installed = await isInstalledOnDisk(id, installer)
        if deletions[id] != nil { return .notInstalled }
        // An install may have started while the disk was being probed.
        if let current = transient[id] { return current }
        return installed ? .installed(bytes: folderSize(installer.installFolder(root: root))) : .notInstalled
    }

    /// The current state, then every change, until the stream is dropped.
    public func events(for id: String) async -> AsyncStream<ModelState> {
        let probed = await state(of: id)
        return subscribe(id, initial: transient[id] ?? probed, finishOnTerminal: false, owner: nil)
    }

    /// Total bytes of every installed model's folder.
    public func storageUsed() async -> Int64 {
        var total: Int64 = 0
        for descriptor in catalog {
            guard let installer = installers[descriptor.id] else { continue }
            if await isInstalledOnDisk(descriptor.id, installer) {
                total += folderSize(installer.installFolder(root: root))
            }
        }
        return total
    }

    // MARK: install / cancel / delete

    /// Installs and warms the model, or joins the install already running, and streams its states.
    /// Batch speech models are only downloaded: they load, and compile, when the post-pass uses them.
    ///
    /// The stream ends with the install: `installed`, `failed`, or `notInstalled` after a cancel. An
    /// installed model yields `installed` and ends without touching the installer's `install`.
    /// Dropping the stream only stops this caller's updates.
    public func install(_ id: String) async -> AsyncStream<ModelState> {
        await install(id, owner: .caller)
    }

    private func install(_ id: String, owner: Owner) async -> AsyncStream<ModelState> {
        while let deletion = deletions[id] { await deletion.value }
        guard let installer = installers[id], descriptors[id] != nil else {
            return Self.single(.failed("Unknown model \(id)"))
        }
        if running[id] == nil {
            let installed = await isInstalledOnDisk(id, installer)
            if let deletion = deletions[id] {
                await deletion.value
                return await install(id, owner: owner)
            }
            // Another caller may have started the install while the disk was being probed.
            if running[id] == nil {
                if installed {
                    return Self.single(.installed(bytes: folderSize(installer.installFolder(root: root))))
                }
                start(id, installer)
            }
        }
        return subscribe(id, initial: transient[id] ?? .downloading(0), finishOnTerminal: true, owner: owner)
    }

    /// Cancels the model's download for every waiter and removes the partial folder. Returns once it
    /// has wound down. A no-op when nothing is running.
    public func cancel(_ id: String) async {
        guard let task = running[id] else { return }
        task.cancel()
        await task.value
    }

    /// A pick for `role` gave up on `id` (another model or the default was picked): its install is
    /// cancelled, and its partial folder removed, unless someone other than a pick for `role` waits for it.
    /// A no-op when nothing is running.
    public func abandon(_ id: String, besidesPicksFor role: ModelRole) async {
        guard running[id] != nil, !isWanted(id, besidesPicksFor: role) else { return }
        await cancel(id)
    }

    /// Cancels any install, removes the model's folder, resets its state and clears any selection of it.
    ///
    /// Concurrent deletes share one operation. New installs wait until resource settlement, file
    /// removal and cache release finish, then may install afresh without losing their new files.
    public func delete(_ id: String) async {
        if let deletion = deletions[id] { await deletion.value; return }
        let deletion = Task { await self.performDelete(id) }
        deletions[id] = deletion
        await deletion.value
    }

    private func performDelete(_ id: String) async {
        defer { deletions[id] = nil }
        while let task = running[id] {
            task.cancel()
            await task.value
        }
        let folder = installers[id]?.installFolder(root: root)
        if let folder { await onWillDelete?(id, folder) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        transient[id] = nil
        for role in ModelRole.allCases where selection.selected(for: role) == id {
            selection.set(nil, for: role)
        }
        publish(id, .notInstalled)
        // Installs remain behind this deletion's reservation until retained copies are released too.
        if let folder { await onDelete?(id, folder) }
    }

    // MARK: selection

    /// The persisted pick for `role`, or `nil` for the zero-download default.
    public func selected(role: ModelRole) -> String? {
        selection.selected(for: role)
    }

    /// Picks `id` for `role`, installing and warming it first if it is missing ("load on pick").
    ///
    /// Returns once the model is installed and the selection has switched. Until then
    /// ``selected(role:)`` keeps answering with the previous choice, and a failed or cancelled install
    /// leaves it untouched. If another pick for the same role arrives meanwhile, the later one wins and
    /// this call returns without switching.
    ///
    /// `superseding`: the pick this one replaces (for example the previous latency tier of the same family).
    /// Its install is cancelled, and its partial folder removed, unless someone other than a pick for
    /// `role` still waits for it (an ``install(_:)`` caller, or a pick for another role). An installed or
    /// idle model is left alone.
    public func select(_ id: String, role: ModelRole, superseding superseded: String? = nil) async throws {
        guard let descriptor = descriptors[id], installers[id] != nil else { throw ModelError.unknownModel(id) }
        guard descriptor.kind == role.kind else { throw ModelError.wrongKind(model: id, role: role) }

        pending[role] = id
        defer { if pending[role] == id { pending[role] = nil } }

        if let superseded, superseded != id, running[superseded] != nil, !isWanted(superseded, besidesPicksFor: role) {
            await cancel(superseded)
        }
        try Task.checkCancellation()

        var last: ModelState = .notInstalled
        for await state in await install(id, owner: .select(role)) { last = state }
        try Task.checkCancellation()

        switch last {
        case .installed:
            if pending[role] == id { selection.set(id, for: role) }
        case .failed(let message):
            throw ModelError.installFailed(model: id, message: message)
        default:
            throw ModelError.cancelled(model: id)
        }
    }

    /// Whether anyone but a pick for `role` waits on `id`'s install.
    private func isWanted(_ id: String, besidesPicksFor role: ModelRole) -> Bool {
        (subscribers[id] ?? [:]).values.contains { sub in
            guard let owner = sub.owner else { return false }
            return owner != .select(role)
        }
    }

    // MARK: install task

    private func start(_ id: String, _ installer: any ModelInstaller) {
        transient[id] = .downloading(0)
        publish(id, .downloading(0))
        running[id] = Task { await self.run(id, installer) }
    }

    private func run(_ id: String, _ installer: any ModelInstaller) async {
        let folder = installer.installFolder(root: root)
        let outcome: ModelState
        do {
            // A download that finished earlier (a warm-up failed or was cut short) is kept. Anything else
            // in the folder is a leftover of an unfinished download that the installer might mistake for
            // a complete one, so it goes before the download starts.
            var downloaded = InstallMarker.stage(in: folder, id: id) == .downloaded
            if downloaded { downloaded = await installer.isInstalled(root: root) }
            if !downloaded {
                try? FileManager.default.removeItem(at: folder)
                try await download(id, installer)
                try Task.checkCancellation()
                try InstallMarker.write(in: folder, id: id, stage: .downloaded)
            }
            try Task.checkCancellation()
            // A batch model's compile takes minutes on first use and would queue the Neural Engine ahead
            // of a meeting's live engine; it compiles when the post-pass (or the after-meeting diarizer)
            // loads it instead.
            if let kind = descriptors[id]?.kind, kind != .speechBatch, kind != .speakersBatch {
                transient[id] = .warming
                publish(id, .warming)
                try await installer.warm(root: root)
            }
            try Task.checkCancellation()
            try InstallMarker.write(in: folder, id: id, stage: .installed)
            outcome = .installed(bytes: folderSize(installer.installFolder(root: root)))
        } catch {
            if Task.isCancelled || error is CancellationError {
                // Warmup has returned (including a late successful native load after cancellation).
                // Release that candidate too; it never became a selected, installed model.
                await onWillDelete?(id, folder)
                try? FileManager.default.removeItem(at: installer.installFolder(root: root))
                await onDelete?(id, folder)
                outcome = .notInstalled
            } else {
                outcome = .failed(Self.message(for: error))
            }
        }
        running[id] = nil
        if case .failed = outcome { transient[id] = outcome } else { transient[id] = nil }
        publish(id, outcome)
    }

    /// Runs the installer's download, applying its progress reports in order.
    private func download(_ id: String, _ installer: any ModelInstaller) async throws {
        let (reports, sink) = AsyncStream<Double>.makeStream()
        let drain = Task { for await fraction in reports { self.report(id, fraction) } }
        do {
            try await installer.install(root: root) { sink.yield($0) }
        } catch {
            sink.finish()
            await drain.value
            throw error
        }
        sink.finish()
        await drain.value
    }

    /// Applies a progress report; reports never move backwards or leave `0...1`.
    private func report(_ id: String, _ fraction: Double) {
        guard case .downloading(let current) = transient[id] else { return }
        let next = min(max(fraction, current), 1)
        guard next > current else { return }
        transient[id] = .downloading(next)
        publish(id, .downloading(next))
    }

    // MARK: subscribers

    private func subscribe(
        _ id: String, initial: ModelState, finishOnTerminal: Bool, owner: Owner?
    ) -> AsyncStream<ModelState> {
        let (stream, continuation) = AsyncStream<ModelState>.makeStream()
        continuation.yield(initial)
        if finishOnTerminal && initial.isTerminal {
            continuation.finish()
            return stream
        }
        let token = UUID()
        subscribers[id, default: [:]][token] = Subscriber(
            continuation: continuation, finishOnTerminal: finishOnTerminal, owner: owner)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id, token) }
        }
        return stream
    }

    private func unsubscribe(_ id: String, _ token: UUID) {
        subscribers[id]?[token] = nil
    }

    private func publish(_ id: String, _ state: ModelState) {
        guard let subs = subscribers[id] else { return }
        for (token, sub) in subs {
            sub.continuation.yield(state)
            if sub.finishOnTerminal && state.isTerminal {
                sub.continuation.finish()
                subscribers[id]?[token] = nil
            }
        }
    }

    // MARK: helpers

    /// Installed means finished: the `installed` marker names this model and the installer finds its files.
    private func isInstalledOnDisk(_ id: String, _ installer: any ModelInstaller) async -> Bool {
        guard InstallMarker.stage(in: installer.installFolder(root: root), id: id) == .installed else { return false }
        return await installer.isInstalled(root: root)
    }

    private static func single(_ state: ModelState) -> AsyncStream<ModelState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Sum of the file sizes under `folder` (the install marker excluded); zero when it does not exist.
    private nonisolated func folderSize(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if url.lastPathComponent == InstallMarker.fileName { continue }
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
