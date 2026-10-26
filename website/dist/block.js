// Block, the app's character, drawn the way the app draws it: a port of Apps/Shared/Characters/Block/BlockView.swift
// (the pose for each moment) and BlockDrawing.swift (the shapes). Change those first, then this, so the site keeps
// showing the real character. Lengths are in body sides; times in seconds.
window.BuddyBlock = (() => {
'use strict';

// MARK: Colours

const mix = (a, b, f) => a.map((v, i) => v + (b[i] - v) * f);
const css = (c, alpha = 1) => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${alpha})`;
const WHITE = [1, 1, 1], BLACK = [0, 0, 0];
const ACCENT = {
 idle: [0.36, 0.66, 1.00], working: [1.00, 0.70, 0.18], thinking: [0.67, 0.53, 1.00], searching: [0.18, 0.80, 0.78],
 approval: [1.00, 0.48, 0.14], question: [1.00, 0.45, 0.74], error: [0.94, 0.22, 0.24], finished: [0.33, 0.82, 0.40],
 rateLimited: [0.96, 0.87, 0.32], sleeping: [0.42, 0.46, 0.86], dizzy: [0.80, 0.82, 0.88]
};
const EYE_WHITE = [0.97, 0.98, 1.00], INK = [0.10, 0.11, 0.16], BLUSH_PINK = [1.00, 0.45, 0.60], HEART_RED = [0.96, 0.20, 0.38];
const STAR_GOLD = [1.00, 0.86, 0.28], DROP_BLUE = [0.55, 0.82, 1.00], SPARKLE_CREAM = [1.00, 0.97, 0.78];

// MARK: Timing

const bump = (t, d) => t >= 0 && t <= d ? Math.sin(Math.PI * t / d) : 0;
const ease = x => { const c = Math.min(Math.max(x, 0), 1); return c * c * (3 - 2 * c); };
const unit = v => Math.min(Math.max(v, -1), 1);
const lid = dt => bump(dt, 0.16);

/// A value in 0..<1 that looks random but is fixed for (k, salt): the app's 64-bit mix, so blinks match it.
function noise(k, salt) {
 const wrap = x => BigInt.asUintN(64, x);
 let x = wrap(wrap(BigInt.asUintN(64, BigInt(k)) * 0x9E3779B97F4A7C15n) + wrap(BigInt(salt + 1) * 0xD1B54A32D192ED03n));
 x = wrap((x ^ (x >> 30n)) * 0xBF58476D1CE5E5B9n);
 x = wrap((x ^ (x >> 27n)) * 0x94D049BB133111EBn);
 x ^= x >> 31n;
 return Number(x >> 11n) / 2 ** 53;
}

/// One blink in each 3.5 s window, 1.2...2.7 s into it; a quarter of them double.
function blinkAt(t) {
 const k = Math.floor(t / 3.5), at = k * 3.5 + 1.2 + 1.5 * noise(k, 0);
 let closed = lid(t - at);
 if (noise(k, 1) < 0.25) closed = Math.max(closed, lid(t - at - 0.3));
 return closed;
}

/// Eyes darting about while working: a new spot every 0.55 s, reached in 0.12 s.
function dart(t) {
 const k = Math.floor(t / 0.55);
 const spot = k => ({dx: noise(k, 2) * 1.6 - 0.8, dy: noise(k, 3) * 0.5});
 const from = spot(k - 1), to = spot(k), f = ease((t - k * 0.55) / 0.12);
 return {dx: from.dx + (to.dx - from.dx) * f, dy: from.dy + (to.dy - from.dy) * f};
}

const DURATION = {love: 2.4, surprised: 1.0, proud: 1.8, wink: 0.9, yawn: 2.0, happy: 1.6, annoyed: 1.1, listening: 3.0};

// MARK: Pose

const BODY_FRACTION = 0.66, REST_FRACTION = 0.56, PILL_BODY_FRACTION = 0.76;
const BADGE_CENTER = {x: 0.42, y: -0.43}, BADGE_RADIUS = 0.16;
const HIGHEST_BADGE_TOP = -(REST_FRACTION - 0.03) / BODY_FRACTION;

const newEye = () => ({shape: 'round', angle: 0, scale: 1, pupil: 1, openness: 1, lidTilt: 0});

function pose(input, now) {
 const p = {
  body: ACCENT[input.state], detailed: input.detailed, offset: {dx: 0, dy: 0}, stretch: {w: 1, h: 1}, rotation: 0,
  left: newEye(), right: newEye(), gaze: {dx: 0, dy: 0}, blush: 0, badge: null, sweat: null, particles: []
 };
 const look = {dx: unit(input.look.dx), dy: unit(input.look.dy)};
 p.gaze = {...look};
 const motion = !input.reduceMotion;
 applyState(p, input.state, Math.max(0, now - input.stateStartedAt), motion);
 let droppingIn = false;
 if (input.greetingStartedAt != null) droppingIn = applyGreeting(p, now - input.greetingStartedAt, motion);
 if (input.emote && input.emoteStartedAt != null) {
  const e = now - input.emoteStartedAt;
  if (e >= 0 && e < DURATION[input.emote]) applyEmote(p, input.emote, e, motion, look);
 }
 if (input.boopedAt != null) applyBoop(p, now - input.boopedAt, motion, look);
 if (input.hovering) { p.left.scale *= 1.06; p.right.scale *= 1.06; }
 if (p.detailed && p.badge && !droppingIn) keepBadgeInside(p);
 if (!p.detailed) {
  p.badge = null; p.sweat = null; p.particles = []; p.offset = {dx: 0, dy: 0};
  p.stretch = {w: 1 + (p.stretch.w - 1) / 2, h: 1 + (p.stretch.h - 1) / 2};
 }
 return p;
}

const eyes = (p, change) => { change(p.left); change(p.right); };
const blink = (p, amount) => eyes(p, e => { if (e.shape === 'round') e.openness *= 1 - amount; });
const squash = (p, amount) => { p.stretch.w *= 1 + amount * 0.8; p.stretch.h *= 1 - amount; };
const breathe = (p, t, period, depth) => squash(p, -depth * Math.sin(2 * Math.PI * t / period));

function applyState(p, state, t, motion) {
 const closed = blinkAt(t);
 switch (state) {
 case 'idle':
  if (motion) breathe(p, t, 3.2, 0.025);
  blink(p, closed); break;
 case 'working':
  eyes(p, e => { e.openness = 0.78; });
  p.gaze = dart(t);
  if (motion) p.offset.dy = -0.015 * Math.abs(Math.sin(2 * Math.PI * t / 0.5));
  p.badge = {kind: 'dots', phase: motion ? t : null};
  blink(p, closed); break;
 case 'thinking':
  p.gaze = {dx: 0.65 + (motion ? 0.15 * Math.sin(2 * Math.PI * t / 2.6) : 0), dy: -0.8};
  p.rotation = 5 + (motion ? 1.5 * Math.sin(2 * Math.PI * t / 3) : 0);
  p.badge = {kind: 'dots', phase: motion ? t : null};
  blink(p, closed); break;
 case 'searching':
  p.gaze = {dx: 0.9 * Math.sin(2 * Math.PI * t / 1.6), dy: 0.1};
  eyes(p, e => { e.scale = 1.05; });
  if (motion) { p.rotation = 3 * Math.sin(2 * Math.PI * t / 1.6); p.offset.dx = 0.02 * Math.sin(2 * Math.PI * t / 1.6); }
  blink(p, closed); break;
 case 'approval':
  eyes(p, e => { e.scale = 1.2; e.pupil = 0.85; });
  p.badge = {kind: 'exclamation'};
  if (motion) {
   // The hop: up and stretched, a squash on landing, then a gentle bounce while waiting.
   if (t < 0.5) { p.offset.dy = -0.13 * bump(t, 0.5); squash(p, -0.07 * bump(t, 0.5)); }
   else if (t < 0.7) squash(p, 0.12 * bump(t - 0.5, 0.2));
   else p.offset.dy = -0.035 * Math.abs(Math.sin(Math.PI * (t - 0.7) / 0.8));
  }
  blink(p, closed); break;
 case 'question':
  p.rotation = -9 * (motion ? ease(t / 0.35) : 1);
  p.left.scale = 0.94; p.right.scale = 1.18;
  p.gaze.dy = Math.min(p.gaze.dy, -0.3);
  p.badge = {kind: 'question'};
  blink(p, closed); break;
 case 'error':
  eyes(p, e => { e.shape = 'flat'; });
  if (motion && t < 0.6) p.offset.dx = 0.07 * Math.sin(2 * Math.PI * 6 * t) * (1 - t / 0.6);
  p.stretch.h = 0.97; break;
 case 'finished':
  eyes(p, e => { e.shape = 'arc'; });
  if (motion) {
   // Crouch, spin with a little hop, land with a squash; sparkles after.
   squash(p, 0.12 * bump(t, 0.5) + 0.1 * bump(t - 0.95, 0.3));
   if (t > 0.25 && t < 0.95) { p.rotation = 360 * ease((t - 0.25) / 0.7); p.offset.dy = -0.12 * bump(t - 0.25, 0.7); }
   sparkles(p, t - 0.6);
  }
  break;
 case 'rateLimited':
  eyes(p, e => { e.openness = 0.42; });
  p.gaze.dy = 0.35;
  p.stretch = {w: 1.02, h: 0.96};
  p.sweat = motion ? (t % 1.8) / 1.8 : 0; break;
 case 'sleeping':
  eyes(p, e => { e.shape = 'closed'; });
  if (motion) { breathe(p, t, 4.5, 0.04); sleepZs(p, t); } else p.badge = {kind: 'sleep'};
  break;
 case 'dizzy':
  eyes(p, e => { e.shape = 'spiral'; e.angle = motion ? t * 540 : 0; });
  if (motion) {
   if (t < 1.3) p.rotation = 720 * ease(t / 1.3);
   else { p.rotation = 7 * Math.sin(2 * Math.PI * (t - 1.3) / 1.1); p.offset.dx = 0.03 * Math.sin(2 * Math.PI * (t - 1.3) / 1.1); }
  }
  break;
 }
}

function applyEmote(p, emote, e, motion, look) {
 const d = DURATION[emote];
 const envelope = ease(e / 0.15) * ease((d - e) / 0.25);
 p.left = newEye(); p.right = newEye();
 switch (emote) {
 case 'love':
  eyes(p, x => { x.shape = 'heart'; });
  p.blush = 1;
  if (motion) {
   const pulse = 1 + 0.04 * Math.sin(2 * Math.PI * e / 0.6) * envelope;
   p.stretch = {w: p.stretch.w * pulse, h: p.stretch.h * pulse};
   hearts(p, e);
  }
  break;
 case 'surprised':
  eyes(p, x => { x.scale = 1.35; x.pupil = 0.6; });
  if (motion) { p.offset.dy -= 0.2 * bump(e, 0.45); squash(p, -0.08 * bump(e, 0.45)); }
  break;
 case 'proud':
  eyes(p, x => { x.shape = 'star'; });
  p.gaze.dy = -0.3;
  if (motion) p.stretch = {w: p.stretch.w * (1 + 0.08 * envelope), h: p.stretch.h * (1 + 0.05 * envelope)};
  break;
 case 'wink':
  if (e > 0.1 && e < 0.7) p.right.shape = 'arc';
  p.blush = 0.4; break;
 case 'yawn':
  if (e > 0.15 && e < 1.75) eyes(p, x => { x.shape = 'closed'; }); else eyes(p, x => { x.openness = 0.6; });
  if (motion) squash(p, -0.1 * bump(e, d));
  break;
 case 'happy':
  eyes(p, x => { x.shape = 'arc'; });
  p.blush = 0.8;
  if (motion && e < 1.2) p.offset.dy -= 0.05 * Math.abs(Math.sin(Math.PI * e / 0.4));
  break;
 case 'annoyed':
  eyes(p, x => { x.openness = 0.42; });
  // Lids slope down towards the middle.
  p.left.lidTilt = 0.35; p.right.lidTilt = -0.35;
  p.gaze = {dx: -0.5, dy: 0.15};
  if (motion && e < 0.6) p.offset.dx += 0.04 * Math.sin(2 * Math.PI * 5 * e) * (1 - e / 0.6);
  break;
 case 'listening':
  p.gaze = {dx: unit(look.dx * 1.3), dy: unit(look.dy * 1.3)};
  eyes(p, x => { x.scale = 1.05; });
  if (motion) { p.rotation += 7 * look.dx * envelope; p.offset.dx += 0.03 * look.dx * envelope; }
  break;
 }
}

/// Drops in, lands with a squash, looks around, blinks twice; about 4 s. True while it is still falling.
function applyGreeting(p, g, motion) {
 if (!(g >= 0 && g < 4)) return false;
 if (motion) {
  if (g < 0.45) { const f = g / 0.45; p.offset.dy -= 1.3 * (1 - f * f); squash(p, -0.07); }
  else squash(p, 0.18 * bump(g - 0.45, 0.35));
 }
 if (g >= 1 && g < 2.6) p.gaze = {dx: 0.9 * Math.sin(2 * Math.PI * (g - 1) / 1.6), dy: -0.1};
 blink(p, Math.max(lid(g - 2.8), lid(g - 3.1)));
 return motion && g < 0.45;
}

/// A click: the eyes squeeze shut and the body flinches away from the pointer.
function applyBoop(p, b, motion, look) {
 if (!(b >= 0 && b < 0.45)) return;
 if (b < 0.22) blink(p, 1);
 if (motion) {
  squash(p, 0.14 * bump(b, 0.45));
  p.offset.dx -= 0.05 * (look.dx < 0 ? -1 : 1) * bump(b, 0.45);
 }
}

/// Lowers the body just enough that the top of the badge stays inside the frame.
function keepBadgeInside(p) {
 const r = p.rotation * Math.PI / 180;
 const x = BADGE_CENTER.x * p.stretch.w, y = 0.5 + (BADGE_CENTER.y - 0.5) * p.stretch.h;
 const top = x * Math.sin(r) + y * Math.cos(r) - BADGE_RADIUS * Math.max(p.stretch.w, p.stretch.h) + p.offset.dy;
 if (top < HIGHEST_BADGE_TOP) p.offset.dy += HIGHEST_BADGE_TOP - top;
}

function sparkles(p, t) {
 if (!(t >= 0 && t < 2.4)) return;
 [[-0.62, -0.42], [0.6, -0.5], [0.64, 0.12], [-0.64, 0.18], [0.04, -0.7]].forEach(([x, y], i) => {
  const since = t - i * 0.17;
  if (since < 0) return;
  const size = 0.14 * bump(since % 0.9, 0.7);
  if (size > 0) p.particles.push({kind: 'sparkle', x, y, size, opacity: 1});
 });
}

function hearts(p, e) {
 [-0.3, 0.32, 0.02].forEach((x, i) => {
  const since = e - i * 0.45;
  if (!(since >= 0 && since < 1.3)) return;
  const f = since / 1.3;
  p.particles.push({kind: 'heart', x: x + 0.04 * Math.sin(2 * Math.PI * f), y: -0.42 - 0.32 * f, size: 0.12 + 0.04 * f, opacity: Math.min(1, f * 4) * (1 - f)});
 });
}

function sleepZs(p, t) {
 for (let i = 0; i < 3; i++) {
  const since = t - i;
  if (since < 0) continue;
  const f = (since % 3) / 3;
  p.particles.push({kind: 'sleepZ', x: 0.36 + 0.2 * f, y: -0.48 - 0.24 * f, size: 0.13 + 0.09 * f, opacity: bump(f, 1)});
 }
}

// MARK: Drawing

/// The rounded square with Apple's continuous corners, approximated by one cubic per corner that starts 1.528 radii
/// from the corner (where a circular corner would start at 1) and passes where the circular one passes at 45°.
function squircle(ctx, x, y, w, h, r) {
 const a = Math.min(1.528 * r, w / 2, h / 2), b = 0.2717 * r;
 ctx.beginPath();
 ctx.moveTo(x + a, y);
 ctx.lineTo(x + w - a, y); ctx.bezierCurveTo(x + w - b, y, x + w, y + b, x + w, y + a);
 ctx.lineTo(x + w, y + h - a); ctx.bezierCurveTo(x + w, y + h - b, x + w - b, y + h, x + w - a, y + h);
 ctx.lineTo(x + a, y + h); ctx.bezierCurveTo(x + b, y + h, x, y + h - b, x, y + h - a);
 ctx.lineTo(x, y + a); ctx.bezierCurveTo(x, y + b, x + b, y, x + a, y);
 ctx.closePath();
}

function roundRect(ctx, x, y, w, h, r) {
 ctx.beginPath();
 ctx.roundRect(x, y, w, h, Math.min(r, w / 2, h / 2));
}

const circle = (ctx, x, y, r) => { ctx.moveTo(x + r, y); ctx.arc(x, y, r, 0, 2 * Math.PI); };

/// Draws `p` into a canvas `w` × `h` CSS pixels whose context is already scaled by `scale` device pixels per CSS
/// pixel (shadows are not scaled by the transform, so they take it separately).
function draw(ctx, p, w, h, scale) {
 const side = Math.min(w, h) * (p.detailed ? BODY_FRACTION : PILL_BODY_FRACTION);
 const restX = w / 2, restY = h * (p.detailed ? REST_FRACTION : 0.5);

 ctx.save();
 ctx.translate(restX + p.offset.dx * side, restY + p.offset.dy * side);
 ctx.rotate(p.rotation * Math.PI / 180);
 ctx.translate(0, side / 2);
 ctx.scale(p.stretch.w, p.stretch.h);
 ctx.translate(0, -side / 2);

 drawBody(ctx, p, side, scale);
 const lidColor = mix(p.body, BLACK, 0.45);
 [[p.left, -0.2], [p.right, 0.2]].forEach(([eye, x]) => drawEye(ctx, eye, x * side, 0.03 * side, p.gaze, lidColor, p.detailed, side));
 if (p.blush > 0) drawBlush(ctx, p.blush, side);
 if (p.sweat != null) drawSweat(ctx, p.sweat, side);
 if (p.badge) drawBadge(ctx, p.badge, lidColor, side, scale);
 ctx.restore();

 ctx.save();
 ctx.translate(restX, restY);
 p.particles.forEach(particle => drawParticle(ctx, particle, side));
 ctx.restore();
}

function drawBody(ctx, p, side, scale) {
 const half = side / 2;
 const gradient = ctx.createLinearGradient(0, -half, 0, half);
 gradient.addColorStop(0, css(mix(p.body, WHITE, 0.3)));
 gradient.addColorStop(0.5, css(p.body));
 gradient.addColorStop(1, css(mix(p.body, BLACK, 0.22)));
 squircle(ctx, -half, -half, side, side, side * 0.28);
 ctx.save();
 if (p.detailed) {
  ctx.shadowColor = 'rgba(0,0,0,0.35)';
  ctx.shadowBlur = side * 0.1 * scale;
  ctx.shadowOffsetY = side * 0.035 * scale;
 }
 ctx.fillStyle = gradient;
 ctx.fill();
 ctx.restore();

 // Gloss: a reflection band hugging the top-left corner, and a specular dot near it.
 ctx.save();
 ctx.clip();
 const s = side;
 ctx.beginPath();
 ctx.moveTo(-0.40 * s, 0);
 ctx.quadraticCurveTo(-0.42 * s, -0.42 * s, 0, -0.40 * s);
 ctx.quadraticCurveTo(-0.27 * s, -0.27 * s, -0.40 * s, 0);
 const shine = ctx.createLinearGradient(-0.35 * s, -0.35 * s, 0, 0);
 shine.addColorStop(0, 'rgba(255,255,255,0.65)');
 shine.addColorStop(1, 'rgba(255,255,255,0.08)');
 ctx.fillStyle = shine;
 ctx.fill();
 ctx.beginPath();
 circle(ctx, -0.13 * s, -0.24 * s, s * 0.035);
 ctx.fillStyle = 'rgba(255,255,255,0.9)';
 ctx.fill();
 ctx.restore();
}

function drawEye(ctx, eye, cx, cy, gaze, lidColor, detailed, side) {
 const w = 0.2 * side * eye.scale, h = 0.27 * side * eye.scale;
 const x0 = cx - w / 2, y0 = cy - h / 2;
 const line = Math.max(0.055 * side, 0.9);
 ctx.lineCap = 'round';
 switch (eye.shape) {
 case 'round': {
  if (eye.openness < 0.12) { drawClosed(ctx, x0, y0, w, h, line, side); return; }
  const lidY = y0 + (1 - eye.openness) * h;
  const leftY = lidY - eye.lidTilt * h * 0.25, rightY = lidY + eye.lidTilt * h * 0.25;
  ctx.save();
  roundRect(ctx, x0, y0, w, h, w * 0.48);
  ctx.clip();
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(x0, leftY); ctx.lineTo(x0 + w, rightY); ctx.lineTo(x0 + w, y0 + h + 1); ctx.lineTo(x0, y0 + h + 1);
  ctx.closePath();
  ctx.clip();
  ctx.fillStyle = css(EYE_WHITE);
  ctx.fillRect(x0, y0, w, h);
  const r = 0.075 * side * eye.scale * eye.pupil;
  const px = cx + gaze.dx * (w / 2 - r) * 0.8, py = cy + gaze.dy * (h / 2 - r) * 0.75;
  ctx.beginPath(); circle(ctx, px, py, r); ctx.fillStyle = css(INK); ctx.fill();
  if (detailed) { ctx.beginPath(); circle(ctx, px - 0.35 * r, py - 0.38 * r, 0.32 * r); ctx.fillStyle = '#fff'; ctx.fill(); }
  ctx.restore();
  if (eye.openness < 0.99 || eye.lidTilt !== 0) {
   ctx.beginPath(); ctx.moveTo(x0, leftY); ctx.lineTo(x0 + w, rightY);
   ctx.lineCap = 'butt'; ctx.strokeStyle = css(lidColor); ctx.lineWidth = line * 0.8; ctx.stroke();
  }
  ctx.restore();
  break;
 }
 case 'flat':
  roundRect(ctx, cx - w * 0.55, cy - line * 0.6, w * 1.1, line * 1.2, line * 0.6);
  ctx.fillStyle = css(INK); ctx.fill(); break;
 case 'arc':
  ctx.beginPath();
  ctx.moveTo(x0, cy + 0.03 * side);
  ctx.quadraticCurveTo(cx, cy - 0.16 * side * eye.scale, x0 + w, cy + 0.03 * side);
  ctx.strokeStyle = css(INK); ctx.lineWidth = line; ctx.stroke(); break;
 case 'closed':
  drawClosed(ctx, x0, y0, w, h, line, side); break;
 case 'spiral': {
  const radius = 0.12 * side * eye.scale;
  ctx.beginPath(); circle(ctx, cx, cy, radius); ctx.fillStyle = css(EYE_WHITE); ctx.fill();
  ctx.beginPath();
  const turns = 2.25, steps = 48, start = eye.angle * Math.PI / 180;
  for (let i = 0; i <= steps; i++) {
   const f = i / steps, a = start + f * turns * 2 * Math.PI;
   const x = cx + radius * 0.85 * f * Math.cos(a), y = cy + radius * 0.85 * f * Math.sin(a);
   if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.strokeStyle = css(INK); ctx.lineWidth = line * 0.6; ctx.stroke(); break;
 }
 case 'heart': {
  const s = 0.26 * side * eye.scale;
  // A slightly bigger white heart behind gives the red one a rim on any body colour.
  heart(ctx, cx - s * 0.58, cy - s * 0.55, s * 1.16, s * 1.12); ctx.fillStyle = '#fff'; ctx.fill();
  heart(ctx, cx - s / 2, cy - s * 0.45, s, s * 0.95); ctx.fillStyle = css(HEART_RED); ctx.fill(); break;
 }
 case 'star':
  star(ctx, cx, cy, 0.15 * side * eye.scale);
  ctx.fillStyle = css(STAR_GOLD); ctx.fill();
  ctx.lineJoin = 'round'; ctx.strokeStyle = css(INK); ctx.lineWidth = line * 0.35; ctx.stroke(); break;
 }
}

/// A shut eye: a shallow downward curve.
function drawClosed(ctx, x0, y0, w, h, line, side) {
 const midY = y0 + h / 2;
 ctx.beginPath();
 ctx.moveTo(x0, midY + 0.02 * side);
 ctx.quadraticCurveTo(x0 + w / 2, midY + 0.12 * side, x0 + w, midY + 0.02 * side);
 ctx.lineCap = 'round'; ctx.strokeStyle = css(INK); ctx.lineWidth = line; ctx.stroke();
}

function drawBlush(ctx, amount, side) {
 ctx.fillStyle = css(BLUSH_PINK, 0.6 * amount);
 for (const x of [-0.32, 0.32]) {
  ctx.beginPath(); ctx.ellipse(x * side, 0.24 * side, 0.07 * side, 0.0375 * side, 0, 0, 2 * Math.PI); ctx.fill();
 }
}

/// A drop on the upper right of the body, `progress` of the way down; it fades as it ends.
function drawSweat(ctx, progress, side) {
 const w = 0.11 * side, h = 0.16 * side;
 const cx = 0.42 * side, cy = (-0.28 + 0.26 * progress) * side;
 const roundY = cy + h / 2 - w / 2, tipY = cy - h / 2;
 const opacity = 1 - progress ** 4;
 ctx.beginPath();
 ctx.moveTo(cx, tipY);
 ctx.quadraticCurveTo(cx + w / 2, cy - h * 0.05, cx + w / 2, roundY);
 ctx.arc(cx, roundY, w / 2, 0, Math.PI);
 ctx.quadraticCurveTo(cx - w / 2, cy - h * 0.05, cx, tipY);
 ctx.fillStyle = css(DROP_BLUE, opacity); ctx.fill();
 ctx.strokeStyle = css(INK, 0.3 * opacity); ctx.lineWidth = Math.max(0.012 * side, 0.5); ctx.stroke();
 ctx.beginPath(); circle(ctx, cx - w * 0.15, roundY - w * 0.1, w * 0.14); ctx.fillStyle = `rgba(255,255,255,${0.85 * opacity})`; ctx.fill();
}

/// A white bubble at the top right of the body with dots, "!", "?" or "z".
function drawBadge(ctx, badge, glyph, side, scale) {
 const cx = BADGE_CENTER.x * side, cy = BADGE_CENTER.y * side;
 ctx.save();
 ctx.shadowColor = 'rgba(0,0,0,0.3)'; ctx.shadowBlur = side * 0.06 * scale; ctx.shadowOffsetY = side * 0.015 * scale;
 ctx.beginPath(); circle(ctx, cx, cy, BADGE_RADIUS * side); ctx.fillStyle = 'rgba(255,255,255,0.96)'; ctx.fill();
 ctx.restore();
 if (badge.kind === 'dots') {
  for (let i = 0; i < 3; i++) {
   const raise = badge.phase == null ? 0 : bump((badge.phase - i * 0.15) % 0.9, 0.45);
   ctx.beginPath(); circle(ctx, cx + (i - 1) * 0.075 * side, cy - raise * 0.03 * side, 0.027 * side);
   ctx.fillStyle = css(INK, badge.phase == null ? 1 : 0.45 + 0.55 * raise); ctx.fill();
  }
  return;
 }
 const text = {exclamation: '!', question: '?', sleep: 'z'}[badge.kind];
 drawText(ctx, text, cx, cy, 0.25 * side, 900, css(glyph));
}

function drawText(ctx, text, x, y, size, weight, color) {
 ctx.font = `${weight} ${size}px ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", system-ui, sans-serif`;
 ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = color;
 ctx.fillText(text, x, y);
}

