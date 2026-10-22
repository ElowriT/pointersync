"""Offline analysis of a PointerSync recording: per source x screen, over the whole file."""
import json, math, sys, collections, statistics as st

PAUSE = 40e6

def q(a, p):
    if not a: return float('nan')
    s = sorted(a); return s[min(len(s) - 1, round((len(s) - 1) * p))]

def lower(a, t):
    lo, hi = 0, len(a)
    while lo < hi:
        m = (lo + hi) // 2
        if a[m] < t: lo = m + 1
        else: hi = m
    return lo

def frame_stats(F, E):
    """F: sorted vsync times; E: sorted events (t, x, y) on this screen."""
    fs = st.median([F[i] - F[i-1] for i in range(1, len(F))])
    lo, hi = lower(F, E[0][0]), lower(F, E[-1][0] + 1)
    F = F[lo:hi]; n = len(F)
    last = [-1] * n; upd = [0] * n; j = -1
    for i in range(n):
        c = 0
        while j + 1 < len(E) and E[j+1][0] <= F[i]: j += 1; c += 1
        last[i] = j; upd[i] = c
    def moving(i):
        li = last[i]
        return li >= 0 and li + 1 < len(E) and F[i] - E[li][0] <= PAUSE and E[li+1][0] - F[i] <= PAUSE
    step = [None] * n
    for i in range(1, n):
        if moving(i) and moving(i-1) and F[i] - F[i-1] <= fs * 1.5:
            a, b = E[last[i-1]], E[last[i]]
            step[i] = math.hypot(b[1] - a[1], b[2] - a[2])
    errs, used = [], []
    for i in range(4, n - 4):
        w = step[i-4:i+5]
        if any(v is None for v in w): continue
        m = sum(w) / 9
        if m < 0.5: continue
        errs.append(abs(step[i] - m) / m); used.append(i)
    h = collections.Counter(min(upd[i], 3) for i in used)
    N = max(len(used), 1)
    stall = sum(1 for i in used if step[i] < 0.05 * sum(step[i-4:i+5]) / 9) / N
    jump = sum(1 for i in used if step[i] > 1.5 * sum(step[i-4:i+5]) / 9) / N
    # phase of each event inside its frame: 0 = right after vsync, 1 = just before the next
    ph = collections.Counter()
    for e in E:
        k = lower(F, e[0])
        if 0 < k < len(F) and F[k] - F[k-1] <= fs * 1.5:
            ph[min(9, int(10 * (e[0] - F[k-1]) / (F[k] - F[k-1])))] += 1
    return dict(refresh=1e9 / fs, frames=len(used), hist=[h[k] / N for k in range(4)],
                uneven=q(errs, .5), uneven95=q(errs, .95), stall=stall, jump=jump,
                phase=[ph[k] for k in range(10)])

def input_unevenness(E):
    """Unevenness of the source's own per-event steps, before any frame aliasing."""
    errs = []
    for i in range(4, len(E) - 3):
        if any(E[k][0] - E[k-1][0] > PAUSE for k in range(i - 2, i + 4)): continue
        s = [math.hypot(E[k][1] - E[k-1][1], E[k][2] - E[k-1][2]) for k in range(i - 3, i + 4)]
        m = sum(s) / 7
        if m < 1: continue
        errs.append(abs(s[3] - m) / m)
    return q(errs, .5), q(errs, .95)

def main(path):
    d = json.load(open(path))
    frames = collections.defaultdict(list)
    for f in d['frames']: frames[f['d']].append(f['t'])
    frames = {k: sorted(set(v)) for k, v in frames.items()}
    def active(disp_id, t):
        F = frames.get(disp_id, [])
        k = lower(F, t)
        return any(0 <= i < len(F) and abs(F[i] - t) < 100e6 for i in (k - 1, k))
    def screen_of(e):
        if d.get('layouts'):
            layout = ([l for l in d['layouts'] if l['t'] <= e[0]] or d['layouts'][:1])[-1]
            for disp in layout['displays']:
                (x0, y0), (w, h) = disp['bounds']
                if x0 <= e[1] < x0 + w and y0 <= e[2] < y0 + h: return disp['id']
            return None
        # Recordings made before layout history: the layout changes when a screen comes or goes,
        # so while only one screen is producing frames the event is on that screen.
        on = [disp for disp in d['displays'] if active(disp['id'], e[0])]
        if len(on) == 1: return on[0]['id']
        for disp in on:
            (x0, y0), (w, h) = disp['bounds']
            if x0 <= e[1] < x0 + w and y0 <= e[2] < y0 + h: return disp['id']
        return None
    by_sender = collections.defaultdict(list)
    for e in d['events']: by_sender[(e['f87'], e['sub'], e.get('m', False))].append((e['t'], e['x'], e['y']))
    for (sender, sub, smoothed), E in sorted(by_sender.items()):
        E.sort()
        iv = [E[i][0] - E[i-1][0] for i in range(1, len(E)) if 0 <= E[i][0] - E[i-1][0] <= PAUSE]
        name = ('trackpad' if sub == 3 else 'mouse') + (' after smoothing' if smoothed else '')
        print(f'== {name} (sender {sender}, subtype {sub}): {len(E)} events, '
              f'{1e9 / st.median(iv):.1f} Hz, interval ms p5/p50/p95 = '
              f'{q(iv, .05) / 1e6:.2f}/{q(iv, .5) / 1e6:.2f}/{q(iv, .95) / 1e6:.2f}')
        iu = input_unevenness(E)
        print(f'   own step unevenness (no frames involved): median {iu[0]:.0%}, p95 {iu[1]:.0%}')
        for disp in d['displays']:
            on = [e for e in E if screen_of(e) == disp['id']]
            if len(on) < 50 or disp['id'] not in frames: continue
            r = frame_stats(frames[disp['id']], on)
            print(f"   {disp['name']} {r['refresh']:.0f} Hz: {r['frames']} moving frames; "
                  f"updates/frame 0/1/2/3+ = {'/'.join(f'{v:.0%}' for v in r['hist'])}; "
                  f"uneven {r['uneven']:.0%} (p95 {r['uneven95']:.0%}); stalls {r['stall']:.0%}, jumps {r['jump']:.0%}")
            tot = sum(r['phase']) or 1
            print('     event phase in frame (10 bins):', ' '.join(f'{v / tot:.0%}' for v in r['phase']))

main(sys.argv[1])
