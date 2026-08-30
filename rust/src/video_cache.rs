// rust/src/video_cache.rs — Video uchun mahalliy (127.0.0.1) HTTP kesh-proksi,
// TO'LIQ Rust'da (native OS ish oqimida, Dart isolate'lariga bog'liq emas).
//
// Bu modul avval lib/services/video_cache_server.dart'da yozilgan bo'lib,
// qurilmada muzlab qolish (Dart asosiy isolate band bo'lganda serverning
// javob berolmay qolishi) muammosiga duch kelgan edi. Rust versiyasi
// butunlay MUSTAQIL, native OS ish oqimida (std::thread) ishlaydi — Flutter/
// Dart VM/engine holatidan qat'i nazar har doim so'rovlarga javob bera
// oladi.
//
// Arxitektura (Dart versiyasi bilan bir xil mantiq, Rust'da):
//   - video_cache_start(cache_dir) — bitta marta chaqiriladi (Dart'dan,
//     dart:ffi orqali). Loopback TCP portini ochadi, so'rovlarni qabul
//     qiladigan ALOHIDA native ish oqimini ishga tushiradi va portni
//     DARHOL qaytaradi (bind operatsiyasi tezkor, servisning o'zi fon'da
//     davom etadi).
//   - Har bir video FIKSIRLANGAN 1 MiB "chunk" fayllarga bo'lib
//     path_provider orqali berilgan (ilova-shaxsiy) papkada saqlanadi —
//     kelajakdagi bo'lak-asosidagi AES shifrlash rejasi bilan mos.
//   - Har bir video uchun "avlod" hisoblagichi: video uchun YANGI so'rov
//     kelsa, ESKI so'rovning javob tanasi va undan tug'ilgan oldindan-
//     yuklash ishlari o'z-o'zini to'xtatadi (orqa fonda cheksiz
//     to'planib, xotira/tarmoqni band qilib qolmasligi uchun).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::ffi_utils::{cstr_to_str, string_to_cptr};

const CHUNK_SIZE: u64 = 1024 * 1024;

/// Bir vaqtda ochiq bo'lishi mumkin bo'lgan eng ko'p ulanish soni.
/// Har bir ulanish bitta OS ish oqimi + ~1 MiB bufer degani, shu sabab
/// bu chegara xotira sarfini bashorat qilinadigan darajada ushlab
/// turadi (tez-tez sek qilishda ilova o'chib qolishining oldini oladi).
const MAX_CONNS: usize = 6;

// ── Umumiy holat ─────────────────────────────────────────────────────

struct Shared {
    cache_root: PathBuf,
    start: Instant,
    generation: Mutex<HashMap<String, u64>>,
    // Hozir tarmoqdan yuklanayotgan "key#index" bo'laklari — parallel
    // so'rovlar bir xil bo'lakni ikki marta yuklab olmasligi uchun.
    in_flight: Mutex<HashSet<String>>,
    logs: Mutex<Vec<String>>,
    agent: ureq::Agent,
    // Hozir ko'rilayotgan video kaliti — fon to'ldiruvchisi (filler)
    // faqat shu video uchun ishlaydi va boshqa video ochilganda
    // o'z-o'zini to'xtatadi.
    active_video: Mutex<Option<String>>,
}

static SHARED: OnceLock<Shared> = OnceLock::new();
static PORT: OnceLock<u16> = OnceLock::new();
static REQ_COUNTER: AtomicU64 = AtomicU64::new(0);
static ACTIVE_CONNS: AtomicUsize = AtomicUsize::new(0);

fn log(msg: impl Into<String>) {
    if let Some(s) = SHARED.get() {
        let elapsed = s.start.elapsed().as_millis();
        let line = format!("[{elapsed}ms] {}", msg.into());
        let mut logs = s.logs.lock().unwrap();
        logs.push(line);
        let len = logs.len();
        if len > 300 {
            logs.drain(0..(len - 300));
        }
    }
}

// ── FFI: ishga tushirish ────────────────────────────────────────────

