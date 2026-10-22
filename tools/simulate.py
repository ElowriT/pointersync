"""Replays a PointerSync recording through cursor-smoothing strategies, frame by frame.

For every vsync of the screen the cursor was on, each strategy decides where the cursor
would be drawn, using only events that had arrived by then. The result is scored on:
  uneven   - |step - average step of the surrounding 9 frames| / that average (median, p95)
  stalls   - frames where a moving cursor did not move; jumps - frames with a step over 1.5x
  latency  - how far behind the hand the drawn cursor is, in ms (best time shift to the true path)
  jitter   - distance from the true path after that shift, in points (p95)
  overshoot- how far past the point where the hand stopped the cursor went (p95 of stops, points)
  reversals- direction changes of the drawn cursor per direction change of the mouse

Usage: python3 -I simulate.py recording.json
"""
import bisect, collections, json, math, statistics as st, sys

PAUSE = 40e6          # a longer gap between events means the hand stopped
HALF = 4              # unevenness compares a step with the average of +-4 frames


def q(a, p):
    if not a:
        return float('nan')
    s = sorted(a)
    return s[min(len(s) - 1, round((len(s) - 1) * p))]


def retime(E, period):
    """Snaps event times onto the device's report grid.

    Bluetooth delivers reports on a fixed connection interval, but a report can miss its
    slot and arrive in the next one together with the following report. Two reports in one
    slot mean the first belongs to an earlier, empty slot. Arrival times still decide when
    a report can be used.

    Returns (first, final): the grid time each report gets when it arrives, and the one it
    ends up with after the next report has arrived (only that one can move it back).
    """
    first, final = [], []
    for i, (t, x, y) in enumerate(E):
        if i == 0 or t - E[i - 1][0] > PAUSE:
            g = float(t)
        else:
            n = round((t - final[-1]) / period)
            if n <= 0:
                # Same slot as the previous report: move that one back if its earlier slot is free.
                if len(final) >= 2 and final[-1] - period > final[-2] + period / 2 \
                        and E[i - 1][0] - E[i - 2][0] <= PAUSE:
                    final[-1] -= period
                g = final[-1] + period
            else:
                g = final[-1] + n * period
            # Follow the arrival phase slowly, so clock drift does not build up.
            g += 0.05 * (t - g)
        first.append(g)
        final.append(g)
    return first, final


class Path:
    """Piecewise-linear cursor path through samples (times, positions)."""

    def __init__(self, times, E):
        self.t = times
        self.p = [(x, y) for _, x, y in E]

    def at(self, tau):
        t = self.t
        k = bisect.bisect_right(t, tau) - 1
        if k < 0:
            return self.p[0]
        if k + 1 >= len(t) or t[k + 1] - t[k] > PAUSE:
            return self.p[k]
        w = (tau - t[k]) / (t[k + 1] - t[k])
        a, b = self.p[k], self.p[k + 1]
        return (a[0] + (b[0] - a[0]) * w, a[1] + (b[1] - a[1]) * w)


def shown_hold(F, E):
    """What macOS does now: the cursor sits where the last event put it."""
    out, j = [], -1
    for v in F:
        while j + 1 < len(E) and E[j + 1][0] <= v:
            j += 1
        out.append((E[j][1], E[j][2]) if j >= 0 else None)
    return out


