import CoreGraphics
import Foundation

/// A few shapes someone might draw with the cursor on the start screen, recognized from the
/// path alone with the $P point-cloud method (Vatavu, Anthony, Wobbrock 2012): the drawing
/// and each template become 48 evenly spaced points, scaled and centred the same way, and
/// the closest cloud wins. Order and direction of the strokes don't matter. Circles, lines
/// and scribbles are templates too, so that ordinary moves have somewhere to go.
enum Doodle: String, CaseIterable {
    case heart, star, rude
    case circle, line, corner, zigzag, eight, wave   // nothing to react to

    var isEasterEgg: Bool { self == .heart || self == .star || self == .rude }
    var isClosed: Bool { self != .line && self != .corner && self != .zigzag && self != .wave }
}

enum Doodles {
    static let size = 48

    struct Match { var doodle: Doodle; var distance: Double; var runnerUp: Double; var all: [Doodle: Double] }

    /// What a drawing is, if it is one of the shapes worth a reaction: the closest template,
    /// close enough and clearly closer than any other kind, and a closed shape with the
    /// corners and crossings that shape has (a star: sharp points and its lines crossing; a
    /// heart or the other one: hardly any crossing, a wobbly hand aside).
    static func recognize(_ path: [CGPoint]) -> Doodle? {
        guard var m = match(path) else { return nil }
        let shape = Shape(path)
        guard shape.closed else { return nil }
        // A closed drawing is weighed only against closed shapes: lines, corners and zigzags
        // are there to catch open moves. Unless one of those fits it clearly better: then it is
        // a scribble that happens to end where it began.
        let open = m.all.filter { !$0.key.isClosed }.map(\.value).min() ?? .infinity
        m.all = m.all.filter { $0.key.isClosed }
        guard let best = m.all.min(by: { $0.value < $1.value }), best.value - open < 0.2 else { return nil }
        m = Match(doodle: best.key, distance: best.value,
                  runnerUp: m.all.filter { $0.key != best.key }.map(\.value).min() ?? .infinity, all: m.all)
        func asHeart() -> Match {
            Match(doodle: .heart, distance: m.all[.heart] ?? .infinity,
                  runnerUp: m.all.filter { $0.key != .heart && $0.key != m.doodle }.map(\.value).min() ?? .infinity, all: m.all)
        }
        let heart = m.all[.heart] ?? .infinity
        // A heart drawn tall looks like the other one upside down, but ends in a point where
        // the other one ends round. And mistaking a heart for the other one is the worst
        // mistake to make, so a near tie goes to the heart too.
        if m.doodle == .rude, heart - m.distance < 0.15 || (shape.pointedEnd && heart < 2.6) { m = asHeart() }
        // The other one has more to it than a heart or a star, so it may stray a little further.
        guard m.doodle.isEasterEgg, m.distance < (m.doodle == .rude ? 2.5 : 2.4),
              m.runnerUp - m.distance > (m.doodle == .rude ? 0.3 : 0.15) else { return nil }
        switch m.doodle {
        // Five lines crossing each other at most a couple of times each, not a scribble.
        case .star:
            return shape.corners >= 4 && shape.crossings >= 3 && Double(shape.crossings) <= 2.5 * Double(shape.corners)
                && shape.lengthRatio <= 7 ? .star : nil
        // A dip between the bumps, or a point: a plain round loop is no heart.
        case .heart: return shape.corners <= 4 && shape.crossings <= 3 && (shape.dent > 0.1 || shape.pointedEnd) ? .heart : nil
        case .rude: return shape.crossings <= 3 && shape.elongation >= 1.3 ? .rude : nil
        default: return nil
        }
    }

    /// What a drawing is: tried whole, and without the way in and out, as long as cutting
    /// those off leaves the same kind of shape (or a heart where the whole looked like one of
    /// its look-alikes).
    static func read(_ path: [CGPoint]) -> Doodle? {
        if let d = recognize(path) { return d }
        guard let part = closedPart(path), let d = recognize(part) else { return nil }
        let whole = match(path)?.doodle
        return d == whole || (d == .heart && (whole == .rude || whole == .circle)) ? d : nil
    }

    /// Everything `recognize` weighs, and the drawing itself as 64 points, for the log.
    static func explain(_ path: [CGPoint]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let m = match(path) {
            out["best"] = m.doodle.rawValue
            out["distance"] = (m.distance * 100).rounded() / 100
            out["runnerUp"] = (m.runnerUp * 100).rounded() / 100
        }
        let shape = Shape(path)
        out["closed"] = shape.closed
        out["corners"] = shape.corners
        out["crossings"] = shape.crossings
        out["elongation"] = (shape.elongation * 100).rounded() / 100
        out["dent"] = (shape.dent * 100).rounded() / 100
        out["pointed"] = shape.pointedEnd
        out["points"] = logged(path)
        return out
    }

