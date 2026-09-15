// rust/src/mp4.rs — MP4 konteyneridan BITTA KADR ajratib olish.
//
// ═══════════════════════════════════════════════════════════════════
//  NEGA BU KERAK
// ═══════════════════════════════════════════════════════════════════
//
// Tomosha tarixida har bir qism foydalanuvchi TO'XTAGAN JOYDAGI kadr
// bilan ko'rsatiladi. Flutter videodan kadr ola olmaydi (rasm GPU
// qatlamida chiziladi), Android'ning o'z vositasi esa — ola oladi,
// lekin unga TO'LIQ, HAQIQIY MP4 fayl kerak.
//
// Butun epizodni (100-500 MB) shuning uchun yuklab olish mantiqsiz.
// Shu sabab bu modul:
//
//   1. faylning `moov` atomini (ichida "qaysi soniya qaysi baytda"
//      jadvali bor) o'qiydi;
//   2. kerakli soniyadan OLDINGI kalit kadrni (keyframe) topadi;
//   3. faqat O'SHA kadrning baytlaridan bitta kadrlik, to'la
//      haqiqiy MP4 yasaydi.
//
// Natijada tarmoqdan ~0,3-1 MB olinadi (butun fayl emas), yasalgan
// mini-MP4 esa diskka umuman yozilmaydi — u xotirada turadi va
// berilgandan keyin darhol o'chadi.
//
// ═══════════════════════════════════════════════════════════════════
//  NEGA DEKODLASH BU YERDA EMAS
// ═══════════════════════════════════════════════════════════════════
//
// Kadrni JPEG'ga o'girishni Rust QILMAYDI. H.264/H.265 dekoderi sof
// Rust'da yo'q — `openh264`/`ffmpeg` esa C kutubxonasi, ya'ni APK
// bir necha MB kattalashadi va loyihaning "faqat sof Rust" qoidasi
// buziladi. Telefonda esa APPARAT dekoder allaqachon bor va u shu
// ishni ~50 ms da, batareyani yemasdan bajaradi. Shuning uchun
// mehnat shunday bo'lingan:
//
//   Rust    — qaysi bayt kerakligini hisoblaydi va olib beradi;
//   Android — faqat dekodlaydi.

/// Bitta namunaning (kadrning) fayldagi o'rni.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SampleRef {
    pub offset: u64,
    pub size: u32,
}

/// Namuna hajmlari: hammasi bir xil bo'lsa bitta son, aks holda
/// jadval.
#[derive(Debug, Clone)]
enum SampleSizes {
    Uniform(u32),
    Table(Vec<u32>),
}

/// `moov` dan o'qilgan video yo'lakcha (track).
#[derive(Debug, Clone)]
pub struct VideoTrack {
    /// Vaqt birligi: bir soniyada shuncha "tik".
    pub timescale: u32,
    pub width: u16,
    pub height: u16,
    /// `stsd` atomining O'ZI (sarlavhasi bilan) — ichida kodek
    /// sozlamalari (`avcC`/`hvcC`) bor va ularsiz hech qanday
    /// dekoder kadrni ocholmaydi. Shu sabab u AYNAN O'SHA HOLIDA
    /// ko'chiriladi.
    stsd: Vec<u8>,
    /// Kalit kadrlar (1 dan boshlab sanaladi). Bo'sh bo'lsa —
    /// `stss` atomi yo'q, ya'ni HAMMA kadr kalit kadr.
    sync_samples: Vec<u32>,
    /// (namunalar soni, har birining davomiyligi).
    stts: Vec<(u32, u32)>,
    sizes: SampleSizes,
    /// (birinchi blok, blokdagi namunalar soni, tavsif indeksi).
    stsc: Vec<(u32, u32, u32)>,
    /// Har bir blokning fayldagi boshlanish o'rni.
    chunk_offsets: Vec<u64>,
    /// Jami namunalar soni.
    sample_count: u32,
}

// ── Atomlarni kezish ───────────────────────────────────────────────

fn be_u32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes([
        *b.get(at)?,
        *b.get(at + 1)?,
        *b.get(at + 2)?,
        *b.get(at + 3)?,
    ]))
}

fn be_u64(b: &[u8], at: usize) -> Option<u64> {
    let hi = be_u32(b, at)? as u64;
    let lo = be_u32(b, at + 4)? as u64;
    Some((hi << 32) | lo)
}

/// Atom sarlavhasi: (tana boshlanadigan o'rin, tana uzunligi, tur).
///
/// `size == 1` bo'lsa haqiqiy uzunlik keyingi 8 baytda (katta
/// fayllarda `mdat` aynan shunday bo'ladi). `size == 0` — atom fayl
/// oxirigacha davom etadi.
pub fn box_header(buf: &[u8], at: usize) -> Option<(usize, u64, [u8; 4])> {
    let size32 = be_u32(buf, at)? as u64;
    let kind = [
        *buf.get(at + 4)?,
        *buf.get(at + 5)?,
        *buf.get(at + 6)?,
        *buf.get(at + 7)?,
    ];
    if size32 == 1 {
        let big = be_u64(buf, at + 8)?;
        if big < 16 {
            return None;
        }
        Some((at + 16, big - 16, kind))
    } else if size32 == 0 {
        // Fayl oxirigacha. Uzunlik chaqiruvchi tomonda hisoblanadi.
        Some((at + 8, u64::MAX, kind))
    } else {
        if size32 < 8 {
            return None;
        }
        Some((at + 8, size32 - 8, kind))
    }
}

