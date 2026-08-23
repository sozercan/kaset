import Foundation

@MainActor
final class AuthCookieClearCoordinator {
    enum Scope: Equatable, Sendable {
        case authenticationCookies
        case allWebsiteData
    }

    private struct ActiveClear {
        let id: UInt64
        let scope: Scope
        let task: Task<Bool, Never>
    }

    private struct PendingAllDataClear {
        let id: UInt64
        let task: Task<Bool, Never>
    }

    private var nextID: UInt64 = 0
    private var activeClear: ActiveClear?
    private var pendingAllDataClear: PendingAllDataClear?

    var isBusy: Bool {
        self.activeClear != nil || self.pendingAllDataClear != nil
    }

    func run(
        scope: Scope,
        operation: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        if let pendingAllDataClear {
            let result = await pendingAllDataClear.task.value
            self.finishPendingAllDataClear(id: pendingAllDataClear.id)
            return result
        }

        if let activeClear {
            if activeClear.scope == .authenticationCookies, scope == .allWebsiteData {
                let pending = self.makePendingAllDataClear(
                    after: activeClear.task,
                    operation: operation
                )
                let result = await pending.task.value
                self.finishPendingAllDataClear(id: pending.id)
                return result
            }

            let result = await activeClear.task.value
            self.finishActiveClear(id: activeClear.id)
            return result
        }

        self.nextID &+= 1
        let clearID = self.nextID
        let task = Task { @MainActor in
            await operation()
        }
        self.activeClear = ActiveClear(
            id: clearID,
            scope: scope,
            task: task
        )

        let result = await task.value
        self.finishActiveClear(id: clearID)
        return result
    }

    private func makePendingAllDataClear(
        after activeTask: Task<Bool, Never>,
        operation: @escaping @MainActor @Sendable () async -> Bool
    ) -> PendingAllDataClear {
        if let pendingAllDataClear {
            return pendingAllDataClear
        }

        self.nextID &+= 1
        let clearID = self.nextID
        let task = Task { @MainActor in
            _ = await activeTask.value
            return await operation()
        }
        let pending = PendingAllDataClear(id: clearID, task: task)
        self.pendingAllDataClear = pending
        return pending
    }

    private func finishActiveClear(id: UInt64) {
        guard self.activeClear?.id == id else { return }
        self.activeClear = nil
    }

    private func finishPendingAllDataClear(id: UInt64) {
        guard self.pendingAllDataClear?.id == id else { return }
        self.pendingAllDataClear = nil
    }
}
