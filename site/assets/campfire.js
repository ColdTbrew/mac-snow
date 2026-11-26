/* MacSnow site: campfire-mode demo inside a fake desktop.
   Drawn after the app's CampfireVisual: warm glow, two crossed logs, glowing coals,
   three layered flames that lean against the motion, rising sparks; snow near the
   fire melts into steam and water drops that run down onto the window below.
   - Pointer over the demo = the fire follows it (cursor hidden there). Otherwise it
     drifts along the snow by itself.
   - Shake it hard and the flame dies down; hold still and it flares back up.
   - Animates only while on screen and the tab is visible, at ~30 fps.
   - prefers-reduced-motion: one still frame. */
(function () {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  function campfire(canvas, opts = {}) {
    const ctx = canvas.getContext('2d');
    const dpr = Math.min(devicePixelRatio || 1, 1.5);
    let W = 0, H = 0, wins = [], flakes = [], drops = [], sparks = [], steam = [];
    let fire = { x: 0, y: 0, vx: 0, flame: 1, phase: 0 }, pointer = null, lastPointer = null;
    let raf = 0, visible = false, last = 0, lastDraw = 0, auto = 0;
    let seed = 11; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);

    function layout() {
      const r = canvas.getBoundingClientRect();
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const k = W / 640;                                  // scale for small screens
      const mk = (x, y, w, h, dark, title) => ({ x: x * W, y: y * H, w: w * W, h: h * H, dark, title, R: 9 * k,
        pile: new Float32Array(Math.ceil(w * W / 2)).fill(15 * k), wet: new Float32Array(Math.ceil(w * W / 2)) });
      wins = [mk(0.07, 0.30, 0.56, 0.42, false, 'Finder'), mk(0.40, 0.58, 0.50, 0.34, true, 'Music')];
      wins.dock = { x: W * 0.22, y: H * 0.93, w: W * 0.56, h: H * 0.07 };
      fire.x = wins[0].x + wins[0].w * 0.5; fire.y = wins[0].y - 10 * k; fire.k = k;
      flakes = Array.from({ length: Math.round(W * H / 5000) }, () => ({ x: rnd() * W, y: rnd() * H, r: 0.6 + rnd() * 1.6, v: 14 + rnd() * 22, ph: rnd() * 6 }));
    }
    const S = () => 2.3 * fire.k;                          // campfire drawing scale

    // ---------- simulation ----------
    function heatAt(win, i) {                              // 0..1 heat on pile column i of win
      const cx = win.x + i * 2, top = win.y - win.pile[i];
      const dx = cx - fire.x, dy = top - (fire.y + 6 * S());
      const R = 46 * S();
      const d = Math.sqrt(dx * dx + dy * dy * 1.6);
      return d < R ? (1 - d / R) * fire.flame : 0;
    }
    function step(dt, t) {
      // fire position: pointer or autopilot along the Finder window's snow
      let tx, ty;
      if (pointer) { tx = pointer.x; ty = pointer.y; }
      else {
        auto += dt;
        const w = wins[0];
        tx = w.x + w.w * (0.5 + 0.36 * Math.sin(auto * 0.45));
        ty = w.y - 9 * fire.k + Math.sin(auto * 1.7) * 3;
      }
      const nvx = (tx - fire.x) / Math.max(dt, 1e-3);
      fire.vx += (nvx - fire.vx) * Math.min(1, dt * 10);
      fire.x = tx; fire.y = ty;
      // shake: fast motion dims the flame, stillness relights it
      const speed = Math.abs(fire.vx);
      const target = speed > 1400 ? 0.12 : speed > 700 ? 0.55 : 1;
      fire.flame += (target - fire.flame) * Math.min(1, dt * (target < fire.flame ? 6 : 1.6));
      fire.phase += dt * 9;

      // melt piles + spawn steam and drops
      for (const w of [...wins, null]) {
        if (!w) continue;
        for (let i = 0; i < w.pile.length; i++) {
          const h = heatAt(w, i);
          if (h <= 0 || w.pile[i] <= 0) continue;
          const m = Math.min(w.pile[i], h * 11 * fire.k * dt);
          w.pile[i] -= m; w.wet[i] += m;                   // melt water collects at the edge
          if (rnd() < m * 0.25) steam.push({ x: w.x + i * 2, y: w.y - w.pile[i], a: 0.55, r: 4 + rnd() * 4 });
        }
        // wet columns keep dripping for a while after the fire moves on
        for (let i = 0; i < w.wet.length; i += 3) {
          if (w.wet[i] <= 0.05) continue;
          if (rnd() < w.wet[i] * 0.9 * dt) { drops.push({ x: w.x + i * 2, y: w.y + 3, vy: 0, life: 0, hang: 0.15 + rnd() * 0.25 }); w.wet[i] -= 1.2; }
          w.wet[i] = Math.max(0, w.wet[i] - dt * 0.4);
        }
      }
      // snow keeps falling, slowly refilling piles
      for (const f of flakes) {
        f.y += f.v * dt; f.x += Math.sin(t * 0.8 + f.ph) * 6 * dt;
        for (const w of wins) {
          const i = Math.floor((f.x - w.x) / 2);
          if (i >= 3 && i < w.pile.length - 3 && f.y >= w.y - w.pile[i] && f.y < w.y + 4) {
            for (let j = -2; j <= 2; j++) w.pile[i + j] = Math.min(18 * fire.k, w.pile[i + j] + 0.9 * (1 - Math.abs(j) / 3));
            f.y = -5; f.x = rnd() * W; break;
          }
        }
        if (f.y > H) { f.y = -5; f.x = rnd() * W; }
      }
      // drops: run down, land on the next window top, the Dock, or the bottom
      for (const d of drops) {
        d.life += dt; if (d.life < d.hang) continue; d.vy += 420 * dt; d.y += d.vy * dt;
        for (const w of [wins[1], wins.dock]) {
          if (d.x > w.x && d.x < w.x + w.w && d.y > w.y && d.y - d.vy * dt <= w.y && d.life > 0.05) { d.dead = true; splash(d.x, w.y); }
        }
        if (d.y > H) d.dead = true;
      }
      drops = drops.filter((d) => !d.dead).slice(-160);
      // sparks
      if (rnd() < 12 * dt * fire.flame * 3) sparks.push({ x: fire.x + (rnd() - 0.5) * 8 * S(), y: fire.y - 4 * S(), vx: (rnd() - 0.5) * 30 - fire.vx * 0.02, vy: -(50 + rnd() * 60), a: 1 });
      for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vy *= 0.985; s.a -= dt * 0.9; }
      sparks = sparks.filter((s) => s.a > 0).slice(-25);
      for (const s of steam) { s.y -= 20 * dt; s.r += 10 * dt; s.a -= dt * 0.45; }
      steam = steam.filter((s) => s.a > 0).slice(-40);
    }
    const splashes = [];
    function splash(x, y) { splashes.push({ x, y, a: 0.9 }); if (splashes.length > 30) splashes.shift(); }

    // ---------- drawing ----------
    function rr(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h); }
    function drawWindow(w) {
      ctx.save(); ctx.shadowColor = 'rgba(0,0,20,.45)'; ctx.shadowBlur = 18 * fire.k; ctx.shadowOffsetY = 6 * fire.k;
      rr(w.x, w.y, w.w, w.h, w.R); ctx.fillStyle = w.dark ? '#26262b' : '#f7f8fb'; ctx.fill(); ctx.restore();
      ctx.save(); rr(w.x, w.y, w.w, w.h, w.R); ctx.clip();
      ctx.fillStyle = w.dark ? '#323238' : '#e9ecf3'; ctx.fillRect(w.x, w.y, w.w, 20 * fire.k);
      const dot = 4 * fire.k;
      ['#ff5f57', '#febc2e', '#28c840'].forEach((c, i) => { ctx.beginPath(); ctx.arc(w.x + (12 + i * 13) * fire.k, w.y + 10 * fire.k, dot, 0, 7); ctx.fillStyle = c; ctx.fill(); });
      ctx.fillStyle = w.dark ? '#d8d8de' : '#59607a'; ctx.font = `600 ${10 * fire.k}px Pretendard Variable, sans-serif`; ctx.fillText(w.title, w.x + 52 * fire.k, w.y + 13.5 * fire.k);
      if (w.dark) { const c = ['#f2545b', '#fb9e3c', '#6a8ff0', '#ef6fa6']; for (let i = 0; i < 4; i++) { rr(w.x + (12 + i * 0.24 * w.w / fire.k) * fire.k, w.y + 30 * fire.k, w.w * 0.2, w.h * 0.5, 6 * fire.k); ctx.fillStyle = c[i]; ctx.fill(); } }
      else { for (let i = 0; i < 6; i++) { ctx.fillStyle = '#5b8def'; ctx.fillRect(w.x + w.w * 0.3, w.y + (32 + i * 15) * fire.k, 8 * fire.k, 8 * fire.k); ctx.fillStyle = '#d4d8e2'; ctx.fillRect(w.x + w.w * 0.3 + 14 * fire.k, w.y + (33 + i * 15) * fire.k, w.w * (0.3 + (i % 3) * 0.08), 6 * fire.k); }
        ctx.fillStyle = '#eef0f5'; ctx.fillRect(w.x, w.y + 20 * fire.k, w.w * 0.24, w.h); }
      ctx.restore();
    }
    function drawPile(w) {
      const n = w.pile.length, xs = [], tops = [], base = [];
      for (let i = 0; i < n; i++) {
        const dx = Math.min(i * 2, w.w), d = Math.min(dx, w.w - dx);
        const drop = d < w.R ? w.R - Math.sqrt(Math.max(0, w.R * w.R - (w.R - d) ** 2)) : 0;
        const env = Math.min(1, Math.max(0, (d - w.R * 0.3) / (w.R + 14)));
        xs.push(w.x + dx); base.push(w.y + drop); tops.push(w.y + drop - w.pile[i] * env * env * (3 - 2 * env));
      }
      ctx.beginPath(); ctx.moveTo(xs[0], base[0]);
      for (let i = 0; i < n; i++) ctx.lineTo(xs[i], tops[i]);
      for (let i = n - 1; i >= 0; i--) ctx.lineTo(xs[i], base[i] + 1);
      ctx.closePath(); ctx.fillStyle = '#f4f7fd'; ctx.fill();
    }
    function teardrop(x, y, w, h, lean, color, blur) {
      ctx.save(); ctx.translate(x, y); ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.bezierCurveTo(w * 0.62, 0, w * 0.58, -h * 0.46, lean, -h);
      ctx.bezierCurveTo(-w * 0.58, -h * 0.46, -w * 0.62, 0, 0, 0);
      ctx.fillStyle = color; if (blur) { ctx.shadowColor = color; ctx.shadowBlur = blur; } ctx.fill(); ctx.restore();
    }
    function drawFire(t) {
      const s = S(), x = fire.x, y = fire.y, f = fire.flame;
      // glow halo
      const g = ctx.createRadialGradient(x, y - 4 * s, 0, x, y - 4 * s, 41 * s);
      g.addColorStop(0, `rgba(255,199,61,${0.6 * (0.35 + 0.65 * f)})`); g.addColorStop(0.34, `rgba(255,117,20,${0.32 * (0.35 + 0.65 * f)})`);
      g.addColorStop(0.7, 'rgba(245,64,8,.09)'); g.addColorStop(1, 'rgba(242,51,0,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y - 4 * s, 41 * s, 0, 7); ctx.fill();
      // logs (crossed)
      const log = (ang, fill, cutRight) => {
        ctx.save(); ctx.translate(x, y + 6.5 * s); ctx.rotate(ang);
        const len = 25 * s, th = 4.8 * s;
        rr(-len / 2, -th / 2, len, th, th * 0.42); ctx.fillStyle = fill; ctx.fill(); ctx.lineWidth = 0.8 * s; ctx.strokeStyle = '#2e170a'; ctx.stroke();
        ctx.beginPath(); ctx.ellipse(cutRight ? len / 2 - th * 0.32 : -len / 2 + th * 0.32, 0, th * 0.28, th * 0.36, 0, 0, 7); ctx.fillStyle = '#ad7a47'; ctx.fill(); ctx.stroke();
        ctx.restore();
      };
      log(-0.36, '#4d2914', false); log(0.36, '#703d1c', true);
      // coals
      ctx.fillStyle = 'rgba(235,71,10,.95)';
      for (const [cx, cy, rx, ry] of [[-4.8, 7.8, 2.3, 1.4], [0, 8.5, 2.8, 1.6], [4.6, 7.7, 2.2, 1.4], [-2, 5.8, 2.1, 1.3], [2.5, 6, 2, 1.3]]) { ctx.beginPath(); ctx.ellipse(x + cx * s, y + cy * s, rx * s, ry * s, 0, 0, 7); ctx.fill(); }
      ctx.fillStyle = 'rgba(255,189,41,.96)';
      for (const [cx, cy, rx, ry] of [[-3.6, 7.4, 1.3, 0.8], [0.2, 8, 1.8, 1], [3.4, 7.4, 1.2, 0.8], [0, 5.8, 1.6, 0.9]]) { ctx.beginPath(); ctx.ellipse(x + cx * s, y + cy * s, rx * s, ry * s, 0, 0, 7); ctx.fill(); }
      // three flames, leaning against the motion
      const lean = Math.max(-9, Math.min(9, -fire.vx * 0.012)) * s;
      const fl = (a) => 0.88 + 0.12 * Math.sin(fire.phase * a);
      const hf = 0.25 + 0.75 * f;
      teardrop(x, y + 5 * s, 15 * s * hf, 27 * s * hf * fl(1.1), lean, 'rgba(245,71,13,.94)', 10 * s);
      teardrop(x, y + 5 * s, 10.5 * s * hf, 19 * s * hf * fl(1.7), lean * 0.8, 'rgba(255,148,26,.96)');
      teardrop(x, y + 5 * s, 6 * s * hf, 11.5 * s * hf * fl(2.3), lean * 0.6, 'rgba(255,232,120,.98)');
    }
    function render(t) {
      const sky = ctx.createLinearGradient(0, 0, 0, H); sky.addColorStop(0, '#1b2452'); sky.addColorStop(1, '#3a4c9a');
      ctx.fillStyle = sky; ctx.fillRect(0, 0, W, H);
      ctx.fillStyle = '#fbf3dc'; ctx.beginPath(); ctx.arc(W * 0.86, H * 0.16, 16 * fire.k, 0, 7); ctx.fill();
      ctx.fillStyle = '#4a5a9e'; ctx.beginPath(); ctx.moveTo(0, H * 0.78); ctx.quadraticCurveTo(W * 0.3, H * 0.6, W * 0.62, H * 0.8); ctx.lineTo(W, H * 0.7); ctx.lineTo(W, H); ctx.lineTo(0, H); ctx.fill();
      // warm light on the scene around the fire
      const warm = ctx.createRadialGradient(fire.x, fire.y, 0, fire.x, fire.y, 180 * fire.k);
      warm.addColorStop(0, `rgba(255,140,40,${0.22 * fire.flame})`); warm.addColorStop(1, 'rgba(255,140,40,0)');
      ctx.fillStyle = 'rgba(255,255,255,.85)';
      for (const f of flakes) { ctx.globalAlpha = 0.4 + f.r / 3; ctx.beginPath(); ctx.arc(f.x, f.y, f.r, 0, 7); ctx.fill(); }
      ctx.globalAlpha = 1;
      drawWindow(wins[0]); drawPile(wins[0]); drawWindow(wins[1]); drawPile(wins[1]);
      // dock
      const d = wins.dock; rr(d.x, d.y, d.w, d.h + 10, 12 * fire.k); ctx.fillStyle = 'rgba(255,255,255,.28)'; ctx.fill();
      ['#4f8ff7', '#f2545b', '#febc2e', '#33c26b', '#9b6cf0', '#fb8a3c'].forEach((c, i) => { rr(d.x + 10 * fire.k + i * (d.w - 20 * fire.k) / 6, d.y + 5 * fire.k, (d.w - 20 * fire.k) / 6 - 6 * fire.k, d.h, 6 * fire.k); ctx.fillStyle = c; ctx.fill(); });
      ctx.fillStyle = warm; ctx.fillRect(0, 0, W, H);
      // steam, drops, splashes
      for (const s of steam) { const g = ctx.createRadialGradient(s.x, s.y, 0, s.x, s.y, s.r); g.addColorStop(0, `rgba(255,255,255,${s.a * 0.5})`); g.addColorStop(1, 'rgba(255,255,255,0)'); ctx.fillStyle = g; ctx.beginPath(); ctx.arc(s.x, s.y, s.r, 0, 7); ctx.fill(); }
      for (const dr of drops) {
        const r = 2.1 * fire.k;
        ctx.beginPath(); ctx.moveTo(dr.x, dr.y - r * 3); ctx.quadraticCurveTo(dr.x + r * 1.3, dr.y - r * 0.2, dr.x, dr.y + r); ctx.quadraticCurveTo(dr.x - r * 1.3, dr.y - r * 0.2, dr.x, dr.y - r * 3);
        ctx.fillStyle = 'rgba(150,215,255,.85)'; ctx.fill();
      }
      for (const sp of splashes) { if (sp.a <= 0) continue; ctx.strokeStyle = `rgba(170,225,255,${sp.a})`; ctx.lineWidth = 1; ctx.beginPath(); ctx.ellipse(sp.x, sp.y, (1 - sp.a) * 8 + 2, 1.5, 0, 0, 7); ctx.stroke(); sp.a -= 0.06; }
      for (const s of sparks) { ctx.fillStyle = `rgba(255,${150 + 80 * s.a | 0},60,${s.a})`; ctx.beginPath(); ctx.arc(s.x, s.y, 1.6 * fire.k, 0, 7); ctx.fill(); }
      drawFire(t);
    }

    function frame(now) {
      raf = requestAnimationFrame(frame);
      if (now - lastDraw < 32) return;                    // ~30 fps is plenty for a fire
      const dt = Math.min(0.05, (now - (last || now)) / 1000); last = now; lastDraw = now;
      step(dt, now / 1000); render(now / 1000);
    }
    function start() { if (!raf && visible && !document.hidden && !reduce) { last = 0; raf = requestAnimationFrame(frame); } }
    function stop() { cancelAnimationFrame(raf); raf = 0; }
    function still() {                                    // reduced motion / first paint
      auto = 1.2; for (let i = 0; i < 90; i++) step(1 / 30, i / 30);
      render(3);
    }

    layout(); still();
    addEventListener('resize', () => { layout(); still(); });
    new IntersectionObserver((es) => { visible = es[0].isIntersecting; visible ? start() : stop(); }).observe(canvas);
    document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));
    if (!reduce) {
      canvas.addEventListener('pointermove', (e) => { const r = canvas.getBoundingClientRect(); pointer = { x: e.clientX - r.left, y: e.clientY - r.top }; });
      canvas.addEventListener('pointerleave', () => { pointer = null; });
    }
    const api = { refill() { for (const w of wins) { w.pile.fill(15 * fire.k); w.wet.fill(0); } drops = []; if (reduce) still(); } };
    return api;
  }
  window.MacSnowCampfire = campfire;
})();