    /// A drawing as 64 points from its top left corner, for the log.
    static func logged(_ path: [CGPoint]) -> [[Double]] {
        let p = resample(path, count: 64)
        let x0 = p.map(\.x).min()!, y0 = p.map(\.y).min()!
        return p.map { [Double(($0.x - x0) * 10).rounded() / 10, Double(($0.y - y0) * 10).rounded() / 10] }
    }

    /// The drawing without the way in and the way out: a hand first brings the cursor to
    /// where the shape starts and may run on past where it ends. Of the path's first and last
    /// quarters, the start and end that meet best, if they meet at all, and if the shape is
    /// still most of the path: a long wander that happens to cross itself isn't a drawing.
    static func closedPart(_ path: [CGPoint]) -> [CGPoint]? {
        let p = resample(path, count: 96)
        var best: (i: Int, j: Int, gap: CGFloat) = (0, 95, .infinity)
        for i in 0...24 {
            for j in 71...95 {
                let gap = hypot(p[i].x - p[j].x, p[i].y - p[j].y)
                if gap < best.gap { best = (i, j, gap) }
            }
        }
        guard best.i > 0 || best.j < 95, best.j - best.i >= 66 else { return nil }
        let part = Array(p[best.i...best.j])
        let xs = part.map(\.x), ys = part.map(\.y)
        let diagonal = hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        return best.gap < 0.15 * diagonal ? part : nil
    }

    /// The best template for a path, with its distance and the best other kind's.
    static func match(_ path: [CGPoint]) -> Match? {
        guard path.count >= 8 else { return nil }
        let cloud = normalize(path)
        var best: [Doodle: Double] = [:]
        for t in templates {
            let d = greedyDistance(cloud, t.cloud)
            if d < best[t.doodle, default: .infinity] { best[t.doodle] = d }
        }
        let ranked = best.sorted { $0.value < $1.value }
        guard let first = ranked.first else { return nil }
        return Match(doodle: first.key, distance: first.value, runnerUp: ranked.count > 1 ? ranked[1].value : .infinity, all: best)
    }

    /// A drawing's plain geometry, from 64 evenly spaced points.
    struct Shape {
        var closed = false
        var corners = 0
        var crossings = 0
        var elongation = 1.0
        /// How deep the deepest dent is, from the shape's convex outline, for its size: a
        /// heart's dip between its bumps; a circle has none.
        var dent = 0.0
        /// A sharp corner at one end of the shape's long axis: a heart's point. The other
        /// one ends round.
        var pointedEnd = false
        /// The path's length over the shape's size: a star, five lines across, is about 5;
        /// a scribble round and round, far more.
        var lengthRatio = 0.0

