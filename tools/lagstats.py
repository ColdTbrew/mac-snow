#!/usr/bin/env python3
"""Drag lag from tools/testwin.swift lagtest logs: how far MacSnow's idea of the window
(last 'A' line) is from where the window really is (last 'W' line), sampled every 1 ms."""
import sys, math, bisect
W = [tuple(map(float, l.split()[1:4])) for l in open(sys.argv[1]) if l.startswith("W")]
A = [tuple(map(float, l.split()[1:4])) for l in open(sys.argv[2]) if l.startswith("A")]
R = [tuple(map(float, l.split()[1:4])) for l in open(sys.argv[2]) if l.startswith("R")]
wt = [w[0] for w in W]; at = [a[0] for a in A]
offs = []
t = W[0][0]
while t < W[-1][0]:
    i = bisect.bisect_right(wt, t) - 1; j = bisect.bisect_right(at, t) - 1
    if j >= 0: offs.append(math.hypot(A[j][1] - W[i][1], A[j][2] - W[i][2]))
    t += 0.001
offs.sort()
print(f"samples={len(offs)} avg={sum(offs)/len(offs):.1f}pt p95={offs[int(len(offs)*.95)]:.1f}pt max={offs[-1]:.1f}pt updates={len(A)}")
# time lag: for each window move, when did MacSnow first show that position (within 0.5 pt)?
lags = []
for (t0, x, y) in W[5:-5]:
    k = bisect.bisect_left(at, t0 - 0.05)
    for a in A[k:]:
        if abs(a[1] - x) < 0.5 and abs(a[2] - y) < 0.5 and a[0] >= t0 - 0.001: lags.append((a[0] - t0) * 1000); break
if lags: lags.sort(); print(f"time lag: n={len(lags)} avg={sum(lags)/len(lags):.1f}ms p95={lags[int(len(lags)*.95)]:.1f}ms max={lags[-1]:.1f}ms")
if R: print("reconcile diffs (pt):", " ".join(f"{math.hypot(r[1], r[2]):.1f}" for r in R))
