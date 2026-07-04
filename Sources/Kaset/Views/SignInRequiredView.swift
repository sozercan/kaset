import SwiftUI

/// Lightweight empty state for routes that need a YouTube account.
/// Guest mode still supports public browsing/search/playback, while personal
/// collections and mutations route here until the user signs in.
struct SignInRequiredView: View {
    let title: String
    let message: String

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService

    var body: some View {
        let shouldExitGuestMode = self.authService.state.isLoggedIn && self.authService.isGuestModeEnabled

        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(self.title)
                    .font(.title3.weight(.semibold))

                Text(self.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                if shouldExitGuestMode {
                    self.authService.exitGuestMode(activeAccountID: self.accountService.currentAccount?.id)
                } else {
                    self.authService.startLogin()
                }
            } label: {
                Text(shouldExitGuestMode ? String(localized: "Exit Guest Mode") : String(localized: "Sign In"))
                    .font(.headline)
                    .frame(minWidth: 140)
            }
            .compatGlassProminentButton()
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SignInRequiredView(
        title: "Sign in required",
        message: "Sign in to access your library."
    )
    .environment(authService)
    .environment(accountService)
}
