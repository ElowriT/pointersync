import AppKit
import SwiftUI

/// A small see-through window beside the main one that shows how to move the mouse, up
/// while the hand rests or crawls during a test. It takes no clicks and no focus, and moves
/// with the main window.
@MainActor
final class HowToPanel {
    private var panel: NSPanel?
    private var glass: Bool?

    func show(_ visible: Bool, model: SetupModel, beside window: NSWindow) {
        if visible {
            let panel = ready(model)
            place(panel, beside: window)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 1
            }
        } else if let panel, panel.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
        }
    }

    /// The panel, made anew when glass was switched on or off since.
    private func ready(_ model: SetupModel) -> NSPanel {
        let glassOn = Settings.shared.glass
        if let panel, glass == glassOn { return panel }
        if let old = panel {
            old.parent?.removeChildWindow(old)
            old.orderOut(nil)
        }
        let card = NSHostingView(rootView: HowToCard(model: model, glass: glassOn))
        let size = card.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.alphaValue = 0
        if glassOn {
            // AppKit's own glass, so the desktop behind shows through it.
            let view = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            view.cornerRadius = 24
            // Tinted with the paper, so the words read the same over any desktop.
            view.tintColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0, alpha: 0.55) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.953, alpha: 0.7)
            }
            view.contentView = card
            panel.contentView = view
        } else {
            panel.contentView = card
        }
        self.panel = panel
        glass = glassOn
        return panel
    }

    /// To the right of the window, else to its left, else over its lower corner; level with
    /// the dial.
    private func place(_ panel: NSPanel, beside window: NSWindow) {
        let w = window.frame, size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? w
        let y = min(max(w.maxY - w.height * 0.42 - size.height / 2, visible.minY + 8), visible.maxY - size.height - 8)
        var x = w.maxX + 14
        if x + size.width > visible.maxX - 8 { x = w.minX - 14 - size.width }
        if x < visible.minX + 8 { x = w.maxX - size.width - 12 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// What the little window says and shows.
struct HowToCard: View {
    @ObservedObject var model: SetupModel
    var glass: Bool
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let content = VStack(alignment: .leading, spacing: 0) {
            MouseDemo()
                .frame(height: 150)
            Caption(text: model.coach == .slow ? tr("Чуть быстрее", "A bit faster") : tr("Води вот так", "Move it like this"),
                    color: Theme.ink)
                .padding(.top, 14)
            FlipLine(text: tr("Большими кругами, всей рукой, примерно круг в секунду.",
                              "Big circles with your whole arm, about one a second."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.72))   // on glass, quieter grey gets lost
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
        .padding(18)
        .frame(width: 232)
        if glass {
            content
        } else {
            content
                .background(Theme.paper.opacity(0.94), in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .clipShape(shape)
        }
    }
}

/// A mouse seen from above going round in a big circle on a pad, an arm swinging it from the
/// elbow, and its trail behind, clockwise, about once a second.
struct MouseDemo: View {
    @ObservedObject private var clock = FrameClock.shared

    var body: some View {
        let t = clock.now
        Canvas { ctx, size in
            let pad = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let padShape = Path(roundedRect: pad, cornerRadius: 18, style: .continuous)
            ctx.stroke(padShape, with: .color(Theme.hairline), lineWidth: 1)
            let c = CGPoint(x: size.width / 2, y: size.height / 2 - 6)
            let rx = size.width * 0.27, ry = size.height * 0.27
            func at(_ a: Double) -> CGPoint { CGPoint(x: c.x + rx * CGFloat(cos(a)), y: c.y + ry * CGFloat(sin(a))) }
            let turn = 1.1
            let a = 2 * .pi * t / turn

            // The way round, dashed, with which way to go.
            var guide = Path()
            guide.addEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
            ctx.stroke(guide, with: .color(Theme.quiet.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let top = at(-.pi / 2)
            var chevron = Path()
            chevron.move(to: CGPoint(x: top.x - 3, y: top.y - 4))
            chevron.addLine(to: CGPoint(x: top.x + 2, y: top.y))
            chevron.addLine(to: CGPoint(x: top.x - 3, y: top.y + 4))
            ctx.stroke(chevron, with: .color(Theme.quiet), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))

            var clipped = ctx
            clipped.clip(to: padShape)
            // The forearm, from an elbow below the pad.
            let mouse = at(a)
            var arm = Path()
            arm.move(to: CGPoint(x: c.x + 16, y: size.height + 40))
            arm.addLine(to: CGPoint(x: mouse.x, y: mouse.y + 14))
            clipped.stroke(arm, with: .color(Theme.ink.opacity(0.07)), style: StrokeStyle(lineWidth: 22, lineCap: .round))
            // The trail of the last third of a turn.
            for k in 0..<24 {
                let back = Double(k) / 24
                let p = at(a - back * 2.1)
                let r = 2.4 * CGFloat(1 - back)
                clipped.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Theme.ink.opacity(0.5 * (1 - back))))
            }
            // The mouse, upright the whole way round, as a hand keeps it.
            let body = CGRect(x: mouse.x - 12, y: mouse.y - 19, width: 24, height: 38)
            let shell = Path(roundedRect: body, cornerRadius: 12, style: .continuous)
            clipped.fill(shell, with: .color(Theme.paper))
            clipped.stroke(shell, with: .color(Theme.ink), lineWidth: 1.5)
            var split = Path()
            split.move(to: CGPoint(x: body.midX, y: body.minY + 1))
            split.addLine(to: CGPoint(x: body.midX, y: body.minY + 13))
            clipped.stroke(split, with: .color(Theme.ink), lineWidth: 1)
            clipped.fill(Path(roundedRect: CGRect(x: body.midX - 1.5, y: body.minY + 5, width: 3, height: 6), cornerRadius: 1.5),
                         with: .color(Theme.ink))
        }
    }
}