/// Berilgan tanadan to'g'ridan-to'g'ri ichidagi atomni topadi
/// (rekursiv emas — har bir daraja alohida chaqiriladi).
fn child<'a>(body: &'a [u8], want: &[u8; 4]) -> Option<&'a [u8]> {
    let mut at = 0usize;
    while at + 8 <= body.len() {
        let (start, len, kind) = box_header(body, at)?;
        let len = if len == u64::MAX {
            (body.len() - start) as u64
        } else {
            len
        };
        let end = start.checked_add(len as usize)?;
        if end > body.len() {
            return None;
        }
        if &kind == want {
            return Some(&body[start..end]);
        }
        at = end;
    }
    None
}

/// Atomning O'ZINI (sarlavhasi bilan birga) qaytaradi.
fn child_with_header<'a>(body: &'a [u8], want: &[u8; 4]) -> Option<&'a [u8]> {
    let mut at = 0usize;
    while at + 8 <= body.len() {
        let (start, len, kind) = box_header(body, at)?;
        let len = if len == u64::MAX {
            (body.len() - start) as u64
        } else {
            len
        };
        let end = start.checked_add(len as usize)?;
        if end > body.len() {
            return None;
        }
        if &kind == want {
            return Some(&body[at..end]);
        }
        at = end;
    }
    None
}

/// `moov` tanasidagi barcha `trak` atomlarini beradi.
fn traks(moov: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 8 <= moov.len() {
        let Some((start, len, kind)) = box_header(moov, at) else {
            break;
        };
        let len = if len == u64::MAX {
            (moov.len() - start) as u64
        } else {
            len
        };
        let Some(end) = start.checked_add(len as usize) else {
            break;
        };
        if end > moov.len() {
            break;
        }
        if &kind == b"trak" {
            out.push(&moov[start..end]);
        }
        at = end;
    }
    out
}

// ── moov -> VideoTrack ─────────────────────────────────────────────

/// `moov` atomining TANASIDAN video yo'lakchani o'qiydi.
///
/// Hech narsa topilmasa yoki fayl kutilmagan ko'rinishda bo'lsa
/// (masalan bo'lakli/fragmented MP4 — unda `stbl` bo'sh bo'ladi)
/// `None` qaytaradi. Chaqiruvchi bunday holatda posterga qaytadi —
/// hech qachon yiqilmaydi.
pub fn parse_moov(moov: &[u8]) -> Option<VideoTrack> {
    for trak in traks(moov) {
        let mdia = match child(trak, b"mdia") {
            Some(v) => v,
            None => continue,
        };
        // Faqat VIDEO yo'lakcha kerak (audio/subtitr emas).
        let hdlr = match child(mdia, b"hdlr") {
            Some(v) => v,
            None => continue,
        };
        // hdlr: [4 version+flags][4 predefined][4 handler_type]
        if hdlr.len() < 12 || &hdlr[8..12] != b"vide" {
            continue;
        }

        let mdhd = child(mdia, b"mdhd")?;
        let version = *mdhd.first()?;
        let timescale = if version == 1 {
            be_u32(mdhd, 20)?
        } else {
            be_u32(mdhd, 12)?
        };
        if timescale == 0 {
            continue;
        }

        let (width, height) = tkhd_size(trak).unwrap_or((0, 0));

        let minf = child(mdia, b"minf")?;
        let stbl = child(minf, b"stbl")?;

        let stsd = child_with_header(stbl, b"stsd")?.to_vec();
        let stts = parse_stts(child(stbl, b"stts")?)?;
        let sizes = parse_stsz(child(stbl, b"stsz")?)?;
        let stsc = parse_stsc(child(stbl, b"stsc")?)?;
        let chunk_offsets = match child(stbl, b"stco") {
            Some(b) => parse_stco(b)?,
            None => parse_co64(child(stbl, b"co64")?)?,
        };
        let sync_samples = match child(stbl, b"stss") {
            Some(b) => parse_stss(b)?,
            None => Vec::new(),
        };

        let sample_count = match &sizes {
            SampleSizes::Table(t) => t.len() as u32,
            SampleSizes::Uniform(_) => stts.iter().map(|(c, _)| *c).sum(),
        };
        if sample_count == 0 || chunk_offsets.is_empty() || stsc.is_empty() {
            continue;
        }

        return Some(VideoTrack {
            timescale,
            width,
            height,
            stsd,
            sync_samples,
            stts,
            sizes,
            stsc,
            chunk_offsets,
            sample_count,
        });
    }
    None
}

fn tkhd_size(trak: &[u8]) -> Option<(u16, u16)> {
    let tkhd = child(trak, b"tkhd")?;
    let version = *tkhd.first()?;
    // 16.16 qat'iy vergulli kenglik/balandlik atomning OXIRIDA
    // turadi — versiyaga qarab o'rni siljiydi, shu sabab oxiridan
    // hisoblagan ishonchliroq.
    let _ = version;
    let n = tkhd.len();
    if n < 8 {
        return None;
    }
    let w = be_u32(tkhd, n - 8)? >> 16;
    let h = be_u32(tkhd, n - 4)? >> 16;
    Some((w as u16, h as u16))
}

fn parse_stts(b: &[u8]) -> Option<Vec<(u32, u32)>> {
    let count = be_u32(b, 4)? as usize;
    let mut out = Vec::with_capacity(count.min(4096));
    for i in 0..count {
        let at = 8 + i * 8;
        out.push((be_u32(b, at)?, be_u32(b, at + 4)?));
    }
    Some(out)
}

