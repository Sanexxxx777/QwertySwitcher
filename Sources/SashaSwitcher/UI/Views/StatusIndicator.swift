import SwiftUI
import AppKit

/// Shows a large icon in the top-right corner of the screen (like Caramba)
/// ✅ when auto-switch is ON, ❌ when OFF
final class StatusIndicatorController {
    static let shared = StatusIndicatorController()
    private var indicatorWindow: NSWindow?
    private var hideTimer: DispatchWorkItem?

    func showEnabled() {
        show(icon: "checkmark.circle.fill", color: .green)
    }

    func showDisabled() {
        show(icon: "xmark.circle.fill", color: .red)
    }

    private func show(icon: String, color: Color) {
        DispatchQueue.main.async { [weak self] in
            self?.display(icon: icon, color: color)
        }
    }

    private func display(icon: String, color: Color) {
        hideTimer?.cancel()

        let hostingView = NSHostingView(rootView: StatusBubble(icon: icon, color: color))
        let size = NSSize(width: 64, height: 64)
        hostingView.frame = NSRect(origin: .zero, size: size)

        // Position: top-right corner of main screen
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(
            x: screen.frame.maxX - size.width - 20,
            y: screen.frame.maxY - size.height - 40 // below menu bar
        )

        if let window = indicatorWindow {
            window.contentView = hostingView
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            window.orderFrontRegardless()
        } else {
            let window = NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = true
            window.contentView = hostingView
            window.orderFrontRegardless()
            self.indicatorWindow = window
        }

        // Entrance: scale up
        indicatorWindow?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            indicatorWindow?.animator().alphaValue = 1
        }

        // Auto-hide after 1.5 seconds
        let hideWork = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self?.indicatorWindow?.animator().alphaValue = 0
            }, completionHandler: {
                self?.indicatorWindow?.orderOut(nil)
            })
        }
        hideTimer = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWork)
    }
}

struct StatusBubble: View {
    let icon: String
    let color: Color

    @State private var scale: CGFloat = 0.3

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 40, weight: .medium))
            .foregroundColor(color)
            .frame(width: 60, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            )
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    scale = 1.0
                }
            }
    }
}
