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
//   - Har bir javob eng ko'pi 4 MiB (MAX_RESPONSE_BYTES) bilan
//     cheklangan — shu sabab har bir ulanish qisqa umr ko'radi va
//     tez-tez sek qilinganda ulanishlar to'planib qolmaydi.
//   - Oldindan yuklash SURILUVCHI OYNA bilan: ijro nuqtasidan keyin
//     eng ko'pi 10 ta bo'lak (PREFETCH_WINDOW) keshga olinadi.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::ffi_utils::{cstr_to_str, string_to_cptr};

const CHUNK_SIZE: u64 = 1024 * 1024;

/// Bir vaqtda ochiq bo'lishi mumkin bo'lgan eng ko'p ulanish soni.
/// Har bir ulanish bitta OS ish oqimi + ~1 MiB bufer degani, shu sabab
/// bu chegara xotira sarfini bashorat qilinadigan darajada ushlab
/// turadi (tez-tez sek qilishda ilova o'chib qolishining oldini oladi).
const MAX_CONNS: usize = 24;

/// Bitta HTTP javobda yuboriladigan ENG KO'P bayt (4 MiB).
///
/// ENG MUHIM ME'MORIY TUZATISH. Avval har bir so'rovga faylning BUTUN
/// QOLGAN QISMI (masalan 9 MB) bitta uzun javobda uzatilardi. Pleyer sek
/// qilganda eski ulanishni tashlab ketardi, lekin server oqimi hali ham
/// unga yozishga urinib, yozish timeout'i tugaguncha (20 soniya!) osilib
/// turardi. Ketma-ket 5-6 marta sek qilinganda bunday "o'lik" ulanishlar
/// to'planib, chegaraga yetardi va undan keyingi so'rov RAD ETILARDI —
/// pleyer esa javobsiz qolib qotib qolardi. Aynan shu sabab orqaga sek
/// qilishda (bir necha yangi so'rov ketma-ket kelgani uchun) crash
/// tezroq yuzaga kelardi.
///
/// Endi har bir javob eng ko'pi 4 MiB — bu HTTP standartiga to'liq mos
/// (206 Partial Content), pleyer qolganini yangi Range so'rovi bilan
/// o'zi so'raydi. Natijada har bir ulanish qisqa umr ko'radi (keshdan
/// o'qilganda millisekundlar), ulanishlar hech qachon to'planmaydi va
/// tashlab ketilgan ulanish ham tezda o'z-o'zidan tugaydi.
const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;

/// Oldindan yuklash OYNASI: ijro nuqtasidan keyin ENG KO'PI BILAN shu
/// qadar bo'lak keshga olinadi. Avval butun fayl fon'da yuklab olinardi
/// — bu foydalanuvchining trafigini keraksiz "so'rib" olardi (u videoni
/// bir necha soniya ko'rib chiqib qo'ysa ham) va xotirani tez to'ldirardi.
/// Endi faqat oldinda turgan 10 ta bo'lak saqlanadi; pleyer oldinga
/// siljigan sari (yoki sek qilinganda) oyna ham u bilan birga suriladi.
const PREFETCH_WINDOW: u64 = 10;

// ── Umumiy holat ─────────────────────────────────────────────────────

struct Shared {
    cache_root: PathBuf,
    start: Instant,
    // Hozir tarmoqdan yuklanayotgan "key#index" bo'laklari — parallel
    // so'rovlar bir xil bo'lakni ikki marta yuklab olmasligi uchun.
    in_flight: Mutex<HashSet<String>>,
    logs: Mutex<Vec<String>>,
    agent: ureq::Agent,
    // Fon to'ldiruvchisi (filler) uchun joriy vazifa. Faqat BITTA
    // to'ldiruvchi ish oqimi bo'ladi va u shu yerdagi vazifani bajaradi;
    // boshqa video ochilsa, vazifa almashadi va eski video uchun
    // yuklash DARHOL to'xtaydi.
    // Hozir ochilgan video kaliti. Boshqa video ochilsa, eski video
    // uchun ishlayotgan oldindan-yuklash DARHOL to'xtaydi.
    active_key: Mutex<String>,
    // "ESHIK": bir vaqtda faqat BITTA oldindan-yuklash ish oqimi
    // bo'lishini ta'minlaydi. Ish tugashi bilan eshik yopiladi va
    // server yana hech narsa so'ray olmaydi — toki pleyer navbatdagi
    // bo'lakka o'tib, eshikni qayta ochmaguncha.
    prefetch_active: AtomicBool,
    // Har bir FAYL uchun alohida tarmoq hisobi: kalit — B2'dagi fayl
    // nomi (masalan "ep_1_2_720p_1788029552837.mp4"), qiymat — shu fayl
    // uchun TARMOQDAN olingan umumiy bayt. Shu bilan "MB aynan qaysi
    // faylga ketyapti" degan savolga aniq javob beriladi.
    net_by_file: Mutex<HashMap<String, u64>>,
}

