import AppIntents
import Foundation
import Observation

/// Cross-cutting navigation requests (e.g. from Siri / the Action button).
@Observable @MainActor
final class NavigationCoordinator {
    static let shared = NavigationCoordinator()
    /// When set, the UI presents the record screen for this person.
    var recordPerson: Person?
    /// Control Center / Action button flow: show the quick person picker.
    var quickRecordPickerShown = false

    func handle(url: URL) {
        guard url.scheme == "luxicon" else { return }
        if url.host == "quick-record" {
            quickRecordPickerShown = true
        }
    }
}

/// A direct report, exposed to Siri/Shortcuts.
struct PersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PersonEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(person: Person) {
        id = person.id
        name = person.name
    }
}

struct PersonEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PersonEntity] {
        Store.peekPeople()
            .filter { identifiers.contains($0.id) }
            .map(PersonEntity.init)
    }

    /// Lets Siri resolve "…with Josh" against the people list.
    @MainActor
    func entities(matching string: String) async throws -> [PersonEntity] {
        Store.peekPeople()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(PersonEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PersonEntity] {
        Store.peekPeople().map(PersonEntity.init)
    }
}

/// "Start a 1-on-1 with Josh" — opens the app straight into the record screen.
/// Recording needs the foreground (microphone + consent moment), so this is a
/// launcher, not a background recorder.
struct StartOneOnOneIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a 1-on-1"
    static let description = IntentDescription(
        "Opens Luxicon ready to record a 1-on-1 with the person you choose.")
    static let openAppWhenRun = true

    @Parameter(title: "Person")
    var person: PersonEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let match = Store.peekPeople().first(where: { $0.id == person.id }) else {
            throw LuxiconIntentError.personNotFound
        }
        NavigationCoordinator.shared.recordPerson = match
        return .result()
    }
}

enum LuxiconIntentError: Error, CustomLocalizedStringResourceConvertible {
    case personNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .personNotFound:
            return "That person isn't in Luxicon. Add them in the app first."
        }
    }
}

/// Zero-setup Siri phrases — registered on install, no Shortcuts authoring
/// needed. Also what the Action button runs via a Shortcut.
struct LuxiconShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartOneOnOneIntent(),
            phrases: [
                "Start a one on one in \(.applicationName)",
                "Start a one on one with \(\.$person) in \(.applicationName)",
                "Record a one on one with \(\.$person) in \(.applicationName)",
                "Record a \(.applicationName) with \(\.$person)",
            ],
            shortTitle: "Start 1-on-1",
            systemImageName: "record.circle"
        )
    }
}