fn parse_stss(b: &[u8]) -> Option<Vec<u32>> {
    let count = be_u32(b, 4)? as usize;
    let mut out = Vec::with_capacity(count.min(65536));
    for i in 0..count {
        out.push(be_u32(b, 8 + i * 4)?);
    }
    Some(out)
}

fn parse_stsz(b: &[u8]) -> Option<SampleSizes> {
    let uniform = be_u32(b, 4)?;
    if uniform != 0 {
        return Some(SampleSizes::Uniform(uniform));
    }
    let count = be_u32(b, 8)? as usize;
    let mut out = Vec::with_capacity(count.min(1 << 20));
    for i in 0..count {
        out.push(be_u32(b, 12 + i * 4)?);
    }
    Some(SampleSizes::Table(out))
}

fn parse_stsc(b: &[u8]) -> Option<Vec<(u32, u32, u32)>> {
    let count = be_u32(b, 4)? as usize;
    let mut out = Vec::with_capacity(count.min(65536));
    for i in 0..count {
        let at = 8 + i * 12;
        out.push((be_u32(b, at)?, be_u32(b, at + 4)?, be_u32(b, at + 8)?));
    }
    Some(out)
}

fn parse_stco(b: &[u8]) -> Option<Vec<u64>> {
    let count = be_u32(b, 4)? as usize;
    let mut out = Vec::with_capacity(count.min(1 << 20));
    for i in 0..count {
        out.push(be_u32(b, 8 + i * 4)? as u64);
    }
    Some(out)
}

fn parse_co64(b: &[u8]) -> Option<Vec<u64>> {
    let count = be_u32(b, 4)? as usize;
    let mut out = Vec::with_capacity(count.min(1 << 20));
    for i in 0..count {
        out.push(be_u64(b, 8 + i * 8)?);
    }
    Some(out)
}

impl VideoTrack {
    /// Berilgan vaqtdagi (millisekund) namuna raqami — 1 dan
    /// boshlab.
    pub fn sample_at_ms(&self, ms: u64) -> u32 {
        let target = ms.saturating_mul(self.timescale as u64) / 1000;
        let mut elapsed: u64 = 0;
        let mut sample: u64 = 1;
        for (count, delta) in &self.stts {
            let span = (*count as u64) * (*delta as u64);
            if target < elapsed + span {
                let into = if *delta == 0 {
                    0
                } else {
                    (target - elapsed) / (*delta as u64)
                };
                return (sample + into).min(self.sample_count as u64) as u32;
            }
            elapsed += span;
            sample += *count as u64;
        }
        self.sample_count
    }

    /// Shu namunadan OLDINGI (yoki aynan o'zi) kalit kadr.
    ///
    /// Dekoder kadrni faqat kalit kadrdan boshlab ocha oladi, shu
    /// sabab thumbnail 1-5 soniya oldingi kadr bo'lishi mumkin —
    /// ko'zga bilinmaydi.
    pub fn sync_at_or_before(&self, sample: u32) -> u32 {
        if self.sync_samples.is_empty() {
            return sample.max(1);
        }
        let mut best = self.sync_samples[0];
        for s in &self.sync_samples {
            if *s <= sample {
                best = *s;
            } else {
                break;
            }
        }
        best.max(1)
    }

    fn size_of(&self, sample: u32) -> Option<u32> {
        match &self.sizes {
            SampleSizes::Uniform(v) => Some(*v),
            SampleSizes::Table(t) => t.get(sample.checked_sub(1)? as usize).copied(),
        }
    }

    /// Namunaning fayldagi o'rni va hajmi.
    ///
    /// `stsc` "qaysi blokda nechta namuna bor"ni siqilgan holda
    /// beradi: yozuv faqat OLDINGISIDAN FARQ QILGANDA qo'shiladi.
    /// Shu sabab bu yerda bloklar ketma-ket kezib chiqiladi.
    pub fn locate(&self, sample: u32) -> Option<SampleRef> {
        if sample == 0 || sample > self.sample_count {
            return None;
        }
        let chunk_count = self.chunk_offsets.len() as u32;
        let mut first_sample_of_chunk: u32 = 1;

        for (i, (first_chunk, per_chunk, _)) in self.stsc.iter().enumerate() {
            let next_first_chunk = self
                .stsc
                .get(i + 1)
                .map(|(fc, _, _)| *fc)
                .unwrap_or(chunk_count + 1);
            if *per_chunk == 0 {
                continue;
            }
            let runs = next_first_chunk.saturating_sub(*first_chunk);
            let samples_here = runs.saturating_mul(*per_chunk);

            if sample < first_sample_of_chunk + samples_here {
                let into = sample - first_sample_of_chunk;
                let chunk_index = first_chunk + into / per_chunk;
                let in_chunk = into % per_chunk;
                let base = *self.chunk_offsets.get((chunk_index - 1) as usize)?;
                // Shu blokdagi undan oldingi namunalar hajmi
                // qo'shib chiqiladi.
                let mut offset = base;
                let chunk_first_sample = sample - in_chunk;
                for s in chunk_first_sample..sample {
                    offset += self.size_of(s)? as u64;
                }
                return Some(SampleRef {
                    offset,
                    size: self.size_of(sample)?,
                });
            }
            first_sample_of_chunk += samples_here;
        }
        None
    }

    /// Namunaning davomiyligi (vaqt birligida).
    fn delta_of(&self, sample: u32) -> u32 {
        let mut seen: u64 = 0;
        for (count, delta) in &self.stts {
            seen += *count as u64;
            if (sample as u64) <= seen {
                return *delta;
            }
        }
        self.stts.last().map(|(_, d)| *d).unwrap_or(1)
    }
}