function drawParticle(ctx, particle, side) {
 const cx = particle.x * side, cy = particle.y * side, s = particle.size * side;
 if (particle.kind === 'sparkle') {
  const r = s / 2, tips = [[cx, cy - r], [cx + r, cy], [cx, cy + r], [cx - r, cy]];
  ctx.beginPath(); ctx.moveTo(...tips[0]);
  for (let i = 1; i <= 4; i++) ctx.quadraticCurveTo(cx, cy, ...tips[i % 4]);
  ctx.closePath(); ctx.fillStyle = css(SPARKLE_CREAM, particle.opacity); ctx.fill();
 } else if (particle.kind === 'heart') {
  heart(ctx, cx - s / 2, cy - s / 2, s, s * 0.95); ctx.fillStyle = css(mix(HEART_RED, WHITE, 0.2), particle.opacity); ctx.fill();
 } else {
  drawText(ctx, 'z', cx, cy, s, 800, `rgba(255,255,255,${0.9 * particle.opacity})`);
 }
}

/// Two lobes and a point, filling the rectangle.
function heart(ctx, x, y, w, h) {
 const lobe = w / 4, midX = x + w / 2;
 ctx.beginPath();
 circle(ctx, midX - lobe, y + lobe, lobe * 1.05);
 circle(ctx, midX + lobe, y + lobe, lobe * 1.05);
 ctx.moveTo(x + w * 0.015, y + lobe * 1.35); ctx.lineTo(x + w - w * 0.015, y + lobe * 1.35); ctx.lineTo(midX, y + h);
 ctx.closePath();
}