def shown_resampled(F, E, times, lag, max_pred, period):
    """Cursor placed at time (vsync - lag) on the path through the events that have arrived.

    `times` is (first, final) from retime(), or one list used for both. Inside the known
    samples it interpolates; past the newest one it extrapolates the last velocity for at
    most max_pred, and only while the newest report is not overdue; otherwise it holds.
    """
    first, final = times if isinstance(times, tuple) else (times, times)
    out, j = [], -1
    for v in F:
        while j + 1 < len(E) and E[j + 1][0] <= v:
            j += 1
        if j < 0:
            out.append(None)
            continue

        def u(k):   # grid time of report k as known at this frame
            return first[j] if k == j else final[k]

        tau = v - lag
        k = j if tau >= first[j] else bisect.bisect_right(final, tau, 0, j) - 1
        if k < 0:
            out.append((E[0][1], E[0][2]))
        elif k < j and u(k + 1) - u(k) <= PAUSE:
            w = (tau - u(k)) / (u(k + 1) - u(k))
            a, b = E[k], E[k + 1]
            out.append((a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w))
        else:
            a = E[k]
            h = min(tau - u(k), max_pred)
            if k >= 1 and u(k) - u(k - 1) <= PAUSE and v - E[k][0] <= 1.5 * period and h > 0:
                b = E[k - 1]
                dt = u(k) - u(k - 1)
                out.append((a[1] + (a[1] - b[1]) / dt * h, a[2] + (a[2] - b[2]) / dt * h))
            else:
                out.append((a[1], a[2]))
    return out


def shown_adaptive(F, E, times, mode_lag, full, period, v0=0.3, v1=1.5, slew=0.25, guard=True):
    """Prediction only for fast, steady motion; the lag eases between full and the mode's."""
    first, final = times if isinstance(times, tuple) else (times, times)
    out, j, prev, lag, last_v = [], -1, None, full, None
    for v in F:
        while j + 1 < len(E) and E[j + 1][0] <= v: j += 1
        if j < 0: out.append(None); continue
        def u(k): return first[j] if k == j else final[k]
        # how much to predict: speed and steadiness of the last two report steps
        g = 0.0
        if j >= 2 and u(j) - u(j - 2) <= 2 * PAUSE and v - E[j][0] <= 1.5 * period:
            a, b, c = E[j - 2], E[j - 1], E[j]
            s1 = (b[1] - a[1], b[2] - a[2]); s2 = (c[1] - b[1], c[2] - b[2])
            m1, m2 = math.hypot(*s1), math.hypot(*s2)
            speed = math.hypot(c[1] - a[1], c[2] - a[2]) / ((u(j) - u(j - 2)) / 1e6)   # pt per ms
            if m1 > 0 and m2 > 0:
                cos = (s1[0] * s2[0] + s1[1] * s2[1]) / (m1 * m2)
                ratio = m2 / m1
                if cos > 0.8 and 0.6 < ratio < 1.6:
                    x = min(max((speed - v0) / (v1 - v0), 0), 1)
                    g = x * x * (3 - 2 * x)
        target = full - g * (full - mode_lag)
        if last_v is not None:
            step = slew * (v - last_v)
            lag = min(max(target, lag - step), lag + step)
        last_v = v
        tau = v - lag
        k = j if tau >= first[j] else bisect.bisect_right(final, tau, 0, j) - 1
        if k < 0: p = (E[0][1], E[0][2])
        elif k < j and u(k + 1) - u(k) <= PAUSE:
            w = (tau - u(k)) / (u(k + 1) - u(k)); a, b = E[k], E[k + 1]
            p = (a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w)
        else:
            a = E[k]; h = min(tau - u(k), full - lag); p = (a[1], a[2])
            if k >= 1 and h > 0 and u(k) - u(k - 1) <= PAUSE and v - E[k][0] <= 1.5 * period:
                b = E[k - 1]; dt = u(k) - u(k - 1)
                p = (a[1] + (a[1] - b[1]) / dt * h, a[2] + (a[2] - b[2]) / dt * h)
        if guard and prev is not None and j >= 1:
            if k < 0: kk = 0
            elif k < j: kk = k + 1
            else: kk = k
            rx, ry = E[kk][1] - E[max(kk - 1, 0)][1], E[kk][2] - E[max(kk - 1, 0)][2]
            dx, dy = p[0] - prev[0], p[1] - prev[1]
            if rx * dx < 0: p = (prev[0], p[1])
            if ry * dy < 0: p = (p[0], prev[1])
        out.append(p); prev = p
    return out


