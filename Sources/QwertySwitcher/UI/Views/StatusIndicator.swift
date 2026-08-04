import SwiftUI
import AppKit

/// Compact confirmation chip under the menu bar: green check when auto-switch turns ON,
/// red cross when it turns OFF. Owner asked to keep the red cross (it reads as "off",
/// not as an error) — only the size was reduced, the semantics stay.
final class StatusIndicatorController {
    static let shared = StatusIndicatorController()
    private var indicatorWindow: NSWindow?
    private var hideTimer: DispatchWorkItem?

    func showEnabled() {
        show(icon: "checkmark.circle.fill", color: Color(red: 0.20, green: 0.78, blue: 0.35))
    }

    func showDisabled() {
        show(icon: "xmark.circle.fill", color: Color(red: 0.94, green: 0.33, blue: 0.31))
    }

    private func show(icon: String, color: Color) {
        DispatchQueue.main.async { [weak self] in
            self?.display(icon: icon, color: color)
        }
    }

    private func display(icon: String, color: Color) {
        hideTimer?.cancel()

        let hostingView = NSHostingView(rootView: StatusBubble(icon: icon, color: color))
        let size = NSSize(width: 34, height: 34)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 12,
            y: visibleFrame.maxY - size.height - 8
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

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            indicatorWindow?.alphaValue = 1
        } else {
            indicatorWindow?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                indicatorWindow?.animator().alphaValue = 1
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: hideWork)
    }
}

struct StatusBubble: View {
    let icon: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 0.94

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(color.opacity(0.92))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            )
            .scaleEffect(scale)
            .onAppear {
                if reduceMotion {
                    scale = 1
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        scale = 1
                    }
                }
            }
    }
}