static SHARED: OnceLock<Shared> = OnceLock::new();
static PORT: OnceLock<u16> = OnceLock::new();
static REQ_COUNTER: AtomicU64 = AtomicU64::new(0);
static ACTIVE_CONNS: AtomicUsize = AtomicUsize::new(0);
/// Ilova ishga tushgandan beri TARMOQDAN olingan umumiy bayt hajmi
/// (keshdan o'qilganlar bunga kirmaydi) — diagnostika uchun.
static NET_BYTES: AtomicU64 = AtomicU64::new(0);
/// Ilova ishga tushgandan beri PLEYERGA (127.0.0.1 — mahalliy
/// "loopback" ulanish) uzatilgan umumiy bayt hajmi.
///
/// NEGA BU KERAK: telefon (MIUI va boshqa qobiqlar) status-satrida
/// ko'rsatadigan "KB/s" hisoblagichi ko'p qurilmalarda BARCHA tarmoq
/// interfeyslarini, shu jumladan MAHALLIY loopback'ni ham qo'shib
/// hisoblaydi. Video keshdan o'qilib pleyerga 127.0.0.1 orqali
/// uzatilganda internetga UMUMAN chiqilmaydi, lekin status-satrida
/// baribir "192 KB/s" kabi raqam ko'rinadi. Endi ekrandagi panel
/// ikkala sonni yonma-yon ko'rsatadi:
///   INTERNET  — haqiqatan worker'dan olingan bayt (NET_BYTES)
///   MAHALLIY  — diskdan o'qib pleyerga berilgan bayt (SERVED_BYTES)
/// Agar INTERNET o'zgarmay, MAHALLIY o'sib borsa — telefon
/// ko'rsatayotgan trafik AYNAN shu mahalliy uzatma, internet emas.
static SERVED_BYTES: AtomicU64 = AtomicU64::new(0);
/// Pleyer HOZIR o'qiyotgan bo'lak indeksi. Oldindan yuklash ish oqimi
/// har bir bo'lakdan oldin shuni tekshiradi: pleyer sek qilib boshqa
/// joyga o'tgan bo'lsa, eski (endi keraksiz) oyna DARHOL tashlanadi.
static CURRENT_CHUNK: AtomicU64 = AtomicU64::new(0);

/// Jurnal fayli eng ko'p hajmi. Oshib ketsa fayl tozalanib, yangidan
/// boshlanadi (cheksiz o'sib, qurilma xotirasini to'ldirmasligi uchun).
const LOG_FILE_MAX_BYTES: u64 = 4 * 1024 * 1024;