/// Kesh-serverni ishga tushiradi (agar allaqachon ishga tushmagan bo'lsa)
/// va bog'langan portni qaytaradi. Xato bo'lsa -1.
/// `cache_dir_ptr` — path_provider'ning Application Support papkasi
/// (Dart tomonidan beriladi, chunki Rust Flutter plaginlariga
/// to'g'ridan-to'g'ri murojaat qila olmaydi).
#[no_mangle]
pub extern "C" fn rust_video_cache_start(cache_dir_ptr: *const c_char) -> i32 {
    if let Some(port) = PORT.get() {
        return *port as i32;
    }
    let cache_dir = match unsafe { cstr_to_str(cache_dir_ptr) } {
        Some(s) => s.to_string(),
        None => return -1,
    };
    let cache_root = PathBuf::from(cache_dir).join("video_byte_cache");
    if let Err(e) = fs::create_dir_all(&cache_root) {
        eprintln!("video_cache: kesh papkasini yaratib bo'lmadi: {e}");
        return -1;
    }

    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(15))
        .timeout_write(Duration::from_secs(10))
        .build();

    let shared = Shared {
        cache_root,
        start: Instant::now(),
        generation: Mutex::new(HashMap::new()),
        in_flight: Mutex::new(HashSet::new()),
        logs: Mutex::new(Vec::new()),
        agent,
        active_video: Mutex::new(None),
    };
    let _ = SHARED.set(shared);
    log("Rust kesh-server ishga tushirilmoqda...".to_string());

    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(l) => l,
        Err(e) => {
            log(format!("XATO: bind bo'lmadi — {e}"));
            return -1;
        }
    };
    let port = match listener.local_addr() {
        Ok(addr) => addr.port(),
        Err(_) => return -1,
    };
    let _ = PORT.set(port);
    log(format!("Rust kesh-server ishga tushdi: 127.0.0.1:{port}"));

    thread::Builder::new()
        .name("video-cache-accept".into())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        // MUHIM (qurilmada aniqlangan crash sababi): pleyer
                        // tez-tez sek qilinganda mdk-sdk eski ulanishni
                        // tashlab, yangisini ochadi. Har bir ulanish uchun
                        // cheklovsiz OS ish oqimi ochilsa, ular (har biri
                        // 1 MiB'lik bo'lak buferi bilan) to'planib, Android
                        // ilovani xotira yetishmovchiligi sabab o'ldirardi.
                        // Shu sabab bir vaqtda ochiq ulanishlar soni QAT'IY
                        // cheklanadi — chegaradan oshgani darhol rad
                        // etiladi (pleyer bunday holatda qayta ulanadi).
                        let active = ACTIVE_CONNS.fetch_add(1, Ordering::SeqCst);
                        if active >= MAX_CONNS {
                            ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                            log(format!(
                                "Ulanish rad etildi — chegara ({MAX_CONNS}) to'ldi"
                            ));
                            drop(stream);
                            continue;
                        }
                        let spawned = thread::Builder::new()
                            .name("video-cache-conn".into())
                            .spawn(move || {
                                if let Err(e) = handle_connection(stream) {
                                    log(format!("XATO (ulanish): {e}"));
                                }
                                ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                            });
                        if spawned.is_err() {
                            ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                            log("XATO: ulanish uchun ish oqimi ochilmadi".to_string());
                        }
                    }
                    Err(e) => {
                        log(format!("XATO: ulanish qabul qilinmadi — {e}"));
                    }
                }
            }
        })
        .ok();

    port as i32
}

/// So'nggi jurnal qatorlarini JSON massiv sifatida qaytaradi (va ularni
/// ichki bufferdan tozalaydi — har chaqiruv faqat YANGI qatorlarni
/// qaytaradi). Dart tomoni buni davriy ravishda (masalan har 400ms)
/// so'rab, ekrandagi diagnostika panelini yangilaydi.
#[no_mangle]
pub extern "C" fn rust_video_cache_pull_logs() -> *mut c_char {
    let Some(s) = SHARED.get() else {
        return string_to_cptr("[]".to_string());
    };
    let mut logs = s.logs.lock().unwrap();
    let json = serde_json::to_string(&*logs).unwrap_or_else(|_| "[]".to_string());
    logs.clear();
    string_to_cptr(json)
}

// ── HTTP so'rovni qabul qilish (minimal, qo'lda tahlil qilingan) ────
//
// tiny_http o'rniga bu yerda ATAYLAB eng minimal, qo'lda yozilgan
// HTTP/1.1 so'rov-satr+sarlavha tahlilchisi ishlatiladi — bizga faqat
// "GET /v?u=<url> HTTP/1.1" va "Range: bytes=..." sarlavhasi kerak,
// video_player/mdk-sdk esa bu mahalliy serverdan faqat oddiy GET
// so'rovlar yuboradi (health-check yoki murakkab metodlar yo'q).

