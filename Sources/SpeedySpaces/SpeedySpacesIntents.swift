import AppIntents
import AppKit

/// macOS Shortcuts integration. Each intent is a thin shim over the `speedyspaces://` URL
/// scheme: it opens the corresponding URL, which LaunchServices routes to the running
/// agent (or launches it) — sidestepping any App-Intents-process-vs-agent lifecycle
/// question. Discovery requires the App Intents metadata bundle, produced by the guarded
/// `appintentsmetadataprocessor` step in build.sh; without it the app still runs and the
/// URL scheme + CLI still work, there are just no native actions in Shortcuts.

/// Fire-and-forget open of a speedyspaces:// URL from an intent's perform().
enum SpeedySpacesURL {
    static func open(_ path: String) {
        guard let url = URL(string: "speedyspaces://\(path)") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
}

/// A workspace exposed to Shortcuts, so "Switch to Space" can offer a picker of the user's
/// named spaces. The query reads spaces + names directly (reusing the live managers when
/// the agent is running, else building its own), so it populates without the agent.
struct SpaceEntity: AppEntity, Identifiable {
    let id: String        // space uuid
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static var defaultQuery = SpaceQuery()
}

struct SpaceQuery: EntityQuery {
    func entities(for identifiers: [String]) async -> [SpaceEntity] {
        await allSpaces().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async -> [SpaceEntity] { await allSpaces() }

    @MainActor
    private func allSpaces() -> [SpaceEntity] {
        let store = MetadataStoreHolder.shared ?? MetadataStore()
        let manager = SpacesManagerHolder.shared ?? SpacesManager()
        manager.refresh()
        return manager.spaces.map { SpaceEntity(id: $0.uuid, title: $0.displayTitle(using: store)) }
    }
}

struct SwitchToSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch to Space"
    static var description = IntentDescription("Switch to a specific workspace.")
    static var openAppWhenRun = false

    @Parameter(title: "Space")
    var space: SpaceEntity

    func perform() async throws -> some IntentResult {
        SpeedySpacesURL.open("switch?uuid=\(space.id)")
        return .result()
    }
}

struct NextSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Space"
    static var description = IntentDescription("Switch to the next workspace.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult { SpeedySpacesURL.open("next"); return .result() }
}

struct PreviousSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Space"
    static var description = IntentDescription("Switch to the previous workspace.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult { SpeedySpacesURL.open("prev"); return .result() }
}

struct OpenSwitcherIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Space Switcher"
    static var description = IntentDescription("Briefly show the floating workspace switcher.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult { SpeedySpacesURL.open("switcher"); return .result() }
}

struct OpenMissionControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Mission Control Workspace View"
    static var description = IntentDescription("Open Mission Control with its spaces bar expanded into workspace thumbnails.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult { SpeedySpacesURL.open("mission-control"); return .result() }
}

struct RenameCurrentSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Rename Current Space"
    static var description = IntentDescription("Open the editor for the current workspace.")
    static var openAppWhenRun = true   // shows the editor window, so bring the app forward
    func perform() async throws -> some IntentResult { SpeedySpacesURL.open("rename"); return .result() }
}

struct SpeedySpacesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SwitchToSpaceIntent(),
                    phrases: ["Switch space in \(.applicationName)"],
                    shortTitle: "Switch to Space", systemImageName: "rectangle.3.group")
        AppShortcut(intent: NextSpaceIntent(),
                    phrases: ["Next space in \(.applicationName)"],
                    shortTitle: "Next Space", systemImageName: "arrow.right")
        AppShortcut(intent: PreviousSpaceIntent(),
                    phrases: ["Previous space in \(.applicationName)"],
                    shortTitle: "Previous Space", systemImageName: "arrow.left")
        AppShortcut(intent: OpenSwitcherIntent(),
                    phrases: ["Show the space switcher in \(.applicationName)"],
                    shortTitle: "Show Space Switcher", systemImageName: "rectangle.3.group.bubble")
    }
}