function star(ctx, cx, cy, radius) {
 ctx.beginPath();
 for (let i = 0; i < 10; i++) {
  const r = i % 2 === 0 ? radius : radius * 0.45, a = -Math.PI / 2 + i * Math.PI / 5;
  ctx.lineTo(cx + r * Math.cos(a), cy + r * Math.sin(a));
 }
 ctx.closePath();
}

// MARK: On the page

const clock = () => performance.now() / 1000;
const instances = new Set();
let reduceMotion = false, frame = 0;

/// Boops on the first and second click within 1.7 s, dizzy for 3.3 s on the third, love after hovering 1.9 s: the
/// app's CharacterDirector, except that a boop is followed by "happy" here (the app shows "annoyed").
function mount(canvas, {state = 'idle', pill = false, interactive = false} = {}) {
 const block = {
  canvas, pill, visible: true, state, stateStartedAt: clock(), emote: null, emoteStartedAt: null, boopedAt: null,
  greetingStartedAt: null, hovering: false, hoverStartedAt: null, lastLove: -Infinity, clicks: [], dizzyUntil: null,
  look: {dx: 0, dy: 0}, stillTimers: [],
  setState(next) {
   if (block.dizzyUntil != null) { block.dizzyUntil = null; block.state = null; }
   if (next === block.state) return;
   block.state = next; block.stateStartedAt = clock(); changed(block);
  },
  showEmote(name) { block.emote = name; block.emoteStartedAt = clock(); changed(block); },
  greet() { block.greetingStartedAt = clock(); changed(block); },
  /// Returns true when this click made Block dizzy.
  click() {
   const now = clock();
   if (block.dizzyUntil != null) return false;
   block.clicks = block.clicks.filter(t => now - t <= 1.7);
   if (block.clicks.length + 1 >= 3) {
    block.clicks = []; block.dizzyUntil = now + 3.3; block.dizzyFrom = block.state;
    block.state = 'dizzy'; block.stateStartedAt = now; block.emote = null; changed(block);
    return true;
   }
   block.clicks.push(now); block.boopedAt = now; block.emote = 'happy'; block.emoteStartedAt = now + 0.3;
   changed(block);
   return false;
  }
 };
 if (interactive) {
  canvas.parentElement.addEventListener('pointerenter', event => { if (event.pointerType !== 'touch') { block.hovering = true; block.hoverStartedAt = clock(); changed(block); } });
  canvas.parentElement.addEventListener('pointerleave', () => { block.hovering = false; block.hoverStartedAt = null; changed(block); });
 }
 visibility.observe(canvas);
 instances.add(block);
 changed(block);
 return block;
}