struct ParsedRequest {
    path_and_query: String,
    range_header: Option<String>,
}

fn read_request_line_and_headers(stream: &mut TcpStream) -> std::io::Result<ParsedRequest> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    // MUHIM (crash sababi): agar klient (mdk-sdk) sek qilib javobni
    // o'qishni to'xtatsa, TCP oqimi to'lib, write_all() ABADIY bloklanib
    // qolardi — ish oqimi hech qachon tugamay, o'zining 1 MiB buferi
    // bilan xotirada qolib ketardi. Tez-tez sek qilinganda bunday
    // "o'lik" ish oqimlari to'planib, ilova o'chib qolardi. Yozish
    // timeout'i bunday oqimni majburan xatoga uchratib, tozalanishini
    // kafolatlaydi.
    stream.set_write_timeout(Some(Duration::from_secs(20)))?;
    let mut buf = Vec::with_capacity(4096);
    let mut byte = [0u8; 1];
    // Sarlavhalar tugashini ("\r\n\r\n") ko'rguncha, bayt-bayt o'qiymiz —
    // so'rov tanasi (agar bo'lsa) BUTUNLAY e'tiborsiz qoldiriladi, chunki
    // bizga faqat GET kerak.
    loop {
        let n = stream.read(&mut byte)?;
        if n == 0 {
            break;
        }
        buf.push(byte[0]);
        if buf.len() >= 4 && &buf[buf.len() - 4..] == b"\r\n\r\n" {
            break;
        }
        if buf.len() > 64 * 1024 {
            break; // haddan tashqari katta sarlavha — himoya
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let path_and_query = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    let mut range_header = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("range") {
                range_header = Some(value.trim().to_string());
            }
        }
    }
    Ok(ParsedRequest {
        path_and_query,
        range_header,
    })
}

fn write_status_and_headers(
    stream: &mut TcpStream,
    status: u16,
    status_text: &str,
    headers: &[(&str, String)],
) -> std::io::Result<()> {
    write!(stream, "HTTP/1.1 {status} {status_text}\r\n")?;
    for (name, value) in headers {
        write!(stream, "{name}: {value}\r\n")?;
    }
    write!(stream, "Connection: close\r\n\r\n")?;
    Ok(())
}

fn handle_connection(mut stream: TcpStream) -> std::io::Result<()> {
    let req_id = REQ_COUNTER.fetch_add(1, Ordering::Relaxed);
    let parsed = read_request_line_and_headers(&mut stream)?;
    // "/v?u=<encoded>" dan asl URL'ni ajratib olamiz.
    let query = parsed
        .path_and_query
        .split_once('?')
        .map(|(_, q)| q)
        .unwrap_or("");
    let original_url = query
        .split('&')
        .find_map(|pair| pair.strip_prefix("u="))
        .map(|v| urlencoding_decode(v))
        .unwrap_or_default();

    if original_url.is_empty() {
        write_status_and_headers(&mut stream, 400, "Bad Request", &[])?;
        return Ok(());
    }

    log(format!(
        "So'rov keldi (#{req_id}): Range={}",
        parsed.range_header.as_deref().unwrap_or("(hammasi)")
    ));

    if let Err(e) = serve(&mut stream, &original_url, parsed.range_header.as_deref()) {
        log(format!("XATO (_serve #{req_id}): {e}"));
    }
    Ok(())
}

// Juda oddiy, faqat "%XX" va shu ilovaning o'zi kodlaydigan formatlar
// uchun yetarli percent-decode (tashqi paketga muhtoj bo'lmaslik uchun).
//
// MUHIM: bu funksiya BUTUNLAY BAYT darajasida ishlaydi (hech qachon
// &str'ni bayt indeksi bilan kesmaydi) — Cargo.toml'da "panic = abort"
// o'rnatilgani sabab, char-chegarasi bo'ylab noto'g'ri &str kesish
// butun ILOVA JARAYONINI (nafaqat shu so'rovni) yiqitib qo'yardi. Faqat
// ASCII-hex raqamlaridan hex qiymat hisoblash uchun oddiy yordamchi
// (from_str_radix o'rniga) ishlatiladi, shu bilan hech qanday &str
// kesish umuman bo'lmaydi.
fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn urlencoding_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                match (hex_digit(bytes[i + 1]), hex_digit(bytes[i + 2])) {
                    (Some(hi), Some(lo)) => {
                        out.push(hi * 16 + lo);
                        i += 3;
                    }
                    _ => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ── Kesh kaliti (FNV-1a) va bo'lak fayl nomi ────────────────────────

fn hash_url(url: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    const PRIME: u64 = 0x100000001b3;
    for byte in url.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(PRIME);
    }
    format!("{hash:016x}")
}