def reversals(steps, eps=0.05):
    """Sign changes of a coordinate's steps: many more than the mouse made reads as a shake."""
    n, last = 0, 0
    for v in steps:
        if abs(v) < eps:
            continue
        s = 1 if v > 0 else -1
        if last and s != last:
            n += 1
        last = s
    return n


def path_reversals(points):
    pts = [p for p in points if p]
    return (reversals([pts[i][0] - pts[i - 1][0] for i in range(1, len(pts))])
            + reversals([pts[i][1] - pts[i - 1][1] for i in range(1, len(pts))]))


def score(F, E, shown, truth, moving):
    n = len(F)
    step = [None] * n
    for i in range(1, n):
        if moving[i] and moving[i - 1] and shown[i] and shown[i - 1]:
            step[i] = math.hypot(shown[i][0] - shown[i - 1][0], shown[i][1] - shown[i - 1][1])
    errs, stalls, jumps = [], 0, 0
    for i in range(HALF, n - HALF):
        w = step[i - HALF:i + HALF + 1]
        if any(s is None for s in w):
            continue
        m = sum(w) / len(w)
        if m < 0.5:
            continue
        errs.append(abs(step[i] - m) / m)
        stalls += step[i] < 0.05 * m
        jumps += step[i] > 1.5 * m
    N = max(len(errs), 1)

    # Latency: the time shift that brings the drawn cursor closest to the true path.
    idx = [i for i in range(n) if moving[i] and shown[i]]
    best = None
    for d10 in range(0, 301, 5):            # 0..30 ms in 0.5 ms steps
        d = d10 * 1e5
        dist = []
        for i in idx:
            p = truth.at(F[i] - d)
            dist.append(math.hypot(shown[i][0] - p[0], shown[i][1] - p[1]))
        m = sum(dist) / len(dist)
        if best is None or m < best[0]:
            best = (m, d, dist)
    _, lag, dist = best

    # Overshoot: after the hand stops, how far past the stop point the cursor goes.
    over = []
    for k in range(2, len(E)):
        nxt = E[k + 1][0] if k + 1 < len(E) else float('inf')
        if nxt - E[k][0] <= 80e6 or E[k][0] - E[k - 1][0] > PAUSE:
            continue
        dx, dy = E[k][1] - E[k - 2][1], E[k][2] - E[k - 2][2]
        speed = math.hypot(dx, dy)
        if speed < 2:
            continue
        ux, uy = dx / speed, dy / speed
        lo = bisect.bisect_left(F, E[k][0])
        hi = bisect.bisect_left(F, E[k][0] + 80e6)
        o = 0.0
        for i in range(lo, hi):
            if shown[i]:
                o = max(o, (shown[i][0] - E[k][1]) * ux + (shown[i][1] - E[k][2]) * uy)
        over.append(o)
    real = max(path_reversals([(x, y) for _, x, y in E]), 1)
    return dict(frames=len(errs), uneven=q(errs, .5), uneven95=q(errs, .95), stalls=stalls / N,
                jumps=jumps / N, latency=lag / 1e6, jitter95=q(dist, .95), overshoot95=q(over, .95),
                stops=len(over), reversals=path_reversals(shown) / real)


def load(path):
    d = json.load(open(path))
    frames = collections.defaultdict(list)
    for f in d['frames']:
        frames[f['d']].append(f['t'])
    frames = {k: sorted(set(v)) for k, v in frames.items()}

    def active(disp_id, t):
        F = frames.get(disp_id, [])
        k = bisect.bisect_left(F, t)
        return any(0 <= i < len(F) and abs(F[i] - t) < 100e6 for i in (k - 1, k))

    def screen_of(e):
        if d.get('layouts'):
            layout = ([l for l in d['layouts'] if l['t'] <= e[0]] or d['layouts'][:1])[-1]
            cands = layout['displays']
        else:
            # Older recordings have no layout history: while only one screen makes frames,
            # the event is on that screen.
            cands = [disp for disp in d['displays'] if active(disp['id'], e[0])]
            if len(cands) == 1:
                return cands[0]['id']
        for disp in cands:
            (x0, y0), (w, h) = disp['bounds']
            if x0 <= e[1] < x0 + w and y0 <= e[2] < y0 + h:
                return disp['id']
        return None

    sources = collections.defaultdict(list)
    for e in d['events']:
        sources[(e['f87'], e['sub'])].append((e['t'], e['x'], e['y']))
    return d, frames, sources, screen_of