fn log(msg: impl Into<String>) {
    if let Some(s) = SHARED.get() {
        let elapsed = s.start.elapsed().as_millis();
        let line = format!("[{elapsed}ms] {}", msg.into());

        // 1) Xotiradagi ro'yxat — ekrandagi panel uchun.
        {
            let mut logs = s.logs.lock().unwrap();
            logs.push(line.clone());
            let len = logs.len();
            if len > 300 {
                logs.drain(0..(len - 300));
            }
        }

        // 2) DISKDAGI YAGONA JURNAL FAYLI — foydalanuvchi uni menga
        //    yuborishi uchun. Barcha loglar (Rust server + Dart pleyer)
        //    shu bitta faylga xronologik tartibda yoziladi:
        //      <ilova ichki xotirasi>/files/video_byte_cache/debug_log.txt
        let path = s.cache_root.join("debug_log.txt");
        if let Ok(meta) = fs::metadata(&path) {
            if meta.len() > LOG_FILE_MAX_BYTES {
                let _ = fs::remove_file(&path);
            }
        }
        if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&path) {
            use std::io::Write as _;
            let _ = writeln!(f, "{line}");
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
        in_flight: Mutex::new(HashSet::new()),
        logs: Mutex::new(Vec::new()),
        agent,
        active_key: Mutex::new(String::new()),
        prefetch_active: AtomicBool::new(false),
        net_by_file: Mutex::new(HashMap::new()),
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
/// Ilova ishga tushgandan beri TARMOQDAN olingan umumiy bayt hajmi.
/// Keshdan o'qilgan bo'laklar bunga KIRMAYDI — shu sabab bu son
/// o'smay tursa, video uchun tarmoqqa umuman chiqilmayotgani aniq
/// bo'ladi. Ekrandagi diagnostika paneli buni doimiy ko'rsatib turadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_net_bytes() -> u64 {
    NET_BYTES.load(Ordering::Relaxed)
}

/// Pleyerga MAHALLIY (127.0.0.1) ulanish orqali uzatilgan umumiy bayt.
/// Yuqoridagi SERVED_BYTES izohiga qarang — telefon status-satridagi
/// "KB/s" ko'rsatkichi ko'pincha aynan shuni ko'rsatadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_served_bytes() -> u64 {
    SERVED_BYTES.load(Ordering::Relaxed)
}

/// Dart tomonidan (video_cache_server.dart / video_player_screen.dart)
/// chaqiriladi — shu bilan PLEYER loglari ham xuddi shu YAGONA
/// debug_log.txt fayliga, server loglari bilan bir xil xronologik
/// tartibda tushadi. Foydalanuvchi keyin o'sha bitta faylni yuborsa,
/// butun manzara (pleyer + kesh-server) ko'rinadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_log(msg_ptr: *const c_char) {
    if let Some(msg) = unsafe { cstr_to_str(msg_ptr) } {
        log(format!("[PLEYER] {msg}"));
    }
}

/// Diskdagi yagona jurnal faylining to'liq yo'lini qaytaradi — ilova
/// uni ekranda ko'rsatishi mumkin, shunda foydalanuvchi faylni topib
/// yuborishi oson bo'ladi.
#[no_mangle]
pub extern "C" fn rust_video_cache_log_path() -> *mut c_char {
    match SHARED.get() {
        Some(s) => string_to_cptr(s.cache_root.join("debug_log.txt").display().to_string()),
        None => string_to_cptr(String::new()),
    }
}

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
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
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

// ── Kesh kaliti (papka nomi) ────────────────────────────────────────
//
// Papka nomi endi B2'dagi FAYL NOMINING O'ZI bo'ladi, masalan:
//   ep_1_2_720p_1788029552837.mp4
// Avval bu tushunarsiz FNV xeshi (masalan "63b1789b28282075") edi.
// Fayl nomi ichida SIFAT ham bor (720p / 1080p / ...), shu sabab
// diskdagi papkalarga qaraboq qaysi epizod va qaysi sifat ekanini
// darhol ajratish mumkin — hamda B2'dagi fayl bilan solishtirish oson.
//
// Fayl nomi aniqlanmasa (kutilmagan URL shakli), zaxira sifatida
// eski FNV-1a xeshi ishlatiladi.
fn cache_key(url: &str) -> String {
    let without_query = url.split('?').next().unwrap_or(url);
    let last = without_query.rsplit('/').next().unwrap_or("");
    let safe: String = last
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_' || *c == '-')
        .collect();
    if safe.is_empty() || safe == "." || safe == ".." {
        return hash_url(url);
    }
    // Juda uzun nomlarni fayl tizimi chegarasidan oshib ketmasligi uchun
    // qisqartiramiz (oxiri saqlanadi — u yerda vaqt belgisi turadi).
    if safe.len() > 120 {
        let tail: String = safe.chars().skip(safe.chars().count() - 120).collect();
        return tail;
    }
    safe
}

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
    expected_total: u64,
) -> Result<Vec<u8>, String> {
    let expected_len = (end - start + 1) as usize;
    let final_path = dir.join(chunk_name(index));
    if let Ok(bytes) = fs::read(&final_path) {
        if bytes.len() == expected_len {
            // MUHIM (diagnostika): diskdan o'qilgan bo'lak uchun TARMOQQA
            // umuman chiqilmaydi. Bu log ekranda ko'rinib turishi kerak —
            // shu bilan "qayta yuklanyaptimi yoki keshdanmi" degan savolga
            // to'g'ridan-to'g'ri javob beradi.
            log(format!("Bo'lak #{index} KESHDAN o'qildi (tarmoqsiz)"));
            return Ok(bytes);
        }
    }
    fetch_and_store_chunk(shared, key, dir, url, index, start, end, expected_len, expected_total)
}

