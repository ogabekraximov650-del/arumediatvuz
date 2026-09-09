#!/usr/bin/env python3
"""PNG kichraytirgich — hech qanday tashqi kutubxonasiz (faqat zlib).

NEGA KERAK: headless Chromium'ning eng kichik oyna o'lchami bor, shu
sabab 48px belgini u to'g'ridan-to'g'ri chiza olmaydi (rasm kesilib
qoladi). Yechim: belgi katta o'lchamda chiziladi, keyin shu skript
uni aniq o'lchamga siqadi.

Shaffoflik to'g'ri ishlanadi: piksellar OLDIN alfaga ko'paytiriladi,
o'rtacha olinadi, keyin qaytariladi — aks holda chetlarda qora hoshiya
paydo bo'lardi.

QIRQISH: headless Chromium oynasining tepasida band bor, shu sabab
rasm pastdan yetishmay qoladi. Yechim — oynani baland so'rab, keyin
chap-yuqori burchakdan aniq kvadratni kesib olish (crop).

Ishlatish:  python3 pngscale.py kirish.png chiqish.png <o'lcham> [crop]
"""
import sys, zlib, struct

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'PNG emas'
    i, idat, hdr = 8, b'', None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]
        typ = d[i+4:i+8]
        body = d[i+8:i+8+ln]
        if typ == b'IHDR':
            hdr = struct.unpack('>IIBBBBB', body)
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        i += 12 + ln
    w, h, depth, color, comp, filt, inter = hdr
    # Chromium shaffof rasmni RGBA (6), noshaffofni RGB (2) qilib beradi
    assert depth == 8 and color in (2, 6) and inter == 0, \
        f'faqat 8-bitli RGB/RGBA qo\'llanadi ({depth},{color})'
    raw = zlib.decompress(idat)

    # Filtrlarni yechish (PNG spetsifikatsiyasi, 9-bo'lim)
    bpp = 3 if color == 2 else 4
    stride = w * bpp
    out = bytearray(h * stride)
    pos = 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        base, prev = y * stride, (y - 1) * stride
        for x in range(stride):
            # `a` — SHU qatorning ALLAQACHON TIKLANGAN chap qo'shnisi
            # (xom bayt emas! bu joyda adashilsa rasm chiziq-chiziq bo'lib buziladi)
            a = out[base+x-bpp] if x >= bpp else 0
            b = out[prev+x] if y else 0
            c = out[prev+x-bpp] if (y and x >= bpp) else 0
            if f == 1:   v = line[x] + a
            elif f == 2: v = line[x] + b
            elif f == 3: v = line[x] + (a + b) // 2
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                v = line[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))
            else:        v = line[x]
            out[base+x] = v & 0xFF

    if bpp == 3:                       # RGB -> RGBA (alfa = 255)
        rgba = bytearray(w * h * 4)
        for i in range(w * h):
            rgba[i*4:i*4+3] = out[i*3:i*3+3]
            rgba[i*4+3] = 255
        out = rgba
    return w, h, out

def scale(w, h, px, n):
    """Quti filtri: har bir yangi piksel manba maydonining o'rtachasi."""
    dst = bytearray(n * n * 4)
    for oy in range(n):
        y0, y1 = oy * h // n, max(oy * h // n + 1, (oy + 1) * h // n)
        for ox in range(n):
            x0, x1 = ox * w // n, max(ox * w // n + 1, (ox + 1) * w // n)
            r = g = b = a = cnt = 0
            for y in range(y0, y1):
                row = y * w * 4
                for x in range(x0, x1):
                    i = row + x * 4
                    al = px[i+3]
                    r += px[i] * al; g += px[i+1] * al; b += px[i+2] * al
                    a += al; cnt += 1
            o = (oy * n + ox) * 4
            if a:
                dst[o] = min(255, r // a); dst[o+1] = min(255, g // a)
                dst[o+2] = min(255, b // a); dst[o+3] = a // cnt
    return dst

def write_png(path, n, px):
    def chunk(typ, body):
        return struct.pack('>I', len(body)) + typ + body + \
               struct.pack('>I', zlib.crc32(typ + body) & 0xFFFFFFFF)
    raw = bytearray()
    for y in range(n):
        raw.append(0)                      # filtr yo'q
        raw += px[y*n*4:(y+1)*n*4]
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
            + chunk(b'IEND', b''))
    open(path, 'wb').write(data)

def crop_tl(w, h, px, c):
    """Chap-yuqori burchakdan c x c kvadratni kesib oladi."""
    out = bytearray(c * c * 4)
    for y in range(c):
        out[y*c*4:(y+1)*c*4] = px[y*w*4:y*w*4 + c*4]
    return out

if __name__ == '__main__':
    src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    w, h, px = read_png(src)
    if len(sys.argv) > 4:
        c = int(sys.argv[4])
        if c > w or c > h:
            raise SystemExit(f'{src}: {w}x{h} — {c}x{c} kesib bo\'lmaydi')
        px = crop_tl(w, h, px, c); w = h = c
    write_png(dst, n, scale(w, h, px, n) if n != w else px)
