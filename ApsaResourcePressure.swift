import AppKit

// Reacts to system events only. There is no timer, so it costs nothing while the
// machine and the browser are idle. WebKit's own cache is left alone: clearing it
// under pressure makes the active page fetch and decode again when that is slowest.
final class ApsaResourcePressure {
    private let hibernate: (TimeInterval) -> Void
    private let purge: () -> Void
    private var source: DispatchSourceMemoryPressure?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastResponse = Date.distantPast

    init(hibernate: @escaping (TimeInterval) -> Void, purge: @escaping () -> Void) {
        self.hibernate = hibernate
        self.purge = purge
    }

    func start() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let event = pressure?.data else { return }
            self.handle(event)
        }
        pressure.resume()
        source = pressure

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (center, center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.adapt() }),
            (center, center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.adapt() }),
            (center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.hibernate(15 * 60) }),
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.hibernate(60) })
        ]
        adapt()
    }

    // The system repeats these events while it compresses and swaps. Answering each
    // one would cost the foreground more than the memory it frees.
    private func handle(_ event: DispatchSource.MemoryPressureEvent) {
        guard Date().timeIntervalSince(lastResponse) >= 30 else { return }
        lastResponse = Date()
        if event.contains(.critical) {
            purge()
            hibernate(2 * 60)
        } else if event.contains(.warning) {
            hibernate(10 * 60)
        }
    }

    private func adapt() {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical {
            purge()
            hibernate(5 * 60)
        } else if info.thermalState == .serious || info.isLowPowerModeEnabled {
            hibernate(5 * 60)
        }
    }

    deinit {
        source?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
    }
}
