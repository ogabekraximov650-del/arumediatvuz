# Ilovaning qo'ng'iroq va bildirishnoma ovozlarini NOLDAN yasaydi.
#
# NEGA GENERATSIYA: tayyor ohangni internetdan olish mualliflik
# huquqi jihatidan xavfli. Bu yerdagi ovozlar sof sinus to'lqin +
# ikkita yumshoq harmonikadan yig'iladi, ya'ni ular butunlay
# loyihaning o'ziniki.
#
# Ishga tushirish:  python3 ci/gen_sounds.py
# Natija:           assets/sounds/*.wav

import math, os, struct, wave

SR = 22050

def blank(dur):
    return [0.0] * int(SR * dur)

def note(buf, start, freq, dur, amp=0.5, attack=0.012, harm=(1.0, 0.28, 0.10)):
    """Yumshoq qo'ng'iroq tovushi: asosiy ton + ikki ohang (harmonika).
    Hujum (attack) ko'tarilgan kosinus bilan — 'klik' bo'lmaydi.
    So'nish eksponensial — tabiiy qo'ng'iroqdek."""
    n = int(SR * dur)
    i0 = int(SR * start)
    for i in range(n):
        t = i / SR
        # envelope
        if t < attack:
            env = 0.5 - 0.5 * math.cos(math.pi * t / attack)
        else:
            env = math.exp(-3.2 * (t - attack) / (dur - attack))
        s = 0.0
        for k, h in enumerate(harm, start=1):
            s += h * math.sin(2 * math.pi * freq * k * t)
        s /= sum(harm)
        idx = i0 + i
        if idx < len(buf):
            buf[idx] += amp * env * s

def fade_in(buf, dur):
    n = min(int(SR * dur), len(buf))
    for i in range(n):
        buf[i] *= i / n

def write(path, buf):
    peak = max(1e-9, max(abs(x) for x in buf))
    if peak > 0.95:
        buf = [x * 0.95 / peak for x in buf]
    data = b''.join(struct.pack('<h', int(max(-1, min(1, x)) * 32767)) for x in buf)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data)

D = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 'assets', 'sounds') + os.sep
os.makedirs(D, exist_ok=True)

# ── 1. KELAYOTGAN QO'NG'IROQ (takrorlanadi, 4 s) ─────────────
# Ko'tarilgan kichik tersiya: D5 → G5. Ikki marta, keyin sukunat.
# Birinchi juftlik past ovozda boshlanadi (fade-in) — cho'chitmaydi.
b = blank(4.0)
note(b, 0.00, 587.33, 0.55, amp=0.42)
note(b, 0.30, 783.99, 0.75, amp=0.42)
note(b, 1.10, 587.33, 0.55, amp=0.50)
note(b, 1.40, 783.99, 0.85, amp=0.50)
fade_in(b, 0.9)
write(D + 'incoming_call.wav', b)

# ── 2. CHIQAYOTGAN QO'NG'IROQ (kutish, 3 s, takrorlanadi) ────
# Past, bo'g'iq "tut... tut" — quloqqa urilmaydi.
b = blank(3.0)
note(b, 0.00, 415.30, 0.85, amp=0.30, attack=0.05, harm=(1.0, 0.12, 0.0))
note(b, 1.50, 415.30, 0.85, amp=0.30, attack=0.05, harm=(1.0, 0.12, 0.0))
write(D + 'outgoing_call.wav', b)

# ── 3. XABAR KELDI (0.9 s) ───────────────────────────────────
# Qisqa, yumshoq ikki nota: A5 → D6. Bir marta.
b = blank(0.9)
note(b, 0.00, 880.00, 0.30, amp=0.40)
note(b, 0.13, 1174.66, 0.55, amp=0.40)
write(D + 'message.wav', b)

# ── 4. QO'NG'IROQ ULANDI (0.5 s) ─────────────────────────────
# Ikki qisqa ko'tariluvchi signal — "ulandi" degani.
b = blank(0.5)
note(b, 0.00, 659.25, 0.16, amp=0.28, harm=(1.0, 0.18, 0.0))
note(b, 0.13, 987.77, 0.30, amp=0.28, harm=(1.0, 0.18, 0.0))
write(D + 'call_connected.wav', b)

# ── 5. QO'NG'IROQ TUGADI (0.6 s) ─────────────────────────────
# Pasayuvchi juftlik — "tugadi".
b = blank(0.6)
note(b, 0.00, 587.33, 0.18, amp=0.26, harm=(1.0, 0.15, 0.0))
note(b, 0.15, 392.00, 0.42, amp=0.26, harm=(1.0, 0.15, 0.0))
write(D + 'call_ended.wav', b)

print("tayyor")
