import AppKit

/// A window that eases into its new height instead of snapping to it.
///
/// The settings window sizes itself to its content (`fixedSize` on the SwiftUI
/// root), so switching to a taller tab makes AppKit apply the new frame in a
/// single step — the tab thumb glides, the panel fades, and the window itself
/// jumps. Animating the CONTENT can't fix that: the window frame is set by
/// AppKit after SwiftUI reports its new intrinsic size, one layer above
/// anything a view modifier can reach. So the animation belongs here.
///
/// Width changes and moves pass through untouched — only a height change is
/// what reads as a jump, and animating a drag-resize would fight the user's
/// own pointer.
final class SmoothResizeWindow: NSWindow {
    private var isAnimatingResize = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let heightDelta = abs(frameRect.height - frame.height)
        guard !isAnimatingResize,
              isVisible,
              heightDelta > 1,
              // Respect the system setting rather than inventing our own
              // preference for it — someone who turned motion down did so for
              // every app at once.
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            super.setFrame(frameRect, display: flag)
            return
        }

        isAnimatingResize = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frameRect, display: true)
        } completionHandler: { [weak self] in
            self?.isAnimatingResize = false
        }
    }
}
