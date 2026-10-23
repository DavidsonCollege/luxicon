import Foundation

/// Watches one directory for entries being added, removed, or renamed (the
/// listener's atomic writes are renames) and calls `onChange` once per burst
/// of events, `debounce` seconds after the last one.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(url: URL, debounce: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.onChange()
        }
    }
}
