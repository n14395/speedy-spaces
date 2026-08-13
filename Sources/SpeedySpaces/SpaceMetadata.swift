import Foundation

/// How a space's icon is represented.
enum IconType: String, Codable {
    case none
    case sfsymbol
    case emoji
}

/// User-assigned, persisted metadata for a space, keyed by the space `uuid`.
struct SpaceMetadata: Codable, Equatable {
    var name: String?
    var iconType: IconType = .none
    var iconValue: String?
    /// Global hotkey bound directly to this space (optional — absent in legacy files).
    var shortcut: ShortcutSpec?

    var isEmpty: Bool {
        (name?.isEmpty ?? true) && iconType == .none && shortcut == nil
    }

    static let empty = SpaceMetadata()
}