fn chunk_name(index: u64) -> String {
    format!("chunk_{index:07}.bin")
}

// ── Meta (umumiy hajm + kontent turi) ───────────────────────────────

#[derive(serde::Serialize, serde::Deserialize)]
struct CacheMeta {
    total_size: u64,
    content_type: String,
}

fn ensure_meta(shared: &Shared, dir: &PathBuf, url: &str) -> Result<CacheMeta, String> {
    let meta_path = dir.join("meta.json");
    if let Ok(raw) = fs::read_to_string(&meta_path) {
        if let Ok(meta) = serde_json::from_str::<CacheMeta>(&raw) {
            if meta.total_size > 0 {
                log(format!("meta.json diskdan o'qildi: hajm={}", meta.total_size));
                return Ok(meta);
            }
        }
    }

    let mut size: u64 = 0;
    let mut content_type = "video/mp4".to_string();

    // Avval HEAD sinaladi (ba'zi manbalar buni qo'llab-quvvatlamaydi —
    // bizning worker'imiz ham 404 qaytaradi, bu normal, keyingi zaxira
    // yo'lga o'tiladi).
    match shared.agent.head(url).call() {
        Ok(resp) => {
            if let Some(len) = resp.header("Content-Length").and_then(|v| v.parse().ok()) {
                size = len;
            }
            if let Some(ct) = resp.header("Content-Type") {
                content_type = ct.to_string();
            }
            log(format!("HEAD javobi: status={}, hajm={size}", resp.status()));
        }
        Err(e) => {
            log(format!("HEAD ishlamadi: {e} — zaxira GET urinib ko'riladi"));
        }
    }

    if size == 0 {
        // Zaxira: "bytes=0-0" bilan GET. Javob tanasi HECH QACHON
        // o'qilmaydi (into_reader() chaqirilmaydi) — shu bilan manba
        // Range'ni e'tiborsiz qoldirib butun faylni yubora boshlagan
        // taqdirda ham, biz shunchaki ulanishni tashlab, hech narsa
        // yuklamagan bo'lamiz (ureq javob tanasini faqat talab qilinsa
        // o'qiydi).
        match shared.agent.get(url).set("Range", "bytes=0-0").call() {
            Ok(resp) => {
                if let Some(cr) = resp.header("Content-Range") {
                    if let Some(total_str) = cr.rsplit('/').next() {
                        size = total_str.parse().unwrap_or(0);
                    }
                } else if let Some(len) =
                    resp.header("Content-Length").and_then(|v| v.parse().ok())
                {
                    size = len;
                }
                if let Some(ct) = resp.header("Content-Type") {
                    content_type = ct.to_string();
                }
                log(format!(
                    "GET bytes=0-0 javobi: status={}, hajm={size}",
                    resp.status()
                ));
            }
            Err(e) => {
                log(format!("GET bytes=0-0 ham ishlamadi: {e}"));
            }
        }
    }

    if size == 0 {
        log("XATO: video hajmini aniqlab bo'lmadi (HEAD ham, GET ham)".to_string());
        return Err("hajm aniqlanmadi".to_string());
    }

    let meta = CacheMeta {
        total_size: size,
        content_type,
    };
    if let Ok(json) = serde_json::to_string(&meta) {
        let _ = fs::write(&meta_path, json);
    }
    Ok(meta)
}

// ── Bo'lakni diskdan o'qish yoki tarmoqdan yuklab, diskka yozish ────