/// The app's director ticks: dizzy ends with "happy", a long hover shows love (again after 6 s).
function tick(block, now) {
 if (block.dizzyUntil != null && now >= block.dizzyUntil) {
  block.dizzyUntil = null; block.state = block.dizzyFrom; block.stateStartedAt = now;
  block.emote = 'happy'; block.emoteStartedAt = now;
  if (block.hoverStartedAt != null) block.hoverStartedAt = now;
 }
 if (block.dizzyUntil == null && block.hoverStartedAt != null && now - block.hoverStartedAt >= 1.9 && now - block.lastLove >= 6) {
  block.lastLove = now; block.emote = 'love'; block.emoteStartedAt = now;
 }
}

function input(block, now) {
 const size = Math.min(block.canvas.clientWidth, block.canvas.clientHeight);
 return {
  state: block.state, emote: block.emote, emoteStartedAt: block.emoteStartedAt, stateStartedAt: block.stateStartedAt,
  hovering: block.hovering, boopedAt: block.boopedAt, greetingStartedAt: block.greetingStartedAt, look: block.look,
  detailed: !block.pill && size >= 24, reduceMotion
 };
}

function render(block, now) {
 const canvas = block.canvas, w = canvas.clientWidth, h = canvas.clientHeight;
 if (!w || !h) return;
 const scale = Math.min(window.devicePixelRatio || 1, 3);
 const pw = Math.round(w * scale), ph = Math.round(h * scale);
 if (canvas.width !== pw || canvas.height !== ph) { canvas.width = pw; canvas.height = ph; }
 const ctx = canvas.getContext('2d');
 ctx.setTransform(scale, 0, 0, scale, 0, 0);
 ctx.clearRect(0, 0, w, h);
 draw(ctx, pose(input(block, now), now), w, h, scale);
}