def main(path):
    d, frames, sources, screen_of = load(path)
    names = {disp['id']: disp['name'] for disp in d['displays']}
    results = []
    for (sender, sub), E in sorted(sources.items(), key=lambda kv: kv[0][1]):
        E.sort()
        iv = [E[i][0] - E[i - 1][0] for i in range(1, len(E)) if E[i][0] - E[i - 1][0] <= PAUSE]
        period = st.median([x for x in iv if x > 0])
        device = 'Трекпад' if sub == 3 else 'Мышь'
        for disp_id in names:
            on = [e for e in E if screen_of(e) == disp_id]
            if len(on) < 200 or disp_id not in frames:
                continue
            F0 = frames[disp_id]
            F = F0[bisect.bisect_left(F0, on[0][0]):bisect.bisect_right(F0, on[-1][0])]
            grid = retime(on, period)
            truth = Path(grid[1], on)
            raw_t = [float(t) for t, _, _ in on]
            moving = []
            for v in F:
                k = bisect.bisect_right(raw_t, v) - 1
                moving.append(0 <= k < len(on) - 1 and v - raw_t[k] <= PAUSE and raw_t[k + 1] - v <= PAUSE)
            strategies = [('Сейчас (macOS)', shown_hold(F, on))]
            full = period + 1e6       # one report interval plus a margin for jitter
            strategies.append(('Интерполяция, без выравнивания',
                               shown_resampled(F, on, raw_t, full, 0, period)))
            for frac in (1.0, 0.75, 0.5, 0.25, 0.0):
                lag = full * frac
                # Predict just enough to bridge a normal report interval, never more.
                strategies.append((f'Выравнивание, сдвиг {lag / 1e6:.1f} мс',
                                   shown_resampled(F, on, grid, lag, full - lag, period)))
            # What the app does: prediction only for fast steady motion, never a step back.
            for frac, mode in ((0.75, 'Баланс'), (0.5, 'Быстро'), (0.25, 'Быстрее macOS')):
                strategies.append((f'Приложение: {mode}', shown_adaptive(F, on, grid, full * frac, full, period)))
            rows = [(name, score(F, on, shown, truth, moving)) for name, shown in strategies]
            results.append((device, names[disp_id], 1e9 / st.median([F[i] - F[i - 1] for i in range(1, len(F))]),
                            1e9 / period, rows))

    for device, screen, hz, src_hz, rows in results:
        print(f'\n## {device} ({src_hz:.0f} Гц) на {screen} ({hz:.0f} Гц)')
        base = rows[0][1]['latency']
        print(f"{'вариант':38} {'неровн.':>8} {'p95':>6} {'стоп':>6} {'скачки':>7} {'задержка':>9} {'+к macOS':>9} {'дрожь p95':>10} {'перелёт':>8} {'развороты':>10}")
        for name, r in rows:
            print(f"{name:38} {r['uneven']:8.0%} {r['uneven95']:6.0%} {r['stalls']:6.0%} {r['jumps']:7.0%} "
                  f"{r['latency']:7.1f}мс {r['latency'] - base:+7.1f}мс {r['jitter95']:8.1f}pt {r['overshoot95']:6.1f}pt {r['reversals']:8.1f}x")
    json.dump([dict(device=a, screen=b, hz=c, src_hz=s, rows=r) for a, b, c, s, r in results],
              open(sys.argv[2], 'w'), ensure_ascii=False, indent=1) if len(sys.argv) > 2 else None


if __name__ == '__main__':
    main(sys.argv[1])