/// Keshni butunlay tozalaydi (meta.json + barcha bo'lak fayllari).
/// Manbadagi fayl o'zgarganda (hajm mos kelmaganda) chaqiriladi.
fn invalidate_cache(dir: &PathBuf) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let _ = fs::remove_file(entry.path());
        }
    }
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
    expected_total: u64,
) -> Result<Vec<u8>, String> {
    let final_path = dir.join(chunk_name(index));
    let flight_key = format!("{key}#{index}");

    // Boshqa ish oqimi bu bo'lakni bizdan oldin allaqachon yuklab
    // boshlagan bo'lishi mumkin — bunday holda diskda paydo bo'lishini
    // (yoki bo'sh joy ochilishini) kutamiz, ikkinchi marta tarmoqqa
    // chiqmaymiz.
    //
    // MUHIM TUZATISH (sek qilganda "qotib qolish"ning asosiy sababi):
    // avval bu kutish CHEKSIZ edi. Agar bo'lakni yuklab olayotgan ish
    // oqimi sekin tarmoqda uzoq osilib qolsa, pleyerga xizmat
    // ko'rsatayotgan ulanish shu yerda ABADIY aylanardi. Foydalanuvchi
    // ketma-ket sek qilganda bunday "osilgan" ulanishlar to'planib,
    // MAX_CONNS chegarasiga yetardi va undan keyingi so'rovlar RAD
    // ETILARDI — pleyer javobsiz qolib qotib qolardi.
    //
    // Endi kutish 6 soniya bilan chegaralangan: shu vaqt ichida bo'lak
    // paydo bo'lmasa, biz uni O'ZIMIZ yuklab olamiz. Ikki marta yuklab
    // olish — qotib qolishdan ming marta yaxshiroq, ustiga-ustak
    // diskka yozish atom (tmp -> rename) bo'lgani uchun xavfsiz.
    let wait_deadline = Instant::now() + Duration::from_secs(6);
    let mut we_own_flight = false;
    loop {
        {
            let mut in_flight = shared.in_flight.lock().unwrap();
            if !in_flight.contains(&flight_key) {
                in_flight.insert(flight_key.clone());
                we_own_flight = true;
                break;
            }
        }
        if let Ok(bytes) = fs::read(&final_path) {
            if bytes.len() == expected_len {
                return Ok(bytes);
            }
        }
        if Instant::now() >= wait_deadline {
            log(format!(
                "Bo'lak #{index} kutish muddati tugadi — mustaqil yuklab olinadi"
            ));
            break;
        }
        thread::sleep(Duration::from_millis(50));
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

        // ── BUTUNLIK TEKSHIRUVI ────────────────────────────────────
        // Yuklab olishdan OLDIN, serverning (Cloudflare kesh/B2)
        // e'lon qilgan UMUMIY fayl hajmini "Content-Range: bytes s-e/TOTAL"
        // dan olib, diskdagi meta.json'da saqlangan hajm bilan
        // solishtiramiz. Agar mos kelmasa — demak manbadagi fayl
        // o'zgargan (qayta yuklangan) va bizning keshimiz ESKIRGAN:
        // bunday holda eski bo'laklarni saqlab qolish videoni buzib
        // ko'rsatishga olib kelardi. Shu sabab kesh butunlay tozalanadi
        // va keyingi ochishda hammasi yangidan, to'g'ri hajm bilan
        // yuklab olinadi.
        if let Some(cr) = resp.header("Content-Range") {
            if let Some(server_total_str) = cr.rsplit('/').next() {
                if let Ok(server_total) = server_total_str.trim().parse::<u64>() {
                    if expected_total > 0 && server_total != expected_total {
                        log(format!(
                            "XATO: hajm mos emas! meta.json={expected_total}, serverda={server_total} — kesh tozalanmoqda"
                        ));
                        invalidate_cache(dir);
                        return Err(format!(
                            "hajm mos emas (meta={expected_total}, server={server_total})"
                        ));
                    }
                }
            }
        }

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
        // Tarmoqdan olingan baytlarning UMUMIY hisobi — foydalanuvchi
        // ekranda "qancha MB ketdi"ni aniq ko'rishi uchun. Agar bu son
        // o'smay tursa, demak barcha ma'lumot keshdan o'qilyapti va
        // tarmoqqa umuman chiqilmayapti.
        let got = collected.len() as u64;
        let total_net = NET_BYTES.fetch_add(got, Ordering::Relaxed) + got;
        // Shu FAYL uchun alohida hisob — "MB aynan qaysi faylga ketyapti"
        // degan savolga to'g'ridan-to'g'ri javob beradi.
        let file_net = {
            let mut m = shared.net_by_file.lock().unwrap();
            let e = m.entry(key.to_string()).or_insert(0);
            *e += got;
            *e
        };
        log(format!(
            "TARMOQDAN >>> fayl='{key}' bo'lak #{index} ({start}-{end}) {got}/{expected_len} bayt | shu fayl: {:.2} MB | jami: {:.2} MB | manba={url}",
            file_net as f64 / (1024.0 * 1024.0),
            total_net as f64 / (1024.0 * 1024.0)
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

    if we_own_flight {
        shared.in_flight.lock().unwrap().remove(&flight_key);
    }
    result
}

// ── Video uchun "avlod" boshqaruvi (eskirgan so'rovlarni bekor qilish) ─

// ── Fon to'ldiruvchisi: SURILUVCHI OYNA ────────────────────────────
//
// Avvalgi versiya video ochilishi bilan BUTUN faylni fon'da yuklab
// olardi. Bu ikki jihatdan yomon edi: (a) foydalanuvchi videoni bir
// necha soniya ko'rib chiqib qo'ysa ham butun fayl uchun trafik
// sarflanardi, (b) xotira/disk keraksiz to'lardi.
//
// ── "ESHIK" MODELI (reaktiv oldindan yuklash) ──────────────────────
//
// MUHIM O'ZGARISH. Avval bu yerda ERKIN ISHLAYDIGAN TSIKL bor edi:
// alohida ish oqimi `loop { ... sleep(200ms) }` bilan aylanib turar,
// ish bo'lmasa ham ~30 soniya davomida o'zini-o'zi qayta-qayta
// tekshirar edi. Tashqaridan bu "server o'zidan-o'zi worker'ga so'rov
// yuboryapti" bo'lib ko'rinardi va aynan shunday ham edi.
//
// Endi tizim BUTUNLAY REAKTIV: hech qanday tsikl, hech qanday taymer,
// hech qanday kutish yo'q. Yagona qoida:
//
//   Eshik FAQAT pleyer yangi bo'lakka o'tganda ochiladi.
//   Ochilganda oynadagi (ijro nuqtasidan keyingi PREFETCH_WINDOW ta)
//   YETISHMAYOTGAN bo'laklar navbatma-navbat olinadi — va tamom.
//   Ish tugashi bilan ish oqimi TUGAYDI, eshik yopiladi.
//
// Masalan: pleyer 2-bo'lakni o'ynay boshladi, oynada faqat 12-bo'lak
// yetishmayapti -> aynan o'sha bitta bo'lak so'raladi -> ish oqimi
// tugaydi. Pleyer 3-bo'lakka o'tmaguncha server BOSHQA HECH NARSA
// so'ramaydi. Oynadagi hamma narsa keshda bo'lsa — birorta ham so'rov
// ketmaydi va ish oqimi darhol tugaydi.
fn maybe_prefetch(
    shared: &'static Shared,
    key: &str,
    dir: &PathBuf,
    url: &str,
    total: u64,
    current_chunk: u64,
) {
    // Joriy videoni belgilab qo'yamiz — boshqa video ochilsa, bu yerda
    // ishlayotgan yuklash o'zini to'xtatadi.
    {
        let mut ak = shared.active_key.lock().unwrap();
        if *ak != key {
            *ak = key.to_string();
        }
    }

    // ESHIK: allaqachon ochiq (ish ketyapti) bo'lsa, ikkinchisini
    // ochmaymiz. Shu bilan bir vaqtda faqat BITTA yuklash bo'ladi.
    if shared.prefetch_active.swap(true, Ordering::SeqCst) {
        return;
    }

    let (key2, dir2, url2) = (key.to_string(), dir.clone(), url.to_string());
    let spawned = thread::Builder::new()
        .name("video-cache-prefetch".into())
        .spawn(move || {
            let chunk_count = total.div_ceil(CHUNK_SIZE);
            let from = current_chunk + 1;
            let until = (from + PREFETCH_WINDOW).min(chunk_count);

            for i in from..until {
                // Boshqa video ochilgan bo'lsa — darhol to'xtaymiz.
                if *shared.active_key.lock().unwrap() != key2 {
                    break;
                }
                // ESKIRGAN OYNANI TASHLASH. Foydalanuvchi sek qilib
                // butunlay boshqa joyga o'tgan bo'lishi mumkin — bunday
                // holda bu yerdagi eski oyna endi keraksiz. Uni davom
                // ettirish (a) bekorga trafik sarflaydi, (b) pleyer
                // HOZIR so'rayotgan bo'lak bilan tarmoq uchun
                // raqobatlashib, sekni sekinlashtiradi va "qotib
                // qolish"ga olib keladi. Shu sabab har bir bo'lakdan
                // OLDIN pleyerning haqiqiy joyi tekshiriladi.
                let live = CURRENT_CHUNK.load(Ordering::Relaxed);
                if live < current_chunk || live >= current_chunk + PREFETCH_WINDOW {
                    log(format!(
                        "Oldindan yuklash to'xtatildi: pleyer #{live} ga o'tdi (eski oyna {from}..{until})"
                    ));
                    break;
                }
                let chunk_start = i * CHUNK_SIZE;
                let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);
                let expected_len = (chunk_end - chunk_start + 1) as usize;

                // Diskda bor bo'lsa — TARMOQQA UMUMAN CHIQILMAYDI.
                if let Ok(m) = fs::metadata(dir2.join(chunk_name(i))) {
                    if m.len() as usize == expected_len {
                        continue;
                    }
                }
                log(format!(
                    "Oldindan yuklanmoqda: bo'lak #{i} (oyna {from}..{until})"
                ));
                let _ = fetch_and_store_chunk(
                    shared, &key2, &dir2, &url2, i, chunk_start, chunk_end, expected_len,
                    total,
                );
            }

            // ESHIK YOPILDI — pleyer navbatdagi bo'lakka o'tmaguncha
            // server endi hech narsa so'ramaydi.
            shared.prefetch_active.store(false, Ordering::SeqCst);
        });

    if spawned.is_err() {
        shared.prefetch_active.store(false, Ordering::SeqCst);
    }
}

// ── Asosiy servis funksiyasi: Range'ni tahlil qilib, javobni yozadi ──

fn serve(stream: &mut TcpStream, url: &str, range_header: Option<&str>) -> std::io::Result<()> {
    let shared = SHARED.get().expect("shared holat ishga tushmagan");
    let key = cache_key(url);
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

    // Javob uzunligini cheklaymiz (yuqoridagi MAX_RESPONSE_BYTES izohiga
    // qarang) — shu bilan har bir ulanish qisqa umr ko'radi va tez-tez
    // sek qilinganda ulanishlar to'planib qolmaydi. Pleyer qolgan qismni
    // yangi Range so'rovi bilan o'zi so'raydi (HTTP 206 uchun bu mutlaqo
    // odatiy holat).
    if is_range && end - start + 1 > MAX_RESPONSE_BYTES {
        end = start + MAX_RESPONSE_BYTES - 1;
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

    // MUHIM: "avlod" (generation) orqali eski so'rovni bekor qilish
    // OLIB TASHLANDI. Sabab: javob uzunligi endi 4 MiB bilan
    // cheklangani uchun har bir so'rov o'zi tezda tugaydi — bekor
    // qilish shart emas. Bundan tashqari u ZARARLI ham edi: pleyer
    // (FFmpeg/mdk-sdk) bir vaqtda BIR NECHTA ulanishdan o'qishi mumkin,
    // eski so'rovni "eskirgan" deb uzib qo'yish esa pleyer hali ham
    // o'qiyotgan oqimni yarmida kesib, uni xatoga olib kelardi.
    let mut cursor = start;
    while cursor <= end {
        let chunk_index = cursor / CHUNK_SIZE;
        let chunk_start = chunk_index * CHUNK_SIZE;
        let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);

        let chunk_bytes = match read_or_fetch_chunk(shared, &key, &dir, url, chunk_index, chunk_start, chunk_end, total) {
            Ok(b) => b,
            Err(e) => {
                log(format!("So'rov uzildi/xato ({start}-{end}): {e}"));
                break;
            }
        };
        log(format!("Bo'lak #{chunk_index} tayyor ({} bayt)", chunk_bytes.len()));
        // Pleyerning HAQIQIY joyi — oldindan yuklash ish oqimi shuni
        // kuzatib turadi va foydalanuvchi sek qilganda eskirgan oynani
        // darhol tashlaydi.
        CURRENT_CHUNK.store(chunk_index, Ordering::Relaxed);

        // ── ESHIK SHU YERDA, FAQAT SHU YERDA OCHILADI ──────────────
        // Pleyer #chunk_index bo'lagini oldi — demak u oldinga siljidi.
        // Shu daqiqada (va faqat shu daqiqada) oynadagi yetishmayotgan
        // bo'laklarni olishga ruxsat beriladi. Ish tugashi bilan eshik
        // yopiladi va server pleyer navbatdagi bo'lakka o'tmaguncha
        // BOSHQA HECH NARSA so'ramaydi. Hech qanday taymer, hech qanday
        // fon tsikli yo'q.
        maybe_prefetch(shared, &key, &dir, url, total, chunk_index);

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
        SERVED_BYTES.fetch_add((slice_end_exclusive - slice_start) as u64, Ordering::Relaxed);
        if let Err(e) = stream.write_all(&chunk_bytes[slice_start..slice_end_exclusive]) {
            // Klient uzilgan bo'lishi mumkin (masalan foydalanuvchi yangi
            // joyga sek qildi) — bu holat xato sifatida qaytarilmaydi,
            // faqat jurnalga yoziladi.
            log(format!("So'rov uzildi/xato ({start}-{end}): {e}"));
            break;
        }
        cursor = chunk_start + slice_end_exclusive as u64;
    }
    // MUHIM DIAGNOSTIKA: har bir so'rov oxirida ilova ishga tushgandan
    // beri TARMOQDAN olingan umumiy hajm ko'rsatiladi. Bu son o'smay
    // tursa — demak video uchun tarmoqqa UMUMAN chiqilmayapti va
    // qurilmada ko'rinayotgan trafik BOSHQA manbadan (boshqa ilova yoki
    // ilovaning boshqa qismi) ketayotgan bo'ladi.
    let net_mb = NET_BYTES.load(Ordering::Relaxed) as f64 / (1024.0 * 1024.0);
    let served_mb = SERVED_BYTES.load(Ordering::Relaxed) as f64 / (1024.0 * 1024.0);
    log(format!(
        "So'rov yakunlandi ({start}-{end}) | INTERNET: {net_mb:.2} MB | MAHALLIY (127.0.0.1): {served_mb:.2} MB"
    ));
    Ok(())
}