function loop() {
 frame = 0;
 const now = clock();
 let any = false;
 instances.forEach(block => { tick(block, now); if (block.visible) { render(block, now); any = true; } });
 if (any && !reduceMotion && !document.hidden) frame = requestAnimationFrame(loop);
}

function start() { if (!frame && !reduceMotion) frame = requestAnimationFrame(loop); }

/// Under reduced motion nothing moves, so a block is drawn only when its picture changes: now, and at the middle and
/// end of an emote, the end of a boop and of a greeting. A moment inside a blink is moved past it, as in the app.
function changed(block) {
 if (!reduceMotion) { start(); return; }
 block.stillTimers.forEach(clearTimeout);
 const now = clock(), moments = [0];
 if (block.emote && block.emoteStartedAt != null) {
  const d = DURATION[block.emote], at = block.emoteStartedAt - now;
  moments.push(at, at + d / 2, at + d);
 }
 if (block.boopedAt != null) moments.push(block.boopedAt + 0.45 - now);
 if (block.greetingStartedAt != null) moments.push(block.greetingStartedAt + 4 - now);
 if (block.dizzyUntil != null) moments.push(block.dizzyUntil - now);
 block.stillTimers = moments.filter(m => m >= 0).map(m => setTimeout(() => {
  let moment = clock();
  tick(block, moment);
  for (let i = 0; i < 12 && blinkAt(Math.max(0, moment - block.stateStartedAt)) !== 0; i++) moment += 0.05;
  render(block, moment);
 }, m * 1000 + 20));
}

