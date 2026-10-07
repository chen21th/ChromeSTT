import AppKit
import Carbon.HIToolbox

final class CursorPaster {
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateCmdV()

        if let old = oldContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
