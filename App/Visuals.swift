import SwiftUI

/// The app's one picture, and everything in it moves as the cursor does. In the middle, the
/// real cursor, small, with its last frames behind it. Round it, the hand points the way the
/// cursor is from the middle, and while a rate is tried, every frame of the last second is a
/// spoke where the cursor was in that frame, as long as its step then against the steps
/// around it: an even ring is a smooth cursor, the one color marks a stall or a jump. On the
/// rim, how far along the test is.
struct Dial: View {
    enum Mode: Equatable { case idle, measure, countdown, done }

    var mode: Mode
    var progress = 0.0
    var live: [LiveFrame] = []
    var liveHz = 0.0
    var switching = false
    /// A drawing on the start screen being answered: the heart beats in the middle, a star
    /// twinkles in the comb, and the other one makes the dial blush and the cursor shake its head.
    var reaction: SetupModel.Reaction?
    var diameter: CGFloat = 250
    @ObservedObject private var clock = FrameClock.shared

    var body: some View {
        let _ = clock.now   // redraw every frame, as the cursor moves
        Canvas { ctx, size in draw(&ctx, size: size) }
            .frame(width: diameter, height: diameter)
    }

    /// How far from the middle the little cursor may go, for a dial `diameter` wide.
    static func cursorRadius(for diameter: CGFloat) -> CGFloat { (diameter / 2 - 2) * 0.62 - 14 }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let rim = size.width / 2 - 2
        let inner = rim * 0.62
        let unit = (rim - 10 - inner) / 2.6   // the spoke of a step as long as its neighbours'
        let cursor = CursorTrail.shared
        let top = -Double.pi / 2
        func at(_ a: Double, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r) }
        func line(_ a: Double, _ r0: CGFloat, _ r1: CGFloat) -> Path {
            var p = Path()
            p.move(to: at(a, r0))
            p.addLine(to: at(a, r1))
            return p
        }
        func dot(_ p: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        let thin = StrokeStyle(lineWidth: 1.3, lineCap: .round)
        let hand = StrokeStyle(lineWidth: 1.5, lineCap: .round)

        // The rim: a hairline, and how far along, in ink.
        ctx.stroke(dot(c, rim), with: .color(Theme.hairline), lineWidth: 1)
        let done = min(progress, 1)
        if done > 0.001 {
            var arc = Path()
            let steps = max(2, Int(240 * done))
            for i in 0...steps {
                let p = at(top + 2 * .pi * done * Double(i) / Double(steps), rim)
                if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
            }
            ctx.stroke(arc, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        switch mode {
        case .idle:
            // An even comb, lit where the cursor has just gone round.
            let now = clock.now
            let age = reaction.map { now - $0.at } ?? 0
            // In over a fifth of a second, out over the last 0.6.
            let on = reaction == nil ? 0 : max(0, min(1, age / 0.2, (SetupModel.reactionSeconds - age) / 0.6))
            let phase = age.truncatingRemainder(dividingBy: 1)
            let beat = exp(-pow((phase - 0.1) / 0.06, 2)) + 0.6 * exp(-pow((phase - 0.32) / 0.06, 2))
            for i in 0..<CursorTrail.slots {
                let a = top + 2 * .pi * Double(i) / Double(CursorTrail.slots)
                var alpha = 0.14 + 0.72 * cursor.glow[i]
                var color = Theme.ink
                switch reaction?.doodle {
                case .heart: alpha = max(alpha, on * (0.25 + 0.5 * beat))
                case .star: alpha = max(alpha, on * (0.5 + 0.5 * sin(now * 7 + Double(i) * 1.7) * sin(now * 3.3 + Double(i) * 0.9)))
                case .rude:
                    color = Theme.signal
                    alpha = max(alpha, on * 0.7)
                default: break
                }
                ctx.stroke(line(a, inner, inner + unit), with: .color(color.opacity(alpha)), style: thin)
            }
            ctx.stroke(line(cursor.canvasAngle, inner - 8, rim - 9), with: .color(Theme.ink), style: hand)
            if reaction?.doodle == .heart {
                drawHeart(&ctx, center: c, size: (inner - 26) * (1 + 0.1 * beat), alpha: on)
            } else {
                // No, no: the cursor shakes its head at the other one.
                let shake = reaction?.doodle == .rude ? CGFloat(7 * sin(age * 38) * exp(-age * 1.6) * on) : 0
                drawCursor(&ctx, center: CGPoint(x: c.x + shake, y: c.y), radius: Self.cursorRadius(for: size.width), dim: 1, onCanvas: true)
            }

        case .measure:
            let dim = switching ? 0.3 : 1
            drawCursor(&ctx, center: c, radius: Self.cursorRadius(for: size.width), dim: dim, onCanvas: false)
            // The last second of frames, oldest first so the newest lie on top.
            let shown = min(live.count, Int(max(liveHz, 30)))
            for age in stride(from: shown - 1, through: 0, by: -1) {
                let frame = live[live.count - 1 - age]
                let dx = Double(frame.p.x - cursor.center.x), dy = Double(frame.p.y - cursor.center.y)
                guard hypot(dx, dy) > 4 else { continue }
                let a = atan2(dy, dx)
                let fade = (1 - 0.8 * Double(age) / Double(shown)) * dim
                guard let r = frame.r else {
                    ctx.fill(dot(at(a, inner + 1), 0.8), with: .color(Theme.quiet.opacity(0.8 * fade)))
                    continue
                }
                if r < 0.25 {
                    ctx.fill(dot(at(a, inner + 2.5), 2), with: .color(Theme.signal.opacity(fade)))
                    continue
                }
                ctx.stroke(line(a, inner, inner + unit * CGFloat(min(r, 2.6))),
                           with: .color(r > 1.6 ? Theme.signal.opacity(fade) : Theme.ink.opacity(0.92 * fade)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            if !switching {
                ctx.stroke(line(cursor.angle, inner - 8, rim - 9), with: .color(Theme.ink), style: hand)
            }

        case .countdown:
            // Sixty ticks for the time left.
            for i in 0..<60 {
                let turns = Double(i) / 60
                let on = turns < done
                ctx.stroke(line(top + 2 * .pi * turns, inner + unit * 0.3, inner + unit * (on ? 1.3 : 0.9)),
                           with: .color(on ? Theme.ink.opacity(0.85) : Theme.hairline), style: thin)
            }

        case .done:
            for i in 0..<CursorTrail.slots {
                let a = top + 2 * .pi * Double(i) / Double(CursorTrail.slots)
                ctx.stroke(line(a, inner, inner + unit), with: .color(Theme.ink.opacity(0.8)), style: thin)
            }
        }
    }

    /// A heart in the one color, as wide as `size`.
    private func drawHeart(_ ctx: inout GraphicsContext, center c: CGPoint, size: CGFloat, alpha: Double) {
        let points = Doodles.heart()
        let xs = points.map(\.x), ys = points.map(\.y)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let cy = (ys.max()! + ys.min()!) / 2
        var path = Path()
        for (i, p) in points.enumerated() {
            let q = CGPoint(x: c.x + p.x / span * size, y: c.y + (p.y - cy) / span * size)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        ctx.fill(path, with: .color(Theme.signal.opacity(0.18 * alpha)))
        ctx.stroke(path, with: .color(Theme.signal.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    /// The real cursor, small, in the middle: it moves as the hand moves the mouse, its last
    /// frames trailing behind. On the start screen's canvas the trail is two seconds long, so a
    /// drawing shows; in the test, on the orbit, a quarter of a second.
    private func drawCursor(_ ctx: inout GraphicsContext, center c: CGPoint, radius: CGFloat, dim: Double, onCanvas: Bool) {
        let trail = CursorTrail.shared
        guard trail.points.count > 1 else { return }
        let path = trail.points.suffix(onCanvas ? 240 : 36).map { p -> CGPoint in
            let q = onCanvas ? trail.canvas(p) : trail.place(p, radius: radius)
            return CGPoint(x: c.x + q.x, y: c.y + q.y)
        }
        for i in 1..<path.count {
            var segment = Path()
            segment.move(to: path[i - 1])
            segment.addLine(to: path[i])
            let a = pow(Double(i) / Double(path.count - 1), 1.5)
            ctx.stroke(segment, with: .color(Theme.ink.opacity(0.5 * a * dim)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        // The pointer, its tip on the newest position, outlined like the real one.
        let tip = path[path.count - 1]
        let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 16), (3.9, 12.3), (6.6, 18.3), (9.2, 17.2), (6.6, 11.3), (11.6, 11.3)]
        var arrow = Path()
        for (i, q) in outline.enumerated() {
            let point = CGPoint(x: tip.x + q.0, y: tip.y + q.1)
            if i == 0 { arrow.move(to: point) } else { arrow.addLine(to: point) }
        }
        arrow.closeSubpath()
        ctx.stroke(arrow, with: .color(Theme.paper.opacity(dim)), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        ctx.fill(arrow, with: .color(Theme.ink.opacity(dim)))
    }
}

/// One rate's frames as a comb: each line as long as that frame's step against the steps
/// around it, the one color where the cursor stood still (a dot) or jumped. Drifts slowly.
struct RhythmComb: View {
    var steps: [Double]
    var ink: Color
    @ObservedObject private var clock = FrameClock.shared

    var body: some View {
        Canvas { ctx, size in
            guard !steps.isEmpty else { return }
            let pitch: CGFloat = 4
            let shown = Int(size.width / pitch) + 1
            let shift = clock.now * 5
            let first = Int(shift.rounded(.down))
            let offset = CGFloat(shift - Double(first)) * pitch
            let base = size.height - 1.5
            for i in 0...shown {
                let r = steps[(first + i) % steps.count]
                let x = CGFloat(i) * pitch - offset + pitch / 2
                if r < 0.25 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: base - 1.6, width: 3.2, height: 3.2)), with: .color(Theme.signal))
                    continue
                }
                var line = Path()
                line.move(to: CGPoint(x: x, y: base))
                line.addLine(to: CGPoint(x: x, y: base - CGFloat(min(r, 2.2) / 2.2) * (size.height - 3)))
                ctx.stroke(line, with: .color(r > 1.6 ? Theme.signal : ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

/// Every rate tried, one row each: its frames as a comb, its score, and what it is. With
/// glass on, the chosen row sits on a glass lens that flows over to the next one chosen: its
/// front edge runs ahead and the back edge catches up, like a drop.
struct RateTable: View {
    var trials: [RateTrial]   // highest rate first
    var selected: Double?
    var recommended: Double?
    var original: Double
    var previous: [Double: Double]
    var pick: (Double) -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var rows: [Double: CGRect] = [:]
    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Hairline()
                ForEach(trials) { t in
                    row(t)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: RowFrames.self, value: [t.hz: g.frame(in: .named("table"))])
                        })
                    Hairline()
                }
            }
            .background(alignment: .topLeading) {
                if settings.glass, selected.flatMap({ rows[$0] }) != nil {
                    Color.clear
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(height: max(0, bottom - top))
                        .padding(.horizontal, -12)
                        .offset(y: top)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .coordinateSpace(.named("table"))
            .onPreferenceChange(RowFrames.self) { new in
                rows = new
                if let hz = selected, let f = new[hz], abs(f.minY + 2 - top) > 0.5 || abs(f.maxY - 2 - bottom) > 0.5 {
                    top = f.minY + 2
                    bottom = f.maxY - 2
                }
            }
            .onChange(of: selected) { old, new in glide(from: old, to: new) }
            Caption(text: tr("Черта — кадр · цветом — рывок · нажми, чтобы выбрать", "Line = frame · color = stutter · click to choose"),
                    size: 9.5)
                .padding(.top, 10)
        }
    }

    private func glide(from old: Double?, to new: Double?) {
        guard let new, let f = rows[new] else { return }
        let ahead = Animation.spring(response: 0.3, dampingFraction: 0.8)
        let behind = Animation.spring(response: 0.5, dampingFraction: 0.76)
        let down = (old.flatMap { rows[$0]?.minY } ?? f.minY) < f.minY
        withAnimation(down ? ahead : behind) { bottom = f.maxY - 2 }
        withAnimation(down ? behind : ahead) { top = f.minY + 2 }
    }

    private func row(_ t: RateTrial) -> some View {
        let on = t.hz == selected
        let tags = [t.hz == recommended ? tr("Лучше", "Best") : nil, abs(t.hz - original) < 0.5 ? tr("Сейчас", "Now") : nil].compactMap { $0 }
        return Button { pick(t.hz) } label: {
            HStack(spacing: 14) {
                Text(f0(t.hz))
                    .font(Theme.mono(13))
                    .foregroundStyle(on ? Theme.ink : Theme.quiet)
                    .frame(width: 32, alignment: .leading)
                RhythmComb(steps: t.strip, ink: on ? Theme.ink : Theme.quiet)
                    .frame(height: 22)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(pct(t.smooth))
                        .font(Theme.mono(13))
                        .foregroundStyle(on ? Theme.ink : Theme.quiet)
                    if let before = previous[t.hz] {
                        Caption(text: tr("было \(pct(before))", "was \(pct(before))"), size: 9)
                    }
                }
                .frame(width: 58, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tags, id: \.self) { Caption(text: $0, color: t.hz == recommended ? Theme.ink : Theme.quiet, size: 9) }
                }
                .frame(width: 52, alignment: .leading)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

private struct RowFrames: PreferenceKey {
    static var defaultValue: [Double: CGRect] { [:] }
    static func reduce(value: inout [Double: CGRect], nextValue: () -> [Double: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Mouse reports (dots) against screen frames (bars), slowed down 28 times. A dashed bar is
/// a frame where the cursor stood still; a colored one got two reports, and the cursor jumped.
struct RhythmLane: View {
    var reports: [Double]   // ms from the start of a run of motion
    var hz: Double
    var slow: Double = 28
    var span: Double = 72   // ms of mouse time across the lane
    @ObservedObject private var clock = FrameClock.shared

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size: size, t: clock.now)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        guard let total = reports.last, total > span * 1.5 else { return }
        let now = (t * 1000 / slow).truncatingRemainder(dividingBy: total - span) + span / 2
        let start = now - span / 2
        let px = size.width / span
        let dotY = size.height * 0.2
        let barY = size.height * 0.55
        let barH = size.height * 0.36
        let frame = 1000 / hz

        func lower(_ x: Double) -> Int {   // reports at or before x
            var lo = 0, hi = reports.count
            while lo < hi { let m = (lo + hi) / 2; if reports[m] <= x { lo = m + 1 } else { hi = m } }
            return lo
        }

        var k = (start / frame).rounded(.down)
        while k * frame < start + span {
            let a = k * frame, b = a + frame
            let rect = CGRect(x: (a - start) * px + 1.5, y: barY, width: frame * px - 3, height: barH)
            let alpha = b <= now ? 1.0 : 0.3
            let bar = Path(roundedRect: rect, cornerRadius: 3.5)
            switch lower(b) - lower(a) {
            case 0: ctx.stroke(bar, with: .color(Theme.signal.opacity(alpha)), style: StrokeStyle(lineWidth: 1.3, dash: [3, 2.5]))
            case 1: ctx.fill(bar, with: .color(Theme.ink.opacity(0.82 * alpha)))
            default: ctx.fill(bar, with: .color(Theme.signal.opacity(alpha)))
            }
            k += 1
        }

        for r in reports[lower(start)..<lower(start + span)] {
            let x = (r - start) * px
            let alpha = r <= now ? 1.0 : 0.3
            let f = (r / frame).rounded(.up) - 1   // the frame this report shows up in
            var link = Path()
            link.move(to: CGPoint(x: x, y: dotY + 4))
            link.addLine(to: CGPoint(x: ((f + 0.5) * frame - start) * px, y: barY))
            ctx.stroke(link, with: .color(Theme.ink.opacity(0.28 * alpha)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 3.4, y: dotY - 3.4, width: 6.8, height: 6.8)),
                     with: .color(Theme.ink.opacity(alpha)))
        }

        ctx.fill(Path(CGRect(x: size.width / 2 - 0.5, y: 0, width: 1, height: size.height)),
                 with: .color(Theme.quiet.opacity(0.35)))
    }
}

struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}
