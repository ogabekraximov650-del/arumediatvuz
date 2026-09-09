// ═══════════════════════════════════════════════════════════════
//  ARU logotipi -> Android ilova belgisi (launcher icon)
//
//  ISHLATISH:  node branding/build-icons.js
//  Natija:     branding/aru-logo.svg, branding/aru-foreground.svg
//              branding/android-res/**  (CI shu papkani ko'chiradi)
//
//  Chromium orqali PNG chiqariladi (repoda allaqachon bor:
//  /opt/pw-browsers/... yoki CHROME muhit o'zgaruvchisi orqali).
// ═══════════════════════════════════════════════════════════════
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { place } = require('./aru-geometry.js');

const OUT = path.join(__dirname, 'android-res');
const TMP = path.join(__dirname, '.tmp');

// ── Brend ranglari ────────────────────────────────────────────
const PLATE = '#000000';   // plita — to'liq qora
const CUT   = '#FFFFFF';   // o'yiqdan ko'rinadigan rang — oq
// Burchak radiusi — 512 lik maydonda 114 (22.3%), ilova belgilari
// uchun odatiy nisbat.
const RX    = 114;
// Alohida kerak bo'lsa — to'la kvadrat nusxa uchun radius
const RX_SQUARE = 0;

const letters = place({}, 0);   // chetlarga to'liq tiralgan

// To'liq belgi: qizil zamin, ustiga qora plita — harflar o'yib olingan
const logoSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs><mask id="cut">
    <rect width="512" height="512" fill="#fff"/>
    <g fill="#000">${letters}</g>
  </mask></defs>
  <rect width="512" height="512" rx="${RX}" fill="${CUT}"/>
  <rect width="512" height="512" rx="${RX}" fill="${PLATE}" mask="url(#cut)"/>
</svg>`;

// ── TELEGRAM KANALI UCHUN ALOHIDA NUSXA ──────────────────────
// Telegram avatarni DOIRA qilib qirqadi. Asosiy logotipda harflar
// chetlarga tiralgani uchun doira ularning uchlarini kesib yuboradi.
// Shu sabab bu nusxada FON to'la kvadrat (burchak radiusi kerak emas —
// baribir qirqiladi), harflar esa ichki doiraga to'liq sig'adigan
// qilib joylashtirilgan. Logotipning O'ZI o'zgarmagan — faqat
// atrofidagi bo'sh joy kattaroq.
//
// Hisob: kengligi w, balandligi h bo'lgan belgi R radiusli doiraga
// sig'ishi uchun sqrt((w/2)^2+(h/2)^2) <= R bo'lishi shart. Bizning
// nisbatimizda bu belgi kengligini maydonning ~86% iga tushiradi.
const TG_INSET = -34;   // 512 lik maydonda: harflar 444px ni egallaydi
const tgSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs><mask id="cutTg">
    <rect width="512" height="512" fill="#fff"/>
    <g fill="#000">${place({}, TG_INSET)}</g>
  </mask></defs>
  <rect width="512" height="512" fill="${CUT}"/>
  <rect width="512" height="512" fill="${PLATE}" mask="url(#cutTg)"/>
</svg>`;

// Moslashuvchan belgi (Android 8+) uchun old qatlam: faqat harflar,
// xavfsiz maydonga (markazning ~66%) siqilgan, foni shaffof.
const SAFE = 0.66;
const fgSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <g transform="translate(${(512 * (1 - SAFE)) / 2} ${(512 * (1 - SAFE)) / 2}) scale(${SAFE})">
    <g fill="${CUT}">${letters}</g>
  </g>
</svg>`;

// To'la kvadrat nusxa — burchaksiz zamin kerak bo'lganda
const squareSvg = logoSvg.split(`rx="${RX}"`).join(`rx="${RX_SQUARE}"`)
  .split('id="cut"').join('id="cutS"').split('url(#cut)').join('url(#cutS)');

fs.writeFileSync(path.join(__dirname, 'aru-logo.svg'), logoSvg);
fs.writeFileSync(path.join(__dirname, 'aru-logo-square.svg'), squareSvg);
fs.writeFileSync(path.join(__dirname, 'aru-foreground.svg'), fgSvg);
fs.writeFileSync(path.join(__dirname, 'aru-telegram.svg'), tgSvg);

// ── PNG chiqarish ─────────────────────────────────────────────
const CHROME = process.env.CHROME ||
  ['/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
   '/usr/bin/chromium', '/usr/bin/google-chrome'].find(p => fs.existsSync(p));
if (!CHROME) { console.error('Chromium topilmadi. CHROME=... bering.'); process.exit(1); }

fs.mkdirSync(TMP, { recursive: true });
// DIQQAT: headless Chromium'ning eng kichik oyna o'lchami bor, shu
// sabab 48px belgini u to'g'ridan-to'g'ri chiza olmaydi — rasm kesilib
// qoladi. Shuning uchun belgi BIR MARTA katta o'lchamda chiziladi,
// keyin `pngscale.py` uni har bir zichlik uchun aniq siqadi.
// Master qanchalik yirik bo'lsa, kichik belgilar shunchalik silliq
// chiqadi (48px belgi 2048'dan siqilganda har bir pikselga ~43x43
// manba pikseli o'rtachalanadi — Chromium'ning o'z tekislashidan ham
// aniqroq).
const MASTER = 2048;
// Oyna tepasidagi band uchun zaxira balandlik — keyin kesib tashlanadi
const PAD = 220;
// Chromium kichik oynani chiza olmaydi; shundan pastini siqib olamiz
const MIN_DIRECT = 640;

function renderMaster(svg, dest, transparent, size = MASTER) {
  const html = `<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0;overflow:hidden;
