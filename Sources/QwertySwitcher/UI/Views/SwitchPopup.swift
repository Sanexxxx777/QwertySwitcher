import SwiftUI
import AppKit

/// Visual popup indicator near cursor when auto-switch happens (like KeyWiz)
final class SwitchPopupController {
    static let shared = SwitchPopupController()
    private var popupWindow: NSWindow?
    private var hideTimer: DispatchWorkItem?

    func show(from: String, to: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showPopup(label: "\(from.uppercased()) → \(to.uppercased())")
        }
    }

    func showUndo() {
        DispatchQueue.main.async { [weak self] in
            self?.showPopup(label: "↺ Отмена")
        }
    }

    private func showPopup(label: String) {
        hideTimer?.cancel()

        let hostingView = NSHostingView(rootView: PopupBubble(text: label))
        hostingView.frame = NSRect(x: 0, y: 0, width: 120, height: 36)

        // Position near mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let popupOrigin = NSPoint(
            x: mouseLocation.x + 15,
            y: mouseLocation.y - 45
        )

        if let window = popupWindow {
            window.contentView = hostingView
            window.setFrameOrigin(popupOrigin)
            window.orderFrontRegardless()
        } else {
            let window = NSWindow(
                contentRect: NSRect(origin: popupOrigin, size: NSSize(width: 120, height: 36)),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.ignoresMouseEvents = true
            window.contentView = hostingView
            window.orderFrontRegardless()
            self.popupWindow = window
        }

        // Fade out after 1.2 seconds
        let hideWork = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.popupWindow?.animator().alphaValue = 0
            }, completionHandler: {
                self?.popupWindow?.orderOut(nil)
                self?.popupWindow?.alphaValue = 1
            })
        }
        hideTimer = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hideWork)

        // Entrance animation
        popupWindow?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            popupWindow?.animator().alphaValue = 1
        }
    }
}

struct PopupBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(hex: 0xF2D4BA))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x2C2823).opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            )
    }
}
