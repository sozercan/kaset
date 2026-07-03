import Foundation

// MARK: - NowPlayingSurfaceDescriptor

struct NowPlayingSurfaceDescriptor: Identifiable, Equatable {
    let id: NowPlayingSurfaceID
    let displayName: String
    let helpText: String
    let requiresSyncedLyrics: Bool

    init(
        id: NowPlayingSurfaceID,
        displayName: String,
        helpText: String,
        requiresSyncedLyrics: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.helpText = helpText
        self.requiresSyncedLyrics = requiresSyncedLyrics
    }
}

// MARK: - Canonical descriptors

extension NowPlayingSurfaceDescriptor {
    static let musicIsland = Self(
        id: .musicIsland,
        displayName: "Music Island",
        helpText: "Show a notch-aligned floating surface with now playing details and synced lyrics.",
        requiresSyncedLyrics: true
    )

    static let boringNotchBridge = Self(
        id: .boringNotchBridge,
        displayName: "Boring Notch Bridge",
        helpText: "Expose a localhost compatibility bridge for boring.notch."
    )
}

// MARK: - NowPlayingSurfaceCatalog

enum NowPlayingSurfaceCatalog {
    static func descriptors(includeMusicIsland: Bool) -> [NowPlayingSurfaceDescriptor] {
        var descriptors: [NowPlayingSurfaceDescriptor] = []
        if includeMusicIsland {
            descriptors.append(.musicIsland)
        }
        descriptors.append(.boringNotchBridge)
        return descriptors
    }
}

// MARK: - NowPlayingSurfaceContext

struct NowPlayingSurfaceContext {
    let snapshots: NowPlayingSnapshotStore
    let commands: any NowPlayingCommandRouting
    let openMainWindow: @MainActor () -> Void
}

// MARK: - NowPlayingSurfaceAdapter

@MainActor
protocol NowPlayingSurfaceAdapter: AnyObject {
    var descriptor: NowPlayingSurfaceDescriptor { get }
    var isRunning: Bool { get }

    /// Starts the surface. Returns `false` if it could not start so the
    /// coordinator can leave it inactive and retry on the next reconcile.
    func start(context: NowPlayingSurfaceContext) async -> Bool
    func stop() async
}

extension NowPlayingSurfaceAdapter {
    var isRunning: Bool {
        true
    }
}

// MARK: - NowPlayingSurfaceCoordinator

@MainActor
final class NowPlayingSurfaceCoordinator {
    private let settingsManager: SettingsManager
    private let snapshotStore: NowPlayingSnapshotStore
    private let commandRouter: any NowPlayingCommandRouting
    private let lyricsDemandCoordinator: LyricsDemandCoordinator
    private let openMainWindow: @MainActor () -> Void
    private var adapters: [NowPlayingSurfaceID: any NowPlayingSurfaceAdapter] = [:]
    private var activeSurfaceIDs: Set<NowPlayingSurfaceID> = []
    private var healthTask: Task<Void, Never>?

    init(
        adapters: [any NowPlayingSurfaceAdapter],
        settingsManager: SettingsManager = .shared,
        snapshotStore: NowPlayingSnapshotStore,
        commandRouter: any NowPlayingCommandRouting,
        lyricsDemandCoordinator: LyricsDemandCoordinator,
        openMainWindow: @escaping @MainActor () -> Void
    ) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.descriptor.id, $0) })
        self.settingsManager = settingsManager
        self.snapshotStore = snapshotStore
        self.commandRouter = commandRouter
        self.lyricsDemandCoordinator = lyricsDemandCoordinator
        self.openMainWindow = openMainWindow
    }

    func start() {
        self.startHealthMonitoring()
        Task { @MainActor in
            await self.reconcileEnabledSurfaces()
        }
    }

    func stop() async {
        self.healthTask?.cancel()
        self.healthTask = nil
        for id in self.activeSurfaceIDs {
            await self.adapters[id]?.stop()
            self.lyricsDemandCoordinator.setDemand(for: id, isActive: false)
        }
        self.activeSurfaceIDs.removeAll()
        self.lyricsDemandCoordinator.stopObserving()
        self.snapshotStore.stopObserving()
    }

    func reconcileEnabledSurfaces() async {
        let enabledIDs = self.settingsManager.enabledNowPlayingSurfaces
        let context = NowPlayingSurfaceContext(
            snapshots: self.snapshotStore,
            commands: self.commandRouter,
            openMainWindow: self.openMainWindow
        )

        let stoppedActiveIDs = self.activeSurfaceIDs.filter { self.adapters[$0]?.isRunning == false }
        for id in stoppedActiveIDs {
            await self.adapters[id]?.stop()
            self.activeSurfaceIDs.remove(id)
            self.lyricsDemandCoordinator.setDemand(for: id, isActive: false)
        }

        for id in enabledIDs.subtracting(self.activeSurfaceIDs) {
            guard let adapter = self.adapters[id] else { continue }
            guard await adapter.start(context: context) else { continue }
            self.activeSurfaceIDs.insert(id)
            self.lyricsDemandCoordinator.setDemand(
                for: id,
                isActive: adapter.descriptor.requiresSyncedLyrics
            )
        }

        for id in self.activeSurfaceIDs.subtracting(enabledIDs) {
            await self.adapters[id]?.stop()
            self.activeSurfaceIDs.remove(id)
            self.lyricsDemandCoordinator.setDemand(for: id, isActive: false)
        }

        self.reconcileObservationLifecycle()
    }

    private func reconcileObservationLifecycle() {
        guard !self.activeSurfaceIDs.isEmpty else {
            self.lyricsDemandCoordinator.stopObserving()
            self.snapshotStore.stopObserving()
            return
        }

        self.snapshotStore.startObserving()
        self.lyricsDemandCoordinator.startObserving()
    }

    private func startHealthMonitoring() {
        guard self.healthTask == nil else { return }
        self.healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.reconcileEnabledSurfaces()
            }
        }
    }
}