background:${transparent ? 'transparent' : '#fff'}}
svg{display:block;width:${size}px;height:${size}px}</style>${svg}`;
  const hp = path.join(TMP, 'p.html');
  const raw = path.join(TMP, 'raw.png');
  fs.writeFileSync(hp, html);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  execFileSync(CHROME, [
    '--headless', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
    '--force-device-scale-factor=1', `--window-size=${size},${size + PAD}`,
    ...(transparent ? ['--default-background-color=00000000'] : []),
    `--screenshot=${raw}`, '--virtual-time-budget=2000', 'file://' + hp,
  ], { stdio: 'ignore' });
  // Chap-yuqori burchakdan aniq MASTER x MASTER kvadrat kesiladi
  execFileSync('python3', [path.join(__dirname, 'pngscale.py'),
    raw, dest, String(size), String(size)], { stdio: 'inherit' });
  check(dest, size);
}

function check(file, size) {
  const d = fs.readFileSync(file).subarray(16, 24);
  const w = d.readUInt32BE(0), h = d.readUInt32BE(4);
  if (w !== size || h !== size) {
    throw new Error(`${file}: ${w}x${h} chiqdi, ${size}x${size} kutilgandi`);
  }
}

function shrink(master, dest, size) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  execFileSync('python3', [path.join(__dirname, 'pngscale.py'), master, dest, String(size)],
    { stdio: 'inherit' });
  check(dest, size);
}

// Eski uslubdagi belgi — 48dp
const LEGACY = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
// Moslashuvchan qatlamlar — 108dp
const ADAPT  = { mdpi: 108, hdpi: 162, xhdpi: 216, xxhdpi: 324, xxxhdpi: 432 };

fs.rmSync(OUT, { recursive: true, force: true });

// Barcha o'lchamlarning manbasi
const masterLogo = path.join(TMP, 'logo.png');
const masterFg = path.join(TMP, 'fg.png');
renderMaster(logoSvg, masterLogo, false);
renderMaster(fgSvg, masterFg, true);

// Tarqatish uchun tayyor yirik nusxalar. Bular vektor'dan TO'G'RIDAN-
// TO'G'RI chiziladi (siqilmaydi), shu sabab chetlari eng aniq chiqadi.
//   2048 — do'kon va bosma uchun zaxira
//   1080 — Telegram kanali, ijtimoiy tarmoqlar
//    512 — ilova do'konlari talab qiladigan eng keng tarqalgan o'lcham
for (const s of [2048, 1080, 512]) {
  renderMaster(logoSvg, path.join(__dirname, `aru-logo-${s}.png`), false, s);
}
// Telegram (doira qirqim) uchun
for (const s of [1080, 512]) {
  renderMaster(tgSvg, path.join(__dirname, `aru-telegram-${s}.png`), false, s);
}
// To'la kvadrat nusxa
renderMaster(squareSvg, path.join(__dirname, 'aru-logo-square-1080.png'), false, 1080);

for (const [d, s] of Object.entries(LEGACY)) {
  shrink(masterLogo, path.join(OUT, `mipmap-${d}`, 'ic_launcher.png'), s);
}
for (const [d, s] of Object.entries(ADAPT)) {
  shrink(masterFg, path.join(OUT, `mipmap-${d}`, 'ic_launcher_foreground.png'), s);
}

// Moslashuvchan belgi ta'rifi
fs.mkdirSync(path.join(OUT, 'mipmap-anydpi-v26'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'mipmap-anydpi-v26', 'ic_launcher.xml'),
`<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
`);
fs.mkdirSync(path.join(OUT, 'values'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'values', 'ic_launcher_background.xml'),
`<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">${PLATE}</color>
</resources>
`);

fs.rmSync(TMP, { recursive: true, force: true });
console.log('✅ Belgilar tayyor: branding/android-res/');
