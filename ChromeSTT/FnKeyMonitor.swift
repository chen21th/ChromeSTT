import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hid

/// Monitors the Fn (🌐) key and fires onToggle on each press.
final class FnKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var fnDown = false
    private var reenableCount = 0

    var onToggle: (() -> Void)?

    func start() {
        // Two separate TCC permissions are in play: Accessibility lets us *post*
        // the paste keystroke, Input Monitoring lets us *observe* the Fn key.
        // Without the latter the tap installs but macOS disables it immediately.
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        Log.write("Accessibility trusted = \(AXIsProcessTrustedWithOptions(opts))")

        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.write("Input Monitoring access = \(hidAccess.rawValue) (0=granted, 1=denied, 2=unknown)")
        if hidAccess != kIOHIDAccessTypeGranted {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Log.write("Input Monitoring request returned \(granted)")
        }

        guard installTap() else { return }

        // macOS can disable a tap without delivering the disable event (e.g. across
        // sleep/wake or while Secure Input is held). Poll so it always comes back.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.ensureTapEnabled()
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    @discardableResult
    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("FnKeyMonitor: tapCreate failed — Accessibility permission missing")
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = src
        Log.write("FnKeyMonitor: tap installed, listening for Fn")
        return true
    }

    private func ensureTapEnabled() {
        guard let tap = eventTap else {
            Log.write("FnKeyMonitor: tap missing, reinstalling")
            installTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            reenableCount += 1
            // A tap that will not stay enabled almost always means Input Monitoring
            // was never granted; log the first few times, then stay quiet.
            if reenableCount <= 3 {
                Log.write("FnKeyMonitor: tap disabled, re-enabling (secureInput=\(Self.isSecureInputActive), hid=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue))")
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            reenableCount = 0
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.write("FnKeyMonitor: tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")), re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let isDown = event.flags.contains(.maskSecondaryFn)
            if isDown && !fnDown {
                fnDown = true
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            } else if !isDown && fnDown {
                fnDown = false
            }

        default:
            break
        }
    }

    /// True while some app holds Secure Input, which suppresses all event taps.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}