// ── Bitta kadrlik MP4 yasash ───────────────────────────────────────

fn push_box(out: &mut Vec<u8>, kind: &[u8; 4], body: &[u8]) {
    out.extend_from_slice(&((body.len() as u32 + 8).to_be_bytes()));
    out.extend_from_slice(kind);
    out.extend_from_slice(body);
}

/// Bitta kadrdan to'la haqiqiy MP4 yasaydi.
///
/// `build_clip_mp4` ning bitta namunali holati (sifat almashtirish
/// yoki kalit kadrga qaytish uchun zaxira yo'l).
pub fn build_single_frame_mp4(track: &VideoTrack, sample: u32, data: &[u8]) -> Option<Vec<u8>> {
    build_clip_mp4(track, sample, &[data.len() as u32], data)
}

/// Ketma-ket namunalardan to'la haqiqiy MP4 yasaydi.
///
/// Faqat VIDEO yo'lakcha bo'ladi (ovoz kerak emas). Kodek
/// sozlamalari asl fayldan `stsd` atomi sifatida AYNAN ko'chiriladi
/// — busiz hech qanday dekoder kadrni ocholmaydi.
///
/// ── NEGA BITTA KADR EMAS ──────────────────────────────────────
///
/// Dekoder kadrni faqat KALIT KADRDAN boshlab ocha oladi, ya'ni
/// bitta kadrlik MP4 har doim so'ralgan vaqtdan 1-5 soniya oldingi
/// rasmni berardi. Bu yerda esa kalit kadrdan SO'RALGAN kadrgacha
/// bo'lgan hamma namuna solinadi va oxirgisi aynan kerakli kadr
/// bo'ladi — Android undan millisekundgacha to'g'ri rasm chiqaradi.
///
/// MUHIM: dekodlash tartibida har bir namunaning tayanch kadrlari
/// undan OLDIN turadi (MP4 qoidasi), shu sabab ro'yxatni istalgan
/// joyda kesish xavfsiz — kesilgan bo'lakdagi hech bir kadr
/// yetishmayotgan tayanchga murojaat qilmaydi.
///
/// `ctts` (ko'rsatish tartibi) ATAYLAB ko'chirilmaydi: usiz
/// ko'rsatish vaqti namuna tartibi bilan bir xil bo'ladi va
/// "eng oxirgi kadr" AYNAN so'ralgan namuna bo'lib qoladi.
pub fn build_clip_mp4(
    track: &VideoTrack,
    first_sample: u32,
    sizes: &[u32],
    data: &[u8],
) -> Option<Vec<u8>> {
    if sizes.is_empty() || first_sample == 0 {
        return None;
    }
    let count = sizes.len() as u32;
    let total: u64 = sizes.iter().map(|v| *v as u64).sum();
    if total != data.len() as u64 || total == 0 {
        return None;
    }

    // ── Namunalar davomiyligi (siqilgan ro'yxat) ─────────────
    let mut runs: Vec<(u32, u32)> = Vec::new();
    let mut media_ticks: u64 = 0;
    for i in 0..count {
        let d = track.delta_of(first_sample + i).max(1);
        media_ticks += d as u64;
        match runs.last_mut() {
            Some((c, last_d)) if *last_d == d => *c += 1,
            _ => runs.push((1, d)),
        }
    }
    let media_ticks = media_ticks.min(u32::MAX as u64) as u32;
    // Ilova tomoni "oxirgi kadr"ni aynan shu davomiylik bo'yicha
    // so'raydi, shu sabab u nol bo'lib qolmasligi shart.
    let movie_ms = ((media_ticks as u64) * 1000 / (track.timescale.max(1) as u64)).max(1);
    let movie_ms = movie_ms.min(u32::MAX as u64) as u32;

    // ── ftyp ──────────────────────────────────────────────────
    let mut ftyp = Vec::new();
    ftyp.extend_from_slice(b"isom");
    ftyp.extend_from_slice(&512u32.to_be_bytes());
    for brand in [b"isom", b"iso2", b"avc1", b"mp41", b"hvc1"] {
        ftyp.extend_from_slice(brand);
    }
    let mut head = Vec::new();
    push_box(&mut head, b"ftyp", &ftyp);

    // ── stbl ──────────────────────────────────────────────────
    let mut stbl = Vec::new();
    stbl.extend_from_slice(&track.stsd);

    let mut stts = Vec::new();
    stts.extend_from_slice(&0u32.to_be_bytes()); // version+flags
    stts.extend_from_slice(&(runs.len() as u32).to_be_bytes());
    for (c, d) in &runs {
        stts.extend_from_slice(&c.to_be_bytes());
        stts.extend_from_slice(&d.to_be_bytes());
    }
    push_box(&mut stbl, b"stts", &stts);

    // Birinchi namuna — kalit kadr (bo'lak aynan undan boshlanadi).
    let mut stss = Vec::new();
    stss.extend_from_slice(&0u32.to_be_bytes());
    stss.extend_from_slice(&1u32.to_be_bytes());
    stss.extend_from_slice(&1u32.to_be_bytes());
    push_box(&mut stbl, b"stss", &stss);

    // Hamma namuna BITTA blokda ketma-ket turadi.
    let mut stsc = Vec::new();
    stsc.extend_from_slice(&0u32.to_be_bytes());
    stsc.extend_from_slice(&1u32.to_be_bytes());
    stsc.extend_from_slice(&1u32.to_be_bytes()); // birinchi blok
    stsc.extend_from_slice(&count.to_be_bytes()); // blokdagi namunalar
    stsc.extend_from_slice(&1u32.to_be_bytes()); // tavsif indeksi
    push_box(&mut stbl, b"stsc", &stsc);

    let mut stsz = Vec::new();
    stsz.extend_from_slice(&0u32.to_be_bytes());
    stsz.extend_from_slice(&0u32.to_be_bytes()); // har xil hajm
    stsz.extend_from_slice(&count.to_be_bytes());
    for s in sizes {
        stsz.extend_from_slice(&s.to_be_bytes());
    }
    push_box(&mut stbl, b"stsz", &stsz);

    // `stco` ichidagi manzil hali noma'lum (u butun sarlavha
    // uzunligiga bog'liq) — avval nol yoziladi, oxirida
    // to'g'rilanadi.
    let mut stco = Vec::new();
    stco.extend_from_slice(&0u32.to_be_bytes());
    stco.extend_from_slice(&1u32.to_be_bytes());
    stco.extend_from_slice(&0u32.to_be_bytes());
    let stco_value_in_stbl = stbl.len() + 8 + 8;
    push_box(&mut stbl, b"stco", &stco);

    // ── minf ──────────────────────────────────────────────────
    let mut minf = Vec::new();
    let mut vmhd = Vec::new();
    vmhd.extend_from_slice(&1u32.to_be_bytes()); // version 0, flags 1
    vmhd.extend_from_slice(&[0u8; 8]);
    push_box(&mut minf, b"vmhd", &vmhd);

    let mut dref = Vec::new();
    dref.extend_from_slice(&0u32.to_be_bytes());
    dref.extend_from_slice(&1u32.to_be_bytes());
    push_box(&mut dref, b"url ", &1u32.to_be_bytes()); // o'z ichida
    let mut dinf = Vec::new();
    push_box(&mut dinf, b"dref", &dref);
    push_box(&mut minf, b"dinf", &dinf);

    let stbl_offset_in_minf = minf.len() + 8;
    push_box(&mut minf, b"stbl", &stbl);

    // ── mdia ──────────────────────────────────────────────────
    let mut mdia = Vec::new();
    let mut mdhd = Vec::new();
    mdhd.extend_from_slice(&0u32.to_be_bytes()); // version 0
    mdhd.extend_from_slice(&0u32.to_be_bytes()); // yaratilgan
    mdhd.extend_from_slice(&0u32.to_be_bytes()); // o'zgartirilgan
    mdhd.extend_from_slice(&track.timescale.to_be_bytes());
    mdhd.extend_from_slice(&media_ticks.to_be_bytes());
    mdhd.extend_from_slice(&0x55c4u16.to_be_bytes()); // til: und
    mdhd.extend_from_slice(&0u16.to_be_bytes());
    push_box(&mut mdia, b"mdhd", &mdhd);

    let mut hdlr = Vec::new();
    hdlr.extend_from_slice(&0u32.to_be_bytes());
    hdlr.extend_from_slice(&0u32.to_be_bytes());
    hdlr.extend_from_slice(b"vide");
    hdlr.extend_from_slice(&[0u8; 12]);
    hdlr.extend_from_slice(b"ARUmedia\0");
    push_box(&mut mdia, b"hdlr", &hdlr);

    let minf_offset_in_mdia = mdia.len() + 8;
    push_box(&mut mdia, b"minf", &minf);

    // ── trak ──────────────────────────────────────────────────
    let mut tkhd = Vec::new();
    tkhd.extend_from_slice(&7u32.to_be_bytes()); // version 0, flags 7
    tkhd.extend_from_slice(&0u32.to_be_bytes());
    tkhd.extend_from_slice(&0u32.to_be_bytes());
    tkhd.extend_from_slice(&1u32.to_be_bytes()); // track_id
    tkhd.extend_from_slice(&0u32.to_be_bytes());
    tkhd.extend_from_slice(&movie_ms.to_be_bytes()); // davomiylik
    tkhd.extend_from_slice(&[0u8; 8]);
    tkhd.extend_from_slice(&0u16.to_be_bytes()); // qatlam
    tkhd.extend_from_slice(&0u16.to_be_bytes());
    tkhd.extend_from_slice(&0u16.to_be_bytes()); // ovoz balandligi
    tkhd.extend_from_slice(&0u16.to_be_bytes());
    for v in [
        0x0001_0000u32, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000,
    ] {
        tkhd.extend_from_slice(&v.to_be_bytes());
    }
    tkhd.extend_from_slice(&((track.width as u32) << 16).to_be_bytes());
    tkhd.extend_from_slice(&((track.height as u32) << 16).to_be_bytes());

    let mut trak = Vec::new();
    push_box(&mut trak, b"tkhd", &tkhd);
    let mdia_offset_in_trak = trak.len() + 8;
    push_box(&mut trak, b"mdia", &mdia);

    // ── moov ──────────────────────────────────────────────────
    let mut mvhd = Vec::new();
    mvhd.extend_from_slice(&0u32.to_be_bytes());
    mvhd.extend_from_slice(&0u32.to_be_bytes());
    mvhd.extend_from_slice(&0u32.to_be_bytes());
    mvhd.extend_from_slice(&1000u32.to_be_bytes()); // vaqt birligi
    mvhd.extend_from_slice(&movie_ms.to_be_bytes()); // davomiylik
    mvhd.extend_from_slice(&0x0001_0000u32.to_be_bytes()); // tezlik
    mvhd.extend_from_slice(&0x0100u16.to_be_bytes()); // ovoz
    mvhd.extend_from_slice(&0u16.to_be_bytes());
    mvhd.extend_from_slice(&[0u8; 8]);
    for v in [
        0x0001_0000u32, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000,
    ] {
        mvhd.extend_from_slice(&v.to_be_bytes());
    }
    mvhd.extend_from_slice(&[0u8; 24]); // oldindan belgilangan
    mvhd.extend_from_slice(&2u32.to_be_bytes()); // keyingi track_id

    let mut moov = Vec::new();
    push_box(&mut moov, b"mvhd", &mvhd);
    let trak_offset_in_moov = moov.len() + 8;
    push_box(&mut moov, b"trak", &trak);

    push_box(&mut head, b"moov", &moov);

    // `stco` dagi manzilni to'g'rilaymiz: u `mdat` TANASIning
    // boshlanish o'rni.
    let mdat_body = head.len() + 8;
    let stco_pos = 8 // ftyp sarlavhasi
        + ftyp.len()
        + 8 // moov sarlavhasi
        + trak_offset_in_moov
        + mdia_offset_in_trak
        + minf_offset_in_mdia
        + stbl_offset_in_minf
        + stco_value_in_stbl;
    if stco_pos + 4 > head.len() {
        return None;
    }
    head[stco_pos..stco_pos + 4].copy_from_slice(&(mdat_body as u32).to_be_bytes());

    let mut out = head;
    out.extend_from_slice(&((data.len() as u32 + 8).to_be_bytes()));
    out.extend_from_slice(b"mdat");
    out.extend_from_slice(data);
    Some(out)
}

