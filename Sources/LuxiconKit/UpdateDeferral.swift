import Foundation

/// Holds update UI and relaunches while the app is busy (recording window
/// open, recording, or a session processing); runs them once it's idle.
@MainActor public final class UpdateDeferral {
    public private(set) var isBusy = false
    private var held: [@MainActor () -> Void] = []

    public init() {}

    /// Updates busy state; on a busy → idle transition runs every held
    /// action once, in the order held, then forgets them.
    public func setBusy(_ busy: Bool) {
        let wasBusy = isBusy
        isBusy = busy
        guard wasBusy, !busy else { return }
        // Copy and clear first so an action that holds another one doesn't
        // run it in this same pass.
        let actions = held
        held = []
        for action in actions { action() }
    }

    /// Not busy: returns false and doesn't keep `action` (caller proceeds).
    /// Busy: keeps `action` and returns true (caller must not proceed).
    public func holdIfBusy(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard isBusy else { return false }
        held.append(action)
        return true
    }
}
