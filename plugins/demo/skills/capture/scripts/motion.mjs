// ABOUTME: Spring motion solver for the camera and the cursor. Pure functions of time: the rig
// steps it once per filmed frame (deterministic capture) and reads poses from it, so a take
// re-filmed from the same beats moves identically.
//
// The look follows Cap (https://github.com/CapSoftware/Cap), the open-source Screen Studio
// alternative. Its renderer is AGPLv3 and this plugin is Apache-2.0, so no Cap code is copied,
// translated or mirrored here: the springs are a plain damped harmonic oscillator integrated below,
// and only numeric constants and observable behaviours are reused, cited as values observed in
// Cap's open-source renderer (path at commit 97c0a45):
//   camera spring 200/40/2.25 ........ crates/project/src/configuration.rs
//   pre-aim while unzoomed (1.0005), framing centre in travel space, hold framing on zoom-out,
//   scale kept >= 1 ................... crates/rendering/src/zoom_spring.rs
//   cursor springs 470/70/3 and 530/40/1, 500ms click snap, 175ms stiffen, shake 0.015/100ms,
//   60fps thinning, 1/1920 min move .. crates/rendering/src/cursor_interpolation.rs
//   click shrink 0.8 over 130ms ...... crates/rendering/src/layers/cursor.rs
//   tilt up to 20 deg ................ crates/rendering/src/lib.rs

// Damped harmonic oscillator m x'' = -k x - c x' (x: displacement from the target), stepped with
// semi-implicit Euler in sub-steps of at most 0.25ms. The stiffest profile here (530/40/1) has a
// natural period of 270ms, over a thousand sub-steps, so it is stable and its curve matches the
// exact solution far below a pixel. Returns [displacement, velocity] after t seconds.
const SUB = 0.00025;
export function spring1d(d, v, t, k, c, m) {
  const n = Math.max(1, Math.ceil(t / SUB)), h = t / n;
  for (let i = 0; i < n; i++) { v += (-k * d - c * v) / m * h; d += v * h; }
  return [d, v];
}

// A spring profile slowed by `ts` (2 = every motion takes twice as long): k/ts^2 and c/ts keep
// the damping ratio, so the curve keeps its shape and only its duration scales.
export const scaled = ({ k, c, m }, ts) => ({ k: k / (ts * ts), c: c / ts, m });

export const CAMERA = { k: 200, c: 40, m: 2.25 };     // camera, observed in Cap
export const CURSOR = { k: 470, c: 70, m: 3 };        // cursor default, observed in Cap
export const SNAPPY = { k: 530, c: 40, m: 1 };        // cursor just before a press, observed in Cap
// zoom.ms 700 (the beat default) plays Cap's camera spring as is; other values scale it.
export const CAMERA_REF_MS = 700;
export const CLICK_LEAD_MS = 500, STIFFEN_MS = 175;   // observed in Cap
export const SHAKE = 0.015, SHAKE_MS = 100;           // observed in Cap
export const MIN_MOVE = 1 / 1920;                     // observed in Cap
const PREAIM = 1.0005;                                // observed in Cap

// One channel: position, velocity and the target it chases. Retargeting keeps velocity.
class Channel {
  constructor(x) { this.x = x; this.v = 0; this.to = x; }
  step(dt, p) { if (dt > 0) [this.x, this.v] = ((r) => [this.to + r[0], r[1]])(spring1d(this.x - this.to, this.v, dt, p.k, p.c, p.m)); }
  snap(x) { this.x = this.to = x; this.v = 0; }
}

// Camera over a W x H CSS viewport: scale s plus the framing centre (u, v) in travel space,
// where u = 0 puts the visible box's left edge at 0 and u = 1 its right edge at W. Any u in
// [0,1] is an in-bounds framing, and zooming at a fixed u scales about the fixed point u*W,
// so a zoom from wide (u pre-aimed) scales straight into its target with no pan.
export class Camera {
  constructor(W, H) { this.W = W; this.H = H; this.s = new Channel(1); this.u = new Channel(0.5); this.v = new Channel(0.5); this.p = CAMERA; }
  box() {
    const s = this.s.x, w = this.W / s, h = this.H / s;
    return { x: this.u.x * (this.W - w), y: this.v.x * (this.H - h), w, h, s };
  }
  // target: a box {x,y,w,h,s} (s = 1 for wide); ts: duration scale
  aim(t, ts = 1) {
    this.p = scaled(CAMERA, ts);
    const w = this.W / t.s, h = this.H / t.s;
    this.s.to = t.s;
    if (t.s > 1) {                                    // a wide keeps its last centre (hold framing)
      const u = this.W - w > 1e-9 ? t.x / (this.W - w) : 0.5, v = this.H - h > 1e-9 ? t.y / (this.H - h) : 0.5;
      // Pre-aim: at identity the centre is invisible, so it jumps to the target and the zoom
      // scales straight into it instead of zooming about a stale centre and panning while magnified.
      if (this.s.x <= PREAIM) { this.u.snap(u); this.v.snap(v); } else { this.u.to = u; this.v.to = v; }
    }
  }
  step(dt) {
    for (const ch of [this.s, this.u, this.v]) ch.step(dt, this.p);
    if (this.s.x < 1) { this.s.x = 1; this.s.v = 0; }   // never show outside the page
    for (const ch of [this.u, this.v]) ch.x = Math.min(1, Math.max(0, ch.x));
  }
  target() { const s = this.s.to, w = this.W / s, h = this.H / s; return { x: this.u.to * (this.W - w), y: this.v.to * (this.H - h), w, h, s }; }
  // Settled once every edge is within `px` output pixels of the target and nearly still; then it
  // snaps exactly onto the target, so the box written into a mark is the one the frame shows.
  settled(px = 0.25) {
    const a = this.box(), b = this.target();
    const off = Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.x + a.w - b.x - b.w), Math.abs(a.y + a.h - b.y - b.h)) * a.s;
    const vel = Math.abs(this.s.v) * this.W + (Math.abs(this.u.v) + Math.abs(this.v.v)) * this.W;
    if (off < px && vel < 30) { this.s.snap(this.s.to); this.u.snap(this.u.to); this.v.snap(this.v.to); return true; }
    return false;
  }
  get wide() { return this.s.x <= PREAIM && this.s.to === 1; }
}

