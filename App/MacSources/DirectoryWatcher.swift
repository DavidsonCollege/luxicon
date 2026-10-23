import Foundation

/// Watches one directory for entries being added, removed, or renamed (the
/// listener's atomic writes are renames) and calls `onChange` once per burst
/// of events, `debounce` seconds after the last one.
///
/// The watch is on an open descriptor, which follows the folder's inode, not
/// its path. If the folder itself is deleted or moved away (e.g. to the
/// Trash), the watcher drops that descriptor, polls until a folder exists at
/// the path again (the app, the listener, or the user may recreate it), and
/// re-arms there, so it never goes silent.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var rearm: Task<Void, Never>?
    private var stopped = false

    init(url: URL, debounce: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stopped = false
        arm()
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        rearm?.cancel()
        rearm = nil
        source?.cancel()
        source = nil
    }

    private func arm() {
        guard !stopped, source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there (yet): wait for it.
            waitForDirectory()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            let events = source.data
            MainActor.assumeIsolated { self?.handle(events) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        scheduleChange()
        guard !events.isDisjoint(with: [.delete, .rename]) else { return }
        // The folder itself went away; this descriptor now watches a dead or
        // relocated folder. Re-arm on the path once one is back.
        source?.cancel()
        source = nil
        waitForDirectory()
    }

    /// Poll (cheaply: one stat per second) until a directory is at `url`,
    /// then watch it and report a change, since files may already be there.
    private func waitForDirectory() {
        guard !stopped, rearm == nil else { return }
        rearm = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: self.url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    self.rearm = nil
                    self.arm()
                    self.scheduleChange()
                    return
                }
            }
        }
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