fn read_or_fetch_chunk(
    shared: &Shared,
    key: &str,
    dir: &PathBuf,
    url: &str,
    index: u64,
    start: u64,
    end: u64,
) -> Result<Vec<u8>, String> {
    let expected_len = (end - start + 1) as usize;
    let final_path = dir.join(chunk_name(index));
    if let Ok(bytes) = fs::read(&final_path) {
        if bytes.len() == expected_len {
            return Ok(bytes);
        }
    }
    fetch_and_store_chunk(shared, key, dir, url, index, start, end, expected_len)
}

fn fetch_and_store_chunk(
    shared: &Shared,
    key: &str,
    dir: &PathBuf,
    url: &str,
    index: u64,
    start: u64,
    end: u64,
    expected_len: usize,
) -> Result<Vec<u8>, String> {
    let final_path = dir.join(chunk_name(index));
    let flight_key = format!("{key}#{index}");

    // Boshqa ish oqimi bu bo'lakni bizdan oldin allaqachon yuklab
    // boshlagan bo'lishi mumkin — bunday holda diskda paydo bo'lishini
    // (yoki bo'sh joy ochilishini) kutamiz, ikkinchi marta tarmoqqa
    // chiqmaymiz.
    loop {
        let mut in_flight = shared.in_flight.lock().unwrap();
        if !in_flight.contains(&flight_key) {
            in_flight.insert(flight_key.clone());
            break;
        }
        drop(in_flight);
        thread::sleep(Duration::from_millis(50));
        if let Ok(bytes) = fs::read(&final_path) {
            if bytes.len() == expected_len {
                return Ok(bytes);
            }
        }
    }

    let result = (|| -> Result<Vec<u8>, String> {
        // Boshqa ish oqimi bizni kutayotganimiz orasida ulgurgan bo'lishi
        // mumkin — yana bir bor tekshiramiz.
        if let Ok(bytes) = fs::read(&final_path) {
            if bytes.len() == expected_len {
                return Ok(bytes);
            }
        }

        log(format!("Bo'lak #{index} worker'dan yuklanmoqda ({start}-{end})..."));
        let range = format!("bytes={start}-{end}");
        let resp = shared
            .agent
            .get(url)
            .set("Range", &range)
            .call()
            .map_err(|e| e.to_string())?;
        let status = resp.status();
        log(format!("Bo'lak #{index} javob: status={status}"));

        // Manba Range'ni e'tiborsiz qoldirib TO'LIQ faylni (0-baytdan)
        // 200 status bilan yuborishi mumkin — bunday holda kerakli
        // qismni javob tanasining ICHKARISIDAN ajratib olamiz va kerakli
        // baytlar to'planishi bilan o'qishni TO'XTATAMIZ (qolgan butun
        // faylni behuda yuklab olmaslik uchun).
        let ignores_range = status == 200;
        let skip_bytes = if ignores_range { start as usize } else { 0 };

        let mut reader = resp.into_reader();
        let mut collected: Vec<u8> = Vec::with_capacity(expected_len);
        let mut skipped = 0usize;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            let mut piece = &buf[..n];
            if skipped < skip_bytes {
                let to_skip = (skip_bytes - skipped).min(piece.len());
                piece = &piece[to_skip..];
                skipped += to_skip;
                if piece.is_empty() {
                    continue;
                }
            }
            let remaining = expected_len - collected.len();
            let take = piece.len().min(remaining);
            collected.extend_from_slice(&piece[..take]);
            if collected.len() >= expected_len {
                break;
            }
        }
        log(format!(
            "Bo'lak #{index} yig'ildi: {}/{expected_len} bayt",
            collected.len()
        ));

        if collected.len() == expected_len {
            // Diskka faqat TO'LIQ bo'lak yuklab bo'lingandan keyin,
            // vaqtinchalik nomdan YAKUNIY nomga ATOM ravishda ko'chirib
            // yoziladi.
            let tmp_path = dir.join(format!(
                "{}.{}.tmp",
                chunk_name(index),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_micros())
                    .unwrap_or(0)
            ));
            fs::write(&tmp_path, &collected).map_err(|e| e.to_string())?;
            if fs::rename(&tmp_path, &final_path).is_err() {
                let _ = fs::remove_file(&tmp_path);
            }
        }
        Ok(collected)
    })();

    shared.in_flight.lock().unwrap().remove(&flight_key);
    result
}

// ── Video uchun "avlod" boshqaruvi (eskirgan so'rovlarni bekor qilish) ─