        init(_ path: [CGPoint]) {
            let p = resample(path, count: 64)
            let xs = p.map(\.x), ys = p.map(\.y)
            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
            let diagonal = max(hypot(w, h), 1e-6)
            closed = hypot(p[0].x - p[63].x, p[0].y - p[63].y) < 0.3 * diagonal
            // Sharp turns: the direction changes by more than 100° over three points either way.
            var turns = [Double](repeating: 0, count: 64)
            for i in 3..<61 {
                let a = atan2(Double(p[i].y - p[i - 3].y), Double(p[i].x - p[i - 3].x))
                let b = atan2(Double(p[i + 3].y - p[i].y), Double(p[i + 3].x - p[i].x))
                turns[i] = abs(remainder(b - a, 2 * .pi)) * 180 / .pi
            }
            var i = 3
            while i < 61 {
                if turns[i] > 100 {
                    corners += 1
                    while i < 61 && turns[i] > 60 { i += 1 }
                }
                i += 1
            }
            // Crossings of non-neighbouring segments, leaving out where the ends meet.
            func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
                func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
                return side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0
            }
            for i in 0..<62 {
                for j in (i + 2)..<63 where !(i < 4 && j > 58) && cross(p[i], p[i + 1], p[j], p[j + 1]) { crossings += 1 }
            }
            // How much longer the shape is along its main axis than across it.
            let cx = xs.reduce(0, +) / 64, cy = ys.reduce(0, +) / 64
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for q in p {
                let dx = Double(q.x - cx), dy = Double(q.y - cy)
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
            let mean = (sxx + syy) / 2, spread = (((sxx - syy) / 2) * ((sxx - syy) / 2) + sxy * sxy).squareRoot()
            elongation = ((mean + spread) / max(mean - spread, 1e-9)).squareRoot()
            // The convex outline, and how far inside it the path goes.
            let hull = Shape.hull(p)
            func inside(_ q: CGPoint) -> Double {
                var nearest = Double.infinity
                for k in hull.indices {
                    let a = hull[k], b = hull[(k + 1) % hull.count]
                    let abx = Double(b.x - a.x), aby = Double(b.y - a.y)
                    let t = max(0, min(1, (Double(q.x - a.x) * abx + Double(q.y - a.y) * aby) / max(abx * abx + aby * aby, 1e-9)))
                    nearest = min(nearest, hypot(Double(q.x - a.x) - t * abx, Double(q.y - a.y) - t * aby))
                }
                return nearest / max(Double(max(w, h)), 1e-9)
            }
            dent = p.map(inside).max()!
            // The long axis, and where along it each point lies. A point sticks out, on the
            // outline: the dip between two bumps is a sharp turn near an end too, but inward.
            let axis = 0.5 * atan2(2 * sxy, sxx - syy)
            let along = p.map { Double($0.x - cx) * cos(axis) + Double($0.y - cy) * sin(axis) }
            let lo = along.min()!, hi = along.max()!
            for i in 3..<61 where turns[i] > 100 {
                let t = (along[i] - lo) / max(hi - lo, 1e-9)
                if (t < 0.12 || t > 0.88) && inside(p[i]) < 0.06 { pointedEnd = true }
            }
            let length = zip(p, p.dropFirst()).map { Double(hypot($1.x - $0.x, $1.y - $0.y)) }.reduce(0, +)
            lengthRatio = length / max(Double(max(w, h)), 1e-9)
        }

        /// The convex hull, by Andrew's monotone chain.
        static func hull(_ points: [CGPoint]) -> [CGPoint] {
            let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
            func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
            var lower: [CGPoint] = [], upper: [CGPoint] = []
            for q in p {
                while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
                lower.append(q)
            }
            for q in p.reversed() {
                while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
                upper.append(q)
            }
            return Array(lower.dropLast() + upper.dropLast())
        }
    }

    // MARK: - $P

