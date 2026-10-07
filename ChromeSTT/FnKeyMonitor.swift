import Cocoa

final class FnKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false

    var onToggle: (() -> Void)?

    func start() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleFlags(event)
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            Log.write("FnKeyMonitor: failed to create event tap (need Accessibility permission)")
            return
        }
        self.eventTap = tap

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("FnKeyMonitor: started, listening for Fn key")
    }

    private func handleFlags(_ event: CGEvent) {
        let isDown = event.flags.contains(.maskSecondaryFn)
        if isDown && !fnDown {
            fnDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        } else if !isDown && fnDown {
            fnDown = false
        }
    }
}