fn bump_generation(shared: &Shared, key: &str) -> u64 {
    let mut gens = shared.generation.lock().unwrap();
    let next = gens.get(key).copied().unwrap_or(0) + 1;
    gens.insert(key.to_string(), next);
    next
}

fn is_current_generation(shared: &Shared, key: &str, my_generation: u64) -> bool {
    let gens = shared.generation.lock().unwrap();
    gens.get(key).copied() == Some(my_generation)
}

// ── Fon to'ldiruvchisi (background filler) ─────────────────────────
//
// Avval har bir bo'lak uchun ALOHIDA ish oqimi ochilardi ("lookahead"),
// bu esa tez-tez sek qilinganda o'nlab ish oqimi (har biri 1 MiB bufer
// bilan) to'planib ketishiga sabab bo'lardi.
//
// Endi har bir video uchun ENG KO'PI BILAN BITTA fon ish oqimi ochiladi.
// U videoning YETISHMAYOTGAN bo'laklarini boshidan oxirigacha ketma-ket
// (bittalab) yuklab, diskka yozib boradi va faqat BOSHQA video
// ochilgandagina to'xtaydi. Natijada:
//   - video bir marta ochilgach, butun fayl fon'da keshga tushadi, shu
//     sabab keyingi ochishda (yoki sek qilinganda) tarmoqqa umuman
//     chiqilmaydi — "qayta yuklab olish" muammosi yo'qoladi;
//   - ish oqimlari soni hech qachon o'smaydi (video uchun aniq bitta),
//     shu sabab xotira sarfi bashorat qilinadigan bo'lib qoladi.
fn ensure_filler(shared: &'static Shared, key: &str, dir: &PathBuf, url: &str, total: u64) {
    {
        // Faqat joriy (eng oxirgi so'ralgan) video to'ldiriladi.
        let mut active = shared.active_video.lock().unwrap();
        if active.as_deref() == Some(key) {
            // Shu video uchun to'ldiruvchi allaqachon ishlayapti.
            return;
        }
        *active = Some(key.to_string());
    }

    let (key2, dir2, url2) = (key.to_string(), dir.clone(), url.to_string());
    thread::Builder::new()
        .name("video-cache-filler".into())
        .spawn(move || {
            let chunk_count = total.div_ceil(CHUNK_SIZE);
            for i in 0..chunk_count {
                // Boshqa video ochilgan bo'lsa — darhol to'xtaymiz.
                {
                    let active = shared.active_video.lock().unwrap();
                    if active.as_deref() != Some(key2.as_str()) {
                        return;
                    }
                }
                let chunk_start = i * CHUNK_SIZE;
                let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);
                let expected_len = (chunk_end - chunk_start + 1) as usize;

                let final_path = dir2.join(chunk_name(i));
                if let Ok(bytes) = fs::read(&final_path) {
                    if bytes.len() == expected_len {
                        continue; // allaqachon keshda
                    }
                }
                log(format!("Bo'lak #{i} fon'da oldindan yuklanmoqda..."));
                if fetch_and_store_chunk(
                    shared, &key2, &dir2, &url2, i, chunk_start, chunk_end, expected_len,
                )
                .is_err()
                {
                    // Tarmoq xatosi — biroz kutib, keyingisiga o'tamiz
                    // (keyingi ochishda qaytadan urinib ko'riladi).
                    thread::sleep(Duration::from_millis(500));
                }
            }
            log(format!("Fon to'ldiruvchi yakunlandi ({chunk_count} bo'lak)"));
        })
        .ok();
}

// ── Asosiy servis funksiyasi: Range'ni tahlil qilib, javobni yozadi ──