// ═══════════════════════════════════════════════════════════════════
//  TESTLAR
// ═══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn boxed(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        push_box(&mut v, kind, body);
        v
    }

    /// Sinov uchun eng kichik, lekin HAQIQIY tuzilishdagi `moov`.
    ///
    /// Ikkita blok, har birida 2 tadan namuna; namunalar hajmi
    /// 10, 20, 30, 40; bloklar 1000 va 2000-baytdan boshlanadi.
    /// Kalit kadrlar — 1 va 3.
    fn test_moov() -> Vec<u8> {
        let mut stbl = Vec::new();

        // stsd — ichida soxta "avc1" yozuvi (ko'chirilishini
        // tekshirish uchun yetarli).
        let mut stsd = Vec::new();
        stsd.extend_from_slice(&0u32.to_be_bytes());
        stsd.extend_from_slice(&1u32.to_be_bytes());
        stsd.extend_from_slice(&boxed(b"avc1", &[7u8; 12]));
        stbl.extend_from_slice(&boxed(b"stsd", &stsd));

        // stts: 4 ta namuna, har biri 512 birlik.
        let mut stts = Vec::new();
        stts.extend_from_slice(&0u32.to_be_bytes());
        stts.extend_from_slice(&1u32.to_be_bytes());
        stts.extend_from_slice(&4u32.to_be_bytes());
        stts.extend_from_slice(&512u32.to_be_bytes());
        stbl.extend_from_slice(&boxed(b"stts", &stts));

        // stss: 1 va 3 — kalit kadrlar.
        let mut stss = Vec::new();
        stss.extend_from_slice(&0u32.to_be_bytes());
        stss.extend_from_slice(&2u32.to_be_bytes());
        stss.extend_from_slice(&1u32.to_be_bytes());
        stss.extend_from_slice(&3u32.to_be_bytes());
        stbl.extend_from_slice(&boxed(b"stss", &stss));

        // stsc: 1-blokdan boshlab har blokda 2 ta namuna.
        let mut stsc = Vec::new();
        stsc.extend_from_slice(&0u32.to_be_bytes());
        stsc.extend_from_slice(&1u32.to_be_bytes());
        stsc.extend_from_slice(&1u32.to_be_bytes());
        stsc.extend_from_slice(&2u32.to_be_bytes());
        stsc.extend_from_slice(&1u32.to_be_bytes());
        stbl.extend_from_slice(&boxed(b"stsc", &stsc));

        // stsz: 10, 20, 30, 40.
        let mut stsz = Vec::new();
        stsz.extend_from_slice(&0u32.to_be_bytes());
        stsz.extend_from_slice(&0u32.to_be_bytes());
        stsz.extend_from_slice(&4u32.to_be_bytes());
        for v in [10u32, 20, 30, 40] {
            stsz.extend_from_slice(&v.to_be_bytes());
        }
        stbl.extend_from_slice(&boxed(b"stsz", &stsz));

        // stco: 1000 va 2000.
        let mut stco = Vec::new();
        stco.extend_from_slice(&0u32.to_be_bytes());
        stco.extend_from_slice(&2u32.to_be_bytes());
        stco.extend_from_slice(&1000u32.to_be_bytes());
        stco.extend_from_slice(&2000u32.to_be_bytes());
        stbl.extend_from_slice(&boxed(b"stco", &stco));

        let minf = {
            let mut m = Vec::new();
            m.extend_from_slice(&boxed(b"vmhd", &[0u8; 12]));
            m.extend_from_slice(&boxed(b"stbl", &stbl));
            m
        };

        let mdia = {
            let mut d = Vec::new();
            let mut hdlr = Vec::new();
            hdlr.extend_from_slice(&0u32.to_be_bytes());
            hdlr.extend_from_slice(&0u32.to_be_bytes());
            hdlr.extend_from_slice(b"vide");
            d.extend_from_slice(&boxed(b"hdlr", &hdlr));
            let mut mdhd = Vec::new();
            mdhd.extend_from_slice(&0u32.to_be_bytes());
            mdhd.extend_from_slice(&0u32.to_be_bytes());
            mdhd.extend_from_slice(&0u32.to_be_bytes());
            mdhd.extend_from_slice(&1024u32.to_be_bytes()); // vaqt birligi
            mdhd.extend_from_slice(&2048u32.to_be_bytes());
            mdhd.extend_from_slice(&0u32.to_be_bytes());
            d.extend_from_slice(&boxed(b"mdhd", &mdhd));
            d.extend_from_slice(&boxed(b"minf", &minf));
            d
        };

        let trak = {
            let mut t = Vec::new();
            let mut tkhd = vec![0u8; 84];
            // Oxirgi 8 bayt — kenglik va balandlik (16.16).
            tkhd[76..80].copy_from_slice(&(1280u32 << 16).to_be_bytes());
            tkhd[80..84].copy_from_slice(&(720u32 << 16).to_be_bytes());
            t.extend_from_slice(&boxed(b"tkhd", &tkhd));
            t.extend_from_slice(&boxed(b"mdia", &mdia));
            t
        };

        // Ovozli yo'lakcha ham qo'shamiz — u E'TIBORSIZ
        // qoldirilishi kerak.
        let audio_trak = {
            let mut t = Vec::new();
            let mut hdlr = Vec::new();
            hdlr.extend_from_slice(&0u32.to_be_bytes());
            hdlr.extend_from_slice(&0u32.to_be_bytes());
            hdlr.extend_from_slice(b"soun");
            let mdia = boxed(b"hdlr", &hdlr);
            t.extend_from_slice(&boxed(b"mdia", &mdia));
            t
        };

        let mut moov = Vec::new();
        moov.extend_from_slice(&boxed(b"trak", &audio_trak));
        moov.extend_from_slice(&boxed(b"trak", &trak));
        moov
    }

    #[test]
    fn moov_video_yolakchani_topadi() {
        let t = parse_moov(&test_moov()).expect("video yo'lakcha topilmadi");
        assert_eq!(t.timescale, 1024);
        assert_eq!(t.width, 1280);
        assert_eq!(t.height, 720);
        assert_eq!(t.sample_count, 4);
        assert_eq!(t.sync_samples, vec![1, 3]);
    }

    #[test]
    fn vaqtdan_namuna_va_kalit_kadr_topiladi() {
        let t = parse_moov(&test_moov()).unwrap();
        // Har bir namuna 512/1024 = 0.5 soniya.
        assert_eq!(t.sample_at_ms(0), 1);
        assert_eq!(t.sample_at_ms(600), 2);
        assert_eq!(t.sample_at_ms(1100), 3);
        assert_eq!(t.sample_at_ms(1700), 4);
        // 2-namunadan oldingi kalit kadr — 1-si.
        assert_eq!(t.sync_at_or_before(2), 1);
        assert_eq!(t.sync_at_or_before(3), 3);
        assert_eq!(t.sync_at_or_before(4), 3);
    }

    /// Namunaning fayldagi o'rni: blok boshi + undan oldingi
    /// namunalar hajmi.
    #[test]
    fn namuna_orni_togri_hisoblanadi() {
        let t = parse_moov(&test_moov()).unwrap();
        assert_eq!(t.locate(1), Some(SampleRef { offset: 1000, size: 10 }));
        assert_eq!(t.locate(2), Some(SampleRef { offset: 1010, size: 20 }));
        assert_eq!(t.locate(3), Some(SampleRef { offset: 2000, size: 30 }));
        assert_eq!(t.locate(4), Some(SampleRef { offset: 2030, size: 40 }));
        assert_eq!(t.locate(5), None);
        assert_eq!(t.locate(0), None);
    }

    /// Yasalgan mini-MP4 haqiqiy tuzilishga ega bo'lishi va
    /// `stco` aynan `mdat` tanasiga ko'rsatishi SHART — aks holda
    /// dekoder kadrni topa olmaydi va thumbnail chiqmaydi.
    #[test]
    fn bitta_kadrlik_mp4_togri_yigiladi() {
        let t = parse_moov(&test_moov()).unwrap();
        let frame = vec![0xABu8; 30];
        let out = build_single_frame_mp4(&t, 3, &frame).expect("yig'ilmadi");

        // Birinchi atom — ftyp.
        let (ftyp_start, ftyp_len, kind) = box_header(&out, 0).unwrap();
        assert_eq!(&kind, b"ftyp");
        let after_ftyp = ftyp_start + ftyp_len as usize;

        // Ikkinchisi — moov.
        let (moov_start, moov_len, kind) = box_header(&out, after_ftyp).unwrap();
        assert_eq!(&kind, b"moov");
        let moov = &out[moov_start..moov_start + moov_len as usize];

        // Uchinchisi — mdat, va uning tanasi aynan bizning kadr.
        let mdat_at = moov_start + moov_len as usize;
        let (mdat_start, mdat_len, kind) = box_header(&out, mdat_at).unwrap();
        assert_eq!(&kind, b"mdat");
        assert_eq!(mdat_len as usize, frame.len());
        assert_eq!(&out[mdat_start..mdat_start + frame.len()], &frame[..]);

        // `stco` ichidagi manzil `mdat` tanasini ko'rsatsin.
        let trak = child(moov, b"trak").unwrap();
        let mdia = child(trak, b"mdia").unwrap();
        let minf = child(mdia, b"minf").unwrap();
        let stbl = child(minf, b"stbl").unwrap();
        let stco = child(stbl, b"stco").unwrap();
        assert_eq!(be_u32(stco, 8).unwrap() as usize, mdat_start);

        // Kodek sozlamalari ko'chirilgan bo'lsin.
        let stsd = child(stbl, b"stsd").unwrap();
        assert!(child(&stsd[8..], b"avc1").is_some(), "stsd ko'chirilmagan");

        // Bitta namuna va u kalit kadr.
        let stsz = child(stbl, b"stsz").unwrap();
        assert_eq!(be_u32(stsz, 8).unwrap(), 1);
        assert_eq!(be_u32(stsz, 12).unwrap(), frame.len() as u32);
        let stss = child(stbl, b"stss").unwrap();
        assert_eq!(be_u32(stss, 4).unwrap(), 1);
        assert_eq!(be_u32(stss, 8).unwrap(), 1);
    }

    /// Buzilgan yoki bo'lakli (fragmented) MP4 — yiqilmasdan
    /// `None` qaytarilsin.
    /// KALIT KADRDAN SO'RALGAN KADRGACHA bo'lgan bo'lak: oxirgi
    /// namuna AYNAN so'ralgan kadr bo'lishi va jadvallar unga mos
    /// kelishi kerak — tarix kadrining aniqligi shunga bog'liq.
    #[test]
    fn kadrgacha_bolgan_bolak_togri_yigiladi() {
        let t = parse_moov(&test_moov()).unwrap();
        // 3-namuna (kalit kadr) va 4-namuna: 30 + 40 bayt.
        let mut data = vec![0x11u8; 30];
        data.extend_from_slice(&[0x22u8; 40]);
        let out = build_clip_mp4(&t, 3, &[30, 40], &data).expect("yig'ilmadi");

        let (ftyp_start, ftyp_len, _) = box_header(&out, 0).unwrap();
        let (moov_start, moov_len, kind) = box_header(&out, ftyp_start + ftyp_len as usize).unwrap();
        assert_eq!(&kind, b"moov");
        let moov = &out[moov_start..moov_start + moov_len as usize];

        let mdat_at = moov_start + moov_len as usize;
        let (mdat_start, mdat_len, kind) = box_header(&out, mdat_at).unwrap();
        assert_eq!(&kind, b"mdat");
        assert_eq!(mdat_len as usize, data.len());
        assert_eq!(&out[mdat_start..mdat_start + data.len()], &data[..]);

        let trak = child(moov, b"trak").unwrap();
        let mdia = child(trak, b"mdia").unwrap();
        let minf = child(mdia, b"minf").unwrap();
        let stbl = child(minf, b"stbl").unwrap();

        // Ikkita namuna, hajmlari o'z tartibida.
        let stsz = child(stbl, b"stsz").unwrap();
        assert_eq!(be_u32(stsz, 8).unwrap(), 2);
        assert_eq!(be_u32(stsz, 12).unwrap(), 30);
        assert_eq!(be_u32(stsz, 16).unwrap(), 40);

        // Hammasi BITTA blokda, blok esa `mdat` tanasidan boshlanadi.
        let stsc = child(stbl, b"stsc").unwrap();
        assert_eq!(be_u32(stsc, 4).unwrap(), 1);
        assert_eq!(be_u32(stsc, 12).unwrap(), 2, "blokda 2 namuna bo'lishi kerak");
        let stco = child(stbl, b"stco").unwrap();
        assert_eq!(be_u32(stco, 4).unwrap(), 1);
        assert_eq!(be_u32(stco, 8).unwrap() as usize, mdat_start);

        // Faqat BIRINCHI namuna kalit kadr deb belgilanadi.
        let stss = child(stbl, b"stss").unwrap();
        assert_eq!(be_u32(stss, 4).unwrap(), 1);
        assert_eq!(be_u32(stss, 8).unwrap(), 1);

        // Davomiylik: 2 x 512 birlik, vaqt birligi 1024 -> 1000 ms.
        // Ilova tomoni aynan shu davomiylik bo'yicha OXIRGI kadrni
        // so'raydi, shu sabab u to'g'ri bo'lishi shart.
        let stts = child(stbl, b"stts").unwrap();
        assert_eq!(be_u32(stts, 4).unwrap(), 1, "bitta siqilgan yozuv");
        assert_eq!(be_u32(stts, 8).unwrap(), 2);
        assert_eq!(be_u32(stts, 12).unwrap(), 512);
        let mdhd = child(mdia, b"mdhd").unwrap();
        assert_eq!(be_u32(mdhd, 16).unwrap(), 1024, "mdhd davomiyligi");
        let mvhd = child(moov, b"mvhd").unwrap();
        assert_eq!(be_u32(mvhd, 16).unwrap(), 1000, "mvhd davomiyligi (ms)");
    }

    /// Hajmlar yig'indisi baytlarga to'g'ri kelmasa — hech qanday
    /// MP4 yasalmaydi (buzuq fayl berishdan ko'ra posterni
    /// ko'rsatgan yaxshi).
    #[test]
    fn nomos_hajmlar_bolak_yasatmaydi() {
        let t = parse_moov(&test_moov()).unwrap();
        assert!(build_clip_mp4(&t, 1, &[10, 20], &vec![0u8; 25]).is_none());
        assert!(build_clip_mp4(&t, 1, &[], &[]).is_none());
    }

    #[test]
    fn notogri_moov_yiqitmaydi() {
        assert!(parse_moov(&[]).is_none());
        assert!(parse_moov(&[0, 0, 0, 4]).is_none());
        assert!(parse_moov(&boxed(b"trak", &[1, 2, 3])).is_none());
        let mut junk = vec![0u8; 64];
        junk[0] = 0xFF;
        assert!(parse_moov(&junk).is_none());
    }
}
