const F = n => Math.round(n * 1000) / 1000;

// ═══════════════════════════════════════════════════════════════
//  ARU — TO'LA PLITADAN KESIB OLINGAN
//
//  Plita — to'liq to'rtburchak (yumaloq burchakli). Harflar undan
//  O'YIB olinadi. Harf ichidagi yopiq bo'shliqlar (A ning uchburchagi,
//  R ning qorni) plita materiali sifatida QOLADI — orol bo'lib
//  osilib turadi. Aynan shu orollar harfni o'qitadi.
//
//  A — R ning tayanchiga yotqizib ulangan: A ning o'ng oyog'i
//  tayanch bilan bitta yaxlit o'yiqqa aylanadi.
//  Chetlar plita qirrasida qaychi bilan kesilgandek to'xtaydi.
// ═══════════════════════════════════════════════════════════════
function glyphs(o = {}) {
  const W  = o.W  ?? 48;
  const th = o.th ?? 40;
  const H  = 300, T = 0, B = H;
  const OS = o.os ?? 5;
  const P = [];

  // ── A ─────────────────────────────────────────────────────
  const aL = 0, aW = o.aW ?? 224, aR = aL + aW;
  const fa = o.fa ?? 26, xc = (aL + aR) / 2;
  const apL = xc - fa / 2, apR = xc + fa / 2;
  const run = apL - aL;
  const wA = W / (H / Math.hypot(run, H));
  const ilB = aL + wA, irB = aR - wA;
  const sk = (irB - ilB) / (2 * run);
  const tipY = B - H * sk;
  const barC = o.barC ?? 214, barT = barC - th / 2, barB = barC + th / 2;
  const ix = (y, left) => { const k = (B - y) / H; return left ? ilB + run * k : irB - run * k; };
  P.push(`M ${F(aL)},${F(B)} L ${F(apL)},${F(T)} L ${F(apR)},${F(T)} L ${F(aR)},${F(B)}
    L ${F(irB)},${F(B)} L ${F(ix(barB,false))},${F(barB)} L ${F(ix(barB,true))},${F(barB)}
    L ${F(ilB)},${F(B)} Z
    M ${F(ix(barT,true))},${F(barT)} L ${F(xc)},${F(tipY)} L ${F(ix(barT,false))},${F(barT)} Z`);

  // ── R ── tayanchi A ning o'ng oyog'i bilan QO'SHILIB ketadi
  const lap = o.lap ?? 26;                    // yotqizib ulash chuqurligi
  const rL = aR - lap, rSR = rL + W;
  const reach = o.reach ?? 104;
  const rR = rSR + reach;
  const bH = o.bH ?? 172, ro = bH / 2, bcx = rR - ro;
  const rix = ro - W, riy = ro - th;
  P.push(`M ${F(rL)},${F(T)} L ${F(bcx)},${F(T)}
    A ${F(ro)},${F(ro)} 0 0 1 ${F(bcx)},${F(bH)} L ${F(rL)},${F(bH)} L ${F(rL)},${F(B)}
    L ${F(rSR)},${F(B)} L ${F(rSR)},${F(T)} Z
    M ${F(rSR)},${F(th)} L ${F(bcx)},${F(th)}
    A ${F(rix)},${F(riy)} 0 0 1 ${F(bcx)},${F(bH - th)} L ${F(rSR)},${F(bH - th)} Z`);
  const g0 = o.g0 ?? 30, g1 = o.g1 ?? 100;
  P.push(`M ${F(rSR + g0)},${F(bH - th)} L ${F(rSR + g0 + W)},${F(bH - th)}
    L ${F(rSR + g1 + W)},${F(B)} L ${F(rSR + g1)},${F(B)} Z`);

  // ── U ── R ning qorniga tegadi
  const uL = rR, uW = o.uW ?? 172, uR = uL + uW;
  const ro2 = uW / 2, cy = B + OS - ro2;
  const rix2 = ro2 - W, riy2 = ro2 - th;
  P.push(`M ${F(uL)},${F(T)} L ${F(uL)},${F(cy)}
    A ${F(ro2)},${F(ro2)} 0 0 0 ${F(uR)},${F(cy)} L ${F(uR)},${F(T)}
    L ${F(uR - W)},${F(T)} L ${F(uR - W)},${F(cy)}
    A ${F(rix2)},${F(riy2)} 0 0 1 ${F(uL + W)},${F(cy)} L ${F(uL + W)},${F(T)} Z`);

  return { paths: P, w: uR, h: B + OS };
}

// Harflarni plita ichiga joylash. bleed>0 bo'lsa chetlardan chiqib
// ketadi va plita qirrasi ularni qaychidek kesadi.
function place(o = {}, bleed = 0, box = 512) {
  const g = glyphs(o);
  const k = (box + 2 * bleed) / g.w;
  const dx = -bleed, dy = (box - g.h * k) / 2;
  return `<g transform="translate(${F(dx)} ${F(dy)}) scale(${F(k)})">
    ${g.paths.map(d => `<path d="${d}"/>`).join('')}</g>`;
}
module.exports = { place };