fn serve(stream: &mut TcpStream, url: &str, range_header: Option<&str>) -> std::io::Result<()> {
    let shared = SHARED.get().expect("shared holat ishga tushmagan");
    let key = hash_url(url);
    let my_generation = bump_generation(shared, &key);
    let dir = shared.cache_root.join(&key);
    fs::create_dir_all(&dir)?;

    let meta = match ensure_meta(shared, &dir, url) {
        Ok(m) => m,
        Err(e) => {
            write_status_and_headers(stream, 502, "Bad Gateway", &[])?;
            return Err(std::io::Error::new(std::io::ErrorKind::Other, e));
        }
    };
    let total = meta.total_size;
    log(format!("Meta: hajm={total}, tur={}", meta.content_type));

    // Butun videoni fon'da (bitta ish oqimida, ketma-ket) keshga
    // to'ldirishni boshlaymiz — shu bilan video bir marta ochilgach,
    // keyingi ochish/sek qilishlarda tarmoqqa umuman chiqilmaydi.
    ensure_filler(shared, &key, &dir, url, total);

    let (start, mut end, is_range) = match range_header {
        Some(h) if h.starts_with("bytes=") => {
            let spec = &h[6..];
            let (s_str, e_str) = spec.split_once('-').unwrap_or((spec, ""));
            if s_str.is_empty() && !e_str.is_empty() {
                // "bytes=-N" — faylning oxiridan N bayt.
                let suffix_len: u64 = e_str.parse().unwrap_or(0);
                let s = total.saturating_sub(suffix_len);
                (s, total - 1, true)
            } else {
                let s: u64 = s_str.parse().unwrap_or(0);
                let e: u64 = if e_str.is_empty() {
                    total - 1
                } else {
                    e_str.parse().unwrap_or(total - 1)
                };
                (s, e, true)
            }
        }
        _ => (0, total - 1, false),
    };
    if end > total - 1 {
        end = total - 1;
    }
    if start > end || start >= total {
        write_status_and_headers(
            stream,
            416,
            "Range Not Satisfiable",
            &[("Content-Range", format!("bytes */{total}"))],
        )?;
        return Ok(());
    }

    let content_length = end - start + 1;
    if is_range {
        write_status_and_headers(
            stream,
            206,
            "Partial Content",
            &[
                ("Accept-Ranges", "bytes".to_string()),
                ("Content-Type", meta.content_type.clone()),
                ("Content-Length", content_length.to_string()),
                ("Content-Range", format!("bytes {start}-{end}/{total}")),
            ],
        )?;
    } else {
        write_status_and_headers(
            stream,
            200,
            "OK",
            &[
                ("Accept-Ranges", "bytes".to_string()),
                ("Content-Type", meta.content_type.clone()),
                ("Content-Length", content_length.to_string()),
            ],
        )?;
    }

    let mut cursor = start;
    while cursor <= end {
        if !is_current_generation(shared, &key, my_generation) {
            log("_serve bekor qilindi (yangi so'rov boshlangan, avlod eskirdi)".to_string());
            break;
        }
        let chunk_index = cursor / CHUNK_SIZE;
        let chunk_start = chunk_index * CHUNK_SIZE;
        let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);

        let chunk_bytes = match read_or_fetch_chunk(shared, &key, &dir, url, chunk_index, chunk_start, chunk_end) {
            Ok(b) => b,
            Err(e) => {
                log(format!("So'rov uzildi/xato ({start}-{end}): {e}"));
                break;
            }
        };
        log(format!("Bo'lak #{chunk_index} tayyor ({} bayt)", chunk_bytes.len()));

        let slice_start = (cursor - chunk_start) as usize;
        let wanted_end_exclusive = ((end.min(chunk_end)) - chunk_start + 1) as usize;
        // MUHIM: tarmoq o'rtada uzilib, kutilganidan QISQAROQ bo'lak
        // qaytishi mumkin ("panic = abort" o'rnatilgani sabab, bunday
        // holatda chegaradan chiqadigan slice BUTUN ILOVA JARAYONINI
        // yiqitib qo'yardi) — shu sabab haqiqiy uzunlikka albatta
        // moslashtiriladi (clamp).
        let slice_end_exclusive = wanted_end_exclusive.min(chunk_bytes.len());
        if slice_start >= slice_end_exclusive {
            log(format!(
                "XATO: bo'lak #{chunk_index} kutilganidan qisqa keldi ({} bayt) — so'rov to'xtatiladi",
                chunk_bytes.len()
            ));
            break;
        }
        if let Err(e) = stream.write_all(&chunk_bytes[slice_start..slice_end_exclusive]) {
            // Klient uzilgan bo'lishi mumkin (masalan foydalanuvchi yangi
            // joyga sek qildi) — bu holat xato sifatida qaytarilmaydi,
            // faqat jurnalga yoziladi.
            log(format!("So'rov uzildi/xato ({start}-{end}): {e}"));
            break;
        }
        cursor = chunk_start + slice_end_exclusive as u64;
    }
    log(format!("So'rov yakunlandi ({start}-{end})"));
    Ok(())
}
