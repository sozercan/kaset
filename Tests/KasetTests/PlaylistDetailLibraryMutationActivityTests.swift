import Testing
@testable import Kaset

// MARK: - PlaylistDetailLibraryMutationActivityTests

@Suite(.tags(.viewModel))
struct PlaylistDetailLibraryMutationActivityTests {
    @Test("An older operation cannot clear a newer operation's loading state")
    func olderOperationCannotFinishNewerActivity() {
        var activity = PlaylistDetailLibraryMutationActivity()
        guard let firstOperation = activity.begin() else {
            Issue.record("Expected the first operation to start")
            return
        }

        activity.finish(firstOperation)
        guard let secondOperation = activity.begin() else {
            Issue.record("Expected the second operation to start")
            return
        }
        activity.finish(firstOperation)

        #expect(activity.isActive)
        #expect(activity.operationID == secondOperation)

        activity.finish(secondOperation)
        #expect(!activity.isActive)
    }
}