// How far the image moves between two camera boxes, in output (CSS) px: the largest
// displacement of a frame corner. Drives motion blur.
export function camMotion(a, b, W, H) {
  let d = 0;
  for (const [fx, fy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) {
    const px = b.x + fx * b.w, py = b.y + fy * b.h;              // page point at b's corner
    d = Math.max(d, Math.hypot((px - a.x) * a.s - fx * W, (py - a.y) * a.s - fy * H));
  }
  return d;
}

// Cursor: a 2D spring chasing waypoints in page CSS px. Move targets come from beats; a click
// is planned so the target jumps to the click point CLICK_LEAD_MS ahead of the press and the
// spring stiffens STIFFEN_MS before it (Cap's click anticipation). Look-ahead is that click
// snap: the scripted path is a series of waypoints, not a continuous raw trace, so Cap's
// separate lag-cancel lead has nothing to sample ahead on.
export class Cursor {
  constructor(x, y, W, H) { this.x = new Channel(x); this.y = new Channel(y); this.ts = 1; this.stiffAt = Infinity; this.W = W; this.H = H; this.legs = []; this.vx = 0; }
  pos() { return { x: this.x.x, y: this.y.x }; }
  profile(t) { return scaled(t >= this.stiffAt ? SNAPPY : CURSOR, t >= this.stiffAt ? 1 : this.ts); }
  // Shake filter: a new waypoint that reverses the last leg, both legs under SHAKE of the screen
  // diagonal and within SHAKE_MS, is a jitter: it is dropped and the spring keeps its target.
  // A move under MIN_MOVE of the screen is dropped outright (Cap's decimation floor).
  aim(t, x, y, ts = 1) {
    const diag = Math.hypot(this.W, this.H), from = { x: this.x.to, y: this.y.to };
    const leg = { t, dx: x - from.x, dy: y - from.y };
    if (Math.hypot(leg.dx, leg.dy) < MIN_MOVE * diag) return false;
    const prev = this.legs.at(-1);
    if (prev && t - prev.t < SHAKE_MS && prev.dx * leg.dx + prev.dy * leg.dy < 0
      && Math.hypot(prev.dx, prev.dy) < SHAKE * diag && Math.hypot(leg.dx, leg.dy) < SHAKE * diag) return false;
    this.legs = [leg]; this.ts = ts; this.stiffAt = Infinity; this.x.to = x; this.y.to = y;
    return true;
  }
  step(t0, dt) {
    const px = this.x.x;
    // a profile switch inside the step is split there, so the stiffening starts on time
    const cut = this.stiffAt > t0 && this.stiffAt < t0 + dt ? this.stiffAt - t0 : 0;
    if (cut) { this.x.step(cut, this.profile(t0)); this.y.step(cut, this.profile(t0)); }
    this.x.step(dt - cut, this.profile(t0 + cut)); this.y.step(dt - cut, this.profile(t0 + cut));
    if (dt > 0) this.vx = (this.x.x - px) / dt;
  }
  // Plan a click at (x, y) from time t: returns the press time. The press waits at least
  // CLICK_LEAD_MS * ts and until a forward simulation puts the cursor within half a pixel.
  click(t, x, y, ts = 1) {
    this.aim(t, x, y, ts);
    const lead = CLICK_LEAD_MS * ts / 1000, fs = 1 / 120;
    for (let press = t + lead; press < t + 4; press += fs) {
      const sim = new Cursor(0, 0, this.W, this.H);
      Object.assign(sim.x, this.x); Object.assign(sim.y, this.y); sim.ts = ts; sim.stiffAt = press - STIFFEN_MS / 1000;
      for (let u = t; u < press - 1e-9; u += fs) sim.step(u, Math.min(fs, press - u));
      if (Math.hypot(sim.x.x - x, sim.y.x - y) < 0.5 && Math.hypot(sim.x.v, sim.y.v) < 40) { this.stiffAt = press - STIFFEN_MS / 1000; return press; }
    }
    this.stiffAt = t + lead - STIFFEN_MS / 1000;
    return t + lead;
  }
  settled() { return Math.hypot(this.x.x - this.x.to, this.y.x - this.y.to) < 0.5 && Math.hypot(this.x.v, this.y.v) < 40; }
}

// Tilt from horizontal velocity (px/s): Cap rotates by dx over the last 400ms * 0.03 * amount
// degrees, amount 0.15 by default, clamped to 20 degrees.
export const tilt = (vx, amount) => Math.max(-20, Math.min(20, vx * 0.4 * 0.03 * amount));