    static func normalize(_ path: [CGPoint]) -> [CGPoint] {
        var points = resample(path, count: size)
        let xs = points.map(\.x), ys = points.map(\.y)
        let scale = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, 1e-6)
        let cx = xs.reduce(0, +) / CGFloat(points.count), cy = ys.reduce(0, +) / CGFloat(points.count)
        for i in points.indices { points[i] = CGPoint(x: (points[i].x - cx) / scale, y: (points[i].y - cy) / scale) }
        return points
    }

    /// `count` points evenly spaced along the path.
    static func resample(_ path: [CGPoint], count: Int) -> [CGPoint] {
        let total = zip(path, path.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
        guard total > 0 else { return Array(repeating: path[0], count: count) }
        let step = total / CGFloat(count - 1)
        var out = [path[0]]
        var carried: CGFloat = 0
        var a = path[0]
        var i = 1
        while i < path.count, out.count < count {
            let b = path[i]
            let d = hypot(b.x - a.x, b.y - a.y)
            if carried + d >= step, d > 0 {
                let t = (step - carried) / d
                let q = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
                out.append(q)
                a = q
                carried = 0
            } else {
                carried += d
                a = b
                i += 1
            }
        }
        while out.count < count { out.append(path[path.count - 1]) }
        return out
    }

    static func greedyDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        let n = a.count
        let step = max(1, Int(Double(n).squareRoot()))
        var best = Double.infinity
        for start in stride(from: 0, to: n, by: step) {
            best = min(best, cloudDistance(a, b, start), cloudDistance(b, a, start))
        }
        return best
    }

    private static func cloudDistance(_ a: [CGPoint], _ b: [CGPoint], _ start: Int) -> Double {
        let n = a.count
        var taken = [Bool](repeating: false, count: n)
        var sum = 0.0
        var i = start
        repeat {
            var nearest = Double.infinity, index = 0
            for j in 0..<n where !taken[j] {
                let d = Double(hypot(a[i].x - b[j].x, a[i].y - b[j].y))
                if d < nearest { nearest = d; index = j }
            }
            taken[index] = true
            sum += (1 - Double((i - start + n) % n) / Double(n)) * nearest
            i = (i + 1) % n
        } while i != start
        return sum
    }

    // MARK: - Templates

    struct Template { var doodle: Doodle; var cloud: [CGPoint] }

    static let templates: [Template] = {
        var all: [Template] = []
        func add(_ doodle: Doodle, _ path: [CGPoint], turns: [Double]) {
            for degrees in turns { all.append(Template(doodle: doodle, cloud: normalize(rotate(path, degrees)))) }
        }
        add(.heart, heart(), turns: [-15, 0, 15])
        for point in [1.8, 2.3, 2.9] { add(.heart, drawnHeart(point: point), turns: [-20, 0, 20]) }
        // And a narrow one, tall and with a long point.
        add(.heart, drawnHeart(point: 2.9).map { CGPoint(x: $0.x * 0.6, y: $0.y) }, turns: [-15, 0, 15])
        add(.star, star(), turns: [-18, 0, 18])
        add(.rude, rude(), turns: [0, 45, 90, 135, 180, 225, 270, 315])
        add(.circle, ellipse(1, 1), turns: [0])
        add(.circle, ellipse(1, 0.8), turns: [0, 45, 90, 135])
        add(.circle, ellipse(1, 0.6), turns: [0, 45, 90, 135])
        add(.circle, ellipse(1, 1, loops: 2), turns: [0])
        add(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)], turns: [0, 45, 90, 135])
        add(.line, arc(), turns: [0, 90, 180, 270])
        add(.corner, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)], turns: [0, 90, 180, 270])
        add(.zigzag, zigzag(), turns: [0, 90])
        add(.eight, eight(), turns: [0, 45, 90, 135])
        add(.wave, wave(), turns: [0, 90])
        return all
    }()

    static func rotate(_ path: [CGPoint], _ degrees: Double) -> [CGPoint] {
        let a = degrees * .pi / 180, c = CGFloat(cos(a)), s = CGFloat(sin(a))
        return path.map { CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
    }

    /// The classic heart curve, from the dip at the top round one lobe, to the point and up
    /// the other. Screen coordinates: y down.
    static func heart() -> [CGPoint] {
        (0...96).map { k in
            let t = 2 * Double.pi * Double(k) / 96
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            return CGPoint(x: x, y: -y)
        }
    }

    /// A heart as people draw it: two round bumps meeting in a dip, and straight sides down to
    /// a point `point` bump-radii below. From the dip, over the left bump, down to the point,
    /// up the right side and over the right bump back to the dip. y down.
    static func drawnHeart(point: Double) -> [CGPoint] {
        var path: [CGPoint] = []
        for k in 0...24 {
            let a = -Double.pi * Double(k) / 24
            path.append(CGPoint(x: -1 + cos(a), y: sin(a)))
        }
        path.append(CGPoint(x: 0, y: point))
        for k in 0...24 {
            let a = -Double.pi * Double(k) / 24
            path.append(CGPoint(x: 1 + cos(a), y: sin(a)))
        }
        return path
    }

    /// Five points in one stroke, each line skipping a point.
    static func star() -> [CGPoint] {
        (0...5).map { k in
            let a = -Double.pi / 2 + Double(k) * 4 * Double.pi / 5
            return CGPoint(x: cos(a), y: sin(a))
        }
    }

    /// The outline everyone has drawn on a school desk at least once: a shaft with a round
    /// end and two round ones at its base, in one stroke. Tip up, y down.
    static func rude() -> [CGPoint] {
        var path: [CGPoint] = []
        func arc(_ cx: Double, _ cy: Double, _ r: Double, from a0: Double, to a1: Double) {
            for k in 0...24 {
                let a = (a0 + (a1 - a0) * Double(k) / 24) * .pi / 180
                path.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
        }
        let w = 0.28, r = 0.36
        // Up the left side of the shaft, round the end, down the right side…
        path.append(CGPoint(x: -w, y: -0.15))
        arc(0, -1.55, w, from: 180, to: 360)
        path.append(CGPoint(x: w, y: -0.15))
        // …round the right one, then the left one, back to the start.
        arc(0.34, 0.12, r, from: -60, to: 160)
        arc(-0.34, 0.12, r, from: 20, to: 240)
        path.append(CGPoint(x: -w, y: -0.15))
        return path
    }

    static func ellipse(_ rx: Double, _ ry: Double, loops: Double = 1) -> [CGPoint] {
        let n = Int(64 * loops)
        return (0...n).map { k in
            let a = 2 * Double.pi * loops * Double(k) / Double(n)
            return CGPoint(x: rx * cos(a), y: ry * sin(a))
        }
    }

    static func arc() -> [CGPoint] {
        (0...32).map { k in
            let a = Double.pi * Double(k) / 32
            return CGPoint(x: cos(a), y: -0.5 * sin(a))
        }
    }

    static func eight() -> [CGPoint] {
        (0...96).map { k in
            let a = 2 * Double.pi * Double(k) / 96
            return CGPoint(x: sin(a), y: sin(a) * cos(a))
        }
    }

    static func wave() -> [CGPoint] {
        (0...48).map { k in
            let t = Double(k) / 48
            return CGPoint(x: 0.4 * sin(2 * .pi * t), y: t)
        }
    }

    static func zigzag() -> [CGPoint] {
        (0...6).map { k in CGPoint(x: Double(k) / 6, y: k % 2 == 0 ? 0 : 0.35) }
    }
}

/// Cuts the cursor's path on the start screen into strokes, a pause between them, and says
/// what a finished drawing was, when it is a shape worth a reaction. The drawing is read as
/// the dial's trail shows it, since that is what the user watches while drawing. The pauses
/// come from the real mouse: after a stop, the dial's cursor still drifts home. A hand may
/// slow down or stop at a corner, so the stroke before (or two) is tried joined with the last
/// one. Only a deliberate drawing counts: 0.4 to 6 seconds long, a good part of the dial, and
/// a path much longer than the shape is wide, which a move across to a button never is.
@MainActor
final class DoodleWatcher {
    private struct Stroke { var shown: [CGPoint]; var began: Double; var ended: Double }

    /// Each drawing weighed, when `--doodle-log` asks for it (see `Doodles.explain`).
    var log: (([String: Any]) -> Void)?
    private var shown: [CGPoint] = []
    private var startedAt = 0.0
    private var lastMove = 0.0
    private var last: CGPoint?
    private var lastShown: CGPoint?
    private var before: [Stroke] = []

    /// One frame: the cursor where it really is, and where the dial shows it.
    func step(real p: CGPoint, shown q: CGPoint, now: Double) -> Doodle? {
        defer {
            last = p
            lastShown = q
        }
        guard let previous = last, let previousShown = lastShown else { return nil }
        if hypot(p.x - previous.x, p.y - previous.y) > 0.25 {
            if shown.isEmpty {
                shown = [previousShown]
                startedAt = now
            }
            shown.append(q)
            lastMove = now
            if now - startedAt > 10 { shown = [] }   // too long for a drawing
            return nil
        }
        guard !shown.isEmpty, now - lastMove > 0.4 else { return nil }
        let finished = Stroke(shown: shown, began: startedAt, ended: lastMove)
        shown = []
        before = Array(before.filter { finished.began - $0.ended < 1.5 }.suffix(2))
        var tries = [finished]
        for k in 0..<before.count {
            let joined = before.suffix(k + 1)
            tries.append(Stroke(shown: joined.flatMap(\.shown) + finished.shown, began: joined.first!.began, ended: finished.ended))
        }
        before.append(finished)
        for (i, t) in tries.enumerated() {
            if let doodle = judge(t.shown, seconds: t.ended - t.began, strokes: i + 1) {
                before = []
                return doodle
            }
        }
        return nil
    }

    private func judge(_ path: [CGPoint], seconds: Double, strokes: Int) -> Doodle? {
        let xs = path.map(\.x), ys = path.map(\.y)
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let length = zip(path, path.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
        // Sizes are the dial's: its cursor goes up to about 62 points out, and a drawing an
        // eighth of the dial across still counts.
        let size = max(w, h)
        let gate = seconds <= 0.4 ? "short" : seconds > 6 ? "long" : size <= 16 ? "small"
                 : min(w, h) <= min(12, 0.3 * size) ? "thin" : length <= 2 * size ? "straight" : "ok"
        let result = gate == "ok" ? Doodles.read(path) : nil
        if let log {
            var entry = gate == "ok" ? Doodles.explain(path) : gate == "short" ? [:] : ["points": Doodles.logged(path)]
            entry["strokes"] = strokes
            entry["seconds"] = (seconds * 100).rounded() / 100
            entry["size"] = [Double(w).rounded(), Double(h).rounded()]
            entry["gate"] = gate
            entry["result"] = result?.rawValue ?? NSNull()
            log(entry)
        }
        return result
    }

    func reset() {
        shown = []
        before = []
        last = nil
        lastShown = nil
    }
}
