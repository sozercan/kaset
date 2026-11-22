import Foundation

public struct UserAccount: Identifiable, Equatable, Sendable, Hashable {
    public let id: String

    public let name: String

    public let handle: String?

    public let brandId: String?

    public let signinURL: URL?

    public let thumbnailURL: URL?

    public let isSelected: Bool

    public var isPrimary: Bool {
        self.brandId == nil
    }

    public var typeLabel: String {
        self.isPrimary ? "Personal" : "Brand"
    }

    var cacheIdentity: String {
        [self.id, self.handle ?? "", self.name].joined(separator: "\u{1F}")
    }

    public init(
        id: String,
        name: String,
        handle: String?,
        brandId: String?,
        thumbnailURL: URL?,
        isSelected: Bool,
        signinURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.brandId = brandId
        self.thumbnailURL = thumbnailURL
        self.isSelected = isSelected
        self.signinURL = signinURL
    }

    public static func from(
        name: String,
        handle: String?,
        brandId: String?,
        thumbnailURL: URL?,
        isSelected: Bool,
        signinURL: URL? = nil
    ) -> UserAccount {
        let accountId = brandId ?? "primary"
        return UserAccount(
            id: accountId,
            name: name,
            handle: handle,
            brandId: brandId,
            thumbnailURL: thumbnailURL,
            isSelected: isSelected,
            signinURL: signinURL
        )
    }

    public static func == (lhs: UserAccount, rhs: UserAccount) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.handle == rhs.handle && lhs.brandId == rhs.brandId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
        hasher.combine(self.handle)
        hasher.combine(self.brandId)
    }
}
