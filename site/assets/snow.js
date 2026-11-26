/* MacSnow site: canvas snow that piles on [data-pile] elements.
   - Pauses when the tab is hidden.
   - 30 fps when idle, full rate only while the page is scrolling (so piles track the DOM).
   - prefers-reduced-motion: no animation; one still frame, redrawn on scroll/resize. */
(function () {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const qs = new URLSearchParams(location.search);
  let seed = +(qs.get('seed') || 7);
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);

  function snow(canvas, o = {}) {
    const opt = Object.assign({ density: 1, color: '255,255,255', wind: true, pile: false,
      pileMax: 26, speed: 1, prefill: 0 }, o);
    const ctx = canvas.getContext('2d');
    let W = 0, H = 0, flakes = [], raf = 0, last = performance.now(), lastDraw = 0, activeUntil = 0;
    const dpr = Math.min(devicePixelRatio || 1, 1.5);
    const piles = new WeakMap();
    let els = [];
    let mouse = { x: -1e4, y: -1e4, vx: 0, t: 0 };
    const api = { density: opt.density, pileMax: opt.pileMax, setDensity(d) { api.density = d; } };

    function resize() {
      const r = canvas.getBoundingClientRect();
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      els = opt.pile ? [...document.querySelectorAll('[data-pile]')] : [];
    }
    function flake(top) {
      const z = 0.35 + rnd() * 0.65;
      return { x: rnd() * W, y: top ? -10 - rnd() * 40 : rnd() * H, z,
        r: 0.8 + z * 2.4, vy: (18 + z * 42) * opt.speed, ph: rnd() * 6.28, sw: 8 + rnd() * 18, vx: 0 };
    }
    // fewer flakes on small screens; ~1 per 9000 px² at density 1
    const target = () => Math.round((W * H) / (W < 700 ? 14000 : 9000) * api.density);
    // A pile is a height per 3px column across the element's width. When the width
    // changes (resize, mobile rotation) the old heights are resampled, not dropped.
    function pileOf(el, w) {
      const n = Math.max(2, Math.ceil(w / 3));
      let p = piles.get(el);
      if (p && p.length !== n) {
        const q = new Float32Array(n);
        for (let i = 0; i < n; i++) q[i] = p[Math.min(p.length - 1, Math.floor(i * p.length / n))];
        piles.set(el, (p = q));
      }
      if (!p) {
        p = new Float32Array(n);
        const base = reduce ? Math.max(opt.prefill, 10) : opt.prefill;
        if (base) for (let i = 0; i < n; i++) p[i] = base;
        piles.set(el, p);
      }
      return p;
    }
    const radii = new WeakMap();
    function radiusOf(el) {
      let r = radii.get(el);
      if (r === undefined) { r = parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0; radii.set(el, r); }
      return r;
    }
    // Shape of the element's top edge at distance d from the nearest side: how far the
    // rounded corner drops below the flat top. 0 on the flat part, R at the very side.
    function cornerDrop(d, R) {
      if (d >= R) return 0;
      const k = R - d;
      return R - Math.sqrt(Math.max(0, R * R - k * k));
    }
    // How much of the pile survives at distance d from the side: 0 at the side, eased up
    // to 1 a little past the corner, so the snow thins out over the rounded corner
    // instead of overhanging it (same idea as the app's pile ends).
    function envelope(d, R, w) {
      const T = Math.min(w / 3, R + 18 + Math.min(40, w * 0.04));
      if (d >= T) return 1;
      const t = Math.max(0, d - R * 0.35) / (T - R * 0.35);
      return t * t * (3 - 2 * t);
    }
    // Small fixed bumps so a full pile isn't a flat slab.
    const bump = (i) => 0.84 + 0.1 * Math.sin(i * 0.37) + 0.06 * Math.sin(i * 1.13 + 1.7);
    function frame(now) {
      const dt = reduce ? 0 : Math.min(0.05, (now - last) / 1000); last = now;
      const want = target();
      while (flakes.length < want) flakes.push(flake(flakes.length > 0 && !reduce));
      if (flakes.length > want) flakes.length = want;
      const cr = canvas.getBoundingClientRect();
      const rects = [];
      for (const el of els) {
        const r = el.getBoundingClientRect();
        const y = r.top - cr.top;
        if (y < -60 || y > H + 60 || r.width === 0) continue;
        rects.push({ el, x: r.left - cr.left, y, w: r.width,
          max: Math.min(+(el.dataset.pileMax || 1e9), api.pileMax), R: radiusOf(el), p: pileOf(el, r.width) });
      }
      ctx.clearRect(0, 0, W, H);
      const t = now / 1000;
      ctx.fillStyle = `rgb(${opt.color})`;
      for (const f of flakes) {
        if (dt) {
          if (opt.wind && Math.abs(mouse.vx) > 1.5) {
            const dx = f.x - mouse.x, dy = f.y - mouse.y, d2 = dx * dx + dy * dy;
            if (d2 < 19600) f.vx += mouse.vx * 0.9 * (1 - Math.sqrt(d2) / 140);
          }
          f.vx *= 0.94;
          const nx = f.x + (Math.sin(t * 0.9 + f.ph) * f.sw * 0.6 + f.vx * 10) * dt, ny = f.y + f.vy * dt;
          let landed = false;
          if (f.z > 0.55) for (const r of rects) {
            const p = r.p, i = Math.floor((nx - r.x) / 3);
            if (i < 0 || i >= p.length) continue;
            const d = Math.min(nx - r.x, r.x + r.w - nx);
            const top = r.y + cornerDrop(d, r.R) - Math.min(p[i], r.max * bump(i)) * envelope(d, r.R, r.w);
            if (f.y <= top && ny >= top) {
              if (p[i] < r.max) {
                const add = 0.9 + f.r * 0.5;
                for (let k = -3; k <= 3; k++) { const j = i + k; if (j >= 0 && j < p.length) p[j] = Math.min(r.max, p[j] + add * (1 - Math.abs(k) / 4)); }
              }
              landed = true; break;
            }
          }
          if (landed || ny > H + 10) Object.assign(f, flake(true));
          else if (nx < -20) { f.x = W + 10; f.y = ny; }
          else if (nx > W + 20) { f.x = -10; f.y = ny; }
          else { f.x = nx; f.y = ny; }
        }
        ctx.globalAlpha = 0.35 + f.z * 0.6;
        ctx.beginPath(); ctx.arc(f.x, f.y, f.r, 0, 6.283); ctx.fill();
      }
      ctx.globalAlpha = 1;
      for (const r of rects) {
        const p = r.p, n = p.length;
        if (dt) for (let i = 1; i < n - 1; i++) { const avg = (p[i - 1] + p[i + 1]) / 2; if (p[i] > avg + 1.2) { const d = (p[i] - avg) * 0.25; p[i] -= d; p[i - 1] += d / 2; p[i + 1] += d / 2; } }
        // Outline: along the pile's top from the left side to the right side, then back
        // along the element's own rounded top edge, so nothing is drawn outside its box.
        const xs = [], top = [], base = [];
        for (let i = 0; i <= n; i++) {
          const dx = Math.min(i * 3, r.w);
          const d = Math.min(dx, r.w - dx);
          const b = r.y + cornerDrop(d, r.R);
          const h = Math.min(p[Math.min(i, n - 1)], r.max * bump(i)) * envelope(d, r.R, r.w);
          xs.push(r.x + dx); base.push(b); top.push(b - h);
          if (dx >= r.w) break;
        }
        ctx.beginPath(); ctx.moveTo(xs[0], base[0]);
        for (let i = 0; i < xs.length; i++) ctx.lineTo(xs[i], top[i]);
        for (let i = xs.length - 1; i >= 0; i--) ctx.lineTo(xs[i], base[i] + 1.5);
        ctx.closePath();
        const g = ctx.createLinearGradient(0, r.y - r.max, 0, r.y);
        g.addColorStop(0, '#ffffff'); g.addColorStop(1, '#dde6f6');
        ctx.fillStyle = g; ctx.fill();
        ctx.strokeStyle = 'rgba(150,170,215,.55)'; ctx.lineWidth = 1;
        // thin rim only where there is actually snow, so the bare corners get no outline
        ctx.beginPath();
        for (let i = 1; i < xs.length; i++) {
          if (base[i] - top[i] < 0.6 || base[i - 1] - top[i - 1] < 0.6) continue;
          ctx.moveTo(xs[i - 1], top[i - 1]); ctx.lineTo(xs[i], top[i]);
        }
        ctx.stroke();
      }
      ctx.fillStyle = `rgb(${opt.color})`;
    }
    function loop(now) {
      raf = requestAnimationFrame(loop);
      if (now < activeUntil || now - lastDraw >= 32) { lastDraw = now; frame(now); }
    }
    function start() { if (!raf && !reduce && !document.hidden) { last = performance.now(); raf = requestAnimationFrame(loop); } }
    function stop() { cancelAnimationFrame(raf); raf = 0; }

    resize();
    addEventListener('resize', () => { resize(); if (reduce) frame(performance.now()); });
    addEventListener('scroll', () => { activeUntil = performance.now() + 250; if (reduce) frame(performance.now()); }, { passive: true });
    document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));
    if (opt.wind && !reduce) addEventListener('pointermove', (e) => {
      const r = canvas.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top, t = performance.now();
      mouse = { x, y, vx: (x - mouse.x) / Math.max(16, t - mouse.t) * 16, t };
      activeUntil = t + 250;
    }, { passive: true });
    for (let i = 0; i < target(); i++) flakes.push(flake(false));
    if (reduce) frame(performance.now()); else start();
    return api;
  }

  async function wireDownload() {
    // Fallback href (releases/latest) stays if the API call fails or is rate-limited.
    try {
      const r = await fetch('https://api.github.com/repos/ColdTbrew/mac-snow/releases/latest');
      if (!r.ok) return;
      const j = await r.json();
      const dmg = (j.assets || []).find((a) => a.name.endsWith('.dmg'));
      if (dmg) document.querySelectorAll('[data-dl]').forEach((a) => (a.href = dmg.browser_download_url));
      if (j.tag_name) document.querySelectorAll('[data-ver]').forEach((v) => (v.textContent = j.tag_name));
    } catch (e) { /* keep fallback */ }
  }
  function progress(el) {
    const r = el.getBoundingClientRect();
    return Math.min(1, Math.max(0, -r.top / Math.max(1, r.height - innerHeight)));
  }
  function reveal(sel = '.reveal') {
    if (reduce || !('IntersectionObserver' in window)) { document.querySelectorAll(sel).forEach((el) => el.classList.add('in')); return; }
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: 0.15 });
    document.querySelectorAll(sel).forEach((el) => io.observe(el));
  }
  window.MacSnow = { snow, wireDownload, progress, reveal, reduce };
})();