const visibility = new IntersectionObserver(entries => entries.forEach(entry => {
 const block = [...instances].find(b => b.canvas === entry.target);
 if (!block) return;
 block.visible = entry.isIntersecting;
 if (block.visible) changed(block);
}), {rootMargin: '100px'});

document.addEventListener('visibilitychange', () => { if (!document.hidden) start(); });
new ResizeObserver(() => instances.forEach(changed)).observe(document.documentElement);

/// The pointer relative to each block, each axis -1...1 at 150 px (the app's island uses the same distance).
document.addEventListener('pointermove', event => {
 if (event.pointerType === 'touch') return;
 instances.forEach(block => {
  const rect = block.canvas.getBoundingClientRect();
  const look = {dx: unit((event.clientX - rect.left - rect.width / 2) / 150), dy: unit((event.clientY - rect.top - rect.height / 2) / 150)};
  if (Math.abs(look.dx - block.look.dx) > 0.03 || Math.abs(look.dy - block.look.dy) > 0.03) { block.look = look; if (reduceMotion) changed(block); }
 });
}, {passive: true});

return {
 mount,
 setReduceMotion(value) {
  reduceMotion = value;
  if (value && frame) { cancelAnimationFrame(frame); frame = 0; }
  instances.forEach(changed);
 }
};
})();
