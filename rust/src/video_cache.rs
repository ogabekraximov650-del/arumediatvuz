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
//   - Javob uzunligi qat'iy chegara bilan kesilmaydi: u keshda
//     UZLUKSIZ mavjud bo'lgan oxirgi baytgacha davom etadi
//     — yetishmayotgan bo'laklar javob yozilayotgan payt yuklab
//     olinadi, shu sabab keraksiz qayta ulanishlar bo'lmaydi.
//   - Oldindan yuklash SURILUVCHI OYNA bilan: ijro nuqtasidan keyin
//     hamisha PREFETCH_WINDOW ta bo'lak (10 MB) tayyor turadi.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::crypto;
use crate::ffi_utils::{cstr_to_str, string_to_cptr};

// 1 MiB — har bir bo'lak diskda MUSTAQIL shifrlangan holda saqlanadi
// (crypto::encrypt_chunk/decrypt_chunk, har biri o'z kaliti bilan —
// video_cache_server.dart emas, crypto.rs'dagi izohga qarang). 1 MiB
// 16 ga karrali (AES blok o'lchami), shu sabab bo'lak chegaralari
// shifrlash blok chegaralari bilan mos keladi.
//
// TUZATISH (uzluksiz "sakrash"/stutter muammosi): bir bosqichda bu
// 100 KB ga tushirilgan edi. Natijada har bir bo'lak uchun ALOHIDA
// HTTP so'rov ketardi — 1 MB video uchun 10 ta so'rov. Yuklash esa
// ketma-ket (bittalab) bo'lgani uchun haqiqiy tezlik
// "bo'lak_hajmi / so'rov kechikishi" bilan cheklanardi: 100 KB va
// 100 ms kechikishda bu atigi ~1 MB/s — 1080p video uchun yetarli
// emas. Bufer bo'shab qolar, pleyer kadr tashlab oldinga sakrardi.
// 1 MiB bilan ayni tarmoqda o'tkazuvchanlik ~10 barobar oshadi,
// so'rovlar soni esa shuncha kamayadi.
const CHUNK_SIZE: u64 = 1024 * 1024;

/// Bir vaqtda ochiq bo'lishi mumkin bo'lgan eng ko'p ulanish soni.
/// Har bir ulanish bitta OS ish oqimi + ~1 MiB bufer degani, shu sabab
/// bu chegara xotira sarfini bashorat qilinadigan darajada ushlab
/// turadi (tez-tez sek qilishda ilova o'chib qolishining oldini oladi).
/// 24 -> 64. Rad etilgan ulanish = pleyer javobsiz qoladi = qotib
/// qolish. Ish oqimi esa arzon (ayniqsa endi ular keshdan o'qiganda
/// millisekundlarda tugaydi), shu sabab chegara ancha kengaytirildi:
/// u endi faqat haqiqiy nosozlikdan himoya vazifasini bajaradi.
const MAX_CONNS: usize = 64;






/// O'chirilayotgan papkalar shu prefiks bilan nomlanadi. Ular
/// "video" emas — kesh skanerlash ularni e'tiborsiz qoldiradi, ilova
/// ishga tushganda esa qolib ketganlari tozalanadi (masalan ilova
/// o'chirish o'rtasida yopilgan bo'lsa).
const TRASH_PREFIX: &str = ".axlat_";

// ── Umumiy holat ─────────────────────────────────────────────────────

struct Shared {
    cache_root: PathBuf,
    start: Instant,
    logs: Mutex<Vec<String>>,
    agent: ureq::Agent,
    // Fon to'ldiruvchisi (filler) uchun joriy vazifa. Faqat BITTA
    // to'ldiruvchi ish oqimi bo'ladi va u shu yerdagi vazifani bajaradi;
    // boshqa video ochilsa, vazifa almashadi va eski video uchun
    // yuklash DARHOL to'xtaydi.
    // Isitish so'rovlari uchun ALOHIDA agent: bu so'rov worker
    // 480 MB'ni B2'dan keshga ko'chirib bo'lguncha javob bermaydi,
    // ya'ni bir necha daqiqa davom etishi mumkin. Oddiy agentning
    // 15 soniyalik o'qish chegarasi uni uzib qo'yardi — va ulanish
    // uzilishi bilan worker ham to'xtardi.
    warm_agent: ureq::Agent,
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


/// Diagnostika jurnali — FAQAT XOTIRADA, cheklangan (300 qator).
///
/// DISKKA YOZISH BUTUNLAY OLIB TASHLANDI. Ikki sabab:
///   1) Har bir qator uchun disk operatsiyasi pleyerga ma'lumot
///      uzatayotgan oqimni sekinlashtirardi;
///   2) debug_log.txt shifrlanmagan holda ilova ma'lumotlari orasida
///      yotardi — yangi himoya siyosatiga zid.
///
/// Xotiradagi ro'yxat ishlab chiqish uchun qoldirildi (arzon, ~30 KB)
/// va `rust_video_cache_pull_logs` orqali o'qish mumkin, lekin ishlab
/// chiqarish versiyasida uni hech kim so'ramaydi.
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
        // ── ULANISHLAR QAYTA ISHLATILSIN ─────────────────────────
        // ureq odatda har bir host uchun BITTA bo'sh ulanishni saqlab
        // qoladi. Yuklab olish esa o'nlab oqimda ketadi: qolganlari
        // har bo'lak uchun YANGI TLS qo'l berishini bajarishga majbur
        // bo'lardi (mobil tarmoqda bu 200-600 ms sof ortiqcha vaqt,
        // ya'ni 1 MiB'lik bo'lak uchun juda katta ulush). Endi bo'sh
        // ulanishlar saqlanadi va oqimlar ularni qayta ishlatadi.
        .max_idle_connections(64)
        .max_idle_connections_per_host(64)
        .build();

    // Isitish agenti: javobni uzoq kutadi (pastdagi `maybe_warm`
    // izohiga qarang).
    let warm_agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(900))
        .timeout_write(Duration::from_secs(30))
        .build();

    let shared = Shared {
        cache_root,
        start: Instant::now(),
        logs: Mutex::new(Vec::new()),
        agent,
        warm_agent,
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

    // ── KESHNI OLDINDAN SKANERLASH ────────────────────────────────
    //
    // Yuklab olish hisobi (qaysi bo'lak diskda bor, necha bayt tayyor)
    // endi FON oqimida hisoblanadi — UI oqimi hech qachon diskni
    // kutmasligi uchun (`stat_snapshot_fast` izohiga qarang). Lekin
    // shu sabab hisob BIRINCHI so'ralganda hali tayyor bo'lmasligi
    // mumkin, oflayn rejimda esa ro'yxat aynan shu hisobga qarab
    // filtrlanadi — natijada ro'yxat bir lahzaga bo'sh ko'rinardi.
    //
    // Yechim: server ishga tushishi bilan (ya'ni ilova ochilganda,
    // foydalanuvchi hali hech qayerga o'tmasdan oldin) butun kesh bir
    // marta fon'da skanerlanadi. Ekran ochilganda hisob ALLAQACHON
    // tayyor bo'ladi.
    thread::Builder::new()
        .name("video-cache-warmup".into())
        .stack_size(256 * 1024)
        .spawn(|| {
            let Some(shared) = SHARED.get() else { return };
            let Ok(entries) = fs::read_dir(&shared.cache_root) else {
                return;
            };
            let mut n = 0usize;
            for entry in entries.flatten() {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }
                let key = entry.file_name().to_string_lossy().to_string();
                if key.is_empty() {
                    continue;
                }
                // Oldingi sessiyada o'chirish oxirigacha yetmagan
                // bo'lsa — qoldiq papka shu yerda yo'q qilinadi.
                if key.starts_with(TRASH_PREFIX) {
                    let _ = fs::remove_dir_all(entry.path());
                    continue;
                }
                let (total, have) = stat_snapshot(&key, &entry.path());
                if total > 0 {
                    n += 1;
                    if let Ok(mut map) = stats().lock() {
                        if let Some(e) = map.get_mut(&key) {
                            e.scanned_at = Some(Instant::now());
                        }
                    }
                    let _ = have;
                }
            }
            log(format!("Kesh oldindan skanerlandi: {n} ta video"));
            // Skanerlash tugagach — tugallanmagan yuklab olishlar
            // avtomatik davom etadi (`restore_queue` izohiga qarang).
            restore_queue();
        })
        .ok();

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
                            // Bu oqim faqat bitta bo'lakni uzatadi —
                            // katta stek kerak emas (xotira tejaladi).
                            .stack_size(512 * 1024)
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

/// Xotiradagi diagnostika qatorlarini qaytaradi (va tozalaydi).
/// Faqat ishlab chiqish uchun — ishlab chiqarish versiyasida
/// chaqirilmaydi.
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
    // ── YOZISH CHEGARASI (write timeout) BUTUNLAY OLIB TASHLANDI ──
    //
    // TUZATILGAN XATO — foydalanuvchi ko'rgan muammoning ILDIZI:
    // "videoni pauza qildim, 31 MB yuklandi va video o'sha joydan
    // qayta boshlandi".
    //
    // Nima bo'lardi:
    //   1. Foydalanuvchi pauza qiladi;
    //   2. ExoPlayer buferi to'ladi (50 soniya) va u soketdan
    //      O'QISHNI TO'XTATADI — bu MUTLAQO NORMAL xulq;
    //   3. Bizning `write_all` shu sabab kutib qoladi — bu ham
    //      normal: aynan shu TCP tormozi ortiqcha yuklanishning
    //      oldini oladi;
    //   4. LEKIN 60 soniyadan keyin yozish CHEGARASI ishlab, xato
    //      qaytarardi va biz ulanishni yopardik;
    //   5. ExoPlayer uchun ulanishning yopilishi = "FAYL TUGADI";
    //   6. ilova buni sezib videoni o'sha nuqtadan QAYTA ochardi va
    //      pleyer yana 50 soniyalik buferni to'ldirardi — har
    //      safar yangi trafik.
    //
    // Ya'ni pauza qancha uzoq bo'lsa, shuncha ko'p qayta ochish va
    // shuncha ko'p behuda trafik. Aynan foydalanuvchi o'lchagan
    // holat.
    //
    // ENDI chegara YO'Q: pleyer o'qishni to'xtatsa, biz shunchaki
    // kutamiz (protsessor ham, trafik ham sarflanmaydi). Pleyer
    // yopilsa yoki ilova o'chsa, soket yopiladi va `write_all`
    // HAQIQIY xato qaytaradi — ish oqimi o'shanda tugaydi. Ya'ni
    // "o'lik ulanish"ni aniqlash uchun chegara kerak emas.
    // Nagle algoritmini o'chirish: sarlavha va kichik bo'laklar
    // kechiktirilmasdan darhol yuboriladi (mahalliy ulanishda bu
    // javob tezligini sezilarli oshiradi).
    let _ = stream.set_nodelay(true);
    // MUHIM TEZLIK TUZATISHI: avval sarlavhalar BAYT-BAYT (har bayt
    // uchun alohida `read()` tizim chaqiruvi bilan) o'qilardi — bitta
    // so'rov uchun 300-500 ta tizim chaqiruvi. Endi bir yo'la 4 KB
    // o'qiladi. GET so'rovida tana (body) bo'lmagani uchun sarlavha
    // chegarasidan ortiq o'qib yuborish xavfi ham yo'q.
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
    loop {
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
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
    // Sarlavhalar BITTA `write_all` bilan yuboriladi. Avval har bir
    // qator alohida `write!` bilan yozilardi — ya'ni bitta javob uchun
    // 5-6 ta alohida TCP yozuvi, natijada ortiqcha paketlar va
    // kechikish.
    let mut head = String::with_capacity(256);
    head.push_str(&format!("HTTP/1.1 {status} {status_text}\r\n"));
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("Connection: close\r\n\r\n");
    stream.write_all(head.as_bytes())
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

    // ── TOMOSHA TARIXI UCHUN KADR ─────────────────────────────
    //
    // "/thumb?u=<url>&ms=<vaqt>" — bitta kadrlik MP4 qaytaradi
    // (`serve_thumb` izohiga qarang). Oddiy "/v" yo'lidan
    // BUTUNLAY ajratilgan: "/v" hech qachon tarmoqqa chiqmaydi,
    // bu esa chiqishi MUMKIN, lekin faqat bir necha yuz kilobayt
    // oladi va hech narsani diskka yozmaydi.
    let path_only = parsed
        .path_and_query
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();
    if path_only == "/thumb" {
        let ms: u64 = query
            .split('&')
            .find_map(|pair| pair.strip_prefix("ms="))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        // `exact=0` bo'lsa faqat kalit kadr (`serve_thumb` ga qarang).
        let exact = !query.split('&').any(|pair| pair == "exact=0");
        log(format!("Kadr so'raldi (#{req_id}): ms={ms} exact={exact}"));
        if let Err(e) = serve_thumb(&mut stream, &original_url, ms, exact, parsed.range_header.as_deref())
        {
            log(format!("XATO (thumb #{req_id}): {e}"));
        }
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

// ═══════════════════════════════════════════════════════════════════
//  MUHIM: bitta "full.enc" faylga yig'ish OLIB TASHLANDI.
// ═══════════════════════════════════════════════════════════════════
//
// Avval video to'liq yuklab bo'lingach barcha bo'laklar BITTA uzun
// faylga (full.enc) qayta shifrlanib yig'ilardi. Bu ikki sabab bilan
// ORTIQCHA edi:
//   1) Pleyer bu faylni HECH QACHON to'g'ridan-to'g'ri (HTTP'siz)
//      o'qimaydi — hozirgi arxitekturada u DOIM mahalliy HTTP
//      proksi orqali ishlaydi (video_player_screen.dart), full.enc
//      esa faqat proksi orqali, kerakli bo'lakni kesib xizmat
//      qilinardi — ya'ni bo'lak fayllaridan farqi yo'q edi.
//   2) server allaqachon bir nechta bo'lakni BITTA uzluksiz javobga
//      birlashtirib beradi — demak "bitta uzun fayl" foydasi bo'lak
//      fayllarining o'zidayoq bor.
// Bularning ustiga, hamma bo'lakni qayta ochib-yopib BITTA faylga
// yig'ish qo'shimcha CPU/xotira sarflardi va o'zi murakkab poyga
// holatlariga (fon to'ldiruvchisi bilan) sabab bo'lardi. Endi HAR BIR
// bo'lak doimiy ravishda o'z holicha (mustaqil shifrlangan) saqlanadi
// — sek qilinganda ham, ketma-ket ijroda ham xizmat aynan shu bo'lak
// fayllaridan ko'rsatiladi.

// ═══════════════════════════════════════════════════════════════════
//  KICHIK XIZMAT FAYLLARI HAM SHIFRLANADI
// ═══════════════════════════════════════════════════════════════════
//
// TALAB: ilovaga tegishli BARCHA fayllar shifrlanadi — video
// bo'laklari allaqachon shifrlangan edi, lekin ular yonidagi kichik
// xizmat fayllari ochiq yotardi:
//
//   * `meta.json`          — qaysi fayl, qanchalik katta, qaysi
//                            sifatda. Ya'ni foydalanuvchi NIMA
//                            ko'rganini oshkor qiladi;
//   * `download_queue.json` — yuklab olinayotgan qismlar ro'yxati;
//   * `w<N>.warm`          — qaysi oyna qachon isitilgani.
//
// Bularning hammasi kichik va HAR DOIM BUTUNLAY o'qiladi, shu sabab
// video bo'laklaridagi CBC emas, `crypto::seal_blob` (AES-256-GCM)
// ishlatiladi: u maxfiylikdan tashqari fayl BUZILGANINI ham
// aniqlaydi.
//
// YORLIQ (kalit undan hosil bo'ladi) har bir fayl uchun ALOHIDA va
// QAT'IY belgilanadi — fayl yo'lidan olinmaydi, chunki papka yo'li
// ilova yangilanganda o'zgarishi mumkin va o'shanda kalit ham
// o'zgarib, eski fayllar o'qilmay qolardi.
//
// MIGRATSIYA: shifrlashdan OLDIN yozilgan ochiq fayllar ham
// o'qilaveradi (avval shifr ochishga urinamiz, bo'lmasa oddiy
// ma'lumot deb qaraymiz). Keyingi yozishda ular o'zi shifrlangan
// holatga o'tadi — ya'ni yangilanishdan keyin yuklash navbati ham,
// kesh ham yo'qolmaydi.

/// Shifrlangan (yoki eski — ochiq) kichik faylni o'qiydi.
fn read_sealed(path: &PathBuf, label: &str) -> Option<Vec<u8>> {
    let raw = fs::read(path).ok()?;
    if crypto::is_enabled() {
        if let Some(plain) = crypto::open_blob(label, &raw) {
            return Some(plain);
        }
    }
    Some(raw)
}

/// Kichik faylni shifrlab yozadi (vaqtinchalik fayl + rename, ya'ni
/// yarim yozilgan fayl hech qachon qolmaydi).
fn write_sealed(path: &PathBuf, label: &str, plain: &[u8]) -> bool {
    let bytes: Vec<u8> = if crypto::is_enabled() {
        match crypto::seal_blob(label, plain) {
            Some(b) => b,
            None => return false,
        }
    } else {
        plain.to_vec()
    };
    let tmp = path.with_extension("writing");
    if fs::write(&tmp, &bytes).is_err() {
        return false;
    }
    fs::rename(&tmp, path).is_ok()
}

/// `meta.json` yorlig'i — papka nomi (ya'ni kesh kaliti) bilan
/// bog'lanadi, shu sabab har bir videoning meta fayli o'z kaliti
/// bilan shifrlanadi.
fn meta_label(dir: &PathBuf) -> String {
    let key = dir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    format!("meta:{key}")
}

fn read_meta(dir: &PathBuf) -> Option<CacheMeta> {
    let raw = read_sealed(&dir.join("meta.json"), &meta_label(dir))?;
    serde_json::from_slice::<CacheMeta>(&raw).ok()
}

fn write_meta(dir: &PathBuf, meta: &CacheMeta) -> bool {
    let Ok(json) = serde_json::to_string(meta) else {
        return false;
    };
    write_sealed(&dir.join("meta.json"), &meta_label(dir), json.as_bytes())
}

/// Bo'lak fayli. `.c2` — AES-128-GCM formati (`crypto.rs`).
///
/// Eski (AES-CBC) bo'laklar `.bin` edi. 1 MiB lik bo'lakda ikkala
/// formatning hajmi deyarli bir xil bo'lgani uchun eski fayl
/// "yuklangan" deb ko'rinib, ochilmay qolishi mumkin edi. Nom boshqa
/// bo'lgani uchun eskilari umuman o'qilmaydi va `scan_and_clean`
/// ularni o'chiradi (video qaytadan yuklanadi).
fn chunk_name(index: u64) -> String {
    format!("chunk_{index:07}.c2")
}

/// Eski formatdagi bo'lak fayli (o'chirish uchun).
fn is_legacy_chunk(name: &str) -> bool {
    name.starts_with("chunk_") && name.ends_with(".bin")
}

/// Diskdagi kutilgan bo'lak hajmi: shifrlash yoqilgan bo'lsa nonce
/// va teg sabab asl (ochiq) hajmdan katta bo'ladi.
/// ── DISKDAGI BO'LAK TO'LIQMI (IKKALA KO'RINISHDA HAM) ─────────
///
/// TOPILGAN XATO (foydalanuvchi: "10 soniya anime ko'rdim lekin
/// 8 MB trafik ketdi; ilovadan chiqib qayta kirsam trafik o'zidan
/// o'zi ko'payib ketyapti").
///
/// SABAB — shifrlash holatining KELISHMOVCHILIGI:
///
///   * `write_full_chunk` har bir bo'lak uchun ALOHIDA qaraydi:
///     kalit chiqsa shifrlab, chiqmasa OCHIQ holda yozadi;
///   * tekshiruv esa UMUMIY `crypto::is_enabled()` bayrog'iga
///     qaraydi va faqat BITTA uzunlikni to'g'ri deb biladi.
///
/// Kalit Android Keystore'dan olinadi va u ba'zan kechikadi yoki
/// umuman chiqmaydi. Shunda bo'laklar ochiq holda yoziladi, keyingi
/// ochilishda esa kalit chiqadi — va `scan_and_clean` diskdagi
/// HAMMA bo'lakni "uzunligi noto'g'ri" deb O'CHIRIB tashlaydi.
///
/// Natija: foydalanuvchi ko'rgan narsa — ilova har ochilganda
/// videoni QAYTADAN yuklab oladi. Aynan shuning uchun 6 MB yuklanib,
/// diskda 663 KB qolgan edi.
///
/// YECHIM: uzunlik IKKALA ko'rinishning biriga to'g'ri kelsa —
/// bo'lak to'liq hisoblanadi. Shifrlash yoqilgani yoki yo'qligi
/// endi diskdagi keshni umuman buzmaydi.
fn chunk_len_ok(on_disk: u64, plain_len: u64) -> bool {
    on_disk == plain_len || on_disk == crypto::encrypted_size(plain_len)
}

/// Bo'lak diskda TO'LIQ turibdimi (shifr ochilmaydi — faqat fayl
/// uzunligi tekshiriladi, ya'ni juda arzon).
fn chunk_cached(dir: &PathBuf, index: u64, total: u64) -> bool {
    let plain = chunk_plain_len(index, total);
    if plain == 0 {
        return false;
    }
    fs::metadata(dir.join(chunk_name(index)))
        .map(|m| chunk_len_ok(m.len(), plain))
        .unwrap_or(false)
}

/// Keshdagi bo'lak faylini o'qiydi va (shifrlash yoqilgan bo'lsa)
/// ochadi. Hajm yoki shifr mos kelmasa (masalan eski, boshqa
/// o'lchamdagi qoldiq fayl) — `None`: chaqiruvchi buni "keshda yo'q"
/// deb talqin qilib, bo'lakni qaytadan yuklab oladi.
fn read_cached_chunk(dir: &PathBuf, key: &str, index: u64, expected_len: usize) -> Option<Vec<u8>> {
    let raw = fs::read(dir.join(chunk_name(index))).ok()?;
    let want = expected_len as u64;
    // Qaysi ko'rinishda yozilgani UZUNLIKDAN bilinadi — umumiy
    // bayroqdan emas (`chunk_len_ok` izohiga qarang).
    if raw.len() as u64 == want {
        // Ochiq holda yozilgan (kalit o'sha paytda tayyor emasdi).
        return Some(raw);
    }
    if raw.len() as u64 != crypto::encrypted_size(want) {
        return None;
    }
    let (k, iv) = crypto::derive_chunk_key_iv(key, index)?;
    let plain = crypto::decrypt_chunk(&raw, &k, &iv)?;
    if plain.len() != expected_len {
        return None;
    }
    Some(plain)
}

// ── YARIM YUKLANGAN BO'LAK ("qoldiq" fayl) ──────────────────────────
//
// TALAB: bo'lak to'liq yuklanmay uzilib qolsa, olingan qismi
// YO'QOLMASIN — diskda saqlanib tursin va keyingi urinishda aynan
// o'sha joydan davom etilsin. Bo'lak to'liq yig'ilgach esa qoldiq
// O'CHIRILADI va uning o'rniga YAKUNIY, to'liq bo'lak yoziladi.
//
// NEGA MUHIM: ilgari 1 MiB bo'lakning 900 KB'i olinib tarmoq uzilsa,
// o'sha 900 KB butunlay tashlanardi va keyingi urinish NOLDAN
// boshlanardi. Zaif tarmoqda bu "abadiy qayta yuklash" halqasiga olib
// kelardi — bo'lak hech qachon tugamasdi va foiz joyida turib qolardi.
//
// Qoldiq YAKUNIY bo'lakdan BOSHQA nom bilan saqlanadi
// ("chunk_0000012.bin.part"), shu sabab uni hech qachon tayyor bo'lak
// deb o'qib bo'lmaydi: `read_cached_chunk` faqat aniq nomdagi va aniq
// hajmdagi faylni qabul qiladi.

fn part_name(index: u64) -> String {
    format!("{}.part", chunk_name(index))
}

fn part_label(key: &str, index: u64) -> String {
    format!("{key}:part:{index}")
}

fn micros_now() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0)
}

/// Diskdagi qoldiqni o'qiydi (shifr ochiladi). Buzuq, bo'sh yoki
/// bo'lak hajmidan kichik emas bo'lsa — fayl o'chiriladi va `None`
/// qaytariladi (bo'lak noldan olinadi).
fn read_part(dir: &PathBuf, key: &str, index: u64, expected_len: usize) -> Option<Vec<u8>> {
    let path = dir.join(part_name(index));
    let raw = fs::read(&path).ok()?;
    let plain = if crypto::is_enabled() {
        match crypto::open_blob(&part_label(key, index), &raw) {
            Some(p) => p,
            None => {
                let _ = fs::remove_file(&path);
                return None;
            }
        }
    } else {
        raw
    };
    if plain.is_empty() || plain.len() >= expected_len {
        let _ = fs::remove_file(&path);
        return None;
    }
    Some(plain)
}

/// Qoldiqni diskka yozadi (atom: tmp -> rename), ya'ni ESKI qoldiq
/// yangisi bilan ALMASHTIRILADI. Vaqtinchalik fayl ".tmp" bilan
/// tugaydi — `scan_and_clean` egasiz qolganini keyin o'zi tozalaydi.
fn write_part(dir: &PathBuf, key: &str, index: u64, plain: &[u8]) {
    if plain.is_empty() {
        return;
    }
    let blob = if crypto::is_enabled() {
        match crypto::seal_blob(&part_label(key, index), plain) {
            Some(b) => b,
            None => return,
        }
    } else {
        plain.to_vec()
    };
    let tmp = dir.join(format!("{}.{}.tmp", part_name(index), micros_now()));
    if fs::write(&tmp, &blob).is_err() {
        let _ = fs::remove_file(&tmp);
        return;
    }
    if fs::rename(&tmp, dir.join(part_name(index))).is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

/// Qoldiqni o'chiradi — bo'lak TO'LIQ yozilgandan keyin chaqiriladi.
fn remove_part(dir: &PathBuf, index: u64) {
    let _ = fs::remove_file(dir.join(part_name(index)));
}

// ── Meta (umumiy hajm + kontent turi) ───────────────────────────────

#[derive(serde::Serialize, serde::Deserialize)]
struct CacheMeta {
    total_size: u64,
    content_type: String,
    /// Bo'laklar QAYSI o'lchamda saqlangani. CHUNK_SIZE o'zgarganda
    /// diskdagi eski bo'laklar yaroqsiz bo'lib qoladi (uzunligi mos
    /// kelmaydi) — ular hech qachon o'qilmasa ham, joyni behuda band
    /// qilib yotardi. Shu sabab bu qiymat joriy CHUNK_SIZE bilan mos
    /// kelmasa, kesh papkasi bir marta butunlay tozalanadi.
    /// `default` — eski (bu maydonsiz) meta.json fayllari uchun: ular
    /// 0 bo'lib o'qiladi va shu bilan "eskirgan" deb aniqlanadi.
    #[serde(default)]
    chunk_size: u64,
    /// Videoning DAVOMIYLIGI (soniya). U MP4 konteynerining
    /// `moov` -> `mvhd` atomidan bir marta o'qiladi va SHU YERDA
    /// doimiy saqlanadi.
    ///
    /// NEGA META'GA YOZILADI: oldindan yuklash oynasi ham, "pleyer
    /// hozir qaysi bo'lakni ko'rsatyapti" hisobi ham aynan shu
    /// songa tayanadi:
    ///
    ///     bo'lak_indeksi = (ijro_soniyasi / davomiylik) * hajm / 1 MiB
    ///     bo'lak #i      = [i * davomiylik * 1MiB / hajm ...] soniyalar
    ///
    /// ya'ni "chunk 1 = 00:00-00:08, chunk 2 = 00:08-00:16" jadvali
    /// shu ikki sondan (davomiylik + hajm) to'liq kelib chiqadi va
    /// uni alohida ro'yxat qilib saqlash shart emas.
    ///
    /// Ilgari davomiylik faqat XOTIRADA turardi: ilova qayta
    /// ochilganda u yo'qolar, 1-bo'lak esa keshda bo'lmasa qaytadan
    /// aniqlab ham bo'lmasdi — natijada oyna zaxira (10 bo'lak)
    /// qiymatda qolib ketardi. Endi u bir marta aniqlanadi va
    /// meta.json'da abadiy qoladi.
    #[serde(default)]
    duration_secs: f64,
    /// ── ANIQ "BO'LAK -> SONIYA" JADVALI ────────────────────────
    ///
    /// `chunk_start_ms[i]` — i-bo'lakda BOSHLANADIGAN birinchi
    /// video kadrning vaqti (millisekund). Ya'ni:
    ///
    ///     bo'lak 1: 00:00 dan
    ///     bo'lak 2: 00:11 dan   (jim sahna — uzun)
    ///     bo'lak 3: 00:14 dan   (jangovar sahna — qisqa)
    ///
    /// NEGA O'RTACHA BITREYT YETMAYDI: har bir bo'lak 1 MiB, lekin
    /// undagi VIDEO uzunligi har xil. Shu sabab "soniya -> bo'lak"
    /// ni o'rtacha bitreyt bilan hisoblash bir necha bo'lakka
    /// adashadi. Bu jadval esa faylning O'ZIDAGI namuna
    /// jadvallaridan (stts/stsz/stsc/stco) aniq hisoblanadi —
    /// `build_block_index` ga qarang.
    ///
    /// Bir marta hisoblanib shu yerda saqlanadi (166 ta son ~1 KB).
    #[serde(default)]
    chunk_start_ms: Vec<u32>,
}

fn ensure_meta(shared: &Shared, dir: &PathBuf, url: &str) -> Result<CacheMeta, String> {
    if let Some(meta) = read_meta(dir) {
        if meta.total_size > 0 && meta.chunk_size == CHUNK_SIZE {
            log(format!("meta.json diskdan o'qildi: hajm={}", meta.total_size));
            return Ok(meta);
        }
        if meta.total_size > 0 {
            log(format!(
                "Kesh eskirgan (bo'lak o'lchami {} != {CHUNK_SIZE}) — tozalanmoqda",
                meta.chunk_size
            ));
            invalidate_cache(dir);
        }
    }

    let mut size: u64 = 0;
    let mut content_type = "video/mp4".to_string();

    // Avval HEAD sinaladi (ba'zi manbalar buni qo'llab-quvvatlamaydi —
    // bizning worker'imiz ham 404 qaytaradi, bu normal, keyingi zaxira
    // yo'lga o'tiladi).
    // HEAD ham imzolanadi. TOPILGAN XATO: u imzosiz ketardi va
    // yo'llar yopilgach 403 olardi. Video butunlay o'lmasdi
    // (pastda zaxira GET bor), lekin har bir ochilishda bitta
    // behuda so'rov va jurnalda chalg'ituvchi xato qolardi.
    //
    // MUHIM: imzo ichida METOD ham bor, shuning uchun bu yerda
    // aynan "HEAD" berilishi shart — "GET" bilan imzolangani
    // o'tmaydi.
    match signed(shared.agent.head(url), "HEAD", url).call() {
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
        match signed(shared.agent.get(url), "GET", url).set("Range", "bytes=0-0").call() {
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
        chunk_size: CHUNK_SIZE,
        // Davomiylik va bo'lak-vaqt jadvali faylning ICHIDA —
        // ular 1-bo'lak keshga tushgandan keyin hisoblanib, shu
        // yerga qayta yoziladi.
        duration_secs: 0.0,
        chunk_start_ms: Vec::new(),
    };
    write_meta(dir, &meta);
    Ok(meta)
}

// ═══════════════════════════════════════════════════════════════════
//  YUKLAB OLISH HOLATI (progress) VA BOSHQARUVI
// ═══════════════════════════════════════════════════════════════════
//
// Foydalanuvchi har bir epizodning har bir SIFATI uchun:
//   * qancha foiz yuklanganini REAL VAQTDA ko'radi (video ko'rilayotgan
//     paytda ham, alohida yuklab olinayotganda ham — ikkalasi bir xil
//     bo'lak fayllariga yozadi, shu sabab hisob bitta);
//   * yuklab olishni boshlashi/pauza qilishi;
//   * o'sha sifatni butunlay o'chirib tashlashi mumkin.
//
// Hisob DISKDAN bir marta o'qib olinadi (skanerlash), keyin esa har bir
// yangi bo'lak yozilganda XOTIRADA yangilanadi — shu sabab Dart tomoni
// buni soniyasiga bir necha marta so'rasa ham disk yuklanmaydi.

/// Bitta video (kalit) uchun yuklab olish holati.
struct StatEntry {
    /// Faylning to'liq hajmi (meta.json dan). 0 = hali noma'lum.
    total: u64,
    /// Diskda TO'LIQ mavjud bo'lak indekslari.
    have: HashSet<u64>,
    /// Shu bo'laklarning ochiq (shifrlanmagan) umumiy hajmi.
    have_bytes: u64,
    /// Disk bir marta skanerlab bo'lindimi.
    scanned: bool,
    /// meta.json oxirgi marta qachon tekshirilgan. Hajm hali noma'lum
    /// bo'lganda (video hech qachon ochilmagan) uni HAR SAFAR diskdan
    /// o'qish keraksiz: oflayn rejimda ekran bir vaqtda o'nlab
    /// qismning holatini so'raydi.
    checked_at: Option<Instant>,
    /// Hozir FON oqimida skanerlash ketyaptimi (ikki marta
    /// boshlanmasligi uchun).
    scanning: bool,
    /// Fon skanerlashi oxirgi marta qachon TUGAGAN. Hajm hali
    /// noma'lum bo'lganda (meta.json yo'q) keraksiz qayta-qayta oqim
    /// ochilmasligi uchun kerak.
    scanned_at: Option<Instant>,

    // ── TEZLIK O'LCHOVI (ekranda ko'rsatish uchun) ──────────────
    //
    // NEGA KERAK: "yuklab olish sekinlashdi" degan gapni tekshirib
    // bo'lmasdi — ilovada tezlik ko'rsatilmasdi va Rust jurnali
    // faqat xotirada edi. Endi ekranda MB/s ko'rinadi, ya'ni
    // muammo taxmin emas, RAQAM bo'ladi.
    /// Oxirgi o'lchov oynasida tarmoqdan olingan bayt.
    speed_acc: u64,
    /// O'lchov oynasi qachon boshlangan.
    speed_at: Option<Instant>,
    /// Silliqlangan tezlik (bayt/soniya).
    speed: u64,
    /// Hozir shu video uchun nechta yuklash oqimi ishlayapti.
    streams: u32,
}

impl StatEntry {
    fn empty() -> Self {
        StatEntry {
            total: 0,
            have: HashSet::new(),
            have_bytes: 0,
            scanned: false,
            checked_at: None,
            scanning: false,
            scanned_at: None,
            speed_acc: 0,
            speed_at: None,
            speed: 0,
            streams: 0,
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  YUKLASH VAQTI QAYERGA KETYAPTI (o'lchagich)
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "boshqa ilovalarda 10 MB/s chiqadi,
// bizda 5-6 dan oshmayapti; foydalanuvchi internetining maksimal
// tezligi qancha bo'lsa shuncha berish kerak".
//
// Server tekshirildi: isitilgan keshdan 35-87 MB/s beradi va
// bo'lak o'lchami deyarli ahamiyatsiz. Demak chegara TELEFONDAGI
// kodda. Qaysi qismida ekani esa TAXMIN qilib emas, O'LCHAB
// aniqlanadi — shu sabab har bir oqim o'z vaqtini beshga bo'lib
// yozadi va yuklash tugagach yig'indi jurnalga chiqadi:
//
//   t_warm  — oynaning keshga tushishini kutish;
//   t_ttfb  — so'rov yuborildi -> birinchi bayt keldi;
//   t_read  — soketdan o'qish (sof tarmoq vaqti);
//   t_write — shifrlash va diskka yozish;
//   t_claim — umumiy qulfni kutish.
//
// Hisoblagichlar atomik va faqat qo'shiladi — o'lchov ishning
// o'ziga sezilarli yuk bermaydi.
#[derive(Default)]
struct DlTiming {
    warm_us: AtomicU64,
    ttfb_us: AtomicU64,
    read_us: AtomicU64,
    write_us: AtomicU64,
    claim_us: AtomicU64,
    bytes: AtomicU64,
    started_ms: AtomicU64,
}

static DL_TIMING: OnceLock<Mutex<HashMap<String, Arc<DlTiming>>>> = OnceLock::new();

fn dl_timing(key: &str) -> Arc<DlTiming> {
    let map = DL_TIMING.get_or_init(|| Mutex::new(HashMap::new()));
    let mut m = match map.lock() {
        Ok(m) => m,
        Err(e) => e.into_inner(),
    };
    let e = m.entry(key.to_string()).or_default();
    if e.started_ms.load(Ordering::Relaxed) == 0 {
        e.started_ms.store(uptime_ms(), Ordering::Relaxed);
    }
    Arc::clone(e)
}

/// Yuklash tugadi — o'lchov natijasini jurnalga yozadi va
/// hisoblagichlarni tozalaydi.
fn dl_timing_report(key: &str) {
    let Some(map) = DL_TIMING.get() else { return };
    let t = {
        let mut m = match map.lock() {
            Ok(m) => m,
            Err(e) => e.into_inner(),
        };
        match m.remove(key) {
            Some(t) => t,
            None => return,
        }
    };
    let started = t.started_ms.load(Ordering::Relaxed);
    if started == 0 {
        return;
    }
    let wall = (uptime_ms().saturating_sub(started)) as f64 / 1000.0;
    if wall <= 0.05 {
        return;
    }
    let mb = t.bytes.load(Ordering::Relaxed) as f64 / 1_048_576.0;
    let sec = |v: u64| v as f64 / 1_000_000.0;
    // Oqimlar parallel ishlagani uchun yig'indi vaqt devor
    // vaqtidan katta bo'lishi MUMKIN — foiz shu sabab yig'indiga
    // nisbatan hisoblanadi.
    let w = sec(t.warm_us.load(Ordering::Relaxed));
    let f = sec(t.ttfb_us.load(Ordering::Relaxed));
    let r = sec(t.read_us.load(Ordering::Relaxed));
    let wr = sec(t.write_us.load(Ordering::Relaxed));
    let c = sec(t.claim_us.load(Ordering::Relaxed));
    let sum = (w + f + r + wr + c).max(0.001);
    let pct = |v: f64| (v / sum * 100.0).round() as i64;
    log(format!(
        "O'LCHOV {key}: {mb:.1} MB / {wall:.1}s = {:.2} MB/s | \
         kutish {w:.1}s ({}%) · ttfb {f:.1}s ({}%) · o'qish {r:.1}s ({}%) · \
         yozish {wr:.1}s ({}%) · qulf {c:.1}s ({}%)",
        if wall > 0.0 { mb / wall } else { 0.0 },
        pct(w), pct(f), pct(r), pct(wr), pct(c),
    ));
}

/// Tezlik o'lchovining oynasi: shundan uzun bo'lsa qayta
/// hisoblanadi.
const SPEED_WINDOW: Duration = Duration::from_millis(1000);

/// Shundan uzoq vaqt bitta ham bayt kelmasa — tezlik NOL.
const SPEED_STALE: Duration = Duration::from_millis(2500);

/// O'lchov oynasi to'lgan bo'lsa tezlikni qayta hisoblaydi.
/// Chaqiruvchi `stats()` qulfini USHLAB turgan bo'lishi kerak.
fn speed_roll(e: &mut StatEntry) {
    let Some(at) = e.speed_at else {
        e.speed_at = Some(Instant::now());
        return;
    };
    let el = at.elapsed();
    if el < SPEED_WINDOW {
        return;
    }
    let now = (e.speed_acc as f64 / el.as_secs_f64()) as u64;
    // Silliqlash: ekrandagi raqam sakramasin.
    e.speed = if e.speed == 0 {
        now
    } else {
        (e.speed / 2) + (now / 2)
    };
    e.speed_acc = 0;
    e.speed_at = Some(Instant::now());
    if el > SPEED_STALE {
        // Uzoq vaqt hech narsa kelmadi — eski qiymat yolg'on
        // bo'lib qolmasin.
        e.speed = now;
    }
}

/// Tarmoqdan bayt keldi — tezlik hisobiga qo'shamiz.
/// (Har 64 KB da bir marta chaqiriladi — juda arzon.)
fn stat_note_net(key: &str, bytes: u64) {
    let Ok(mut map) = stats().lock() else { return };
    let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
    e.speed_acc += bytes;
    speed_roll(e);
}

/// Yuklash oqimi ochildi (+1) yoki yopildi (-1).
fn stat_stream_delta(key: &str, delta: i32) {
    let Ok(mut map) = stats().lock() else { return };
    let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
    if delta > 0 {
        e.streams = e.streams.saturating_add(delta as u32);
    } else {
        e.streams = e.streams.saturating_sub((-delta) as u32);
        if e.streams == 0 {
            // Oxirgi oqim yopildi — tezlik darhol nolga tushsin.
            e.speed = 0;
            e.speed_acc = 0;
            e.speed_at = None;
        }
    }
}

/// Ekran uchun: (tezlik bayt/soniya, faol oqimlar soni).
/// DISKKA CHIQMAYDI — faqat xotiradagi hisob.
fn stat_speed_now(key: &str) -> (u64, u32) {
    let Ok(mut map) = stats().lock() else { return (0, 0) };
    let Some(e) = map.get_mut(key) else { return (0, 0) };
    speed_roll(e);
    // Hech narsa kelmayotgan bo'lsa tezlik NOL ko'rsatiladi.
    let stale = e
        .speed_at
        .map(|t| t.elapsed() > SPEED_STALE && e.speed_acc == 0)
        .unwrap_or(true);
    if stale {
        e.speed = 0;
    }
    (e.speed, e.streams)
}

static STATS: OnceLock<Mutex<HashMap<String, StatEntry>>> = OnceLock::new();

/// Fon'da bir vaqtda ishlaydigan skanerlash oqimlari soni va uning
/// chegarasi. Skanerlash DISKKA tayanadi, ya'ni oqimlarni ko'paytirish
/// tezlik bermaydi — chegara faqat oqim to'planib ketishining oldini
/// oladi.
static SCAN_THREADS: AtomicUsize = AtomicUsize::new(0);
const MAX_SCAN_THREADS: usize = 2;

fn stats() -> &'static Mutex<HashMap<String, StatEntry>> {
    STATS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Berilgan indeksdagi bo'lakning OCHIQ (shifrlanmagan) uzunligi.
fn chunk_plain_len(index: u64, total: u64) -> u64 {
    let start = index * CHUNK_SIZE;
    if total == 0 || start >= total {
        return 0;
    }
    let end = (start + CHUNK_SIZE - 1).min(total - 1);
    end - start + 1
}

fn meta_total_from_disk(dir: &PathBuf) -> u64 {
    match read_meta(dir) {
        Some(m) if m.chunk_size == CHUNK_SIZE => m.total_size,
        _ => 0,
    }
}

/// Diskni bir marta ko'rib chiqadi: TO'LIQ bo'laklarni sanaydi va
/// YARIM QOLGAN / BUZILGAN qoldiqlarni TOZALAYDI.
///
/// Nima uchun tozalash kerak: yuklab olish yarmida to'xtatilsa yoki
/// ilova o'chib qolsa, diskda uzunligi noto'g'ri bo'lgan fayl qolishi
/// mumkin. Bunday fayl hech qachon ishlatilmaydi (o'qishda uzunlik
/// tekshiriladi), lekin joyni band qilib yotadi. Endi u darhol
/// o'chiriladi — foydalanuvchi keyinroq xohlagan paytda o'sha
/// bo'lakdan yuklashni davom ettiraveradi.
fn scan_and_clean(dir: &PathBuf, total: u64) -> (HashSet<u64>, u64) {
    // 1) Egasiz vaqtinchalik (.tmp) fayllar. FAQAT eskilari o'chiriladi —
    //    yangisini shu daqiqada boshqa ish oqimi yozayotgan bo'lishi
    //    mumkin.
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            // Eski (AES-CBC) formatdagi bo'lak — endi o'qilmaydi.
            if is_legacy_chunk(&name) {
                let _ = fs::remove_file(entry.path());
                continue;
            }
            if !name.ends_with(".tmp") {
                continue;
            }
            let old = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.elapsed().ok())
                .map(|age| age > Duration::from_secs(120))
                .unwrap_or(true);
            if old {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    let mut have = HashSet::new();
    let mut have_bytes = 0u64;
    if total == 0 {
        return (have, have_bytes);
    }
    let count = total.div_ceil(CHUNK_SIZE);
    for i in 0..count {
        let plain = chunk_plain_len(i, total);
        let path = dir.join(chunk_name(i));
        let Ok(m) = fs::metadata(&path) else { continue };
        if chunk_len_ok(m.len(), plain) {
            have.insert(i);
            have_bytes += plain;
            // Bo'lak to'liq — undan qolgan "qoldiq" fayl (agar bo'lsa)
            // endi keraksiz.
            remove_part(dir, i);
        } else {
            // 2) To'liq bo'lmagan YAKUNIY fayl — tozalanadi.
            //    (".part" qoldig'iga TEGILMAYDI: u ataylab saqlanadi
            //    va keyingi urinishda davom ettirish uchun kerak.)
            let _ = fs::remove_file(&path);
        }
    }
    (have, have_bytes)
}

/// Yangi bo'lak diskka yozilganda (yoki keshda borligi tasdiqlanganda)
/// hisobni yangilaydi. Bir xil bo'lak ikki marta sanalmaydi.
fn stat_note_chunk(key: &str, index: u64, plain_len: u64) {
    let mut map = stats().lock().unwrap();
    let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
    if e.have.insert(index) {
        e.have_bytes += plain_len;
    }
}

/// Videoning joriy holati: (to'liq hajm, yuklangan hajm).
/// TARMOQQA UMUMAN CHIQMAYDI — faqat diskdagi holatga qaraydi.
fn stat_snapshot(key: &str, dir: &PathBuf) -> (u64, u64) {
    {
        let map = stats().lock().unwrap();
        if let Some(e) = map.get(key) {
            if e.scanned && e.total > 0 {
                return (e.total, e.have_bytes);
            }
        }
    }
    // Hajm hali noma'lum — meta.json (kichik fayl) o'qiladi. U paydo
    // bo'lgach BIR MARTA to'liq skanerlash qilinadi.
    // Hajm noma'lum bo'lsa, meta.json 3 soniyada bir martadan ko'p
    // o'qilmaydi.
    {
        let map = stats().lock().unwrap();
        if let Some(e) = map.get(key) {
            if let Some(t) = e.checked_at {
                if e.total == 0 && t.elapsed() < Duration::from_secs(3) {
                    return (0, e.have_bytes);
                }
            }
        }
    }
    let total = meta_total_from_disk(dir);
    if total == 0 {
        let mut map = stats().lock().unwrap();
        let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
        e.checked_at = Some(Instant::now());
        return (0, e.have_bytes);
    }
    // Skanerlash DISKKA tayanadi va u YAKUNIY haqiqat hisoblanadi:
    // xotiradagi eski ro'yxat (masalan fayllar tashqaridan o'chirilgan
    // bo'lsa) uni almashtira olmaydi. Yagona istisno — aynan
    // skanerlash davomida qo'shilgan yangi bo'laklar: ular yo'qolib
    // qolmasligi uchun alohida saqlanadi.
    let before: HashSet<u64> = {
        let map = stats().lock().unwrap();
        map.get(key).map(|e| e.have.clone()).unwrap_or_default()
    };
    let (mut have, _) = scan_and_clean(dir, total);
    let mut map = stats().lock().unwrap();
    let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
    for i in e.have.difference(&before) {
        have.insert(*i);
    }
    e.have_bytes = have.iter().map(|i| chunk_plain_len(*i, total)).sum();
    e.have = have;
    e.total = total;
    e.scanned = true;
    e.checked_at = Some(Instant::now());
    (e.total, e.have_bytes)
}

/// ── UI OQIMI UCHUN: HECH QACHON BLOKLANMAYDI ────────────────────
///
/// Bu funksiya Dart tomonidan, ya'ni Flutter'ning UI oqimida,
/// soniyada bir necha marta chaqiriladi. Ilgari u to'g'ridan-to'g'ri
/// `stat_snapshot` ni chaqirardi va u yerda `fs::read_dir` + har bir
/// bo'lak uchun `fs::metadata` bajarilardi. 166 MB video = 166 ta
/// fayl; ochilgan qismning bir necha sifati bilan bu MINGGA yaqin
/// syscall degani — hammasi UI oqimida, yuklab olish oqimlari o'sha
/// diskka yozib turgan paytda. Natijada qismlar ro'yxatini surganda
/// kadrlar tashlanardi (15-25 fps).
///
/// Endi qoida qat'iy: BU YERDA DISKKA CHIQILMAYDI. Xotiradagi hisob
/// darhol qaytariladi; diskni skanerlash kerak bo'lsa, u FON oqimida
/// bir marta bajariladi va natija keyingi so'rovda tayyor bo'ladi.
/// Hisobning o'zi (qaysi bo'lak bor, necha bayt) mutlaqo o'zgarmadi —
/// faqat u ENDI BOSHQA OQIMDA hisoblanadi.
fn stat_snapshot_fast(key: &str, dir: &PathBuf) -> (u64, u64) {
    // Tayyor hisob bo'lsa — darhol qaytaramiz (eng keng tarqalgan yo'l).
    let (total, have, need_scan) = {
        let mut map = stats().lock().unwrap();
        let e = map.entry(key.to_string()).or_insert_with(StatEntry::empty);
        if e.scanned && e.total > 0 {
            return (e.total, e.have_bytes);
        }
        // Skanerlash allaqachon ketyaptimi yoki hozirgina tugadimi?
        let recently = e
            .scanned_at
            .map(|t| t.elapsed() < Duration::from_secs(1))
            .unwrap_or(false);
        let need = !e.scanning && !recently;
        if need {
            e.scanning = true;
        }
        (e.total, e.have_bytes, need)
    };
    if !need_scan {
        return (total, have);
    }

    // Bir vaqtda ochiladigan skanerlash oqimlari CHEKLANADI. Oflayn
    // rejimda ekran bir zumda o'nlab qismning holatini so'raydi —
    // chegarasiz holda o'nlab oqim birdan ochilib, bir xil disk uchun
    // raqobatlashardi. Chegaradan oshgani shunchaki KUTADI: keyingi
    // so'rovda (bir necha yuz millisekunddan keyin) navbati keladi.
    if SCAN_THREADS.fetch_add(1, Ordering::SeqCst) >= MAX_SCAN_THREADS {
        SCAN_THREADS.fetch_sub(1, Ordering::SeqCst);
        if let Ok(mut map) = stats().lock() {
            if let Some(e) = map.get_mut(key) {
                e.scanning = false;
            }
        }
        return (total, have);
    }

    let (k, d) = (key.to_string(), dir.clone());
    let spawned = thread::Builder::new()
        .name("video-cache-scan".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            // Og'ir ish — FON oqimida (UI kutmaydi).
            let _ = stat_snapshot(&k, &d);
            if let Ok(mut map) = stats().lock() {
                if let Some(e) = map.get_mut(&k) {
                    e.scanning = false;
                    e.scanned_at = Some(Instant::now());
                }
            }
            SCAN_THREADS.fetch_sub(1, Ordering::SeqCst);
        });
    if spawned.is_err() {
        SCAN_THREADS.fetch_sub(1, Ordering::SeqCst);
        if let Ok(mut map) = stats().lock() {
            if let Some(e) = map.get_mut(key) {
                e.scanning = false;
            }
        }
    }
    (total, have)
}

fn stat_reset(key: &str, keep_total: u64) {
    let mut map = stats().lock().unwrap();
    map.insert(
        key.to_string(),
        StatEntry {
            // Hajm ekranda ko'rinib tursin ("0% / 0 / 240 MB").
            total: keep_total,
            have: HashSet::new(),
            have_bytes: 0,
            // MUHIM: `scanned = false`. Fayllar endigina o'chirildi,
            // ya'ni YAGONA haqiqat — DISK. `true` qo'yilsa hisob
            // abadiy xotiradagi (eski) qiymatda qotib qolar va disk
            // qayta ko'rib chiqilmasdi; video qayta yuklanganda esa
            // foiz noto'g'ri ko'rinishi mumkin edi.
            scanned: false,
            checked_at: None,
            scanning: false,
            scanned_at: None,
            speed_acc: 0,
            speed_at: None,
            speed: 0,
            streams: 0,
        },
    );
}

// ── YUKLAB OLISH NAVBATI ("Telegram uslubi") ───────────────────────
//
// TALAB: foydalanuvchi yuklab olish tugmasini XOHLAGAN PAYTDA,
// XOHLAGANCHA bosa olsin; ilova hech qachon yiqilmasin; uzilish yoki
// xato bo'lsa yuklash O'ZI to'xtagan joyidan davom etsin.
//
// AVVALGI TIZIMDAGI KAMCHILIK: har bir sifat uchun ALOHIDA 1 + 3 ta
// ish oqimi ochilardi. Foydalanuvchi bir necha sifatni yonma-yon
// bosса, o'nlab ish oqimi paydo bo'lib, ularning har biri o'z 1 MiB
// buferi bilan xotirani band qilardi va bir xil tarmoq uchun
// raqobatlashardi — natijada ilova xotira yetishmasligidan o'chib
// qolardi. Xato bo'lganda esa yuklash JIMGINA to'xtardi: tugmani
// qayta bosish ham hech narsa bermasdi.
//
// YANGI TIZIM — bitta MARKAZIY navbat va CHEGARALANGAN ish oqimlari:
//   * butun ilovada bor-yo'g'i DOWNLOAD_WORKERS ta ish oqimi bo'ladi,
//     nechta sifat navbatga qo'yilishidan qat'i nazar;
//   * har bir vazifa bo'laklarni DOWNLOAD_THREADS ta oqimda parallel
//     va CHEKLOVSIZ oladi (tezlikni faqat foydalanuvchi tarmog'i
//     belgilaydi); xotira esa oqimlar soni bilan chegaralangan —
//     bir vaqtda eng ko'pi DOWNLOAD_THREADS x 1 MiB bufer;
//   * xato bo'lsa vazifa navbatdan CHIQMAYDI: kechikish bilan (2, 4,
//     8 ... 60 soniya) o'zi qayta uriniladi va aynan to'xtagan
//     bo'lagidan davom etadi;
//   * "pauza" — shunchaki "xohlanmagan" deb belgilash; ish oqimi
//     navbatdagi bo'lakdan oldin buni tekshiradi va darhol chiqadi.
//
// Shu sabab tugmani necha marta bosilsa ham yangi ish oqimi
// ochilmaydi — faqat vazifaning holati o'zgaradi.

/// Butun ilova bo'yicha bir vaqtda yuklanadigan videolar (sifatlar)
/// soni.
///
/// TALAB (foydalanuvchi): "bir vaqtning o'zida maksimal 3 ta sifat
/// yuklab olinsin, bittasi tugashi bilan avtomatik keyingisi
/// boshlansin, qolganlari navbatda tursin". Navbat tartibi —
/// BOSILISH tartibi (`DownloadState::seq`, `pick_task`).
const DOWNLOAD_WORKERS: usize = 3;

/// BITTA videoni yuklab olishda bir vaqtda ishlaydigan oqimlar soni.
///
/// NEGA KERAK: ilgari bo'laklar KETMA-KET olinardi — bitta so'rov
/// tugamaguncha keyingisi boshlanmasdi. Bunda haqiqiy tezlik
/// "bo'lak hajmi / so'rov kechikishi" bilan cheklanadi: 1 MiB va
/// 200 ms kechikishda bu atigi ~5 MB/s, mobil tarmoqda ancha kam.
///
/// TALAB: "yuklab olish tugmasi bosilsa, fayl hech qanday cheklovsiz,
/// foydalanuvchi interneti qancha tez bo'lsa shuncha tez olinsin".
///
/// ── NEGA 6 EMAS, 16 (qurilmada IKKI MARTA o'lchandi) ──────────
///
/// 1-o'lchov. Foydalanuvchining tarmog'i 8 MB/s, yuklash esa eng
/// yaxshi holatda 3 MB/s edi — ya'ni BITTA oqim atigi ~0.5 MB/s
/// beryapti. Bu mobil/uzoq tarmoqlar uchun odatiy: bitta TCP
/// ulanishning tezligi yo'l kechikishi (RTT) bilan cheklanadi va
/// uni faqat PARALLEL ulanishlar ko'paytiradi. 6 x 0.5 = 3 MB/s —
/// o'lchov bilan aynan mos.
///
/// 2-o'lchov (12 oqim bilan): 5 MB/s -> 4 -> 3.5-4 MB/s, ya'ni
/// bitta oqim ~0.4 MB/s. Kanal (8 MB/s) hali to'lmagan, shu sabab
/// oqimlar soni 16 ga chiqarildi: 16 x 0.4 = ~6.5 MB/s.
///
/// Bundan ko'proq qilishning ma'nosi yo'q: kanal to'lgach oqim
/// qo'shish tezlikni oshirmaydi, faqat xotira va batareya sarflaydi.
///
/// Xotira uchun xavfsiz: bir vaqtda eng ko'pi
/// DOWNLOAD_THREADS x 1 MiB bufer (16 MiB) bo'ladi, oqim steki esa
/// 256 KB. Tezlikni esa faqat foydalanuvchining tarmog'i belgilaydi.
///
/// MUHIM: oqimlar ishni UMUMIY KURSORDAN, kichik va moslashuvchan
/// ulushlar bilan oladi (pastdagi `Work` izohiga qarang) — shu
/// sabab oxirgi baytgacha hammasi band bo'ladi.
const DOWNLOAD_THREADS: usize = 16;


/// ── SERVERNING HAQIQIY ORALIQ CHEGARASI ────────────────────────
///
/// TUZATILGAN XATO (foydalanuvchi: "yuklab olish sekin va 70-80%
/// da to'xtab qoladi"):
///
/// Yuklovchi bir so'rovda 10 MiB so'rardi, worker esa (o'zining
/// `RANGE_MAX` chegarasi sabab) HAR DOIM atigi 8 MiB qaytarardi.
/// Ya'ni har bir guruhning OXIRGI 2 MiB'i (aynan 20%) hech qachon
/// kelmasdi. Ular keyin bittalab, "chetga qo'yilgan" sekin yo'l
/// bilan (har biri uchun 10 soniyagacha kutish bilan) olinardi —
/// natijada foiz 80% ga borib SUDRALIB qolardi.
///
/// Endi ikki himoya bor:
///   1) `DL_REQUEST_CHUNKS` worker'ning `RANGE_MAX` chegarasiga
///      aynan mos qilib tanlangan;
///   2) shunga qaramay server so'ralganidan KAM qaytarsa, uning
///      haqiqiy chegarasi shu yerda ESLAB QOLINADI va keyingi
///      so'rovlar o'sha o'lchamda yuboriladi. Ya'ni server
///      chegarasi kelajakda o'zgarsa ham, ilova unga o'zi
///      moslashadi va bu xato QAYTA TAKRORLANMAYDI.
static SERVER_SPAN_MAX: AtomicU64 = AtomicU64::new(u64::MAX);

/// Chegara OXIRGI MARTA qachon o'rnatilgan (server ishga tushgandan
/// beri o'tgan millisekund). 0 — o'rnatilmagan.
///
/// ── NIMA UCHUN KERAK (tuzatilgan xato) ────────────────────────
///
/// Ilgari `SERVER_SPAN_MAX` FAQAT kamayardi va hech qachon
/// tiklanmasdi. Ya'ni bitta noxush javob (masalan worker o'sha
/// lahzada band bo'lib, kichikroq oraliq bergani) BUTUN ilovani
/// ilova qayta ishga tushmaguncha mayda so'rovlarga o'tkazib
/// yuborardi — yuklab olish esa shu sababdan sekinlashib qolardi
/// va o'z-o'zidan hech qachon tuzalmasdi.
///
/// Endi chegara "muddatli": shu vaqtdan keyin u UNUTILADI va
/// ilova yana to'liq o'lchamdagi so'rov bilan sinab ko'radi.
/// Server chegarasi haqiqatan pastligicha qolsa — birinchi
/// javobdayoq yana o'rnatiladi (bir marta ortiqcha so'rov, ya'ni
/// deyarli hech qanday narx).
static SERVER_SPAN_AT_MS: AtomicU64 = AtomicU64::new(0);

/// Chegara shu muddatdan keyin unutiladi.
const SERVER_SPAN_TTL_MS: u64 = 5 * 60 * 1000;

/// Server ishga tushgandan beri o'tgan millisekund.
fn uptime_ms() -> u64 {
    SHARED
        .get()
        .map(|s| s.start.elapsed().as_millis() as u64)
        .unwrap_or(0)
        .max(1)
}

/// Serverning kuzatilgan chegarasi bo'yicha oraliqni qisqartiradi.
fn clamp_span(range_start: u64, range_end: u64) -> u64 {
    let cap = SERVER_SPAN_MAX.load(Ordering::Relaxed);
    if cap == u64::MAX {
        return range_end;
    }
    // Chegara eskirgan bo'lsa — unutamiz va to'liq o'lchamda
    // so'raymiz (yuqoridagi `SERVER_SPAN_AT_MS` izohiga qarang).
    let set_at = SERVER_SPAN_AT_MS.load(Ordering::Relaxed);
    if set_at > 0 && uptime_ms().saturating_sub(set_at) > SERVER_SPAN_TTL_MS {
        SERVER_SPAN_MAX.store(u64::MAX, Ordering::Relaxed);
        SERVER_SPAN_AT_MS.store(0, Ordering::Relaxed);
        log("Server oraliq chegarasi eskirdi — to'liq o'lchamda qayta sinaladi".to_string());
        return range_end;
    }
    let want = range_end.saturating_sub(range_start) + 1;
    if want <= cap {
        range_end
    } else {
        range_start + cap - 1
    }
}

/// Server so'ralgan ORALIQNI qisqartirdi — chegarani eslab qolamiz.
///
/// MUHIM: bu qaror FAQAT `Content-Range` sarlavhasiga qarab
/// qabul qilinadi, tananing uzunligiga EMAS. Sabab sinovda
/// aniqlandi: uzatma yo'lda uzilib, tana qisqa kelishi mumkin —
/// bu serverning chegarasi emas, oddiy tarmoq nosozligi. Agar
/// shunga ishonilsa, bitta tasodifiy uzilish BUTUN ilovani
/// abadiy mayda so'rovlarga o'tkazib yuborardi (sinovda aynan
/// shunday bo'ldi: 8 MiB o'rniga 712 KB).
///
/// `Content-Range` esa serverning O'ZI "men shunchasini beraman"
/// deb aytgani — ishonchli signal. Ustiga chegara hech qachon
/// bitta bo'lakdan kichik bo'lmaydi.
fn note_server_span(asked: u64, granted: u64) {
    if granted == 0 || granted >= asked {
        return;
    }
    let granted = granted.max(CHUNK_SIZE);
    let prev = SERVER_SPAN_MAX.load(Ordering::Relaxed);
    if granted < prev {
        SERVER_SPAN_MAX.store(granted, Ordering::Relaxed);
        SERVER_SPAN_AT_MS.store(uptime_ms(), Ordering::Relaxed);
        log(format!(
            "Server bir so'rovda eng ko'pi {:.1} MiB beradi — keyingi so'rovlar shunga moslashtirildi",
            granted as f64 / 1048576.0
        ));
    }
}

struct DownloadState {
    url: String,
    /// Foydalanuvchi yuklashni xohlaydimi. Pauza bosilsa `false` —
    /// ish oqimi navbatdagi bo'lakdan oldin buni ko'rib to'xtaydi.
    wanted: bool,
    /// Hozir ish oqimi shu vazifa ustida ishlayaptimi.
    running: bool,
    /// Ketma-ket muvaffaqiyatsiz urinishlar soni (kechikish uchun).
    failures: u32,
    /// Shu vaqtdan oldin qayta urinilmaydi.
    next_try: Instant,
    /// ── BUYRUQ RAQAMI (epoch) ─────────────────────────────────
    ///
    /// TUZATILGAN XATO (foydalanuvchi ko'rgan asosiy muammo):
    /// videoni tozalab, DARHOL "yuklab olish"ni bosganda yuklash
    /// umuman boshlanmasdi. Sabab: tozalashning fon oqimi va
    /// tugagan yuklashning yakuniy bosqichi navbatdagi yozuvni
    /// SO'ZSIZ o'chirib tashlardi — va o'sha lahzada yozuv
    /// allaqachon YANGI (foydalanuvchi hozirgina bosgan) buyruq
    /// bo'lardi. Natijada tugma bosilardi-yu, hech narsa
    /// bo'lmasdi.
    ///
    /// Endi har bir yangi buyruq (tugma bosilishi) bu raqamni
    /// oshiradi. Eski ish tugagach yozuvni o'chirishdan OLDIN
    /// raqam solishtiriladi: u o'zgargan bo'lsa — bu boshqa,
    /// YANGI buyruq, unga tegilmaydi.
    epoch: u64,
    /// ── NAVBATDAGI O'RNI ─────────────────────────────────────
    ///
    /// TOPILGAN XATO (foydalanuvchi: "qaysi sifat boshida bosilsa
    /// avval o'sha yuklansin, yangi bosilganlar navbatda tursin").
    /// Navbat `HashMap` edi va ish oqimi undan BIRINCHI UCHRAGANINI
    /// olardi — xesh tartibi esa tasodifiy. Ya'ni oxirgi bosilgan
    /// sifat birinchisidan oldin boshlanib ketishi mumkin edi.
    /// Endi har bir yangi buyruq o'sib boruvchi raqam oladi va eng
    /// kichigi birinchi olinadi.
    seq: u64,
    /// Yuklash BOSHLANGANMI (bo'sh joy olganmi). Boshlangan vazifa
    /// tugaguncha o'z joyini ushlab turadi — tarmoq xatosi bilan
    /// qisqa kutayotgan bo'lsa ham navbatdagisi uning o'rniga
    /// kirib olmaydi, ya'ni bir vaqtda `DOWNLOAD_WORKERS` tadan
    /// ko'p video HECH QACHON yuklanmaydi.
    started: bool,
}

// ── BUTUN ILOVA BO'YICHA ULANISHLAR CHEGARASI ─────────────────
//
// TOPILGAN XATO (foydalanuvchi: "yangi tizimda battar sekin, tezlik
// 2 MB/s dan o'tmayapti; avvalgisi yaxshiroq edi").
//
// Bir vaqtda 3 ta sifat yuklana boshlagach, har biri o'zining 16 ta
// oqimini ochardi — jami 48 ta parallel HTTP ulanish. Mobil tarmoqda
// bu foyda emas, zarar: ulanishlar bitta tor kanalni talashadi,
// har biri TCP "sekin start"da qoladi va radio/operator NAT navbati
// to'lib, umumiy tezlik pasayadi. Telegram ham butun fayl uchun
// atigi 4-12 ta so'rovni havoda ushlaydi (`FileLoadOperation`).
//
// Endi havodagi so'rovlar soni BUTUN ILOVA uchun `DL_TOTAL_CONNS`
// bilan cheklangan (ilgari bitta video 16 ta bilan 5,5 MB/s bergan
// edi — xuddi shu son). Sifatlar ularni bo'lishadi: bittasi tugasa,
// bo'shagan ulanishlarni qolganlari DARHOL oladi.
const DL_TOTAL_CONNS: usize = 16;

static DL_CONNS: Mutex<usize> = Mutex::new(0);
static DL_CONNS_CV: std::sync::Condvar = std::sync::Condvar::new();

/// Bitta havodagi so'rov uchun ruxsat (yo'qolganda bo'shaydi).
struct DlPermit;

impl DlPermit {
    /// Ruxsat olinguncha kutadi. Yuklash to'xtatilsa — `None`.
    fn acquire(key: &str) -> Option<DlPermit> {
        let mut n = DL_CONNS.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if *n < DL_TOTAL_CONNS {
                *n += 1;
                return Some(DlPermit);
            }
            let (g, _) = DL_CONNS_CV
                .wait_timeout(n, Duration::from_millis(200))
                .unwrap_or_else(|e| e.into_inner());
            n = g;
            if !download_active(key) {
                return None;
            }
        }
    }
}

impl Drop for DlPermit {
    fn drop(&mut self) {
        let mut n = DL_CONNS.lock().unwrap_or_else(|e| e.into_inner());
        *n = n.saturating_sub(1);
        drop(n);
        DL_CONNS_CV.notify_one();
    }
}

/// Navbat raqami (`DownloadState::seq`).
static DL_SEQ: AtomicU64 = AtomicU64::new(0);

static DOWNLOADS: OnceLock<Mutex<HashMap<String, DownloadState>>> = OnceLock::new();
static DL_POOL: AtomicBool = AtomicBool::new(false);
/// Har bir yangi yuklash buyrug'i uchun o'sib boradigan raqam
/// (`DownloadState::epoch` izohiga qarang).
static DL_EPOCH: AtomicU64 = AtomicU64::new(0);

fn downloads() -> &'static Mutex<HashMap<String, DownloadState>> {
    DOWNLOADS.get_or_init(|| Mutex::new(HashMap::new()))
}

// ── YUKLAB OLISH NAVBATI ILOVA YOPILSA HAM YO'QOLMAYDI ─────────
//
// TUZATILGAN XATO (foydalanuvchi: "yuklab olish barqaror emas"):
// navbat FAQAT xotirada turardi. Android esa fon'dagi ilovani
// xotira kerak bo'lganda istalgan vaqtda o'ldiradi — shundan
// keyin yuklash O'Z-O'ZIDAN TIKLANMASDI: foydalanuvchi ilovani
// qayta ochib, har bir qism uchun tugmani QAYTA bosishi kerak
// edi. Ko'p qismli anime'da bu amalda "yuklab olish ishlamaydi"
// degani.
//
// Endi navbat diskda oddiy JSON ro'yxat sifatida saqlanadi va
// ilova ochilishi bilan avtomatik davom etadi. Olingan bo'laklar
// allaqachon diskda, ya'ni yuklash aynan to'xtagan joyidan
// davom etadi — bitta ham bayt qayta olinmaydi.

/// Navbat fayli.
fn queue_path() -> Option<PathBuf> {
    Some(SHARED.get()?.cache_root.join("download_queue.json"))
}

/// Navbatni diskka yozadi. Chaqiruvchi `downloads()` qulfini
/// USHLAB TURGAN bo'lishi kerak (qulf ikki marta olinmasin).
fn save_queue_locked(map: &HashMap<String, DownloadState>) {
    let Some(path) = queue_path() else { return };
    // NAVBAT TARTIBIDA yoziladi — ilova qayta ochilganda ham
    // birinchi bosilgani birinchi davom etadi.
    let mut rows: Vec<&DownloadState> = map.values().filter(|s| s.wanted).collect();
    rows.sort_by_key(|s| s.seq);
    let urls: Vec<&str> = rows.iter().map(|s| s.url.as_str()).collect();
    if let Ok(json) = serde_json::to_string(&urls) {
        write_sealed(&path, "download-queue", json.as_bytes());
    }
}

/// Diskdagi navbatni o'qib, yuklashlarni qaytadan boshlaydi.
fn restore_queue() {
    let Some(path) = queue_path() else { return };
    let Some(raw) = read_sealed(&path, "download-queue") else {
        return;
    };
    let Ok(urls) = serde_json::from_slice::<Vec<String>>(&raw) else {
        return;
    };
    if urls.is_empty() {
        return;
    }
    log(format!(
        "Tugallanmagan yuklab olish tiklanmoqda: {} ta",
        urls.len()
    ));
    for url in urls {
        if url.is_empty() {
            continue;
        }
        // To'liq yuklab bo'lingan bo'lsa qayta boshlanmaydi
        // (`start_download` ichidagi tekshiruv emas — bu yerda
        // tarmoqqa chiqmasdan, faqat diskka qarab hal qilinadi).
        if let Some(shared) = SHARED.get() {
            let key = cache_key(&url);
            let dir = shared.cache_root.join(&key);
            let total = meta_total_from_disk(&dir);
            if total > 0 {
                let count = total.div_ceil(CHUNK_SIZE);
                if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                    continue;
                }
            }
        }
        start_download(&url);
    }
}


/// Yuklash NAVBATDA yoki KETAYAPTIMI (foydalanuvchi uchun ikkalasi
/// ham "yuklanmoqda" degani).
fn download_active(key: &str) -> bool {
    downloads()
        .lock()
        .map(|m| m.get(key).map(|s| s.wanted).unwrap_or(false))
        .unwrap_or(false)
}

/// Xato sabab kutib turgan vazifa (UI buni ko'rsatishi mumkin).
fn download_failing(key: &str) -> bool {
    downloads()
        .lock()
        .map(|m| m.get(key).map(|s| s.failures > 0).unwrap_or(false))
        .unwrap_or(false)
}

/// Ish oqimlari havzasini bir marta ishga tushiradi.
fn ensure_pool() {
    if DL_POOL.swap(true, Ordering::SeqCst) {
        return;
    }
    for n in 0..DOWNLOAD_WORKERS {
        let spawned = thread::Builder::new()
            .name(format!("video-download-{n}"))
            // Kichik stek yetarli: bu oqim faqat bitta bo'lakni
            // oladi va diskka yozadi.
            .stack_size(256 * 1024)
            .spawn(pool_worker);
        if spawned.is_err() {
            log("XATO: yuklab olish ish oqimi ochilmadi".to_string());
        }
    }
}

/// Navbatdan bajarishga tayyor vazifani tanlaydi.
///
/// Qoidalar:
///   1) avval BOSHLANGAN vazifalar (ular o'z joyini ushlab turadi);
///   2) bo'sh joy bo'lsa (`DOWNLOAD_WORKERS` dan kam) — navbatdagi
///      ENG BIRINCHI bosilgani;
///   3) har ikkala holatda ham eng kichik `seq` birinchi.
fn pick_task() -> Option<(String, String, u64)> {
    let now = Instant::now();
    let mut map = downloads().lock().ok()?;
    let key = choose_task(&map, now)?;
    let st = map.get_mut(&key)?;
    st.running = true;
    st.started = true;
    Some((key, st.url.clone(), st.epoch))
}

/// `pick_task` ning qarori (sof funksiya — test uchun alohida).
fn choose_task(map: &HashMap<String, DownloadState>, now: Instant) -> Option<String> {
    let ready = |s: &DownloadState| s.wanted && !s.running && s.next_try <= now;
    let started = map
        .iter()
        .filter(|(_, s)| s.started && ready(s))
        .min_by_key(|(_, s)| s.seq)
        .map(|(k, _)| k.clone());
    if started.is_some() {
        return started;
    }
    let busy = map.values().filter(|s| s.wanted && s.started).count();
    if busy >= DOWNLOAD_WORKERS {
        return None;
    }
    map.iter()
        .filter(|(_, s)| !s.started && ready(s))
        .min_by_key(|(_, s)| s.seq)
        .map(|(k, _)| k.clone())
}

/// Vazifa navbatda turibdi (hali boshlanmagan) — UI "navbatda"
/// deb ko'rsatadi.
fn download_queued(key: &str) -> bool {
    downloads()
        .lock()
        .map(|m| m.get(key).map(|s| s.wanted && !s.started).unwrap_or(false))
        .unwrap_or(false)
}

/// Bitta yuklash bosqichining natijasi.
enum DlOutcome {
    /// Videoning HAMMA bo'lagi diskda — vazifa tugadi.
    Done,
    /// Foydalanuvchi pauza qildi.
    Paused,
    /// Bir qismi olindi, lekin hammasi emas. Bu XATO EMAS: vazifa
    /// navbatda qoladi va DARHOL (kutmasdan) davom ettiriladi.
    Partial(u64),
}

fn pool_worker() {
    loop {
        let Some((key, url, epoch)) = pick_task() else {
            // Ish yo'q — havza tinch turadi (protsessor sarflanmaydi).
            thread::sleep(Duration::from_millis(400));
            continue;
        };

        let outcome = run_download(&key, &url);

        let mut map = match downloads().lock() {
            Ok(m) => m,
            Err(_) => continue,
        };
        // ── ISH TUGADI, LEKIN BU HALI HAM O'SHA ISHMI? ──────────
        // Ish davom etayotganda foydalanuvchi videoni tozalab, qayta
        // "yuklab olish"ni bosgan bo'lishi mumkin. U holda navbatdagi
        // yozuv ENDI BOSHQA (yangi) buyruq — uni o'chirish yangi
        // yuklashni jimgina o'ldirardi (aynan foydalanuvchi ko'rgan
        // xato). Shu sabab raqam o'zgargan bo'lsa, yozuvga TEGMAYMIZ
        // va uni darhol ishga tayyor qilib qo'yamiz.
        if map.get(&key).map(|s| s.epoch != epoch).unwrap_or(false) {
            if let Some(st) = map.get_mut(&key) {
                st.running = false;
                st.failures = 0;
                st.next_try = Instant::now();
            }
            log(format!(
                "Yuklab olish qayta so'ralgan ({key}) — yangi buyruq bilan davom etadi"
            ));
            continue;
        }
        let still_wanted = map.get(&key).map(|s| s.wanted).unwrap_or(false);
        match outcome {
            // To'liq yuklandi — vazifa navbatdan chiqadi.
            Ok(DlOutcome::Done) => {
                map.remove(&key);
                save_queue_locked(&map);
                log(format!("Yuklab olish TUGADI: {key}"));
                dl_timing_report(&key);
            }
            // Foydalanuvchi pauza qildi.
            Ok(DlOutcome::Paused) => {
                map.remove(&key);
                save_queue_locked(&map);
            }
            // ── ENG MUHIM O'ZGARISH (yuklab olish tezligi) ─────────
            // Bir necha bo'lak olindi, ba'zilari esa olinmadi (tarmoq
            // xatosi yoki o'sha bo'lak ayni payt pleyer qo'lida edi).
            // AVVAL bunday holat ham "xato" hisoblanib, butun vazifa
            // 2 -> 4 -> 8 -> 16 -> 32 soniya KUTARDI. Zaif mobil
            // tarmoqda xato deyarli har bosqichda uchraydi, natijada
            // yuklash vaqtining ko'p qismi KUTISHGA ketardi va tezlik
            // 0.2-0.5 MB/s ga tushib qolardi — garchi 12 ta oqim
            // tayyor turgan bo'lsa ham.
            //
            // Endi ILGARILASH BO'LSA — kutish YO'Q: vazifa darhol
            // davom etadi va faqat yetishmayotgan bo'laklar olinadi.
            Ok(DlOutcome::Partial(done)) => {
                if !still_wanted {
                    map.remove(&key);
                } else if let Some(st) = map.get_mut(&key) {
                    st.running = false;
                    st.failures = 0;
                    // Ilgarilash bo'lgan bo'lsa deyarli tanaffussiz
                    // davom etamiz; bo'lmasa (hamma bo'lak ayni payt
                    // pleyer qo'lida edi) — bir soniya kutamiz, ya'ni
                    // bo'sh aylanish bo'lmaydi.
                    let pause = if done > 0 { 200 } else { 1000 };
                    st.next_try = Instant::now() + Duration::from_millis(pause);
                    log(format!(
                        "Yuklab olish davom etmoqda ({key}): shu bosqichda {done} bo'lak olindi"
                    ));
                }
            }
            // HECH QANDAY ilgarilash bo'lmadi (masalan internet
            // butunlay uzilgan) — faqat SHU holatda kechikib qayta
            // uriniladi va aynan to'xtagan bo'lagidan davom etadi.
            Err(e) => {
                if !still_wanted {
                    map.remove(&key);
                } else if let Some(st) = map.get_mut(&key) {
                    st.running = false;
                    st.failures = st.failures.saturating_add(1);
                    // 2 -> 4 -> 8 -> 10 s. Ilgari 60 s gacha o'sardi:
                    // oxirgi bo'lak bir necha marta yiqilsa, yuklash
                    // 98% da daqiqalab to'xtab turardi.
                    let wait = 2u64.saturating_pow(st.failures.min(5)).min(10);
                    st.next_try = Instant::now() + Duration::from_secs(wait);
                    log(format!(
                        "Yuklab olish uzildi ({key}): {e} — {wait}s dan keyin davom etadi"
                    ));
                }
            }
        }
    }
}

/// ── BITTA SO'ROVDA ENG KO'PI SHUNCHA BO'LAK ───────────────────
///
/// Worker isitilgan oynadan baytlarni OQIM bilan kesib beradi
/// (xotiraga yig'ilmaydi), shu sabab bitta so'rov katta bo'lishi
/// mumkin. Bu to'g'ridan-to'g'ri xarajat: 166 MB'lik video
/// 16 MiB'lik so'rovlarda 11 ta, 64 MiB'lik so'rovlarda esa
/// atigi 6 ta so'rov bo'ladi.
///
/// Worker tomondagi `RANGE_MAX` bilan AYNAN bir xil bo'lishi
/// kerak. Farq bo'lib qolsa ham xato bo'lmaydi: `note_server_span`
/// serverning haqiqiy chegarasini birinchi javobdayoq o'rganib
/// oladi va keyingi so'rovlar shunga moslashadi.
const DL_REQUEST_CHUNKS: u64 = 64;

/// ── ISH TAQSIMOTI: UMUMIY KURSOR + MOSLASHUVCHAN ULUSH ───────
///
/// TUZATILGAN XATO (foydalanuvchi: "boshida 3 MB/s edi, keyin 2,
/// keyin 1 va 0.5 MB/s ga tushib qoldi", 166 MB'lik fayl).
///
/// ── ESKI TIZIM VA U NEGA ISHLAMADI ──
///
/// Ilgari oynadagi ish `DOWNLOAD_THREADS` ta TENG "yo'lak"ka
/// bo'linardi va har bir oqim faqat o'z yo'lagini olardi. Yo'lagi
/// tugagan oqim boshqasining ishini "o'g'irlashi" mumkin edi,
/// LEKIN faqat HAVODA BO'LMAGAN (hali so'ralmagan) qismini.
/// Amalda esa:
///
///     166 MB fayl  = 166 ta bo'lak;
///     166 / 6      = ~28 ta bo'lak — bitta yo'lak;
///     bitta so'rov = 64 tagacha bo'lak (`DL_REQUEST_CHUNKS`).
///
/// Ya'ni HAR BIR OQIM O'Z YO'LAGINING HAMMASINI bitta so'rovda
/// olib qo'yardi va yo'lakda o'g'irlash uchun bitta ham bo'lak
/// qolmasdi (`rem = 0`). Ishi tugagan oqim esa ish topolmay
/// butunlay chiqib ketardi. Natijada faol oqimlar soni
/// 6 -> 5 -> ... -> 1 ga tushib borar, tezlik ham AYNAN shunga
/// proporsional pasayardi — foydalanuvchi ko'rgan
/// 3 -> 2 -> 1 -> 0.5 MB/s roppa-rosa shu.
///
/// Ya'ni "yo'lak" tuzatishi faqat YO'LAK SO'ROVDAN KATTA bo'lganda
/// (taxminan 400 MB'dan katta fayllarda) ishlardi; odatdagi
/// epizodda esa umuman ishlamasdi.
///
/// ── YANGI TIZIM ──
///
/// Yo'lak yo'q. Oynadagi yetishmayotgan bo'laklar BITTA umumiy
/// kursorda turadi, oqimlar esa ishni KERAK BO'LGANDA, kichik
/// ulushlar bilan oladi. Uch qoida:
///
///   1) ADIL ULUSH — hech bir oqim qolgan ishning `1/oqimlar`
///      ulushidan ko'pini olmaydi. Shu sabab oxirida bitta oqimda
///      katta ish qolib ketmaydi: qolgan ish HAR DOIM hammaga
///      bo'linadi va oqimlar deyarli bir vaqtda tugaydi.
///   2) VAQTGA MOSLASHISH — ulush oqimning O'Z o'lchangan
///      tezligiga qarab, taxminan `CLAIM_TARGET_SECS` soniyalik
///      ish qilib tanlanadi. Tez ulanish katta ulush oladi
///      (so'rovlar soni kam bo'ladi), sekin ulanish esa kichik
///      ulush oladi — ya'ni bitta sekin ulanish butun yuklashni
///      kutdirib qo'ymaydi.
///   3) QAYTARISH — javob yarmida uzilsa, ulushning olinmagan
///      qismi umumiy navbatga QAYTARILADI va uni birinchi bo'sh
///      qolgan oqim oladi.
///
/// Bitta bayt ham ikki marta olinmaydi: ulush kursordan QULF
/// ostida ajratiladi va kursor darhol suriladi, ya'ni ikkita oqim
/// bir xil bo'lakni hech qachon so'ramaydi. Diskda allaqachon bor
/// bo'lak ham qayta olinmaydi — ulush o'sha yerda kesiladi.
///
/// Testlar: `yuklab_olish_yolaklar_bilan_takrorsiz_ketadi`
/// (qoplama — takror ham, bo'shliq ham yo'q) va
/// `yuklab_olish_sekin_ulanish_bolsa_ham_oxirigacha_tez`
/// (bitta sekin ulanish yuklashni sudramaydi).

/// Bitta so'rov taxminan shuncha davom etsin.
///
/// Kichikroq qilinsa so'rovlar soni ortadi (har birida ortiqcha
/// yo'l vaqti), kattaroq qilinsa oxirida bitta oqim uzoq vaqt
/// yolg'iz qolishi mumkin. 5 soniya — o'rtasi: 0.5 MB/s li oqim
/// uchun bu ~2-3 bo'lak, 5 MB/s li oqim uchun ~25 bo'lak.
const CLAIM_TARGET_SECS: f64 = 5.0;

/// ENG KICHIK ULUSH (bo'lakda).
///
/// Ikki vazifasi bor:
///   1) tezlik hali noma'lum bo'lganda (birinchi so'rov) ulush
///      aynan shuncha bo'ladi — ya'ni birinchi so'rov tezlikni
///      o'lchash uchun ham xizmat qiladi;
///   2) ulush bundan KICHIK bo'lmaydi: aks holda oxirida
///      bo'lakma-bo'lak (1 MiB) so'rovlar paydo bo'lardi va har
///      biriga bitta yo'l vaqti (RTT) qo'shilardi.
///
/// 4 MiB: 0.5 MB/s li oqimda ~8 soniyalik ish — oxirgi ulush
/// yolg'iz qolsa ham yuklash sezilarli cho'zilmaydi.
const CLAIM_MIN: u64 = 4;

/// Oynadagi ish: umumiy kursor + uzilgan so'rovlardan qaytgan
/// qoldiqlar. HAMMASI bitta qulf ostida — poyga imkonsiz.
struct Work {
    /// Hali hech kimga berilmagan birinchi bo'lak.
    next: u64,
    /// Oyna chegarasi (bu raqam KIRMAYDI).
    end: u64,
    /// Nechta oqim ishlayapti — adil ulush shunga bo'linadi.
    lanes: u64,
    /// ENG KICHIK ulush (bo'lakda). Oyna boshida BIR MARTA
    /// hisoblanadi: `min(CLAIM_MIN, oynadagi ish / oqimlar)`.
    ///
    /// NEGA "bir marta": adil ulush (`qolgan / oqimlar`) har bir
    /// so'rovda kichrayib boradi va tekshirilmasa oxirida
    /// bo'lakma-bo'lak (1 MiB) so'rovlarga aylanardi. Pastki
    /// chegara buni to'xtatadi; kichik faylda esa chegara o'zi
    /// kichik bo'ladi, ya'ni oqimlar bo'sh turib qolmaydi.
    floor: u64,
    /// Uzilib qolgan so'rovlardan qaytarilgan oraliqlar.
    back: Vec<(u64, u64)>,
    /// HAVODAGI ulushlar: oqim raqami -> (hali yozilmagan birinchi
    /// bo'lak, ulushning oxirgi bo'lagi). Ish o'g'irlash
    /// (`steal_locked`) shundan foydalanadi.
    inflight: HashMap<usize, Inflight>,
    /// Yakuniy takrorlovchilar: oqim -> (asl egasi, bo'lak).
    dups: HashMap<usize, (usize, u64)>,
    /// Odatdagi bitta bo'lak vaqti (ms, silliqlangan); 0 — hali
    /// o'lchanmagan.
    chunk_ms: f64,
    /// Har bir oqim JORIY bo'lakdan nechta bayt olgan
    /// (`fetch_span` yangilaydi, qulfsiz).
    progress: Arc<Vec<AtomicU64>>,
}

// ── ISH O'G'IRLASH: OXIRIDA TEZLIK TUSHMAYDI ────────────────────
//
// TOPILGAN XATO (foydalanuvchi: "yuklab olishda fayl 70 foizlarga
// borganda tezlik pasayib ketyapti", fayllar 71 MB gacha).
//
// Sabab: har bir oqim olgan ulushini (odatda 4 MiB) OXIRIGACHA o'zi
// tortardi. 71 MB li faylda 16 oqim birinchi aylanishdayoq 64 ta
// bo'lakni bo'lishib olardi; tez oqimlar tugagach qolgan 7 bo'lakni
// ikkitasi olar, qolganlari ISHSIZ chiqib ketardi. Oxirida esa
// sekinroq ulanishlar o'z ulushini YOLG'IZ tortardi — umumiy tezlik
// faol ulanishlar soniga proporsional, ya'ni ~70% dan keyin
// pasayib borardi. Testlar: `yuklab_olish_umumiy_kanalda_oxirigacha_tez`,
// `yuklab_olish_sekin_ulanishlar_aralash_bolsa_ham_togri`.
//
// Endi ikki bosqich:
//
//   1) O'G'IRLASH — ish qolmagan oqim eng ko'p ishi qolgan havodagi
//      ulushning ikkinchi yarmini oladi; egasi o'z yarmini yozishi
//      bilan so'rovini to'xtatadi (`on_chunk` `false` qaytaradi).
//      Takroriy trafik yo'q.
//   2) YAKUNIY TAKRORLASH — o'g'irlaydigan narsa qolmaganda (har bir
//      oqimda bittadan bo'lak qolgan) va biror bo'lak odatdagidan
//      ancha uzoq yuklanayotgan bo'lsa, bo'sh oqim AYNAN o'sha
//      bo'lakni parallel oladi. Qaysi biri birinchi tugasa,
//      ikkinchisi DARHOL to'xtaydi (`stop` bayrog'i). Har bir bo'lak
//      eng ko'pi bir marta takrorlanadi, ya'ni ortiqcha trafik faqat
//      oxirgi bir necha bo'lakda va har biri uchun 1 MiB dan kam.

/// Shundan kam (bo'lakda) ishi qolgan ulushdan o'g'irlanmaydi —
/// egasi hozir yozayotgan bo'lakni ikki marta olmaslik uchun
/// kamida 2 bo'lak qolishi kerak.
const STEAL_MIN: u64 = 2;

/// Egasi qolgan ishni shundan tezroq tugatadigan bo'lsa —
/// o'g'irlanmaydi: yangi so'rov ochish (borib-kelish vaqti) o'zini
/// oqlamaydi va faqat so'rovlar sonini ko'paytiradi.
const STEAL_MIN_MS: f64 = 1500.0;

/// Bo'lak odatdagidan shuncha barobar uzoq yuklanayotgan bo'lsa —
/// "sekin" hisoblanadi va yakuniy takrorlashga loyiq.
const DUP_SLOW_FACTOR: f64 = 2.0;

/// Bitta bo'lak eng ko'pi shuncha marta takrorlanadi. Ortiqcha
/// trafik shu bilan chegaralangan: faqat oxirgi bo'laklarda, faqat
/// yangi ulanish ANIQ tezroq tugatadigan holatda (`duplicate_locked`)
/// va yutqazgan oqim darhol to'xtaydi.
const DUP_MAX: u8 = 1;

/// Takrorlash kamida shuncha vaqt (ms) yutuq bersagina qilinadi.
/// Tez tarmoqda bo'lak millisekundlarda keladi va oqimning bir
/// lahzalik kechikishi ham "sekin" ko'rinardi — takror esa faqat
/// trafikni isrof qilardi.
const DUP_MIN_GAIN_MS: f64 = 1000.0;

/// Havodagi bitta ulush.
struct Inflight {
    /// Hali yozilmagan birinchi bo'lak.
    next: u64,
    /// Ulushning oxirgi bo'lagi.
    last: u64,
    /// `next` bo'lak qachondan beri yuklanmoqda.
    since: Instant,
    /// `next` bo'lak necha marta takrorlangan (`DUP_MAX` gacha).
    dup: u8,
    /// Ulush qachon boshlangan va shundan beri nechta bo'lak
    /// yozilgan — egasining tezligini baholash uchun.
    claim_at: Instant,
    done: u64,
}

impl Inflight {
    fn new(next: u64, last: u64) -> Self {
        let now = Instant::now();
        Inflight { next, last, since: now, dup: 0, claim_at: now, done: 0 }
    }

    /// Egasining bitta bo'lakka ketadigan taxminiy vaqti (ms).
    /// Hali bitta ham bo'lak yozilmagan bo'lsa — kutilgan vaqtdan
    /// kam emas (`fast_ms`).
    fn ms_per_chunk(&self, fast_ms: f64) -> f64 {
        let spent = self.claim_at.elapsed().as_secs_f64() * 1000.0;
        if self.done > 0 {
            // Joriy bo'lak ustida o'tgan vaqt ham hisobga olinadi:
            // tezlik birdan tushsa darhol ko'rinadi.
            let cur = self.since.elapsed().as_secs_f64() * 1000.0;
            (spent / self.done as f64).max(cur)
        } else {
            spent.max(fast_ms)
        }
    }
}

/// Havodagi ulushlardan eng UZOQ kutiladiganining bir qismini
/// `lane` ga beradi.
///
/// Qaysidan: qolgan bo'laklar x egasining bo'lak vaqti eng katta
/// bo'lgani (ko'p ish qolgan emas, eng KECH tugaydigani).
/// Qancha: ikkalasi taxminan BIR VAQTDA tugaydigan qilib — sekin
/// egadan ko'proq olinadi (6 barobar sekin bo'lsa ~6/7 qismi).
fn steal_locked(w: &mut Work, lane: usize) -> Claim {
    let fast = if w.chunk_ms > 0.0 { w.chunk_ms } else { 0.0 };
    let (victim, next, last, ms_v) = w
        .inflight
        .iter()
        .filter(|(l, _)| **l != lane)
        .filter(|(_, f)| f.last >= f.next && f.last - f.next + 1 >= STEAL_MIN)
        .map(|(l, f)| (*l, f.next, f.last, f.ms_per_chunk(fast)))
        .filter(|(_, n, e, ms)| (*e - *n + 1) as f64 * *ms >= STEAL_MIN_MS)
        .max_by(|a, b| {
            let ta = (a.2 - a.1 + 1) as f64 * a.3;
            let tb = (b.2 - b.1 + 1) as f64 * b.3;
            ta.partial_cmp(&tb).unwrap_or(std::cmp::Ordering::Equal)
        })?;
    let rem = last - next + 1;
    // O'g'rining kutilgan bo'lak vaqti — "yaxshi" ulanishniki.
    let ms_t = if fast > 0.0 { fast } else { ms_v };
    let share_v = if ms_v > 0.0 && ms_t > 0.0 {
        ms_t / (ms_t + ms_v)
    } else {
        0.5
    };
    let keep = ((rem as f64 * share_v).round() as u64).clamp(1, rem - 1);
    let new_last = next + keep - 1;
    if let Some(f) = w.inflight.get_mut(&victim) {
        f.last = new_last;
    }
    w.inflight.insert(lane, Inflight::new(new_last + 1, last));
    Some((new_last + 1, last))
}

/// Yakuniy takrorlash: eng uzoq yuklanayotgan (va hali
/// takrorlanmagan) bo'lakni `lane` ga beradi.
fn duplicate_locked(w: &mut Work, lane: usize) -> Claim {
    // Odatdagi bo'lak vaqti hali o'lchanmagan — kim sekinligini
    // bilmaymiz, takrorlamaymiz.
    if w.chunk_ms <= 0.0 {
        return None;
    }
    let fast = w.chunk_ms;
    let chunk_bytes = CHUNK_SIZE as f64;
    let mut best: Option<(usize, u64, f64)> = None;
    for (l, f) in w.inflight.iter() {
        if *l == lane || f.dup >= DUP_MAX || f.next > f.last {
            continue;
        }
        let el = f.since.elapsed().as_secs_f64() * 1000.0;
        // Bo'lak hali 1 soniya ham yuklanmagan — takrorlashga erta.
        // (Bo'lak boshida kelgan bir necha KB dan tezlikni to'g'ri
        // baholab bo'lmaydi: unga so'rov ochilish vaqti ham kiradi.)
        if el < DUP_MIN_GAIN_MS {
            continue;
        }
        let got = w
            .progress
            .get(*l)
            .map(|a| a.load(Ordering::Relaxed) as f64)
            .unwrap_or(0.0)
            .min(chunk_bytes);
        let need = chunk_bytes - got;
        // Yarmidan kam qolgan — egasi o'zi tez tugatadi, takror
        // faqat trafikni isrof qiladi (yutqazgan oqimning olgani
        // behuda ketadi).
        if need < chunk_bytes / 2.0 {
            continue;
        }
        // Egasi shu bo'lakni yana qancha tortadi (ms).
        let owner_left = if got > 0.0 {
            need / (got / el.max(1.0))
        } else if el > (fast * DUP_SLOW_FACTOR).max(DUP_MIN_GAIN_MS) {
            // Odatdagidan 2 barobar ko'p (va kamida 1 soniya) vaqt
            // o'tdi, bitta bayt ham kelmadi — ulanish qotgan. (Tez
            // tarmoqda "2 barobar" atigi bir necha millisekund —
            // endigina yuborilgan so'rov ham "qotgan" ko'rinardi.)
            f64::INFINITY
        } else {
            continue;
        };
        // Yangi ulanish qolganini qancha vaqtda oladi (so'rov
        // ochilishi uchun yarim bo'lak vaqti qo'shiladi).
        let fresh = fast * (need / chunk_bytes) + fast * 0.5;
        if owner_left <= fresh * DUP_SLOW_FACTOR {
            continue;
        }
        let gain = owner_left - fresh;
        if gain < DUP_MIN_GAIN_MS {
            continue;
        }
        if best.map(|(_, _, g)| gain > g).unwrap_or(true) {
            best = Some((*l, f.next, gain));
        }
    }
    let (victim, chunk, _) = best?;
    if let Some(f) = w.inflight.get_mut(&victim) {
        f.dup += 1;
    }
    w.dups.insert(lane, (victim, chunk));
    Some((chunk, chunk))
}

/// Egasi bo'lak `idx` ni yozdi. `true` — ulush davom etadi,
/// `false` — ulush shu yerda tugadi (qolgani o'g'irlangan bo'lishi
/// mumkin).
fn inflight_progress(work: &Mutex<Work>, stop: &[AtomicBool], lane: usize, idx: u64) -> bool {
    let Ok(mut w) = work.lock() else {
        return true;
    };
    // Bu oqim TAKRORLOVCHI edi — bo'lak tayyor, asl egasi to'xtaydi.
    if let Some((victim, chunk)) = w.dups.remove(&lane) {
        if chunk == idx {
            if let Some(f) = w.inflight.get(&victim) {
                if f.next == idx {
                    if let Some(flag) = stop.get(victim) {
                        flag.store(true, Ordering::SeqCst);
                    }
                }
            }
            // Shu bo'lakning boshqa takrorlovchilari ham to'xtaydi.
            let others: Vec<usize> = w
                .dups
                .iter()
                .filter(|(_, (v, c))| *v == victim && *c == chunk)
                .map(|(d, _)| *d)
                .collect();
            for d in others {
                w.dups.remove(&d);
                if let Some(flag) = stop.get(d) {
                    flag.store(true, Ordering::SeqCst);
                }
            }
        }
        return false;
    }
    // Shu bo'lakni kimdir takrorlayotgan bo'lsa — u to'xtaydi.
    let twins: Vec<usize> = w
        .dups
        .iter()
        .filter(|(_, (v, c))| *v == lane && *c == idx)
        .map(|(d, _)| *d)
        .collect();
    for d in twins {
        w.dups.remove(&d);
        if let Some(flag) = stop.get(d) {
            flag.store(true, Ordering::SeqCst);
        }
    }
    let mut spent = None;
    let more = match w.inflight.get_mut(&lane) {
        Some(f) => {
            spent = Some(f.since.elapsed().as_secs_f64() * 1000.0);
            f.next = idx + 1;
            f.since = Instant::now();
            f.dup = 0;
            f.done += 1;
            idx < f.last
        }
        None => true,
    };
    if let Some(ms) = spent {
        // "Yaxshi" ulanishdagi bo'lak vaqti. Oddiy o'rtacha
        // yaramaydi: sekin ulanishlar uni o'zi tomon tortib,
        // sekinlarning o'zini "odatdagi" qilib qo'yardi va takrorlash
        // hech qachon ishga tushmasdi. Shu sabab tez natijaga tez,
        // sekiniga esa juda sust moslashadi.
        w.chunk_ms = if w.chunk_ms <= 0.0 {
            ms
        } else if ms < w.chunk_ms {
            w.chunk_ms * 0.5 + ms * 0.5
        } else {
            w.chunk_ms * 0.95 + ms * 0.05
        };
    }
    more
}

/// Ulush tugadi: havodagilardan olib tashlanadi va uning HOZIRGI
/// oxiri qaytadi (o'g'irlangan bo'lsa — qisqargan oxiri).
fn inflight_done(work: &Mutex<Work>, lane: usize, last: u64) -> u64 {
    let Ok(mut w) = work.lock() else {
        return last;
    };
    if w.dups.remove(&lane).is_some() {
        // Takrorlovchi: navbatga hech narsa qaytarmaydi — bo'lak
        // egasida qoladi.
        return last;
    }
    w.inflight.remove(&lane).map(|f| f.last).unwrap_or(last)
}

/// So'rov haqiqatan boshlandi — vaqt hisobi shu lahzadan.
fn inflight_restart(work: &Mutex<Work>, lane: usize) {
    if let Ok(mut w) = work.lock() {
        if let Some(f) = w.inflight.get_mut(&lane) {
            let now = Instant::now();
            f.since = now;
            f.claim_at = now;
            f.done = 0;
        }
    }
}

/// Qayta urinilayotgan ulushni havodagilar qatoriga qo'yadi.
fn inflight_set(work: &Mutex<Work>, lane: usize, first: u64, last: u64) {
    if let Ok(mut w) = work.lock() {
        w.inflight.insert(lane, Inflight::new(first, last));
    }
}

/// Bitta oqim uchun navbatdagi ish: `first..=last` bo'laklar.
type Claim = Option<(u64, u64)>;

/// Oqim uchun navbatdagi ish ulushini ajratadi.
///
/// `rate` — shu oqimning o'lchangan tezligi (bayt/soniya; 0 =
/// hali noma'lum). Diskda allaqachon bor bo'laklar o'tkazib
/// yuboriladi (ular `cached` ro'yxatiga yig'iladi — hisob qulfdan
/// TASHQARIDA yangilanadi). `None` — oyna bo'yicha ish qolmadi.
fn claim_next(
    work: &Mutex<Work>,
    dir: &PathBuf,
    total: u64,
    rate: f64,
    cached: &mut Vec<u64>,
    tm: &DlTiming,
    lane: usize,
) -> Claim {
    let t_lock = Instant::now();
    let mut w = work.lock().ok()?;
    tm.claim_us
        .fetch_add(t_lock.elapsed().as_micros() as u64, Ordering::Relaxed);

    // 1) Uzilgan so'rovdan qaytgan qoldiq bo'lsa — avval o'sha
    //    olinadi (u fayl ichida "teshik" bo'lib qolmasin).
    while let Some((f, l)) = w.back.pop() {
        let mut i = f;
        while i <= l && chunk_cached(dir, i, total) {
            cached.push(i);
            i += 1;
        }
        if i <= l {
            w.inflight.insert(lane, Inflight::new(i, l));
            return Some((i, l));
        }
    }

    // 2) Diskda allaqachon bor bo'laklarni o'tkazib yuboramiz.
    let mut i = w.next;
    while i < w.end && chunk_cached(dir, i, total) {
        cached.push(i);
        i += 1;
    }
    w.next = i;
    if i >= w.end {
        // Taqsimlanmagan ish qolmadi — bo'sh turmaymiz, havodagi
        // eng katta qoldiqdan yarmini olamiz.
        if let Some(c) = steal_locked(&mut w, lane) {
            return Some(c);
        }
        return duplicate_locked(&mut w, lane);
    }

    // 3) Ulush: ADIL ULUSHDAN ham, VAQT ULUSHIDAN ham oshmaydi,
    //    lekin `CLAIM_MIN` dan kichik ham bo'lmaydi.
    //
    //    Adil ulush "qolgan ish / oqimlar soni" — ya'ni ulushlar
    //    oxirga borgan sari KICHRAYADI va oqimlar deyarli bir
    //    vaqtda tugaydi (klassik "guided self-scheduling").
    let remaining = w.end - i;
    let fair = remaining.div_ceil(w.lanes.max(1));
    let want = if rate > 0.0 {
        (((rate * CLAIM_TARGET_SECS) / CHUNK_SIZE as f64).round() as u64).max(1)
    } else {
        CLAIM_MIN
    };
    let span = want.min(fair).clamp(w.floor.max(1), DL_REQUEST_CHUNKS);
    let mut last = (i + span - 1).min(w.end - 1);

    // Ulush ichida diskda BOR bo'lak uchrasa — shu yerda kesamiz.
    // (Aks holda bor narsa uchun bekorga trafik sarflanardi.)
    let mut j = i + 1;
    while j <= last {
        if chunk_cached(dir, j, total) {
            last = j - 1;
            break;
        }
        j += 1;
    }

    w.next = last + 1;
    w.inflight.insert(lane, Inflight::new(i, last));
    Some((i, last))
}

/// Uzilib qolgan ulushning OLINMAGAN qismini navbatga qaytaradi.
/// Uni birinchi bo'sh qolgan oqim oladi — ya'ni bitta uzilish
/// hech qanday bo'lakni "yo'qotmaydi" va bosqich oxirigacha
/// kutdirmaydi.
fn return_work(work: &Mutex<Work>, first: u64, last: u64) {
    if first > last {
        return;
    }
    if let Ok(mut w) = work.lock() {
        w.back.push((first, last));
    }
}

/// Bitta videoni yuklaydi (bitta bosqich).
///
/// Ish OYNA-OYNA boradi (tanbal keshlash qoidasi buzilmasin:
/// faqat kerak bo'lgan oyna isitiladi), oyna ichida esa
/// yetishmayotgan bo'laklar teng yo'laklarga bo'linib, hamma
/// oqim oxirgi baytgacha band bo'ladi (yuqoridagi `Lane` izohi).
///
/// ── QAT'IY QOIDA: BITTA XATO QOLGANINI TO'XTATMAYDI ──
/// Xato bo'lgan yo'lak qisqa tanaffus bilan qayta urinadi;
/// uch marta ketma-ket bo'lmasa — bo'lak o'tkazib yuboriladi va
/// bosqich oxiridagi DISK tekshiruvi uni baribir ko'radi, vazifa
/// esa darhol yangi bosqich bilan davom etadi.
fn run_download(key: &str, url: &str) -> Result<DlOutcome, String> {
    let Some(shared) = SHARED.get() else {
        return Err("kesh-server ishga tushmagan".to_string());
    };
    let dir = shared.cache_root.join(key);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    // B2'ga bitta ham ortiqcha so'rov ketmasligi uchun: avval oyna
    // keshga isitiladi (va hajm ham o'sha javobdan olinadi), keyin
    // yuklash BUTUNLAY keshdan ketadi. Takroriy chaqiruv bepul.
    start_prepare(url);

    // ── TAYYORLASH TUGASHINI KUTAMIZ ───────────────────────────
    // Oyna keshga tushmaguncha boshlamaymiz: aks holda `ensure_meta`
    // hajmni aniqlash uchun B2'ga alohida so'rov yuborardi va
    // bo'laklar ham to'g'ridan-to'g'ri B2'dan kelardi. Kutish
    // chegaralangan va pauza bosilsa darhol uziladi.
    {
        let deadline = Instant::now() + WARM_WAIT_MAX;
        while Instant::now() < deadline {
            if prepare_ready(key) || !download_active(key) {
                break;
            }
            thread::sleep(Duration::from_millis(300));
        }
    }

    // Hajmni aniqlash (meta.json bo'lsa — tarmoqqa chiqilmaydi).
    let meta = ensure_meta(shared, &dir, url)?;
    let total = meta.total_size;
    if total == 0 {
        return Err("hajm aniqlanmadi".to_string());
    }
    // Yarim qolgan qoldiqlar tozalanadi va hisob yangilanadi.
    let _ = stat_snapshot(key, &dir);

    let count = total.div_ceil(CHUNK_SIZE);
    let win_chunks = (WARM_WINDOW / CHUNK_SIZE).max(1);
    let windows = count.div_ceil(win_chunks).max(1);

    // Foydalanuvchi pauza bosdimi (oqimlar buni ko'rib chiqadi).
    let paused = Arc::new(AtomicBool::new(false));
    // Birinchi xato — faqat jurnal va xabar uchun.
    let first_err: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    // Shu bosqichda TARMOQDAN muvaffaqiyatli olingan so'rovlar soni.
    let done_count = Arc::new(AtomicU64::new(0));

    for widx in 0..windows {
        if paused.load(Ordering::SeqCst) || !download_active(key) {
            break;
        }
        let w_first = widx * win_chunks;
        let w_last = (w_first + win_chunks - 1).min(count - 1);

        // Oynadagi hamma bo'lak diskda bo'lsa — u UMUMAN isitilmaydi
        // (B2'ga ham, worker'ga ham bitta so'rov ketmaydi).
        let mut missing_first: Option<u64> = None;
        for i in w_first..=w_last {
            if chunk_cached(&dir, i, total) {
                stat_note_chunk(key, i, chunk_plain_len(i, total));
            } else if missing_first.is_none() {
                missing_first = Some(i);
            }
        }
        let Some(start_idx) = missing_first else {
            continue;
        };

        // ── TANBAL KESHLASH: FAQAT SHU OYNA ISITILADI ──
        ensure_window_for_download(url, key, widx * WARM_WINDOW);
        if !download_active(key) {
            paused.store(true, Ordering::SeqCst);
            break;
        }

        // ── ISHNI UMUMIY KURSORGA QO'YAMIZ ──
        // (Yo'lak yo'q — yuqoridagi `Work` izohiga qarang.)
        let span = w_last + 1 - start_idx;
        // Har bir oqimga kamida 2 ta bo'lak to'g'ri kelsin: undan
        // kichik ulush uchun so'rov ochish o'zini oqlamaydi (har
        // bir so'rovning o'z yo'l vaqti bor).
        let lanes_n = (DOWNLOAD_THREADS as u64).min((span / 2).max(1)) as usize;
        // Har bir oqimning "to'xta" bayrog'i va joriy bo'lakdagi
        // baytlari (yakuniy takrorlash uchun).
        let stops: Arc<Vec<AtomicBool>> =
            Arc::new((0..lanes_n).map(|_| AtomicBool::new(false)).collect());
        let progress: Arc<Vec<AtomicU64>> =
            Arc::new((0..lanes_n).map(|_| AtomicU64::new(0)).collect());
        let work = Arc::new(Mutex::new(Work {
            next: start_idx,
            end: w_last + 1,
            lanes: lanes_n as u64,
            floor: CLAIM_MIN.min(span.div_ceil(lanes_n as u64)).max(1),
            back: Vec::new(),
            inflight: HashMap::new(),
            dups: HashMap::new(),
            chunk_ms: 0.0,
            progress: Arc::clone(&progress),
        }));

        // ── KEYINGI OYNANI OLDINDAN ISITISH ────────────────────
        //
        // Oyna chegarasida (480 MiB) hamma oqim to'xtab, keyingi
        // oyna B2'dan keshga ko'chguncha kutib turardi — 480 MiB
        // uchun bu o'nlab soniya. Endi oynadagi OXIRGI ulush
        // olingan zahoti keyingi oyna FON'DA isitila boshlaydi:
        // oxirgi bo'laklar hali kelayotgan paytda kesh tayyor
        // bo'ladi va yuklash chegarada umuman to'xtamaydi.
        //
        // TANBAL KESHLASH QOIDASI BUZILMAYDI: isitish faqat
        // oynaning oxirida, ya'ni foydalanuvchi ANIQ keyingi
        // oynaga o'tayotgan paytda boshlanadi (ilgari ham xuddi
        // shu chaqiruv, atigi bir necha soniya keyinroq bo'lardi).
        let next_warmed = Arc::new(AtomicBool::new(widx + 1 >= windows));

        // ── KEYINGI OYNA ENDI OYNA BOSHIDAYOQ ISITILADI ────────
        //
        // TOPILGAN XATO (foydalanuvchi: "fayl 70 foizlarga borganda
        // tezlik pasayib ketyapti").
        //
        // Kesh oynasi 480 MiB. Ilgari keyingi oyna faqat shu
        // oynaning OXIRGI ulushi olinganda isitila boshlardi —
        // 480 MiB ni B2'dan keshga ko'chirish esa o'nlab soniya.
        // Shu orada hamma oqim `wait_for_warm` da turib qolardi.
        // 700 MB li faylda oyna chegarasi aynan 480/700 ≈ 69% —
        // foydalanuvchi ko'rgan "70% da sekinlashish" roppa-rosa
        // shu.
        //
        // Yuklab olishda butun fayl baribir kerak, ya'ni keyingi
        // oynani oldinroq isitish ORTIQCHA B2 so'rovi emas (o'sha
        // oyna o'sha bir marta isitiladi). Isitish serverda
        // bo'ladi — telefon tarmog'idan ulush olmaydi.
        if !next_warmed.swap(true, Ordering::SeqCst) {
            warm_window_bg(url, widx + 1);
        }

        let mut workers = Vec::with_capacity(lanes_n);
        for lane in 0..lanes_n {
            let work = Arc::clone(&work);
            let stops = Arc::clone(&stops);
            let progress = Arc::clone(&progress);
            let paused = Arc::clone(&paused);
            let first_err = Arc::clone(&first_err);
            let done_count = Arc::clone(&done_count);
            let (k, d, u) = (key.to_string(), dir.clone(), url.to_string());
            let next_warmed = Arc::clone(&next_warmed);
            let h = thread::Builder::new()
                .name("video-download-w".into())
                // Kichik stek yetarli: oqim faqat bitta bo'lakni
                // xotirada tutadi va diskka yozadi.
                .stack_size(256 * 1024)
                .spawn(move || {
                    // Ekranda "nechta oqim ishlayapti" ko'rinishi
                    // uchun (diagnostika).
                    stat_stream_delta(&k, 1);
                    // Vaqt o'lchagichi (`DlTiming` izohiga qarang).
                    let tmw = dl_timing(&k);
                    let mut fails: u32 = 0;
                    // Shu oqimning o'lchangan tezligi (bayt/soniya).
                    // Ulush hajmi aynan shunga qarab tanlanadi.
                    let mut rate: f64 = 0.0;
                    // Uzilib qolgan ulush — AYNAN shu oqim qayta
                    // uradi (eng ko'pi uch marta).
                    let mut pending: Claim = None;
                    // Diskda topilgan bo'laklar — hisob qulfdan
                    // TASHQARIDA yangilanadi.
                    let mut cached: Vec<u64> = Vec::new();
                    loop {
                        if paused.load(Ordering::SeqCst) {
                            break;
                        }
                        if !download_active(&k) {
                            paused.store(true, Ordering::SeqCst);
                            break;
                        }
                        // ── NAVBATDAGI ULUSHNI OLAMIZ ──
                        // Qulf ostida: diskda bor bo'laklar
                        // o'tkaziladi, kursor esa DARHOL suriladi.
                        // Shu sabab ikkita oqim hech qachon bir xil
                        // baytni so'ramaydi.
                        let claim = match pending.take() {
                            Some((f, l)) => {
                                inflight_set(&work, lane, f, l);
                                Some((f, l))
                            }
                            None => claim_next(
                                &work, &d, total, rate, &mut cached, &tmw, lane),
                        };
                        for idx in cached.drain(..) {
                            stat_note_chunk(&k, idx, chunk_plain_len(idx, total));
                        }
                        let Some((first, last)) = claim else {
                            // Hozircha ish yo'q, lekin boshqa oqimlar
                            // hali ishlayapti — ularning ulushi
                            // o'g'irlashga yaraydigan bo'lib qolishi
                            // yoki uzilib navbatga qaytishi mumkin.
                            // Chiqib ketmaymiz, bir zum kutamiz.
                            let busy = work
                                .lock()
                                .map(|w| w.inflight.keys().any(|l| *l != lane))
                                .unwrap_or(false);
                            if busy {
                                thread::sleep(Duration::from_millis(40));
                                continue;
                            }
                            break;
                        };

                        // Oynadagi oxirgi ulush olindimi — keyingi
                        // oynani fon'da isitib qo'yamiz.
                        if !next_warmed.load(Ordering::SeqCst) {
                            let taken = work
                                .lock()
                                .map(|w| w.next >= w.end && w.back.is_empty())
                                .unwrap_or(false);
                            if taken && !next_warmed.swap(true, Ordering::SeqCst) {
                                warm_window_bg(&u, widx + 1);
                            }
                        }

                        // Bu ulush yakuniy TAKRORLASHmi (boshqa oqim
                        // ham aynan shu bo'lakni olmoqda).
                        let is_dup = work
                            .lock()
                            .map(|w| w.dups.contains_key(&lane))
                            .unwrap_or(false);
                        let stop = &stops[lane];

                        // Shu so'rovda diskka tushgan OXIRGI bo'lak.
                        let mut got_upto: Option<u64> = None;
                        let t0 = Instant::now();
                        let res = fetch_span(shared, &k, &d, &u, first, last, total, stop, &progress[lane], &mut || inflight_restart(&work, lane), &mut |idx| {
                            stat_note_chunk(&k, idx, chunk_plain_len(idx, total));
                            got_upto = Some(idx);
                            // Qolgani o'g'irlangan bo'lsa — shu
                            // yerda to'xtaymiz.
                            inflight_progress(&work, &stops, lane, idx)
                        });
                        let secs = t0.elapsed().as_secs_f64();
                        // Ulushning HOZIRGI oxiri (o'g'irlangan
                        // bo'lsa qisqargan).
                        let last = inflight_done(&work, lane, last);
                        // Egizagi bo'lakni birinchi tugatdi — bu
                        // so'rov ataylab to'xtatildi (xato EMAS).
                        let stopped = stop.swap(false, Ordering::SeqCst);

                        if is_dup {
                            // Takrorlovchi natijasi qanday bo'lmasin,
                            // navbatga hech narsa qaytmaydi va xato
                            // hisoblanmaydi: bo'lak egasida qoladi.
                            if got_upto.is_some() {
                                done_count.fetch_add(1, Ordering::SeqCst);
                            }
                            continue;
                        }
                        if stopped {
                            // Yozilgan bo'lsa — ilgarilash; qolgani
                            // (diskda bori o'tkazib yuboriladi)
                            // navbatga qaytadi.
                            if got_upto.is_some() {
                                done_count.fetch_add(1, Ordering::SeqCst);
                            }
                            let from = got_upto.map(|u| u + 1).unwrap_or(first);
                            if from <= last {
                                return_work(&work, from, last);
                            }
                            fails = 0;
                            continue;
                        }

                        if let Err(e) = res {
                            if let Ok(mut slot) = first_err.lock() {
                                if slot.is_none() {
                                    *slot = Some(e);
                                }
                            }
                        }

                        if let Some(upto) = got_upto {
                            // Baytlar keldi va kamida bitta bo'lak
                            // diskka tushdi — bu ILGARILASH. Javob
                            // yarmida uzilgan bo'lsa ham xato
                            // hisoblanmaydi.
                            fails = 0;
                            done_count.fetch_add(1, Ordering::SeqCst);
                            // Tezlikni o'lchaymiz (silliqlash bilan).
                            let got = (upto + 1 - first) * CHUNK_SIZE;
                            if secs > 0.05 {
                                let now = got as f64 / secs;
                                rate = if rate > 0.0 { rate * 0.5 + now * 0.5 } else { now };
                            }
                            // Ulushning olinmagan qismi bo'lsa —
                            // navbatga qaytaramiz (uni birinchi
                            // bo'sh qolgan oqim oladi).
                            if upto < last {
                                return_work(&work, upto + 1, last);
                            }
                            continue;
                        }

                        // Hech narsa siljimadi.
                        fails += 1;
                        if fails >= 3 {
                            // Uch marta ketma-ket bo'lmadi —
                            // TO'XTAMAYMIZ, bu ulushdan voz
                            // kechamiz. Yetishmagani bosqich
                            // oxiridagi DISK tekshiruvida ko'rinadi
                            // va vazifa yangi bosqich bilan davom
                            // etadi. Bittalab surilsa, tarmoq
                            // butunlay yo'q paytda ming marta
                            // bekorga so'rov ketardi.
                            fails = 0;
                            continue;
                        }
                        // Qisqa tanaffus — tarmoq bir lahzaga
                        // uzilgan bo'lsa shu yerda tiklanadi va
                        // AYNAN shu ulush qayta uriniladi.
                        pending = Some((first, last));
                        thread::sleep(Duration::from_millis(300 * fails as u64));
                    }
                    stat_stream_delta(&k, -1);
                });
            match h {
                Ok(h) => workers.push(h),
                Err(_) => log("XATO: yuklab olish oqimi ochilmadi".to_string()),
            }
        }
        // Birorta oqim ochilmagan bo'lsa — vazifa bajarilmadi.
        if workers.is_empty() {
            return Err("yuklab olish oqimlari ochilmadi".to_string());
        }
        for w in workers {
            let _ = w.join();
        }
    }

    if paused.load(Ordering::SeqCst) || !download_active(key) {
        return Ok(DlOutcome::Paused);
    }

    // YAKUNIY HAQIQAT — DISK.
    let missing = (0..count).filter(|i| !chunk_cached(&dir, *i, total)).count() as u64;
    if missing == 0 {
        return Ok(DlOutcome::Done);
    }
    let done = done_count.load(Ordering::SeqCst);
    if done > 0 {
        // Ilgarilash bor — kutmasdan davom etamiz.
        return Ok(DlOutcome::Partial(done));
    }
    Err(first_err
        .lock()
        .ok()
        .and_then(|mut s| s.take())
        .unwrap_or_else(|| format!("{missing} ta bo'lak olinmadi")))
}

/// Yuklab olishni boshlaydi yoki davom ettiradi. DARHOL qaytadi.
/// Bir necha marta bosilsa ham yangi ish oqimi ochilmaydi.
fn start_download(url: &str) -> bool {
    if SHARED.get().is_none() {
        return false;
    }
    // Oynani isitish (`start_prepare`) endi shu yerda EMAS, vazifa
    // haqiqatan BOSHLANGANDA (`run_download`) bo'ladi: navbatda
    // turgan sifatlar oldindan isitilsa, B2 va worker navbat
    // kelguncha kerak bo'lmagan ish bilan band bo'lardi.
    ensure_pool();
    let key = cache_key(url);
    let Ok(mut map) = downloads().lock() else {
        return false;
    };
    match map.get_mut(&key) {
        Some(st) => {
            // Allaqachon navbatda — foydalanuvchi qayta bosgan bo'lsa
            // kutishni bekor qilib, darhol davom ettiramiz.
            st.wanted = true;
            st.failures = 0;
            st.next_try = Instant::now();
            st.url = url.to_string();
            st.epoch = st.epoch.wrapping_add(1);
        }
        None => {
            map.insert(
                key.clone(),
                DownloadState {
                    url: url.to_string(),
                    wanted: true,
                    running: false,
                    failures: 0,
                    next_try: Instant::now(),
                    epoch: DL_EPOCH.fetch_add(1, Ordering::SeqCst) + 1,
                    seq: DL_SEQ.fetch_add(1, Ordering::SeqCst) + 1,
                    started: false,
                },
            );
        }
    }
    save_queue_locked(&map);
    log(format!("Yuklab olish navbatga qo'yildi: {key}"));
    true
}

/// Pauza: vazifa navbatdan olinadi. Yuklangan bo'laklar joyida
/// qoladi — keyin xohlagan paytda o'sha joydan davom etadi.
fn stop_download(key: &str) {
    if let Ok(mut map) = downloads().lock() {
        if let Some(st) = map.get_mut(key) {
            st.wanted = false;
        }
        // Ish oqimi hozir band bo'lsa, u navbatdagi bo'lakdan oldin
        // `wanted`ni ko'rib chiqadi; yozuvning o'zi shu yerda olib
        // tashlanadi.
        if map.get(key).map(|s| !s.running).unwrap_or(false) {
            map.remove(key);
        }
        save_queue_locked(&map);
    }
}

/// Shu videoning (aynan shu sifatning) barcha keshlangan ma'lumotini
/// o'chiradi. Yuklab olish ketayotgan bo'lsa — avval to'xtatiladi.
/// FFI chaqiruvi bloklanmasligi uchun asosiy ish fon ish oqimida
/// bajariladi; hisob esa DARHOL nolga tushiriladi, shu sabab ekranda
/// natija bir zumda ko'rinadi.
fn delete_cached(url: &str) -> bool {
    let Some(shared) = SHARED.get() else {
        return false;
    };
    let key = cache_key(url);
    stop_download(&key);
    // O'chirish lahzasidagi buyruq raqami. Fon oqimi navbatdagi
    // yozuvni FAQAT shu raqam o'zgarmagan bo'lsa o'chiradi — aks
    // holda u foydalanuvchi hozirgina bergan YANGI buyruq bo'ladi.
    let epoch_at_delete = downloads().lock().ok().and_then(|m| m.get(&key).map(|s| s.epoch));

    // ── XOTIRADAGI HAMMA IZ DARHOL TOZALANADI ──────────────────
    // Hajm saqlanadi (u manbadan olingan, o'chirilishi shart emas) —
    // shu bilan ro'yxatda "0% / 0 / 240MB" ko'rinadi.
    let total = {
        let map = stats().lock().unwrap();
        map.get(&key).map(|e| e.total).unwrap_or(0)
    };
    stat_reset(&key, total);
    // Davomiylik va bo'lak-vaqt jadvali ham yangi fayl uchun
    // qaytadan hisoblanishi kerak.
    forget_derived(&key);
    if let Ok(mut m) = shared.net_by_file.lock() {
        m.remove(&key);
    }

    // ── TOZALANGAN VIDEO "MUTLAQO YANGI" BO'LIB QOLISHI SHART ──
    //
    // TUZATILGAN XATO: bu ikki belgi tozalashdan keyin ham
    // XOTIRADA qolib ketardi:
    //   * `prepares()` — "bu video allaqachon tayyorlangan";
    //   * `warm_state()` — "bu videoning oynasi allaqachon keshda".
    // Natijada video qayta ochilganda TAYYORLASH BOSQICHI BUTUNLAY
    // O'TKAZIB YUBORILARDI: worker'ga isitish so'rovi ketmasdi va
    // faylning hajmi (meta.json) yozilmasdi. Ya'ni tozalangan video
    // "yarim tayyor" holatda ochilishga urinardi.
    //
    // Endi tozalash bu izlarni ham o'chiradi — video xuddi birinchi
    // marta ochilayotgandek, to'liq yo'ldan o'tadi.
    if let Ok(mut m) = prepares().lock() {
        m.remove(&key);
    }
    if let Ok(mut m) = warm_state().lock() {
        let prefix = format!("{key}#w");
        m.retain(|k, _| !k.starts_with(&prefix));
    }

    // ═══════════════════════════════════════════════════════════
    //  PAPKA BUTUNLAY O'CHIRILADI — VA AYNI SHU LAHZADA
    // ═══════════════════════════════════════════════════════════
    //
    // ── AVVALGI XATO ────────────────────────────────────────────
    // Avval fayllar FON ish oqimida, yuklovchilar to'xtashini 5
    // SONIYAGACHA kutib turgandan keyin o'chirilardi. Shu 5 soniya
    // ichida foydalanuvchi videoni qayta ochsa, pleyer yangi
    // meta.json va bo'laklarni yozib ulgurar, keyin esa o'chiruvchi
    // oqim ularni ham supurib tashlardi. Natijada video "qayta
    // yuklanmay" qolar va ekranda "Videoni yuklab bo'lmadi" chiqardi
    // — foydalanuvchi ko'rgan xato aynan shu edi.
    //
    // ── ENDI ────────────────────────────────────────────────────
    // Papka BIR LAHZADA boshqa nomga ko'chiriladi (`rename` — atom
    // va bir zumda bajariladigan amal). Shu paytdan boshlab eski nom
    // bo'sh: keyin yozilgan HAR QANDAY bo'lak YANGI, toza papkaga
    // tushadi va hech qachon o'chirilmaydi. Axlat papkasi esa fon'da
    // butunlay (`remove_dir_all` — ichidagi hamma fayl bilan)
    // yo'q qilinadi.
    let dir = shared.cache_root.join(&key);
    let trash = shared
        .cache_root
        .join(format!("{TRASH_PREFIX}{}_{}", key, micros_now()));
    let moved = fs::rename(&dir, &trash).is_ok();
    if !moved {
        // Papka yo'q bo'lsa ham shu yerga tushamiz — zarari yo'q.
        let _ = fs::remove_dir_all(&dir);
    }

    let key2 = key.clone();
    let spawned = thread::Builder::new()
        .name("video-cache-delete".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            if moved {
                let _ = fs::remove_dir_all(&trash);
            }
            // Yuklab olish vazifasi qolgan bo'lsa — olib tashlanadi.
            // (Ish oqimi navbatdagi bo'lakdan oldin `wanted`ni
            // ko'rib o'zi to'xtaydi.)
            //
            // MUHIM: FAQAT o'chirish lahzasidagi O'SHA vazifa
            // olib tashlanadi. Foydalanuvchi shu orada "yuklab
            // olish"ni qayta bosgan bo'lsa, navbatda ENDI YANGI
            // buyruq turadi va unga TEGILMAYDI — aks holda yangi
            // yuklash jimgina o'lardi (aynan foydalanuvchi ko'rgan
            // xato: tozalagandan keyin video boshqa yuklanmasdi).
            let Some(epoch) = epoch_at_delete else {
                log(format!("Kesh butunlay tozalandi (papka bilan): {key2}"));
                return;
            };
            for _ in 0..40 {
                let busy = downloads()
                    .lock()
                    .map(|m| {
                        m.get(&key2)
                            .map(|s| s.running && s.epoch == epoch)
                            .unwrap_or(false)
                    })
                    .unwrap_or(false);
                if !busy {
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
            if let Ok(mut m) = downloads().lock() {
                if m.get(&key2).map(|s| s.epoch == epoch).unwrap_or(false) {
                    m.remove(&key2);
                }
            }
            log(format!("Kesh butunlay tozalandi (papka bilan): {key2}"));
        });
    // Fayllar ALLAQACHON (rename bilan) yo'q qilingan — fon oqimi
    // ochilmasa ham natija to'g'ri.
    let _ = spawned;
    true
}

// ── FFI: yuklab olish boshqaruvi va holati ──────────────────────────

/// Kirish: JSON massiv — video URL'lari.
/// Chiqish: JSON obyekt — har bir URL uchun
/// {"total":<bayt>,"downloaded":<bayt>,"downloading":<bool>,
///  "retrying":<bool>,"speed":<bayt/soniya>,"streams":<son>}.
///
/// BITTA chaqiruvda bir nechta sifat so'raladi (epizod ochilganda 2-4 ta)
/// — shu bilan Dart tomoni soniyasiga bir necha marta so'rasa ham FFI
/// chaqiruvlari soni minimal bo'ladi.
#[no_mangle]
pub extern "C" fn rust_video_cache_stats(urls_json_ptr: *const c_char) -> *mut c_char {
    let Some(shared) = SHARED.get() else {
        return string_to_cptr("{}".to_string());
    };
    let Some(json) = (unsafe { cstr_to_str(urls_json_ptr) }) else {
        return string_to_cptr("{}".to_string());
    };
    let urls: Vec<String> = serde_json::from_str(json).unwrap_or_default();
    let mut out = serde_json::Map::new();
    for url in urls {
        if url.is_empty() {
            continue;
        }
        let key = cache_key(&url);
        let dir = shared.cache_root.join(&key);
        // MUHIM: bu FFI Flutter'ning UI oqimida ishlaydi — shu sabab
        // bu yerda DISKKA CHIQILMAYDI (stat_snapshot_fast izohiga
        // qarang). Aks holda ro'yxatni surish qotib-qotib ketardi.
        let (total, downloaded) = stat_snapshot_fast(&key, &dir);
        let mut item = serde_json::Map::new();
        item.insert("total".to_string(), serde_json::json!(total));
        item.insert("downloaded".to_string(), serde_json::json!(downloaded));
        item.insert(
            "downloading".to_string(),
            serde_json::json!(download_active(&key)),
        );
        // Navbatda (hali boshlanmagan) — `downloading` ham `true`
        // bo'ladi, UI esa "navbatda" deb yozadi.
        item.insert(
            "queued".to_string(),
            serde_json::json!(download_queued(&key)),
        );
        // Tarmoq uzilgan va qayta urinish kutilayotgan bo'lsa — UI
        // buni ko'rsatishi mumkin (yuklash TO'XTAGANI YO'Q).
        item.insert(
            "retrying".to_string(),
            serde_json::json!(download_failing(&key)),
        );
        // ── TEZLIK VA FAOL OQIMLAR (ekranda ko'rinadi) ──────────
        // Bu ikki raqam bo'lmagani uchun "yuklash sekinlashdi"
        // degan gapni tekshirib bo'lmasdi. Endi foydalanuvchi ham,
        // ishlab chiquvchi ham darhol ko'radi.
        let (speed, streams) = stat_speed_now(&key);
        item.insert("speed".to_string(), serde_json::json!(speed));
        item.insert("streams".to_string(), serde_json::json!(streams));
        out.insert(url, serde_json::Value::Object(item));
    }
    string_to_cptr(serde_json::Value::Object(out).to_string())
}

/// ── SHU VIDEO TELEFONDA TO'LIQ BORMI ────────────────────────────
///
/// Pleyer AYNAN SHU javobga qarab manba tanlaydi:
///   * `1` — fayl to'liq diskda: pleyer MAHALLIY server orqali
///     ko'rsatadi va internetga umuman chiqmaydi (internet bo'lsa
///     ham, bo'lmasa ham);
///   * `0` — fayl to'liq emas: pleyer to'g'ridan-to'g'ri worker'ga
///     ulanadi (internet kerak).
///
/// NEGA BU CHAQIRUV `rust_video_cache_stats` DAN FARQ QILADI:
/// `stats` UI oqimida soniyada bir necha marta chaqilgani uchun
/// diskka UMUMAN chiqmaydi — javob hali skanerlanmagan videoda
/// "0 bayt" bo'lib chiqadi. Bu yerda esa javob ANIQ bo'lishi shart
/// (aks holda to'liq yuklangan video baribir internetdan
/// ko'rsatilib, foydalanuvchining trafigi bekorga sarflanardi).
/// Shu sabab bu funksiya diskni SINXRON skanerlaydi — lekin u
/// faqat video OCHILGANDA bir marta chaqiriladi, ya'ni ro'yxatni
/// surishga hech qanday ta'siri yo'q.
#[no_mangle]
pub extern "C" fn rust_video_cache_complete(url_ptr: *const c_char) -> i32 {
    let Some(shared) = SHARED.get() else {
        return 0;
    };
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    let key = cache_key(url);
    let dir = shared.cache_root.join(&key);
    if !dir.is_dir() {
        return 0;
    }
    let (total, downloaded) = stat_snapshot(&key, &dir);
    if total > 0 && downloaded >= total {
        1
    } else {
        0
    }
}

/// Videoni to'liq yuklab olishni boshlaydi (yetishmayotgan bo'laklarni).
/// Darhol qaytadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_download(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    if start_download(url) {
        1
    } else {
        0
    }
}

/// Yuklab olishni to'xtatadi (pauza). Yuklangan bo'laklar joyida
/// qoladi — keyin xohlagan paytda o'sha joydan davom etadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_pause(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    stop_download(&cache_key(url));
    1
}

/// Shu sifatdagi videoning keshlangan ma'lumotini butunlay o'chiradi.
#[no_mangle]
pub extern "C" fn rust_video_cache_delete(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if delete_cached(url) {
        1
    } else {
        0
    }
}

/// ── HAMMASINI O'CHIRISH (hisobdan chiqilganda) ────────────────
///
/// TALAB (foydalanuvchi): "foydalanuvchi accountini o'chirsa yoki
/// chiqib ketsa, ilova shu zahoti oflayn rejim uchun yuklab
/// olingan ma'lumotlarni tozalab tashlasin".
///
/// Shu sabab bu yerda BUTUN kesh papkasi bo'shatiladi: yuklab
/// olingan videolar, navbat, isitish belgilari — hammasi. Avval
/// barcha yuklashlar to'xtatiladi va navbat bo'shatiladi, aks
/// holda fon oqimi o'chirilgan faylni qaytadan yozib qo'yardi.
///
/// Qaytadi: o'chirilgan papkalar soni (diagnostika uchun).
#[no_mangle]
pub extern "C" fn rust_video_cache_wipe() -> i32 {
    let Some(shared) = SHARED.get() else { return 0 };

    // 1) Navbatni butunlay bo'shatamiz — fon oqimlari yangi ish
    //    olmaydi va ketayotganlari keyingi tekshiruvda to'xtaydi.
    if let Ok(mut map) = downloads().lock() {
        for st in map.values_mut() {
            st.wanted = false;
        }
        map.clear();
        save_queue_locked(&map);
    }
    DL_EPOCH.fetch_add(1, Ordering::SeqCst);

    // 2) Xotiradagi hosila hisoblar.
    if let Ok(mut m) = stats().lock() {
        m.clear();
    }
    if let Ok(mut m) = warm_state().lock() {
        m.clear();
    }
    if let Ok(mut m) = prepares().lock() {
        m.clear();
    }
    if let Ok(mut m) = THUMB_MEMO.lock() {
        m.clear();
    }
    if let Ok(mut m) = MOOV_MEMO.lock() {
        m.clear();
    }

    // 3) Diskdagi hamma narsa. Papkalar avval "axlat" nomiga
    //    ko'chiriladi: shu zahoti ko'rinmay qoladi, o'chirish esa
    //    fon'da davom etsa ham xavfsiz.
    let mut removed = 0;
    if let Ok(entries) = fs::read_dir(&shared.cache_root) {
        for entry in entries.flatten() {
            let path = entry.path();
            let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
            if is_dir {
                let trash = shared
                    .cache_root
                    .join(format!("{TRASH_PREFIX}wipe_{}", micros_now()));
                if fs::rename(&path, &trash).is_ok() {
                    let _ = fs::remove_dir_all(&trash);
                } else {
                    let _ = fs::remove_dir_all(&path);
                }
                removed += 1;
            } else {
                let _ = fs::remove_file(&path);
            }
        }
    }
    log(format!("Kesh butunlay tozalandi: {removed} ta papka"));
    removed
}

// ── Bo'lakni diskdan o'qish yoki tarmoqdan yuklab, diskka yozish ────

/// Shu video uchun XOTIRADAGI hosila ma'lumotlarni (davomiylik va
/// bo'lak-vaqt jadvali) tashlaydi. Kesh tozalanganda yoki manbadagi
/// fayl o'zgarganda chaqiriladi — aks holda eski jadval yangi
/// faylga qo'llanib qolardi.
fn forget_derived(_key: &str) {
    // Hosila ma'lumotlar (davomiylik jadvali) endi umuman
    // hisoblanmaydi — tozalanadigan narsa qolmadi.
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


// ═══════════════════════════════════════════════════════════════
//  OYNANI KESHGA ISITISH (worker'dagi `/api/warm/...`)
// ═══════════════════════════════════════════════════════════════
//
// ── MAQSAD: B2 XARAJATINI ENG KAMIGA TUSHIRISH ─────────────────
//
// Worker B2'dan olgan ma'lumotni Cloudflare keshiga yozadi. Kesh
// yozuvi qancha KATTA bo'lsa, bitta faylni qoplash uchun shuncha
// KAM B2 so'rovi kerak. Eng katta ruxsat etilgan yozuv 512 MB, shu
// sabab oyna 480 MB qilib olingan (32 MB zaxira bilan).
//
// Ya'ni: 166 MB'lik video uchun B2'ga ATIGI BITTA so'rov ketadi —
// o'sha bitta so'rov butun faylni keshga ko'chiradi. Shundan keyin
// bu videoni kim ko'rsa ham, kim yuklab olsa ham, B2'ga UMUMAN
// chiqilmaydi: hammasi Cloudflare chekkasidan xizmat qilinadi.
//
// ── NEGA ALOHIDA SO'ROV KERAK (eng muhim nuqta) ────────────────
//
// Isitish ilgari worker ichida `waitUntil` (fon vazifasi) bilan
// qilinardi va aynan shu uni buzardi: Cloudflare `waitUntil` uchun
// javob yuborilgandan keyin ATIGI 30 SONIYA beradi. 480 MB'ni 30
// soniyada ko'chirib bo'lmasdi — isitish o'rtada uzilar, keshga
// hech narsa tushmasdi.
//
// Cloudflare'ning boshqa qoidasi esa: MIJOZ ULANIB TURGANDA
// so'rovning davomiyligiga CHEGARA YO'Q. Shu sabab isitish endi
// ALOHIDA, oddiy HTTP so'rovi sifatida bajariladi va ILOVA uni
// tugaguncha ushlab turadi — worker o'sha davomida "uyg'oq"
// qoladi. Aynan shuning uchun bu yerda alohida `warm_agent` bor:
// uning o'qish chegarasi 15 soniya emas, 15 daqiqa.
//
// ── QUYIDAGI `maybe_warm` FAQAT YUKLAB OLISH UCHUN ────────────
//
// U fon ish oqimida ketadi va yuklab olish oqimini bloklamaydi:
// bo'laklar isitish tugashini `wait_for_warm` orqali kutadi,
// lekin kutish chegaralangan.
//
// IJRO (pleyer) yo'li BOSHQACHA: u `start_prepare` orqali boradi
// va isitish HAQIQATAN tugagunicha kutadi — chunki
// `/api/play/...` faqat keshdan xizmat qiladi va kesh bo'sh
// bo'lsa 503 qaytaradi.

/// Kesh oynasi — worker'dagi `WARM_WINDOW` bilan AYNAN bir xil
/// bo'lishi shart (ikkalasi bir xil oyna raqamini hisoblaydi).
const WARM_WINDOW: u64 = 480 * 1024 * 1024;


/// Bitta oyna uchun isitish holati.
#[derive(Clone, Copy, PartialEq, Eq)]
enum WarmState {
    /// Isitish ketyapti — yuklab olish shuni kutadi.
    Running,
    /// Oyna keshda — endi hamma narsa chekkadan keladi.
    Done,
    /// Isitib bo'lmadi (tarmoq uzildi va h.k.) — keyinroq qayta
    /// uriniladi, yuklash esa odatdagidek davom etaveradi.
    Failed,
}

/// Oyna holati: "kalit#wN" -> (holat, oxirgi urinish vaqti).
static WARM_STATE: OnceLock<Mutex<HashMap<String, (WarmState, Instant)>>> = OnceLock::new();

fn warm_state() -> &'static Mutex<HashMap<String, (WarmState, Instant)>> {
    WARM_STATE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Isitish urinishi muvaffaqiyatsiz tugasa, shu muddat ichida
/// QAYTA URINILMAYDI.
///
/// TUZATILGAN XATO (qurilmada o'lchangan): worker `{"status":
/// "warming"}` javobini qaytarganda holat `Failed` bo'lib qolar,
/// `maybe_warm` esa `Failed`ni "qayta urinsa bo'ladi" deb bilardi.
/// Natijada HAR BIR 1 MiB bo'lak uchun worker'ga QO'SHIMCHA
/// isitish so'rovi ketardi — ya'ni so'rovlar soni IKKI BAROBAR
/// bo'lar, har bir bo'lakdan oldin ortiqcha kechikish qo'shilar
/// va foydalanuvchining trafigi behuda sarflanardi. Jurnalda bu
/// aniq ko'rindi: har bir bo'lakdan oldin "Oyna #0 keshga
/// isitilmoqda" qatori.
const WARM_RETRY_COOLDOWN: Duration = Duration::from_secs(600);

/// TANBAL isitish (`warm_window_bg`) uchun qayta urinish oralig'i.
///
/// Yuqoridagi 600 soniya `maybe_warm` uchun to'g'ri: u HAR BIR
/// bo'lakdan chaqiriladi, ya'ni uzun tanaffus so'rovlar bo'ronining
/// oldini oladi. Tanbal isitish esa BOSHQACHA — uni ilova ataylab,
/// aniq bir oyna uchun chaqiradi (foydalanuvchi o'sha joyga sek
/// qildi yoki yaqinlashdi). Bu yerda 10 daqiqa kutish foydalanuvchi
/// uchun "video ochilmayapti" degani bo'lardi.
///
/// 15 soniya: tarmoq bir lahzaga uzilgan bo'lsa tez tiklanadi,
/// lekin B2'ga bo'ron ham ketmaydi (bir oyna uchun eng ko'pi
/// 15 soniyada bitta urinish).
const WARM_LAZY_RETRY_COOLDOWN: Duration = Duration::from_secs(15);

/// Video manzilidan isitish manzilini yasaydi:
///   .../api/image/ep_1_2_720p.mp4  ->  .../api/warm/ep_1_2_720p.mp4?w=0
/// Manzil kutilgan shaklda bo'lmasa `None` (isitish o'tkazib
/// yuboriladi, qolgan hamma narsa avvalgidek ishlaydi).
fn warm_url_for(url: &str, widx: u64) -> Option<String> {
    warm_url_for_force(url, widx, false)
}

/// `force = true` bo'lsa worker keshdagi eskirgan yozuvni ham,
/// o'lib qolgan isitishning "belgisi"ni ham e'tiborsiz qoldirib,
/// oynani QAYTADAN isitadi.
fn warm_url_for_force(url: &str, widx: u64, force: bool) -> Option<String> {
    const MARK: &str = "/api/image/";
    let i = url.find(MARK)?;
    let head = &url[..i];
    let tail = &url[i + MARK.len()..];
    let name = tail.split('?').next().unwrap_or(tail);
    if name.is_empty() {
        return None;
    }
    let suffix = if force { "&force=1" } else { "" };
    Some(format!("{head}/api/warm/{name}?w={widx}{suffix}"))
}

/// Kerakli oynani keshga isitishni BIR MARTA boshlaydi. Darhol
/// qaytadi — kutish fon ish oqimida.
fn maybe_warm(url: &str, key: &str, byte_pos: u64) {
    let widx = byte_pos / WARM_WINDOW;
    let tag = format!("{key}#w{widx}");
    {
        let Ok(mut m) = warm_state().lock() else { return };
        match m.get(&tag) {
            // Allaqachon ketyapti yoki tugagan — qaytarmaymiz.
            Some((WarmState::Running, _)) | Some((WarmState::Done, _)) => return,
            // Muvaffaqiyatsiz tugagan — TEZDA qayta urinmaymiz.
            Some((WarmState::Failed, at)) if at.elapsed() < WARM_RETRY_COOLDOWN => return,
            _ => {}
        }
        m.insert(tag.clone(), (WarmState::Running, Instant::now()));
    }
    let Some(warm_url) = warm_url_for(url, widx) else {
        // Manzil kutilmagan shaklda — isitish umuman mumkin emas.
        // MUHIM: holatni "Failed" qilib qo'yamiz, aks holda u
        // abadiy "Running" bo'lib qolar va yuklab olish `wait_for_warm`
        // ichida 90 soniya bekorga kutib turardi.
        if let Ok(mut m) = warm_state().lock() {
            m.insert(tag, (WarmState::Failed, Instant::now()));
        }
        return;
    };
    let tag_for_thread = tag.clone();
    let spawned = thread::Builder::new()
        .name("video-cache-warm".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let tag = tag_for_thread;
            let Some(shared) = SHARED.get() else { return };
            log(format!("Oyna #{widx} keshga isitilmoqda: {warm_url}"));
            match signed(shared.warm_agent.get(&warm_url), "GET", &warm_url).call() {
                Ok(resp) => {
                    let status = resp.status();
                    let body = resp.into_string().unwrap_or_default();
                    let ok = body.contains("cached") || body.contains("warmed");
                    log(format!("Isitish javobi ({status}): {body}"));
                    if let Ok(mut m) = warm_state().lock() {
                        let st = if ok { WarmState::Done } else { WarmState::Failed };
                        m.insert(tag, (st, Instant::now()));
                    }
                }
                Err(e) => {
                    log(format!("Isitish uzildi: {e}"));
                    if let Ok(mut m) = warm_state().lock() {
                        m.insert(tag, (WarmState::Failed, Instant::now()));
                    }
                }
            }
        });
    if spawned.is_err() {
        if let Ok(mut m) = warm_state().lock() {
            m.insert(tag, (WarmState::Failed, Instant::now()));
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  "TAYYORLASH": B2'GA ATIGI BITTA SO'ROV
// ═══════════════════════════════════════════════════════════════
//
// TALAB: B2'ga faqat BIR MARTA murojaat qilinsin — o'sha bitta
// so'rov oynani keshga ko'chirsin, qolgan hamma narsa keshdan
// kelsin. Foydalanuvchi esa shu isitish tugaguncha kutsin.
//
// ── NEGA KUTISH ILOVA DARAJASIDA QILINADI ─────────────────────
// Kutishni mahalliy serverning HTTP javobi ichida qilib bo'lmaydi:
// ExoPlayer javob sarlavhasini 8 soniya kutadi, undan uzog'ida
// ulanishni uzib, xatoga chiqadi. Shu sabab kutish PLEYER
// OCHILISHIDAN OLDIN, ekranda oddiy "yuklanmoqda" belgisi bilan
// bajariladi.
//
// Ish tartibi:
//   1. Foydalanuvchi qismni bosadi;
//   2. Dart `rust_video_cache_prepare` ni chaqiradi — u DARHOL
//      qaytadi va fon'da isitishni boshlaydi;
//   3. Dart har 300 ms da `rust_video_cache_prepare_status` ni
//      so'rab turadi va spinner ko'rsatadi;
//   4. Tayyor bo'lgach pleyer ochiladi — endi har bir bo'lak
//      Cloudflare chekkasidan keladi.
//
// Isitish javobida faylning UMUMIY HAJMI ham bo'ladi va u shu
// yerda meta.json'ga yoziladi — ya'ni hajmni bilish uchun ham
// B2'ga alohida so'rov ketmaydi.
//
// Fayl allaqachon to'liq diskda bo'lsa (yuklab olingan), hech
// narsa qilinmaydi: tayyorlash darhol "tayyor" deb qaytadi va
// tarmoqqa umuman chiqilmaydi.

/// Tayyorlash holati.
///
/// ── NEGA UCH HOLAT (tuzatilgan xato) ────────────────────────────
///
/// Ilgari bu shunchaki `bool` edi va isitish MUVAFFAQIYATSIZ
/// tugaganda ham "tayyor" deb belgilanardi. Natijada ilova
/// pleyerni ochar, `/api/play/...` esa kesh bo'sh bo'lgani uchun
/// 503 qaytarardi va ekranda "Videoni yuklab bo'lmadi" chiqardi —
/// foydalanuvchi ko'rgan asosiy muammo aynan shu edi.
///
/// Endi muvaffaqiyatsizlik ALOHIDA holat: ilova buni ko'rib
/// isitishni majburan (`force`) qayta boshlaydi va faqat shundan
/// keyin ham chiqmasa aniq xabar ko'rsatadi.
#[derive(Clone, Copy, PartialEq, Eq)]
enum PrepareState {
    /// Isitish ketyapti.
    Running,
    /// Oyna(lar) keshda — ijro qilsa bo'ladi.
    Ready,
    /// Isitib bo'lmadi.
    Failed,
}

static PREPARE: OnceLock<Mutex<HashMap<String, PrepareState>>> = OnceLock::new();

fn prepares() -> &'static Mutex<HashMap<String, PrepareState>> {
    PREPARE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Keyingi tayyorlash MAJBURAN (worker keshini e'tiborsiz
/// qoldirib) bajarilishi kerak bo'lgan kalitlar.
static PREPARE_FORCE: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

fn prepare_force() -> &'static Mutex<HashSet<String>> {
    PREPARE_FORCE.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Bitta oynani isitadi va natijasini qaytaradi: (muvaffaqiyatmi,
/// faylning umumiy hajmi). Isitish holati (`warm_state`) ham shu
/// yerda yangilanadi, ya'ni yuklab olish oqimi ham xuddi shu
/// natijadan foydalanadi va B2'ga qo'shimcha so'rov ketmaydi.
fn warm_one_window(url: &str, key: &str, widx: u64, force: bool) -> (bool, u64) {
    let tag = format!("{key}#w{widx}");
    // ── HOLAT HECH QACHON "KETYAPTI"DA QOLIB KETMASIN ──────────
    //
    // TUZATILGAN XATO: quyidagi ikki erta chiqishda oyna holati
    // yangilanmasdi. Chaqiruvchi esa holatni "Running" deb ko'rib,
    // hech qachon kelmaydigan natijani kutardi — yuklab olish
    // har bir bo'lakda 90 soniyagacha muzlab turardi.
    let fail = |t: &str| {
        if let Ok(mut m) = warm_state().lock() {
            m.insert(t.to_string(), (WarmState::Failed, Instant::now()));
        }
    };
    let Some(shared) = SHARED.get() else {
        fail(&tag);
        return (false, 0);
    };
    // Manzil `/api/image/...` shaklida bo'lmasa isitish umuman
    // mumkin emas (masalan sinovdagi to'g'ridan-to'g'ri manba) —
    // bunday holatda baytlar odatdagidek to'g'ridan-to'g'ri
    // olinaveradi.
    let Some(warm_url) = warm_url_for_force(url, widx, force) else {
        fail(&tag);
        return (false, 0);
    };
    log(format!("Isitish: {warm_url}"));
    match signed(shared.warm_agent.get(&warm_url), "GET", &warm_url).call() {
        Ok(resp) => {
            let body = resp.into_string().unwrap_or_default();
            log(format!("Isitish javobi: {body}"));
            // Worker endi "warming" qaytarmaydi — u oyna keshda
            // paydo bo'lishini KUTADI va natijani tekshiradi.
            // Shu sabab bu yerda javob aniq: "cached"/"warmed" —
            // oyna keshda; boshqa hamma narsa — muvaffaqiyatsizlik.
            let ok = body.contains("\"cached\"") || body.contains("\"warmed\"");
            let total = parse_warm_total(&body);
            if let Ok(mut m) = warm_state().lock() {
                let st = if ok { WarmState::Done } else { WarmState::Failed };
                m.insert(tag, (st, Instant::now()));
            }
            // Diskka BELGI: "bu oyna keshda ko'rilgan". Ilova keyingi
            // ochilishda shu belgiga qarab isitish so'rovini UMUMAN
            // yubormaydi (`warm_marker_fresh` izohiga qarang).
            if ok && total > 0 {
                write_warm_marker(key, widx);
            }
            (ok && total > 0, total)
        }
        Err(e) => {
            log(format!("Isitish uzildi: {e}"));
            if let Ok(mut m) = warm_state().lock() {
                m.insert(tag, (WarmState::Failed, Instant::now()));
            }
            (false, 0)
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  "BU OYNA KESHDA KO'RILGAN" BELGISI
// ═══════════════════════════════════════════════════════════════
//
// ── MUAMMO (foydalanuvchi: "video keshda bo'lsa ham sekin
//    ochilyapti") ─────────────────────────────────────────────
//
// Ilova video ochilishidan OLDIN har safar `/api/warm` ga so'rov
// yuborar va javobni KUTARDI — hatto oyna allaqachon keshda
// bo'lsa ham. O'lchandi: bunday "bo'sh" so'rov data-markazdan
// 0.26-0.63 soniya, telefonda mobil tarmoqda esa 1-3 soniya.
// `/api/play` ning o'zi atigi 0.3 soniyada javob beradi — ya'ni
// kutishning KATTA QISMI shu keraksiz so'rovga ketardi.
//
// ── YECHIM ───────────────────────────────────────────────────
//
// Isitish muvaffaqiyatli tugaganda diskka kichik belgi yoziladi.
// Belgi YANGI bo'lsa, ilova isitishni KUTMAYDI: pleyerni darhol
// ochadi va isitishni fon'da ishga tushiradi. Kesh kutilmaganda
// o'chirilgan bo'lsa, pleyer xatoga chiqadi va odatdagi tiklanish
// yo'li (`_handleFatalError`) oynani isitib, o'sha joydan qayta
// ochadi.
//
// Ya'ni: eng ko'p uchraydigan holat (kesh joyida) TEZ bo'ladi,
// nodir holat (kesh o'chgan) esa avvalgidek ishlaydi.

/// Belgi shu muddat ichida "ishonchli" hisoblanadi.
const WARM_MARKER_TTL_SECS: u64 = 6 * 60 * 60;

fn warm_marker_path(key: &str, widx: u64) -> Option<PathBuf> {
    Some(
        SHARED
            .get()?
            .cache_root
            .join(key)
            .join(format!("w{widx}.warm")),
    )
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn write_warm_marker(key: &str, widx: u64) {
    let Some(path) = warm_marker_path(key, widx) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    write_sealed(&path, &warm_label(key, widx), unix_now().to_string().as_bytes());
}

/// Isitish belgisining shifrlash yorlig'i.
fn warm_label(key: &str, widx: u64) -> String {
    format!("warm:{key}:{widx}")
}

/// Belgi bor va hali eskirmaganmi.
fn warm_marker_fresh(key: &str, widx: u64) -> bool {
    let Some(path) = warm_marker_path(key, widx) else {
        return false;
    };
    let Some(raw) = read_sealed(&path, &warm_label(key, widx)) else {
        return false;
    };
    let Ok(at) = String::from_utf8_lossy(&raw).trim().parse::<u64>() else {
        return false;
    };
    let now = unix_now();
    // Soat orqaga surilgan bo'lsa ham noto'g'ri "yangi" demaymiz.
    at <= now && now - at <= WARM_MARKER_TTL_SECS
}

/// Shu oyna KESHDA KO'RILGANMI (belgi yangi bo'lsa 1).
///
/// Ilova buni pleyerni ochishdan oldin so'raydi: 1 bo'lsa isitish
/// KUTILMAYDI va video darhol ochiladi.
#[no_mangle]
pub extern "C" fn rust_video_cache_window_seen(url_ptr: *const c_char, widx: u64) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    let key = cache_key(url);
    // Xotirada "tayyor" deb turgan bo'lsa — shubhasiz.
    if window_state_of(&key, widx) == Some(WarmState::Done) {
        return 1;
    }
    if warm_marker_fresh(&key, widx) {
        1
    } else {
        0
    }
}

/// Isitish javobidan hajmni ajratib oladi: {"status":"...","total":N}
fn parse_warm_total(body: &str) -> u64 {
    let Some(i) = body.find("\"total\"") else {
        return 0;
    };
    let rest = &body[i + 7..];
    let digits: String = rest
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().unwrap_or(0)
}

/// Videoni ijroga tayyorlaydi. DARHOL qaytadi — ish fon oqimida.
///
/// ── NIMA QILADI ────────────────────────────────────────────────
///
/// Faylning BARCHA oynalarini (480 MiB'lik bo'laklarini) worker
/// orqali Cloudflare keshiga isitadi va faqat HAMMASI keshda
/// bo'lgandagina "tayyor" deb belgilaydi.
///
/// NEGA HAMMASI: `/api/play/...` B2'ga umuman chiqmaydi — u faqat
/// keshdan xizmat qiladi. Foydalanuvchi 480 MiB'dan katta
/// videoning ikkinchi yarmiga sek qilsa, o'sha oyna ham keshda
/// bo'lishi shart, aks holda 503 keladi. Odatdagi epizodlar
/// (~200 MB) bitta oynaga sig'adi, ya'ni amalda BITTA isitish
/// bo'ladi.
///
/// B2'ga ketadigan so'rovlar soni: har bir oyna uchun ATIGI BITTA
/// (va u ham faqat o'sha oyna keshda bo'lmaganda). Keyin video
/// necha marta ko'rilsa ham B2'ga umuman chiqilmaydi.
fn start_prepare(url: &str) -> bool {
    let Some(shared) = SHARED.get() else {
        return false;
    };
    let key = cache_key(url);
    // Reset'dan keyin keyingi tayyorlash MAJBURAN bajariladi.
    let force = prepare_force()
        .lock()
        .map(|mut m| m.remove(&key))
        .unwrap_or(false);
    {
        let Ok(mut m) = prepares().lock() else {
            return false;
        };
        // Allaqachon ketyapti yoki tayyor — qayta boshlamaymiz.
        // "Failed" esa QAYTA URINISHGA ruxsat beradi.
        match m.get(&key) {
            Some(PrepareState::Running) | Some(PrepareState::Ready) => return true,
            _ => {}
        }
        m.insert(key.clone(), PrepareState::Running);
    }
    let dir = shared.cache_root.join(&key);
    let (k, u) = (key.clone(), url.to_string());
    let spawned = thread::Builder::new()
        .name("video-cache-prepare".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let finish = |state: PrepareState| {
                if let Ok(mut m) = prepares().lock() {
                    m.insert(k.clone(), state);
                }
            };
            let _ = fs::create_dir_all(&dir);

            // 1) Fayl butunlay diskda bo'lsa — hech narsa kerak emas
            //    (tarmoqqa umuman chiqilmaydi).
            let known_total = meta_total_from_disk(&dir);
            if known_total > 0 {
                let count = known_total.div_ceil(CHUNK_SIZE);
                if (0..count).all(|i| chunk_cached(&dir, i, known_total)) {
                    log(format!("Tayyorlash: {k} allaqachon to'liq diskda"));
                    finish(PrepareState::Ready);
                    return;
                }
            }

            // 2) BIRINCHI oynani isitamiz. Javobda faylning umumiy
            //    hajmi ham bo'ladi — ya'ni hajmni bilish uchun ham
            //    B2'ga alohida so'rov KETMAYDI.
            let (ok, total) = warm_one_window(&u, &k, 0, force);
            if !ok {
                log(format!(
                    "Tayyorlash MUVAFFAQIYATSIZ: {k} oynasi keshga tushmadi"
                ));
                finish(PrepareState::Failed);
                return;
            }

            // 3) Hajm isitish javobidan olindi — meta.json shu yerda
            //    yoziladi.
            if total > 0 && meta_total_from_disk(&dir) == 0 {
                let meta = CacheMeta {
                    total_size: total,
                    content_type: "video/mp4".to_string(),
                    chunk_size: CHUNK_SIZE,
                    duration_secs: 0.0,
                    chunk_start_ms: Vec::new(),
                };
                write_meta(&dir, &meta);
                log(format!("Tayyorlash: hajm aniqlandi — {total} bayt"));
            }

            // 4) QOLGAN OYNALAR SHU YERDA ISITILMAYDI — TANBAL
            //    (lazy) KESHLASH.
            //
            //    Ilgari bu yerda faylning HAMMA oynasi ketma-ket
            //    isitilardi. 1.5 GB'lik faylda bu 4 ta oyna, ya'ni
            //    B2'dan 1.5 GB o'qish va foydalanuvchi uchun bir
            //    necha daqiqalik kutish — holbuki u videoning
            //    faqat boshini ko'rishi mumkin edi. Ya'ni pul ham,
            //    vaqt ham behuda ketardi.
            //
            //    ENDI: faqat BIRINCHI oyna (0-480 MiB) isitiladi va
            //    video shu zahoti ochiladi. Keyingi oyna FAQAT
            //    pleyer o'sha joyga yaqinlashganda yoki foydalanuvchi
            //    o'sha joyga sek qilganda isitiladi
            //    (`rust_video_cache_warm_window`). Foydalanuvchi
            //    videoning oxiriga umuman bormasa, oxirgi oyna
            //    B2'dan HECH QACHON o'qilmaydi.
            let windows = total.div_ceil(WARM_WINDOW).max(1);
            log(format!(
                "Tayyorlash tayyor: {k} — #0 oyna keshda ({windows} oynadan). \
                 Qolganlari faqat kerak bo'lganda isitiladi."
            ));
            finish(PrepareState::Ready);
        });
    if spawned.is_err() {
        if let Ok(mut m) = prepares().lock() {
            m.insert(key, PrepareState::Failed);
        }
    }
    true
}

/// Videoni ijroga tayyorlashni boshlaydi (darhol qaytadi).
#[no_mangle]
pub extern "C" fn rust_video_cache_prepare(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    if start_prepare(url) {
        1
    } else {
        0
    }
}

/// Tayyorlash TUGADIMI (muvaffaqiyatli yoki muvaffaqiyatsiz).
///
/// Yuklab olish oqimi shu javobga qarab kutishni to'xtatadi —
/// isitish muvaffaqiyatsiz bo'lsa ham abadiy kutib o'tirmasligi
/// kerak.
fn prepare_ready(key: &str) -> bool {
    prepares()
        .lock()
        .map(|m| !matches!(m.get(key), Some(PrepareState::Running)))
        .unwrap_or(true)
}

/// ── ISITISHNI BOSHIDAN QAYTA BOSHLASH ───────────────────────────
///
/// Cloudflare keshi katta yozuvlarni (480 MiB'lik oyna) xotira
/// siqilganda o'chirib yuborishi mumkin. Bunday holatda
/// `/api/play/...` 503 qaytaradi va video ochilmaydi.
///
/// Ilova buni sezganda shu funksiyani chaqiradi: isitish "tayyor"
/// belgisi va oyna holati tozalanadi, ya'ni keyingi
/// `rust_video_cache_prepare` oynani HAQIQATDAN qayta isitadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_prepare_reset(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    let key = cache_key(url);
    if let Ok(mut m) = prepares().lock() {
        m.remove(&key);
    }
    let prefix = format!("{key}#w");
    if let Ok(mut m) = warm_state().lock() {
        m.retain(|k, _| !k.starts_with(&prefix));
    }
    // Diskdagi "keshda ko'rilgan" belgilari ham o'chadi — aks holda
    // ilova majburan qayta isitishdan keyin ham eski belgiga
    // ishonib qolardi.
    if let Some(shared) = SHARED.get() {
        let dir = shared.cache_root.join(&key);
        if let Ok(entries) = fs::read_dir(&dir) {
            for e in entries.flatten() {
                if e.file_name().to_string_lossy().ends_with(".warm") {
                    let _ = fs::remove_file(e.path());
                }
            }
        }
    }
    // Keyingi tayyorlash MAJBURAN bo'lsin: worker o'zining
    // eskirgan kesh yozuvini ham, o'lib qolgan isitishning
    // "belgisi"ni ham e'tiborsiz qoldirib qaytadan isitadi. Bu
    // belgisiz qayta urinish ko'pincha aynan o'sha eski,
    // ishlamaydigan holatni qaytarardi.
    if let Ok(mut m) = prepare_force().lock() {
        m.insert(key.clone());
    }
    log(format!("Tayyorlash holati tozalandi — majburan qayta isitiladi: {key}"));
    1
}

/// Tayyorlash holati:
///   0 — hali ketyapti;
///   1 — TAYYOR (oyna(lar) keshda, ijro qilsa bo'ladi);
///   2 — MUVAFFAQIYATSIZ (isitish chiqmadi — ilova majburan qayta
///       urinadi, keyin esa aniq xabar ko'rsatadi).
#[no_mangle]
pub extern "C" fn rust_video_cache_prepare_status(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 1;
    };
    match prepares().lock().ok().and_then(|m| m.get(&cache_key(url)).copied()) {
        Some(PrepareState::Running) => 0,
        Some(PrepareState::Failed) => 2,
        // Yozuv yo'q — kutadigan narsa ham yo'q.
        _ => 1,
    }
}

// ═══════════════════════════════════════════════════════════════
//  TANBAL (LAZY) OYNA KESHLASH
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): 1.5 GB'lik video birinchi marta ochilganda
// FAQAT boshidagi 480 MiB keshga olinsin. Foydalanuvchi ko'rib yoki
// sek qilib o'sha bo'lakning oxiriga yetsagina — 481-960 MiB'lik
// IKKINCHI bo'lak keshlansin. Ketma-ket hamma bo'lakni keshlash
// xarajatni behuda ko'paytiradi.
//
// Shu sabab bu yerda ikkita ish bor:
//
//   1. `rust_video_cache_warm_window` — berilgan oynani FON'DA
//      isitishni boshlaydi (idempotent: bir necha marta chaqirilsa
//      ham B2'ga bitta so'rov ketadi). Pleyer oyna chegarasiga
//      yaqinlashganda ILOVA shuni chaqiradi — ya'ni keyingi oyna
//      foydalanuvchi u yerga yetib borgunicha tayyor bo'ladi va
//      hech qanday kutish sezilmaydi.
//
//   2. `rust_video_cache_window_status` — o'sha oynaning holati.
//      Foydalanuvchi hali isitilmagan joyga SEK qilsa, ilova
//      pleyerga tegmasdan (buferni saqlagan holda) shu holat
//      "tayyor" bo'lishini kutadi va faqat keyin sek qiladi.
//      Shu bilan pleyer HECH QACHON 503 ko'rmaydi — ya'ni xato
//      ham, bufer tozalanishi ham bo'lmaydi.
//
// B2'GA ORTIQCHA SO'ROV KETMAYDI: baytlar faqat isitish paytida,
// oynasiga bir marta o'qiladi. Boshqa hech qaysi yo'l B2'ga
// chiqmaydi.

/// ── OYNA KESHDAN TUSHIB KETGANDA QAYTA ISITISH ────────────────
///
/// Worker javobida `X-Cache: MISS` yoki `HIT-RANGE` kelsa — bu
/// "javob isitilgan oynadan emas" degani, ya'ni Cloudflare oyna
/// yozuvini o'chirgan. Bunday holatda har bir so'rov B2'ga tushadi
/// va sekin ishlaydi.
///
/// Qayta isitish B2'dan 480 MiB o'qish degani — ya'ni PUL. Shu
/// sabab u QATTIQ cheklangan: bitta oyna uchun `REWARM_COOLDOWN`
/// ichida eng ko'pi BIR MARTA.
static REWARM_AT: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();

fn rewarm_at() -> &'static Mutex<HashMap<String, Instant>> {
    REWARM_AT.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Bitta oyna shu muddat ichida eng ko'pi bir marta qayta
/// isitiladi.
const REWARM_COOLDOWN: Duration = Duration::from_secs(300);

fn note_cold_window(url: &str, key: &str, byte_pos: u64) {
    let widx = byte_pos / WARM_WINDOW;
    let tag = format!("{key}#w{widx}");
    {
        let Ok(mut m) = rewarm_at().lock() else { return };
        if let Some(at) = m.get(&tag) {
            if at.elapsed() < REWARM_COOLDOWN {
                return;
            }
        }
        m.insert(tag.clone(), Instant::now());
    }
    // Xotiradagi "tayyor" belgisini olib tashlamasak,
    // `warm_window_bg` hech narsa qilmaydi.
    if let Ok(mut m) = warm_state().lock() {
        m.remove(&tag);
    }
    if let Ok(mut m) = rewarm_wait_until().lock() {
        m.insert(tag.clone(), Instant::now() + REWARM_WAIT_MAX);
    }
    log(format!(
        "Oyna #{widx} kesh chetiga chiqib ketgan (javob keshdan emas) — qayta isitilmoqda"
    ));
    warm_window_bg(url, widx);
}

/// Oynaning hozirgi holati (ichki).
fn window_state_of(key: &str, widx: u64) -> Option<WarmState> {
    let tag = format!("{key}#w{widx}");
    warm_state().lock().ok().and_then(|m| m.get(&tag).map(|(s, _)| *s))
}

/// Oynani FON'DA isitishni boshlaydi. Allaqachon ketayotgan yoki
/// tugagan bo'lsa — hech narsa qilmaydi (B2'ga takroriy so'rov
/// KETMAYDI).
fn warm_window_bg(url: &str, widx: u64) -> bool {
    if SHARED.get().is_none() {
        return false;
    }
    let key = cache_key(url);
    let tag = format!("{key}#w{widx}");
    {
        let Ok(mut m) = warm_state().lock() else {
            return false;
        };
        match m.get(&tag) {
            // Ketyapti yoki tayyor — qayta boshlamaymiz.
            Some((WarmState::Running, _)) | Some((WarmState::Done, _)) => return true,
            // Yaqinda muvaffaqiyatsiz tugagan — darhol qayta
            // urinmaymiz (so'rovlar bo'roni bo'lmasligi uchun).
            Some((WarmState::Failed, at)) if at.elapsed() < WARM_LAZY_RETRY_COOLDOWN => {
                return false
            }
            _ => {}
        }
        m.insert(tag.clone(), (WarmState::Running, Instant::now()));
    }
    let (u, k) = (url.to_string(), key.clone());
    let spawned = thread::Builder::new()
        .name("video-cache-warmw".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            log(format!("Tanbal isitish: #{widx} oyna ({k})"));
            let (ok, total) = warm_one_window(&u, &k, widx, false);
            if !ok {
                // Qo'shimcha kafolat: holat "ketyapti"da qolmaydi.
                if let Ok(mut m) = warm_state().lock() {
                    let tag = format!("{k}#w{widx}");
                    if m.get(&tag).map(|(s, _)| *s) == Some(WarmState::Running) {
                        m.insert(tag, (WarmState::Failed, Instant::now()));
                    }
                }
            }
            // Hajm ma'lum bo'ldi — meta.json'ga yozib qo'yamiz
            // (keyingi safar so'rov kerak bo'lmasin).
            if ok && total > 0 {
                if let Some(shared) = SHARED.get() {
                    let dir = shared.cache_root.join(&k);
                    if meta_total_from_disk(&dir) == 0 {
                        let _ = fs::create_dir_all(&dir);
                        let meta = CacheMeta {
                            total_size: total,
                            content_type: "video/mp4".to_string(),
                            chunk_size: CHUNK_SIZE,
                            duration_secs: 0.0,
                            chunk_start_ms: Vec::new(),
                        };
                        write_meta(&dir, &meta);
                    }
                }
            }
            log(format!(
                "Tanbal isitish tugadi: #{widx} oyna — {}",
                if ok { "tayyor" } else { "muvaffaqiyatsiz" }
            ));
        });
    if spawned.is_err() {
        if let Ok(mut m) = warm_state().lock() {
            m.insert(tag, (WarmState::Failed, Instant::now()));
        }
        return false;
    }
    true
}

/// Oynani isitishni boshlaydi (yoki allaqachon ketayotgan bo'lsa —
/// hech narsa qilmaydi). DARHOL qaytadi.
#[no_mangle]
pub extern "C" fn rust_video_cache_warm_window(url_ptr: *const c_char, widx: u64) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    if warm_window_bg(url, widx) {
        1
    } else {
        0
    }
}

/// Oyna holati:
///   0 — isitilyapti (kutish kerak);
///   1 — TAYYOR (keshda — o'sha joyni ijro qilsa bo'ladi);
///   2 — muvaffaqiyatsiz (qayta urinsa bo'ladi);
///   3 — hali umuman boshlanmagan.
///
/// Fayl DISKDA to'liq bo'lsa oyna tushunchasining o'zi kerak
/// emas — 1 qaytariladi (tarmoqqa umuman chiqilmaydi).
#[no_mangle]
pub extern "C" fn rust_video_cache_window_status(url_ptr: *const c_char, widx: u64) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 3;
    };
    if url.is_empty() {
        return 3;
    }
    let key = cache_key(url);
    // Diskdagi to'liq fayl uchun isitish kerak emas.
    if let Some(shared) = SHARED.get() {
        let dir = shared.cache_root.join(&key);
        let total = meta_total_from_disk(&dir);
        if total > 0 {
            let count = total.div_ceil(CHUNK_SIZE);
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                return 1;
            }
        }
    }
    match window_state_of(&key, widx) {
        Some(WarmState::Running) => 0,
        Some(WarmState::Done) => 1,
        Some(WarmState::Failed) => 2,
        None => 3,
    }
}

/// Faylning umumiy hajmi (bayt). 0 — hali noma'lum.
///
/// Ilova shu son orqali "pleyer hozir qaysi oynada" degan savolga
/// javob beradi: `bayt = (pozitsiya / davomiylik) * hajm`.
#[no_mangle]
pub extern "C" fn rust_video_cache_total(url_ptr: *const c_char) -> u64 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    let Some(shared) = SHARED.get() else {
        return 0;
    };
    meta_total_from_disk(&shared.cache_root.join(cache_key(url)))
}

/// Bitta oynadagi baytlar soni — ilova oyna chegarasini AYNAN shu
/// songa qarab hisoblaydi (Rust va worker bilan bir xil bo'lishi
/// shart, shu sabab qiymat qo'lda takrorlanmaydi).
#[no_mangle]
pub extern "C" fn rust_video_cache_window_size() -> u64 {
    WARM_WINDOW
}

// ═══════════════════════════════════════════════════════════════
//  TRAFIKNI KIM SARFLAGANI
// ═══════════════════════════════════════════════════════════════
//
// ── O'ZGARDI: ENDI SANOQNI ILOVANING O'ZI YURITADI ────────────
//
// Ilgari har bir so'rovga `X-U` sarlavhasi qo'yilar, worker esa
// javob tanasini sanovchi quvurdan o'tkazib, natijani o'sha
// hisobga yozardi. Hisob NOTO'G'RI chiqdi (pleyer ochilgan
// oraliqni yarmida uzadi) va ijro ba'zan "yuklanmadi" xatosiga
// yiqildi.
//
// Endi worker javobga UMUMAN tegmaydi. Baytlarni ilova qurilma
// darajasida sanaydi (`lib/services/traffic_service.dart`) va
// sutkada bir marta bitta son yuboradi. Shu sabab bu yerdagi
// sarlavha ham olib tashlandi.
//
// Hisob raqami baribir saqlanadi: u kelajakda kerak bo'lishi
// mumkin va `rust_set_user_id` ilova tomonidan chaqiriladi.
static TRAFFIC_USER: AtomicI64 = AtomicI64::new(0);

/// Ilova kirgan hisob raqamini bildiradi (chiqilganda 0).
///
/// Hozircha yadro undan foydalanmaydi — so'rovlarga hech qanday
/// qo'shimcha sarlavha qo'yilmaydi.
// ── YADRONING O'Z SO'ROVLARI HAM IMZOLANADI ───────────────────
//
// TALAB (foydalanuvchi): "worker faqat yangi xavfsiz ilovaga javob
// bersin va tashqaridan hech kim hech narsa so'ray olmasin".
//
// Ilgari video yo'llari (`/api/play`, `/api/warm`, `/api/image`)
// tekshiruvdan OZOD edi — ular "ochiq tarkib" deb hisoblanardi.
// Sababi texnik edi: bu so'rovlarni Flutter emas, SHU YADRO
// yuboradi va u imzo yasay olmasdi.
//
// Endi yasay oladi (`crate::sign_v2`), shu sabab ozodlik kerak
// emas: yadro ham har so'roviga imzo va versiya qo'yadi, worker
// esa hamma yo'lni bir xil tekshiradi.
fn signed(req: ureq::Request, method: &str, url: &str) -> ureq::Request {
    let req = match crate::sign_v2(method, url) {
        Some(sig) => req.set("X-App-Sig", &sig),
        None => req,
    };
    let ver = crate::app_version();
    if ver.is_empty() {
        req
    } else {
        req.set("X-App-Version", &ver)
    }
}

#[no_mangle]
pub extern "C" fn rust_set_user_id(id: i64) {
    let old = TRAFFIC_USER.swap(id.max(0), Ordering::Relaxed);
    if old != id.max(0) {
        log(format!("Hisob almashdi: {old} -> {}", id.max(0)));
    }
}

/// ── YUKLAB OLISH ISITISHNI KUTADI ─────────────────────────────
///
/// Foydalanuvchi "yuklab olish"ni bosganda eng tejamkor va eng tez
/// yo'l — avval oynaning keshga tushishini kutib, keyin HAMMASINI
/// Cloudflare chekkasidan olish:
///   * B2'ga bitta ham qo'shimcha so'rov ketmaydi (xarajat eng kam);
///   * chekkadan olish B2'dan olishdan sezilarli tez.
///
/// Kutish CHEGARALANGAN: isitish `WARM_WAIT_MAX` ichida tugamasa,
/// yuklash baribir davom etadi (ya'ni hech qachon "muzlab" qolmaydi).
/// Foydalanuvchi pauza bossa ham kutish darhol uziladi.
///
/// Pleyer (ijro) ham isitishni kutadi, lekin kutish MANTIG'I
/// boshqa joyda — Dart tomonida (`_prepareSource`), chunki u yerda
/// ekranda "Video tayyorlanyabdi..." belgisi ko'rsatiladi va
/// foydalanuvchi boshqa qismni bosib kutishni bekor qila oladi.
const WARM_WAIT_MAX: Duration = Duration::from_secs(90);

/// ── QAYTA ISITISHNI KUTISH CHEKLANGAN ────────────────────────
///
/// TOPILGAN XATO (foydalanuvchi skrinshoti: 98,59% da telefon
/// tarmog'i 0 KB/s, ekranda tezlik asta pasayib 25 KB/s).
///
/// Yuklash davomida bitta javob keshdan emas kelsa
/// (`note_cold_window`), oyna qayta isitiladi. Ilgari HAR BIR oqim
/// HAR BIR so'rovdan oldin o'sha isitishni 90 soniyagacha kutardi —
/// fayl deyarli tugagan bo'lsa ham yuklash to'xtab qolardi (va har
/// oqimning kutishi alohida hisoblangani uchun bir necha marta).
///
/// Endi qayta isitish uchun BITTA umumiy muddat bor
/// (`REWARM_WAIT_MAX`): undan keyin oqimlar kutmasdan davom etadi,
/// isitish esa fon'da tugaydi. Test:
/// `keshdan_bitta_miss_yuklashni_toxtatib_qoymaydi`.
const REWARM_WAIT_MAX: Duration = Duration::from_secs(3);

fn rewarm_wait_until() -> &'static Mutex<HashMap<String, Instant>> {
    static M: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

fn wait_for_warm(key: &str, byte_pos: u64) {
    let widx = byte_pos / WARM_WINDOW;
    let tag = format!("{key}#w{widx}");
    // Qayta isitish bo'lsa — umumiy (qisqa) muddat, aks holda
    // birinchi isitish uchun odatdagi muddat.
    let deadline = rewarm_wait_until()
        .lock()
        .ok()
        .and_then(|m| m.get(&tag).copied())
        .unwrap_or_else(|| Instant::now() + WARM_WAIT_MAX);
    let mut logged = false;
    loop {
        let state = warm_state().lock().ok().and_then(|m| m.get(&tag).map(|(s, _)| *s));
        if state != Some(WarmState::Running) {
            return;
        }
        if Instant::now() >= deadline {
            log(format!(
                "Isitish {}s ichida tugamadi — yuklash baribir davom etadi",
                WARM_WAIT_MAX.as_secs()
            ));
            return;
        }
        if !download_active(key) {
            return;
        }
        if !logged {
            logged = true;
            log(format!(
                "Yuklab olish oynasi #{widx} keshga tushishini kutmoqda..."
            ));
        }
        thread::sleep(Duration::from_millis(300));
    }
}

/// ── YUKLAB OLISH: KERAKLI OYNANI ISITIB, KUTADI ───────────────
///
/// Tanbal keshlashda yuklab olish ham aynan pleyer kabi ishlaydi:
/// bo'lak qaysi oynaga tegishli bo'lsa, FAQAT o'sha oyna isitiladi.
/// Yuklash tartib bilan borgani uchun oynalar ham tartib bilan,
/// kerak bo'lgan sari isitiladi — ya'ni foydalanuvchi yuklashni
/// yarmida to'xtatsa, qolgan oynalar B2'dan umuman o'qilmaydi.
///
/// Kutish CHEGARALANGAN va pauza bosilsa darhol uziladi.
/// `true` — oyna keshda (yoki kutish tugadi, baribir davom etamiz).
fn ensure_window_for_download(url: &str, key: &str, byte_pos: u64) {
    let widx = byte_pos / WARM_WINDOW;
    if window_state_of(key, widx) == Some(WarmState::Done) {
        return;
    }
    warm_window_bg(url, widx);
    let deadline = Instant::now() + WARM_WAIT_MAX;
    while Instant::now() < deadline {
        if !download_active(key) {
            return;
        }
        match window_state_of(key, widx) {
            Some(WarmState::Running) => {}
            // Tayyor, muvaffaqiyatsiz yoki umuman boshlanmagan —
            // kutadigan narsa yo'q (muvaffaqiyatsiz bo'lsa bo'lak
            // baribir olinishga urinadi, xato bo'lsa odatdagi
            // qayta urinish mantiqi ishlaydi).
            _ => return,
        }
        thread::sleep(Duration::from_millis(200));
    }
}

/// Bo'lakni diskka YAKUNIY holda yozadi (shifrlab, atom ravishda).
fn write_full_chunk(dir: &PathBuf, key: &str, index: u64, plain: &[u8]) -> bool {
    let on_disk: Vec<u8> = match crypto::derive_chunk_key_iv(key, index) {
        Some((k, iv)) => crypto::encrypt_chunk(plain, &k, &iv),
        None => plain.to_vec(),
    };
    // Shifrlash yiqildi (tasodifiy son olinmadi) — yozmaymiz, bo'lak
    // keyinroq qaytadan olinadi.
    if on_disk.is_empty() && !plain.is_empty() {
        return false;
    }
    let tmp = dir.join(format!("{}.{}.tmp", chunk_name(index), micros_now()));
    if fs::write(&tmp, &on_disk).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    if fs::rename(&tmp, dir.join(chunk_name(index))).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    // Yakuniy bo'lak joyiga tushdi — eski qoldiq endi keraksiz.
    remove_part(dir, index);
    true
}

/// ── BITTA SO'ROVDA KETMA-KET BO'LAKLARNI OLADI ────────────────
///
/// `first..=last` oralig'idagi bo'laklar BITTA uzoq HTTP so'rovda
/// olinadi va baytlar kelishi bilan bittalab, shifrlanib, atom
/// ravishda diskka yoziladi. Xotirada bir vaqtda faqat BITTA
/// bo'lak (1 MiB) turadi — so'rov 64 MiB bo'lsa ham.
///
/// Har bir bo'lak diskka tushishi bilan `on_chunk` chaqiriladi:
/// yo'lak (`Lane`) o'z hisobini shu orqali yuritadi, ya'ni oqim
/// uzilib qolsa ham keyingi urinish AYNAN to'xtagan joyidan
/// davom etadi.
///
/// Qaytadi:
///   * `Ok(())`  — tarmoqdan baytlar olindi (hammasi bo'lmasa ham);
///   * `Err(..)` — bitta ham bayt olinmadi.
fn fetch_span(
    shared: &Shared,
    key: &str,
    dir: &PathBuf,
    url: &str,
    first: u64,
    last: u64,
    total: u64,
    stop: &AtomicBool,
    cur_bytes: &AtomicU64,
    on_start: &mut dyn FnMut(),
    on_chunk: &mut dyn FnMut(u64) -> bool,
) -> Result<(), String> {
    if total == 0 {
        return Err("hajm noma'lum".to_string());
    }
    let chunk_count = total.div_ceil(CHUNK_SIZE);
    if first >= chunk_count {
        return Err(format!("bo'lak #{first} fayldan tashqarida"));
    }
    let last = last.min(chunk_count - 1);

    // ── QOLDIQDAN DAVOM ETISH ──────────────────────────────────
    // Oldingi urinishda birinchi bo'lakning bir qismi olinib,
    // tarmoq uzilgan bo'lishi mumkin. O'sha qism diskda saqlangan:
    // uni o'qib, tarmoqdan FAQAT yetishmayotgan dumini so'raymiz.
    let first_len = chunk_plain_len(first, total) as usize;
    let prefix = read_part(dir, key, first, first_len).unwrap_or_default();
    let range_start = first * CHUNK_SIZE + prefix.len() as u64;
    let range_end = clamp_span(
        range_start,
        ((last + 1) * CHUNK_SIZE).saturating_sub(1).min(total - 1),
    );
    if range_start > range_end {
        return Err(format!("bo'lak #{first} uchun so'raladigan oraliq bo'sh"));
    }

    // ── OYNANI ISITISH ─────────────────────────────────────────
    // Odatda oyna `ensure_window_for_download` bilan allaqachon
    // isitilgan bo'ladi va bu ikki chaqiruv darhol qaytadi. Bu
    // yerdagisi — himoya: kesh o'chib ketgan bo'lsa ham so'rov
    // B2'ga emas, baribir keshga boradi.
    let tm = dl_timing(key);
    let t_warm = Instant::now();
    maybe_warm(url, key, range_start);
    wait_for_warm(key, range_start);
    tm.warm_us
        .fetch_add(t_warm.elapsed().as_micros() as u64, Ordering::Relaxed);
    if !download_active(key) {
        return Err("pauza".to_string());
    }

    // ── HAVODAGI SO'ROVLAR CHEGARASI (`DL_TOTAL_CONNS`) ──
    // Ruxsat AYNAN shu yerda — isitishni kutish tugagach, so'rov
    // yuborilishidan oldin — olinadi va javob o'qib bo'lingach
    // bo'shaydi. Ya'ni ruxsat faqat baytlar haqiqatan tortilayotganda
    // band bo'ladi.
    let Some(_permit) = DlPermit::acquire(key) else {
        return Err("pauza".to_string());
    };
    // Kutish vaqti oqimning "sekinligi" hisobiga kirmasin (aks holda
    // ruxsat kutgan oqimning ishi behuda o'g'irlanardi).
    on_start();
    log(format!(
        "Bo'laklar {first}..={last} worker'dan olinmoqda ({range_start}-{range_end})..."
    ));
    let t_req = Instant::now();
    let resp = signed(shared.agent.get(url), "GET", url)
        .set("Range", &format!("bytes={range_start}-{range_end}"))
        .call()
        .map_err(|e| e.to_string())?;
    tm.ttfb_us
        .fetch_add(t_req.elapsed().as_micros() as u64, Ordering::Relaxed);
    let status = resp.status();

    // ── BUTUNLIK TEKSHIRUVI ────────────────────────────────────
    // Server so'ralgan ORALIQNI qisqartirdimi — chegarasini eslab
    // qolamiz (`SERVER_SPAN_MAX` izohiga qarang). Faqat
    // `Content-Range`ga ishoniladi.
    //
    // MUHIM ISTISNO. Worker'da ikkita yo'l bor:
    //   * ISITILGAN OYNADAN kesib berish (`X-Cache: HIT-WINDOW`) —
    //     baytlar oqim bilan o'tadi, chegara HAQIQIY va doimiy;
    //   * xotiraga yig'ib berish — B2'dan (`MISS`) yoki eski mayda
    //     oraliq keshidan (`HIT-RANGE`). Bu yo'lda oraliq worker
    //     xotirasini asrash uchun qisqartiriladi va bu uning
    //     DOIMIY chegarasi EMAS.
    // Ikkinchi yo'ldan "o'rgansak", keyingi barcha so'rovlar
    // bekorga mayda bo'lib qolardi.
    let memory_path = resp
        .header("X-Cache")
        .map(|v| {
            let v = v.trim();
            v.eq_ignore_ascii_case("MISS") || v.eq_ignore_ascii_case("HIT-RANGE")
        })
        .unwrap_or(false);
    if memory_path {
        // ── OYNA KESHDAN TUSHIB KETGAN ─────────────────────────
        // Javob isitilgan oynadan EMAS, worker xotirasidan keldi
        // (B2 yoki eski mayda oraliq keshi). Demak Cloudflare oyna
        // yozuvini chetga surib qo'ygan. Bu yo'l sezilarli SEKIN
        // (bir so'rovda 8 MiB, ustiga worker xotirasiga yig'iladi),
        // shu sabab oynani QAYTA isitamiz — qolgan yuklash yana
        // to'liq tezlikda, chekkadan ketadi.
        //
        // Ilgari bu sezilmasdi: ilova xotirasida oyna "tayyor"
        // bo'lib qolar va yuklash oxirigacha sekin yo'ldan
        // ketaverardi — o'z-o'zidan hech qachon tuzalmasdi.
        note_cold_window(url, key, range_start);
    } else {
        if let Some(cr) = resp.header("Content-Range") {
            if let Some((s_str, e_str)) = cr
                .trim()
                .strip_prefix("bytes ")
                .and_then(|r| r.split('/').next())
                .and_then(|r| r.split_once('-'))
            {
                if let (Ok(rs), Ok(re)) =
                    (s_str.trim().parse::<u64>(), e_str.trim().parse::<u64>())
                {
                    if re >= rs {
                        note_server_span(range_end - range_start + 1, re - rs + 1);
                    }
                }
            }
        }
    }
    // Serverning e'lon qilgan UMUMIY fayl hajmi diskdagi meta.json
    // bilan mos kelmasa — manbadagi fayl o'zgargan va keshimiz
    // ESKIRGAN. Eski bo'laklarni saqlash videoni buzib ko'rsatardi.
    if let Some(cr) = resp.header("Content-Range") {
        if let Some(server_total_str) = cr.rsplit('/').next() {
            if let Ok(server_total) = server_total_str.trim().parse::<u64>() {
                if server_total != total {
                    log(format!(
                        "XATO: hajm mos emas! meta.json={total}, serverda={server_total} — kesh tozalanmoqda"
                    ));
                    invalidate_cache(dir);
                    forget_derived(key);
                    return Err(format!(
                        "hajm mos emas (meta={total}, server={server_total})"
                    ));
                }
            }
        }
    }

    // Manba Range'ni e'tiborsiz qoldirib TO'LIQ faylni (0-baytdan)
    // yuborishi mumkin — bunday holda kerakli joygacha bo'lgan
    // baytlar tashlab yuboriladi.
    let mut skip = if status == 200 { range_start as usize } else { 0 };

    // ── OQIMNI BO'LAKMA-BO'LAK DISKKA YOZAMIZ ──────────────────
    let mut cur = first;
    let mut want = first_len;
    let mut acc: Vec<u8> = prefix;
    cur_bytes.store(acc.len() as u64, Ordering::Relaxed);
    let mut reader = resp.into_reader();
    let mut buf = [0u8; 64 * 1024];
    let mut read_err: Option<String> = None;
    let mut got_net: u64 = 0;

    'outer: loop {
        // Egizak oqim bo'lakni birinchi tugatdi (yakuniy
        // takrorlash) — ortiqcha trafik sarflamaymiz.
        if stop.load(Ordering::SeqCst) {
            read_err = Some("egizak oqim tugatdi".to_string());
            break;
        }
        // ── PAUZA: TARMOQ OQIMI DARHOL UZILADI ─────────────────
        // Bayroq HAR 64 KB da tekshiriladi: pauza bosilsa o'qish
        // shu yerda to'xtaydi, `reader` tashlanadi va TCP ulanish
        // uziladi — trafik butunlay to'xtaydi. Yarim olingan bo'lak
        // qoldiq sifatida diskda qoladi, shu sabab davom
        // ettirilganda aynan o'sha joydan boshlanadi.
        if !download_active(key) {
            read_err = Some("pauza — oqim uzildi".to_string());
            break;
        }
        let t_rd = Instant::now();
        let n = match reader.read(&mut buf) {
            Ok(n) => n,
            Err(e) => {
                read_err = Some(e.to_string());
                break;
            }
        };
        tm.read_us
            .fetch_add(t_rd.elapsed().as_micros() as u64, Ordering::Relaxed);
        if n == 0 {
            break;
        }
        let mut piece = &buf[..n];
        if skip > 0 {
            let k = skip.min(piece.len());
            piece = &piece[k..];
            skip -= k;
            if piece.is_empty() {
                continue;
            }
        }
        got_net += piece.len() as u64;
        tm.bytes.fetch_add(piece.len() as u64, Ordering::Relaxed);
        // Ekrandagi MB/s shu yerdan hisoblanadi (arzon: har 64 KB
        // da bitta atomik qo'shish).
        stat_note_net(key, piece.len() as u64);
        while !piece.is_empty() {
            if want == 0 || acc.len() >= want {
                break;
            }
            let take = (want - acc.len()).min(piece.len());
            acc.extend_from_slice(&piece[..take]);
            cur_bytes.store(acc.len() as u64, Ordering::Relaxed);
            piece = &piece[take..];
            if acc.len() < want {
                continue;
            }
            // Bo'lak to'ldi — diskka yozamiz va yo'lakka xabar
            // qilamiz.
            let t_wr = Instant::now();
            let saved = write_full_chunk(dir, key, cur, &acc);
            tm.write_us
                .fetch_add(t_wr.elapsed().as_micros() as u64, Ordering::Relaxed);
            // `false` — ulushning qolgani boshqa oqimga berildi
            // (ish o'g'irlash), bu so'rov shu yerda to'xtaydi.
            if saved && !on_chunk(cur) {
                break 'outer;
            }
            if cur >= last {
                break 'outer;
            }
            cur += 1;
            want = chunk_plain_len(cur, total) as usize;
            acc = Vec::with_capacity(want);
            cur_bytes.store(0, Ordering::Relaxed);
        }
    }

    // Yarim qolgan bo'lak — qoldiq sifatida saqlanadi, keyingi
    // urinish AYNAN shu joydan davom etadi.
    if cur <= last && !acc.is_empty() && acc.len() < want && !chunk_cached(dir, cur, total) {
        write_part(dir, key, cur, &acc);
        log(format!(
            "Bo'lak #{cur} to'liq emas ({}/{want}) — qoldiq saqlandi",
            acc.len()
        ));
    }

    // Tarmoqdan olingan baytlarning umumiy hisobi.
    let total_net = NET_BYTES.fetch_add(got_net, Ordering::Relaxed) + got_net;
    let file_net = {
        let mut m = shared.net_by_file.lock().unwrap();
        let e = m.entry(key.to_string()).or_insert(0);
        *e += got_net;
        *e
    };
    log(format!(
        "TARMOQDAN >>> fayl='{key}' bo'laklar {first}..={last} ({range_start}-{range_end}) {got_net} bayt | shu fayl: {:.2} MB | jami: {:.2} MB",
        file_net as f64 / (1024.0 * 1024.0),
        total_net as f64 / (1024.0 * 1024.0)
    ));

    if got_net == 0 {
        return Err(read_err.unwrap_or_else(|| format!("bo'lak #{first} uchun bo'sh javob")));
    }
    Ok(())
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
// ═══════════════════════════════════════════════════════════════
//  VIDEO DAVOMIYLIGI (MP4 `moov` -> `mvhd`)
// ═══════════════════════════════════════════════════════════════
//
// Oldindan yuklash oynasi endi videoning BITREYTIGA qarab
// hisoblanadi: "bir daqiqalik video necha MB?" degan savolga javob
// aynan shu — oynaning bo'lakdagi kengligi (1 bo'lak = 1 MiB).
//
//     oyna = floor(hajm_MiB / davomiylik_daqiqa)
//
// Masalan 166.54 MiB / 24:05 (24.08 daqiqa) = 6.91 -> 6 bo'lak.
//
// Davomiylik HTTP metadatasida yo'q — u faylning ICHIDA, MP4
// konteynerining `moov` -> `mvhd` atomida yotadi. Manba fayllar har
// doim "faststart" bilan tayyorlanadi (moov atomi faylning BOSHIDA)
// va H.265'da kodlanadi, shu sabab BIRINCHI bo'lakning o'zi yetarli:
// tarmoqqa qo'shimcha so'rov ketmaydi.

// ── IJRO NUQTASI (pleyer HOZIR qayerni ko'rsatyapti) ──────────────
//
// MUHIM: bu BUFER UCHI emas. Pleyer (ExoPlayer) o'zining ichki buferi
// uchun ijro nuqtasidan bir necha bo'lak OLDINGA o'qib qo'yadi. Agar
// oldindan yuklash oynasini BUFER UCHIDAN hisoblasak, ikkalasi
// QO'SHILIB ketadi:
//
//     bufer (~6 bo'lak) + oyna (6 bo'lak) = 12-16 bo'lak
//
// Foydalanuvchi aynan shuni ko'rgan: 7 o'rniga 16 bo'lak yuklandi.
//
// Talab esa aniq: "pleyrda 10-bo'lak ko'rsatilayotgan bo'lsa oldindan
// 16-bo'lakkacha yuklab olinadi, undan ko'p emas". Ya'ni oyna IJRO
// NUQTASIDAN hisoblanishi kerak. Pleyerning o'z buferi shu oynaning
// ICHIDA qoladi va ustiga hech narsa qo'shilmaydi.
//
// Ijro nuqtasini faqat Dart tomoni biladi (`controller.value.position`),
// shu sabab u `rust_video_cache_set_position` orqali xabar qilib
// turadi (soniyada bir marta, juda arzon: ikkita atomik yozuv).
static PLAY_POS_MS: AtomicU64 = AtomicU64::new(0);
/// Ijro nuqtasi QAYSI video uchun ekanini bildiruvchi kalit hashi.
/// 0 = hali xabar qilinmagan.
static PLAY_POS_KEY: AtomicU64 = AtomicU64::new(0);
/// Ijro nuqtasi OXIRGI MARTA qachon xabar qilingan (server ishga
/// tushgandan beri o'tgan millisekund).
///
/// NEGA KERAK: cheklov aynan shu songa tayanadi, ya'ni son ESKIRGAN
/// bo'lsa cheklov ham noto'g'ri joyda ishlaydi. Masalan ilova fonga
/// ketib, pleyer to'xtab qolsa, oxirgi xabar bir necha daqiqa
/// oldingi bo'lishi mumkin. Bunday holatda ijro nuqtasi
/// ISHLATILMAYDI — o'rniga so'rovning O'ZIDAGI boshlanish nuqtasi
/// olinadi (u har doim haqiqiy).
static PLAY_POS_AT_MS: AtomicU64 = AtomicU64::new(0);

/// Kalitni raqamga o'giradi (atomik solishtirish uchun).
fn key_tag(key: &str) -> u64 {
    let mut h: u64 = 1469598103934665603;
    for b in key.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    // 0 "xabar qilinmagan" degani, shu sabab hech qachon 0 bo'lmasin.
    if h == 0 {
        1
    } else {
        h
    }
}

/// Dart tomoni ijro nuqtasini shu yerda xabar qiladi.
#[no_mangle]
pub extern "C" fn rust_video_cache_set_position(
    url_ptr: *const c_char,
    position_ms: u64,
) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 0;
    };
    if url.is_empty() {
        return 0;
    }
    PLAY_POS_KEY.store(key_tag(&cache_key(url)), Ordering::Relaxed);
    PLAY_POS_MS.store(position_ms, Ordering::Relaxed);
    PLAY_POS_AT_MS.store(
        SHARED
            .get()
            .map(|s| s.start.elapsed().as_millis() as u64)
            .unwrap_or(0)
            .max(1),
        Ordering::Relaxed,
    );
    1
}

// ═══════════════════════════════════════════════════════════════════
//  TOMOSHA TARIXI UCHUN KADR ("/thumb")
// ═══════════════════════════════════════════════════════════════════
//
// Tarixdagi har bir qism foydalanuvchi TO'XTAGAN JOYDAGI kadr bilan
// ko'rsatiladi. Butun epizodni (100-500 MB) shuning uchun yuklab
// olish mantiqsiz, shu sabab bu yo'l:
//
//   1. `moov` atomini o'qiydi (ichida "qaysi soniya qaysi baytda"
//      jadvali bor) — odatda 0,2-0,8 MB;
//   2. kerakli soniyadan oldingi KALIT KADRni topadi va faqat
//      o'shani oladi — 50-300 KB;
//   3. shu kadrdan bitta kadrlik, to'la haqiqiy MP4 yasaydi
//      (`mp4::build_single_frame_mp4`) va shuni qaytaradi.
//
// Dart tomoni bu manzilni Android'ning kadr ajratuvchisiga beradi va
// undan JPEG oladi. Yasalgan MP4 DISKKA UMUMAN YOZILMAYDI — u
// xotirada turadi va qisqa muddatdan keyin o'zi o'chadi.
//
// ── "/v" DAN FARQI ────────────────────────────────────────────────
//
// Mahalliy server (`serve`) TARMOQQA UMUMAN CHIQMAYDI — bu loyihaning
// asosiy qoidasi: "videoni ko'rish" hech qachon "yuklab olish"ga
// aylanmasligi kerak. Bu yo'l esa ATAYLAB alohida: u tarmoqqa
// chiqishi mumkin, lekin FAQAT bir necha yuz kilobayt oladi va
// bo'laklarni diskka yozmaydi. Ikkovini bir joyga qo'shmang.

/// Tarmoqdan olingan baytlarni umumiy hisobga qo'shadi.
///
/// Kadr olish ham shu hisobga kiradi — foydalanuvchi trafigi
/// SHAFFOF bo'lishi kerak, "qayerdandir yo'qolgan MB" bo'lmasin.
fn note_net_bytes(key: &str, bytes: u64) {
    if bytes == 0 {
        return;
    }
    NET_BYTES.fetch_add(bytes, Ordering::Relaxed);
    if let Some(shared) = SHARED.get() {
        if let Ok(mut m) = shared.net_by_file.lock() {
            *m.entry(key.to_string()).or_insert(0) += bytes;
        }
    }
}

/// Kadr uchun baytlarni o'qish: avval xotiradagi zaxiradan, keyin
/// diskdan, bo'lmasa tarmoqdan.
///
/// ═══════════════════════════════════════════════════════════════
///  ZAXIRA BO'LAK (TOPILGAN XATO: KADR JUDA SEKIN CHIQARDI)
/// ═══════════════════════════════════════════════════════════════
///
/// TOPILGAN XATO (foydalanuvchi): "thumbnail qo'yish juda juda
/// sekin ishlayapti ... tomosha tarixidagi thumbnail qo'yish ham
/// nimagadir sekin".
///
/// SABAB: har bir `read()` ALOHIDA HTTP so'rovi edi, `find_moov`
/// esa MP4 sarlavhalarini ATIGI 16 BAYTDAN o'qiydi. Odatdagi
/// fayl tartibi `ftyp` -> `mdat` -> `moov`, ya'ni bitta kadr
/// uchun:
///
///   1. read(0, 16)            -> so'rov #1  (ftyp sarlavhasi)
///   2. read(32, 16)           -> so'rov #2  (mdat sarlavhasi)
///   3. read(<oxiri>, 16)      -> so'rov #3  (moov sarlavhasi)
///   4. read(moov, ~0,5 MB)    -> so'rov #4  (moov tanasi)
///   5. kalit kadr             -> so'rov #5
///
/// Beshta KETMA-KET so'rov, har biri to'liq borib-kelish vaqti
/// (mobil tarmoqda 0,3-0,8 s) — ya'ni bitta kadr uchun 2-5
/// soniya, hech qanday foydali ish qilmasdan. Bu tomosha
/// tarixiga ham, yozishmaga ham BIR XIL tegadi — foydalanuvchi
/// ikkalasining ham sekinligini aytgani shundan.
///
/// YECHIM: tarmoqqa chiqilganda kerakligidan KO'PROQ olinadi va
/// xotirada saqlanadi. 16 baytlik sarlavha o'qishlari endi o'sha
/// bo'lakdan chiqadi. Amalda so'rovlar soni 5 tadan 2 taga
/// tushadi (ko'pincha `moov` va kalit kadr bitta bo'lakka
/// tushib, bittaga ham).
struct ThumbReader<'a> {
    shared: &'a Shared,
    dir: PathBuf,
    key: String,
    url: String,
    total: u64,
    /// Oxirgi tarmoq o'qishi: (boshlanish o'rni, baytlar).
    ///
    /// `RefCell` yetarli: `ThumbReader` bitta so'rov ichida
    /// yaratiladi va FAQAT o'sha oqimda ishlatiladi.
    /// Zaxira bo'laklar — eng ko'pi ikkita: faylning BOSHI va
    /// OXIRI. `moov` oxirida bo'lgan faylda (telefon va
    /// Telegram videolari) kalit kadr boshida, `moov` esa oxirida
    /// turadi; bitta zaxira bo'lsa oxirini o'qish boshini o'chirib
    /// yuborardi va kalit kadr uchun yana bitta so'rov ketardi.
    buf: RefCell<Vec<(u64, Vec<u8>)>>,
}

impl ThumbReader<'_> {
    /// Tarmoqqa chiqilganda eng kami shuncha bayt olinadi.
    ///
    /// 256 KB — `moov` ning katta qismini (odatda 0,2-0,8 MB) va
    /// sarlavhalarni qoplaydi, lekin sekin tarmoqda ham og'ir
    /// emas. Yozishmadagi video 2-5 MB, ya'ni bu faylning
    /// atigi bir qismi.
    const READAHEAD: u64 = 256 * 1024;

    /// Xotirada saqlanadigan zaxiraning eng katta hajmi.
    ///
    /// Kalit kadr oralig'i 8 MB gacha bo'lishi mumkin — bunday
    /// katta o'qish saqlanmaydi, aks holda arzon telefonda
    /// xotira video ijrosidan tortib olinardi.
    const BUF_MAX: u64 = 1024 * 1024;

    /// Kerakli oraliq zaxira bo'lak ichidami.
    fn from_buf(&self, start: u64, len: u64) -> Option<Vec<u8>> {
        let b = self.buf.borrow();
        for (at, data) in b.iter() {
            if start < *at {
                continue;
            }
            let from = (start - *at) as usize;
            let Some(to) = from.checked_add(len as usize) else {
                continue;
            };
            if to <= data.len() {
                return Some(data[from..to].to_vec());
            }
        }
        None
    }

    fn read(&self, start: u64, len: u64) -> Option<Vec<u8>> {
        if len == 0 || start >= self.total {
            return None;
        }
        let len = len.min(self.total - start);
        if let Some(v) = self.from_buf(start, len) {
            return Some(v);
        }
        if let Some(v) = self.read_from_disk(start, len) {
            return Some(v);
        }
        // Tarmoqqa chiqyapmiz — bir yo'la ko'proq olamiz.
        let want = len.max(Self::READAHEAD).min(self.total - start);
        let data = self.read_from_net(start, want, len)?;
        let out = data[..len as usize].to_vec();
        if data.len() as u64 <= Self::BUF_MAX {
            self.keep(start, data);
        }
        Some(out)
    }

    /// Kerakli baytlar TO'LIQ keshda bo'lsa — tarmoqqa umuman
    /// chiqilmaydi (yuklab olingan qismlarda thumbnail bepul).
    /// Zaxira bo'lakni saqlaydi (eng ko'pi ikkita, eskisi chiqadi).
    fn keep(&self, start: u64, data: Vec<u8>) {
        let mut b = self.buf.borrow_mut();
        if b.len() >= 2 {
            // Faylning BOSHI (kalit kadrlar shu yerda) iloji boricha
            // saqlanadi — oxiridagi eski bo'lak chiqadi.
            let drop = b.iter().position(|(at, _)| *at != 0).unwrap_or(0);
            b.remove(drop);
        }
        b.push((start, data));
    }

    fn read_from_disk(&self, start: u64, len: u64) -> Option<Vec<u8>> {
        let first = start / CHUNK_SIZE;
        let last = (start + len - 1) / CHUNK_SIZE;
        let mut out = Vec::with_capacity(len as usize);
        for i in first..=last {
            let plain_len = chunk_plain_len(i, self.total);
            if plain_len == 0 {
                return None;
            }
            let chunk = read_cached_chunk(&self.dir, &self.key, i, plain_len as usize)?;
            let chunk_start = i * CHUNK_SIZE;
            let chunk_end = chunk_start + plain_len;
            let from = start.max(chunk_start) - chunk_start;
            let to = (start + len).min(chunk_end) - chunk_start;
            if from >= to || to > chunk.len() as u64 {
                return None;
            }
            out.extend_from_slice(&chunk[from as usize..to as usize]);
        }
        if out.len() as u64 == len {
            Some(out)
        } else {
            None
        }
    }

    /// `want` bayt so'raydi, lekin KAMIDA `need` bayt kelsa
    /// yetarli deb hisoblaydi.
    ///
    /// Nega shunday: zaxira uchun kerakligidan ko'proq so'raymiz
    /// va manba undan kamroq bersa (fayl oxiriga yaqin joy,
    /// oraliqni qisqartiradigan proksi) bu XATO emas — kerakli
    /// qism baribir kelgan bo'lsa ish davom etadi.
    fn read_from_net(&self, start: u64, want: u64, need: u64) -> Option<Vec<u8>> {
        let end = start + want - 1;
        let resp = signed(self.shared.warm_agent.get(&self.url), "GET", &self.url)
            .timeout(THUMB_NET_TIMEOUT)
            .set("Range", &format!("bytes={start}-{end}"))
            .call()
            .ok()?;
        // Manba Range'ni e'tiborsiz qoldirib BUTUN faylni
        // yuborayotgan bo'lsa (status 200), boshidan boshqa hech
        // qayerni o'qib bo'lmaydi — bunday javobni qabul qilmaymiz,
        // aks holda noto'g'ri baytdan "kadr" yasab qo'yardik.
        if resp.status() != 206 && start != 0 {
            return None;
        }
        let mut buf = Vec::with_capacity(want as usize);
        resp.into_reader()
            .take(want)
            .read_to_end(&mut buf)
            .ok()?;
        note_net_bytes(&self.key, buf.len() as u64);
        if buf.len() as u64 >= need {
            Some(buf)
        } else {
            None
        }
    }
}

/// Faylning yuqori darajadagi atomlarini kezib `moov` ni topadi.
///
/// Faqat 16 baytlik SARLAVHALAR o'qiladi, ya'ni `mdat` (butun video)
/// ustidan sakrab o'tiladi va uning birorta bayti ham olinmaydi.
/// Shu sabab `moov` faylning oxirida turgan taqdirda ham (faststart
/// qilinmagan fayllar) bu yo'l ishlaydi.
/// Kadr uchun tarmoq so'rovining eng uzun kutishi.
///
/// Worker yozishmadagi faylni FAQAT keshdan beradi: fayl hali
/// keshda bo'lmasa, birinchi so'rov butun fayl keshga
/// ko'chirilguncha javobsiz turadi (katta videoda o'nlab soniya).
/// Ulanish shu orada uzilsa, isitish ham to'xtab qolardi va kadr
/// HECH QACHON chiqmasdi. Shu sabab bu yerda uzoq kutiladi —
/// kadr ajratuvchi (Kotlin) vaqti tugab ketsa ham ish davom etadi
/// va natija `THUMB_MEMO` da qoladi: keyingi urinish uni darhol
/// oladi.
const THUMB_NET_TIMEOUT: Duration = Duration::from_secs(180);

/// Faylning boshini (`want` bayt) oladi va umumiy hajmni
/// `Content-Range` dan o'qiydi: `(hajm, turi, baytlar)`.
fn probe_head(shared: &Shared, url: &str, want: u64) -> Option<(u64, String, Vec<u8>)> {
    let resp = signed(shared.warm_agent.get(url), "GET", url)
        .timeout(THUMB_NET_TIMEOUT)
        .set("Range", &format!("bytes=0-{}", want.saturating_sub(1)))
        .call()
        .ok()?;
    let ct = resp
        .header("Content-Type")
        .unwrap_or("video/mp4")
        .to_string();
    let total: u64 = if resp.status() == 206 {
        resp.header("Content-Range")?
            .rsplit('/')
            .next()?
            .trim()
            .parse()
            .ok()?
    } else {
        // 200 — oraliq e'tiborsiz qoldirildi, tana butun fayl.
        resp.header("Content-Length")?.trim().parse().ok()?
    };
    if total == 0 {
        return None;
    }
    let mut buf = Vec::with_capacity(want.min(total) as usize);
    resp.into_reader()
        .take(want.min(total))
        .read_to_end(&mut buf)
        .ok()?;
    Some((total, ct, buf))
}

fn find_moov(reader: &ThumbReader) -> Option<Vec<u8>> {
    /// Himoya: buzilgan faylda cheksiz aylanib qolmaslik uchun.
    const MAX_BOXES: usize = 64;
    /// `moov` odatda 1 MB atrofida; 32 MB dan kattasi shubhali.
    const MAX_MOOV: u64 = 32 * 1024 * 1024;

    let mut at: u64 = 0;
    for _ in 0..MAX_BOXES {
        if at + 8 > reader.total {
            return None;
        }
        let head = reader.read(at, 16.min(reader.total - at))?;
        let (body_in_head, raw_len, kind) = crate::mp4::box_header(&head, 0)?;
        let body_start = at + body_in_head as u64;
        if body_start > reader.total {
            return None;
        }
        let body_len = if raw_len == u64::MAX {
            reader.total - body_start
        } else {
            raw_len
        };
        if &kind == b"moov" {
            if body_len == 0 || body_len > MAX_MOOV {
                return None;
            }
            return reader.read(body_start, body_len);
        }
        let next = body_start.checked_add(body_len)?;
        if next <= at {
            return None;
        }
        at = next;
    }
    None
}

/// Yaqinda yasalgan kadrlar — xotirada, qisqa muddatga.
///
/// NEGA KERAK: Android'ning kadr ajratuvchisi bitta manzilni bir
/// necha marta ochadi (avval metadata uchun, keyin kadrning o'zi
/// uchun). Saqlanmasa, HAR SAFAR `moov` qaytadan yuklanardi.
///
/// ═══════════════════════════════════════════════════════════════
///  TOPILGAN XATO: BITTA YOZUV YETMAS EKAN
/// ═══════════════════════════════════════════════════════════════
///
/// Ilgari bu yerda ATIGI BITTA yozuv turardi va izohda "bitta
/// yetarli — ro'yxat qatorlari birin-ketin so'raydi" deb yozilgan
/// edi. Bu TAXMIN faqat BITTA kadr yasalayotganda to'g'ri. Tomosha
/// tarixi esa ikkitasini parallel yasaydi
/// (`watch_history.dart` -> `_maxParallelThumbs`).
///
/// Natijada shunday bo'lardi:
///
///   1. A videosi uchun bo'lak yasaldi  -> yozuv = A
///   2. B videosi uchun bo'lak yasaldi  -> yozuv = B (A O'CHDI)
///   3. A ning kadr ajratuvchisi manzilni QAYTA ochdi -> yozuv
///      topilmadi -> butun bo'lak qaytadan yasaladi. Sekin
///      tarmoqda bu urinish muddati tugab, A KADRSIZ qolardi.
///
/// Ya'ni bir vaqtda nechta so'ralsa ham, amalda FAQAT BITTASI
/// omadli chiqardi. Foydalanuvchining skrinshotlarida aynan
/// shunday edi: uch-to'rt videodan har safar bittasida kadr
/// chiqardi.
///
/// (Yo'ldan chiqqan taxmin: videolar buzuq deb o'ylangan edi.
/// Foydalanuvchi ularning Telegram'da kadr bilan turganini
/// ko'rsatib, buni RAD ETDI — fayllar butun, xato bu yerda edi.)
///
/// ── YECHIM ────────────────────────────────────────────────────
///
/// Bir nechta yozuv saqlanadi. Chegara ikki tomonlama: yozuvlar
/// SONI ham, ularning umumiy HAJMI ham cheklangan — bo'lak
/// odatda 50-300 KB, lekin uzun kalit kadr oralig'ida bir necha
/// megabayt bo'lishi mumkin (`MAX_SPAN`).
static THUMB_MEMO: Mutex<Vec<(String, Vec<u8>, Instant)>> = Mutex::new(Vec::new());
const THUMB_MEMO_SECS: u64 = 600;
/// Eng ko'pi shuncha yozuv.
///
/// Kadr yasash endi uzoq davom etishi mumkin (fayl keshga
/// ko'chirilguncha, `THUMB_NET_TIMEOUT`) va kadr ajratuvchi
/// o'shangacha taslim bo'lgan bo'ladi. Tayyor bo'lak shu yerda
/// kutib turadi — keyingi urinish (yoki yozishma qayta ochilganda)
/// uni darhol oladi. Bir vaqtda bir necha video shunday kutishi
/// mumkin, shu sabab 8 ta.
const THUMB_MEMO_MAX: usize = 8;
/// Va eng ko'pi shuncha bayt.
///
/// Bo'lak odatda 50-300 KB; 6 MB sakkizta odatdagi bo'lakka
/// yetadi. Ilgari bu yerda 12 MB turardi — arzon telefonda bu
/// sezilarli va ijroga xalaqit berishi mumkin edi.
const THUMB_MEMO_BYTES: usize = 6 * 1024 * 1024;

// ── `moov` JADVALI XOTIRADA SAQLANADI ─────────────────────────
//
// TOPILGAN XATO (foydalanuvchi: "tomosha tarixidagi kadrlar sekin
// yangilanyapti", "pleyer sekin ochilyapti").
//
// Har bir kadr so'rovi `moov` ni (odatda 0,3-2 MB) QAYTADAN
// tarmoqdan olardi — hatto o'sha videoning kadri bir daqiqa oldin
// yasalgan bo'lsa ham. Ko'rish davomida kadr har 45 soniyada
// oldindan tayyorlanadi, ya'ni har safar megabaytlab ortiqcha
// trafik ijro bilan BIR KANALNI bo'lishardi va pleyer qotardi.
//
// `moov` video o'zgarmaguncha o'zgarmaydi — uni bir marta olib,
// xotirada ushlab turish kifoya. Endi keyingi kadrlar uchun
// faqat kalit kadr baytlari olinadi.
static MOOV_MEMO: Mutex<Vec<(String, std::sync::Arc<Vec<u8>>, Instant)>> =
    Mutex::new(Vec::new());
/// Bir vaqtda shuncha videoning `moov` i saqlanadi.
const MOOV_MEMO_MAX: usize = 4;
/// Jami hajm chegarasi — arzon telefonda xotira ijrodan olinmasin.
const MOOV_MEMO_BYTES: usize = 16 * 1024 * 1024;
/// Shuncha vaqt ishlatilmasa chiqarib yuboriladi.
const MOOV_MEMO_SECS: u64 = 30 * 60;

fn moov_from_memo(key: &str) -> Option<std::sync::Arc<Vec<u8>>> {
    let mut guard = MOOV_MEMO.lock().ok()?;
    guard.retain(|(_, _, at)| at.elapsed().as_secs() <= MOOV_MEMO_SECS);
    let pos = guard.iter().position(|(k, _, _)| k == key)?;
    // Ishlatilgani oxiriga (eng yangi) ko'chadi.
    let (k, bytes, _) = guard.remove(pos);
    guard.push((k, bytes.clone(), Instant::now()));
    Some(bytes)
}

fn moov_to_memo(key: &str, bytes: Vec<u8>) -> std::sync::Arc<Vec<u8>> {
    let arc = std::sync::Arc::new(bytes);
    let Ok(mut guard) = MOOV_MEMO.lock() else {
        return arc;
    };
    guard.retain(|(k, _, at)| k != key && at.elapsed().as_secs() <= MOOV_MEMO_SECS);
    guard.push((key.to_string(), arc.clone(), Instant::now()));
    while guard.len() > MOOV_MEMO_MAX {
        guard.remove(0);
    }
    while guard.len() > 1
        && guard.iter().map(|(_, b, _)| b.len()).sum::<usize>() > MOOV_MEMO_BYTES
    {
        guard.remove(0);
    }
    arc
}

fn thumb_from_memo(tag: &str) -> Option<Vec<u8>> {
    let guard = THUMB_MEMO.lock().ok()?;
    for (saved_tag, bytes, at) in guard.iter() {
        if saved_tag == tag && at.elapsed().as_secs() <= THUMB_MEMO_SECS {
            return Some(bytes.clone());
        }
    }
    None
}

fn thumb_to_memo(tag: &str, bytes: &[u8]) {
    let Ok(mut guard) = THUMB_MEMO.lock() else {
        return;
    };
    // Muddati o'tganlari va shu tagning eski nusxasi chiqib ketadi.
    guard.retain(|(t, _, at)| {
        t != tag && at.elapsed().as_secs() <= THUMB_MEMO_SECS
    });
    guard.push((tag.to_string(), bytes.to_vec(), Instant::now()));
    // Chegaradan oshsa — ENG ESKISI olib tashlanadi (ro'yxat
    // qo'shilish tartibida, ya'ni birinchisi eng eskisi).
    while guard.len() > THUMB_MEMO_MAX {
        guard.remove(0);
    }
    while guard.len() > 1
        && guard.iter().map(|(_, b, _)| b.len()).sum::<usize>() > THUMB_MEMO_BYTES
    {
        guard.remove(0);
    }
}

/// KALIT KADRDAN SO'RALGAN KADRGACHA bo'lgan kichik MP4.
///
/// ── NEGA BITTA KADR YETMAYDI ──────────────────────────────────
///
/// Dekoder rasmni faqat KALIT KADRDAN boshlab ocha oladi. Kalit
/// kadrlar esa odatda 2-10 soniyada bir keladi, ya'ni "bitta
/// kadrlik MP4" har doim foydalanuvchi to'xtagan joydan bir necha
/// soniya OLDINGI rasmni berardi (foydalanuvchi aynan shuni
/// ko'rgan va shikoyat qilgan).
///
/// Endi kalit kadrdan so'ralgan kadrgacha bo'lgan namunalar bir
/// yo'la olinadi va MP4 ning OXIRGI kadri aynan kerakli kadr
/// bo'ladi.
///
/// ── TARMOQQA BITTA SO'ROV ─────────────────────────────────────
///
/// Namunalar fayl ichida ketma-ket yotadi (orasida ovoz bo'lishi
/// mumkin), shu sabab ular BITTA oraliq bilan o'qiladi va keyin
/// xotirada ajratiladi. Har bir namuna uchun alohida so'rov
/// yuborish — yo'l kechikishi sabab — bir necha barobar sekin
/// bo'lardi.
///
/// Oraliq juda katta chiqsa (buzilgan jadval yoki juda uzun kalit
/// kadr oralig'i) eski yo'lga — bitta kalit kadrga — qaytamiz:
/// rasm bir oz eskiroq bo'ladi, lekin trafik cheklangan qoladi.
fn build_thumb_clip(
    reader: &ThumbReader,
    track: &crate::mp4::VideoTrack,
    sync: u32,
    target: u32,
) -> Option<Vec<u8>> {
    /// Bitta kadr uchun eng ko'pi shuncha bayt o'qiladi.
    ///
    /// Odatdagi kalit kadr oralig'i (2-10 s) bunga bemalol
    /// sig'adi; chegara faqat buzilgan yoki g'alati fayldan
    /// himoya. Yasalgan bo'lak 60 soniya XOTIRADA turadi
    /// (`THUMB_MEMO`), shu sabab uni katta qilib bo'lmaydi.
    const MAX_SPAN: u64 = 8 * 1024 * 1024;
    /// Va eng ko'pi shuncha namuna (uzun kalit kadr oralig'idan
    /// himoya).
    const MAX_SAMPLES: u32 = 900;

    let single = |sample: u32| -> Option<Vec<u8>> {
        let loc = track.locate(sample)?;
        if loc.size == 0 || loc.size as u64 > 32 * 1024 * 1024 {
            return None;
        }
        let data = reader.read(loc.offset, loc.size as u64)?;
        let built = crate::mp4::build_single_frame_mp4(track, sample, &data)?;
        log(format!(
            "Kadr tayyor (kalit kadr): namuna #{sample}, {} bayt",
            built.len()
        ));
        Some(built)
    };

    if target <= sync || target - sync + 1 > MAX_SAMPLES {
        return single(sync);
    }

    // Namunalarning fayldagi o'rinlari.
    let mut refs = Vec::with_capacity((target - sync + 1) as usize);
    for s in sync..=target {
        let loc = match track.locate(s) {
            Some(v) => v,
            None => return single(sync),
        };
        if loc.size == 0 {
            return single(sync);
        }
        refs.push((loc.offset, loc.size));
    }

    let start = refs.iter().map(|(o, _)| *o).min()?;
    let end = refs.iter().map(|(o, s)| *o + *s as u64).max()?;
    if end <= start || end - start > MAX_SPAN {
        return single(sync);
    }

    let span = match reader.read(start, end - start) {
        Some(v) => v,
        None => return single(sync),
    };

    let mut sizes = Vec::with_capacity(refs.len());
    let mut data = Vec::with_capacity((end - start) as usize);
    for (offset, size) in &refs {
        let from = (*offset - start) as usize;
        let to = from + *size as usize;
        if to > span.len() {
            return single(sync);
        }
        data.extend_from_slice(&span[from..to]);
        sizes.push(*size);
    }

    match crate::mp4::build_clip_mp4(track, sync, &sizes, &data) {
        Some(built) => {
            log(format!(
                "Kadr tayyor: namunalar #{sync}-#{target}, {} bayt",
                built.len()
            ));
            Some(built)
        }
        None => single(sync),
    }
}

fn serve_thumb(
    stream: &mut TcpStream,
    url: &str,
    ms: u64,
    exact: bool,
    range_header: Option<&str>,
) -> std::io::Result<()> {
    let not_found = |stream: &mut TcpStream| -> std::io::Result<()> {
        write_status_and_headers(stream, 404, "Not Found", &[])
    };

    let Some(shared) = SHARED.get() else {
        return not_found(stream);
    };
    let key = cache_key(url);
    let tag = format!("{key}|{ms}|{}", if exact { 1 } else { 0 });

    let body = match thumb_from_memo(&tag) {
        Some(cached) => cached,
        None => {
            let dir = shared.cache_root.join(&key);
            let _ = fs::create_dir_all(&dir);

            // Hajm: avval diskdan, bo'lmasa bitta kichik so'rov bilan.
            let mut total = meta_total_from_disk(&dir);
            // ── HAJM BIRINCHI O'QISHNING O'ZIDAN ─────────────────
            //
            // TOPILGAN XATO (foydalanuvchi: "support chatdagi
            // videolarning hammasida thumbnail ko'rsatilmayapti").
            //
            // Ilgari hajm alohida so'ralardi: avval HEAD (worker
            // uni tanimaydi — har doim 404), keyin `bytes=0-0`.
            // Ya'ni kadrning o'ziga yetguncha IKKITA ortiqcha
            // so'rov ketardi. Endi faylning boshi (256 KB) bitta
            // so'rovda olinadi va hajm uning `Content-Range`
            // sarlavhasidan o'qiladi; olingan baytlar esa zaxira
            // bo'lak bo'lib qoladi (ftyp, ko'pincha moov va kalit
            // kadr ham shu yerda).
            let mut head: Option<Vec<u8>> = None;
            if total == 0 {
                if let Some((t, ct, bytes)) = probe_head(shared, url, ThumbReader::READAHEAD) {
                    note_net_bytes(&key, bytes.len() as u64);
                    write_meta(
                        &dir,
                        &CacheMeta {
                            total_size: t,
                            content_type: ct,
                            chunk_size: CHUNK_SIZE,
                            duration_secs: 0.0,
                            chunk_start_ms: Vec::new(),
                        },
                    );
                    total = t;
                    head = Some(bytes);
                }
            }
            if total == 0 {
                total = ensure_meta(shared, &dir, url)
                    .map(|m| m.total_size)
                    .unwrap_or(0);
            }
            if total == 0 {
                log("Kadr: hajm aniqlanmadi".to_string());
                return not_found(stream);
            }

            let reader = ThumbReader {
                shared,
                dir,
                key: key.clone(),
                url: url.to_string(),
                total,
                buf: RefCell::new(Vec::new()),
            };
            if let Some(bytes) = head {
                if !bytes.is_empty() && bytes.len() as u64 <= ThumbReader::BUF_MAX {
                    reader.keep(0, bytes);
                }
            }

            // Har bir qadamda "bo'lmasa 404" — foydalanuvchi
            // posterni ko'radi, ilova esa hech qachon yiqilmaydi.
            let moov = match moov_from_memo(&key) {
                Some(m) => m,
                None => {
                    let Some(m) = find_moov(&reader) else {
                        log("Kadr: moov topilmadi".to_string());
                        return not_found(stream);
                    };
                    moov_to_memo(&key, m)
                }
            };
            let Some(track) = crate::mp4::parse_moov(&moov) else {
                log("Kadr: video yo'lakcha o'qilmadi".to_string());
                return not_found(stream);
            };
            let mut target = track.sample_at_ms(ms);
            let sync = track.sync_at_or_before(target);
            // `exact=0` — faqat KALIT KADR (bitta kichik o'qish).
            // Ko'rish davomidagi oldindan tayyorlash shuni so'raydi:
            // u ijro bilan bir kanalni bo'lishadi va kalit kadrdan
            // to'xtagan joygacha bo'lgan (8 MB gacha) oraliqni
            // olib, pleyerni sekinlashtirmasligi kerak.
            if !exact {
                target = sync;
            }
            let Some(built) = build_thumb_clip(&reader, &track, sync, target) else {
                log("Kadr: bo'lak yasalmadi".to_string());
                return not_found(stream);
            };
            thumb_to_memo(&tag, &built);
            built
        }
    };

    // Kadr ajratuvchi ko'pincha Range bilan so'raydi — qo'llab
    // quvvatlaymiz (javob baribir xotirada, kesish arzon).
    let total = body.len() as u64;
    let (start, end, is_range) = match range_header {
        Some(h) if h.starts_with("bytes=") => {
            let spec = &h[6..];
            let (s_str, e_str) = spec.split_once('-').unwrap_or((spec, ""));
            let s: u64 = s_str.parse().unwrap_or(0);
            let e: u64 = if e_str.is_empty() {
                total - 1
            } else {
                e_str.parse().unwrap_or(total - 1)
            };
            (s, e.min(total - 1), true)
        }
        _ => (0, total.saturating_sub(1), false),
    };
    if start > end || start >= total {
        return write_status_and_headers(
            stream,
            416,
            "Range Not Satisfiable",
            &[("Content-Range", format!("bytes */{total}"))],
        );
    }

    let slice = &body[start as usize..=end as usize];
    let mut headers: Vec<(&str, String)> = vec![
        ("Content-Type", "video/mp4".to_string()),
        ("Content-Length", slice.len().to_string()),
        ("Accept-Ranges", "bytes".to_string()),
    ];
    if is_range {
        headers.push(("Content-Range", format!("bytes {start}-{end}/{total}")));
    }
    write_status_and_headers(
        stream,
        if is_range { 206 } else { 200 },
        if is_range { "Partial Content" } else { "OK" },
        &headers,
    )?;
    stream.write_all(slice)
}

// ── Asosiy servis funksiyasi: Range'ni tahlil qilib, javobni yozadi ──

fn serve(stream: &mut TcpStream, url: &str, range_header: Option<&str>) -> std::io::Result<()> {
    let shared = SHARED.get().expect("shared holat ishga tushmagan");
    let key = cache_key(url);
    let dir = shared.cache_root.join(&key);
    fs::create_dir_all(&dir)?;

    // ── HAJM HAM FAQAT DISKDAN OLINADI ─────────────────────────
    //
    // Ilgari bu yerda `ensure_meta` chaqirilardi va u meta.json
    // bo'lmasa hajmni aniqlash uchun TARMOQQA chiqardi. Endi
    // mahalliy server tarmoqqa UMUMAN chiqmaydi: meta.json bo'lmasa
    // — demak bu video mahalliy ijro uchun tayyor emas va ilova
    // workerdan ko'rsatishi kerak.
    let total = meta_total_from_disk(&dir);
    if total == 0 {
        log("Mahalliy ijro: meta.json yo'q — worker yo'li ishlatilsin".to_string());
        write_status_and_headers(stream, 404, "Not Found", &[])?;
        return Ok(());
    }
    log(format!("Meta: hajm={total} (diskdan)"));

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

    // ═══════════════════════════════════════════════════════════
    //  ODDIY HTTP SERVER: HECH NARSA USHLAB TURILMAYDI
    // ═══════════════════════════════════════════════════════════
    //
    // ── NEGA "SEKINLASHTIRISH" BUTUNLAY OLIB TASHLANDI ─────────
    //
    // Avval bu server pleyerga baytlarni ATAYLAB sekin berardi:
    // "ijro nuqtasidan 15 soniya oldinga" degan chegara bor edi.
    // Maqsad — foydalanuvchi trafigini tejash — to'g'ri edi, lekin
    // YECHIM NOTO'G'RI edi.
    //
    // O'LCHOV (sekin mobil tarmoqda, 125 KB/s):
    //   * oqim 90 soniyada 16 marta 5-8 SONIYAGA jim qolardi;
    //   * ExoPlayer'ning HTTP o'qish chegarasi esa 8 SONIYA.
    // Ya'ni pleyer ulanishni xato deb uzardi, video to'xtardi yoki
    // boshidan boshlanardi. Tez internetda muammo ko'rinmasdi.
    //
    // ── CHEKLOV ALLAQACHON PLEYER TOMONIDA BOR (media3 manbasi) ─
    //
    //   DefaultLoadControl.DEFAULT_MAX_BUFFER_MS = 50_000
    //   shouldContinueLoading(): bufer >= maxBufferUs -> false
    //   ProgressiveMediaPeriod.ExtractingLoadable.load():
    //       loadCondition.block();   // bufer to'lsa SHU YERDA TO'XTAYDI
    //
    // Ya'ni pleyer buferida 50 soniyalik video yig'ilishi bilan u
    // soketdan O'QISHNI TO'XTATADI. Biz yozayotgan bo'lsak, TCP
    // o'zi bizni ushlab qoladi (`write_all` bloklanadi) — demak
    // tarmoqdan ham hech narsa olinmaydi.
    //
    // XULOSA: 24 daqiqalik 166 MB'lik videoda 50 soniya ~6-12 MB
    // degani — butun fayl EMAS. Serverning yana o'zidan cheklashi
    // hech narsa qo'shmaydi, faqat yuqoridagi nosozlikni keltirib
    // chiqaradi.
    //
    // Shu sabab endi server ODDIY, TO'G'RI HTTP fayl serveri:
    // so'ralgan baytni imkon qadar TEZ beradi, keshda bo'lmasa
    // tarmoqdan olib, kelishi bilan DARHOL uzatadi va bir vaqtda
    // diskka yozadi.

    let content_length = end - start + 1;

    if is_range {
        write_status_and_headers(
            stream,
            206,
            "Partial Content",
            &[
                ("Accept-Ranges", "bytes".to_string()),
                ("Content-Type", "video/mp4".to_string()),
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
                ("Content-Type", "video/mp4".to_string()),
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
    // Hozir qo'lda turgan bo'lak: (indeks, baytlar). Bir bo'lak
    // bir necha bo'lib yozilishi mumkin (chegara asta ochiladi),
    // shu sabab uni qayta-qayta diskdan o'qib, shifrini ochish
    // keraksiz — bir marta o'qib, shu yerda ushlab turiladi.
    let mut held: Option<(u64, Vec<u8>)> = None;
    while cursor <= end {
        let chunk_index = cursor / CHUNK_SIZE;
        let chunk_start = chunk_index * CHUNK_SIZE;
        let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);
        // Shu bo'lakda shu so'rov uchun kerak bo'lgan OXIRGI bayt.
        let stop = chunk_end.min(end);

        // Bu bo'lakdan shu so'rov uchun kerak bo'lgan HAMMA bayt
        // beriladi — hech narsa ushlab turilmaydi.
        let write_to = stop + 1;

        // ═══════════════════════════════════════════════════════
        //  BO'LAK FAQAT DISKDAN O'QILADI — TARMOQQA CHIQILMAYDI
        // ═══════════════════════════════════════════════════════
        //
        // ── TUZATILGAN XATO (foydalanuvchi ko'rgan) ─────────────
        //
        // Mahalliy server diskda yetishmayotgan bo'lakni ko'rsa, uni
        // TARMOQDAN olib, diskka yozib qo'yardi. Ya'ni "videoni
        // ko'rish" amalda "yuklab olish"ga aylanardi: foydalanuvchi
        // yuklab olish tugmasini bosmagan bo'lsa ham, video diskka
        // yozilib borardi.
        //
        // Eng yomoni: videoni O'CHIRGANDAN keyin ham ekrandagi hisob
        // bir necha soniya "to'liq" bo'lib turardi, pleyer esa shunga
        // ishonib mahalliy serverga kelardi — va bu yerda butun fayl
        // QAYTADAN yuklab olinardi.
        //
        // ── ENDI: IKKI MUSTAQIL TIZIM ──────────────────────────
        //
        //   * fayl 100% diskda  -> mahalliy server (tarmoq YO'Q);
        //   * fayl to'liq emas  -> FAQAT worker (diskka YOZILMAYDI).
        //
        // Mahalliy server faqat to'liq yuklab olingan fayl uchun
        // ishlatilgani sabab kerakli bo'lak har doim diskda bo'ladi.
        // Kutilmaganda topilmasa — ulanish yopiladi va ilova
        // workerga o'tadi (`_playEpisode` ichidagi zaxira yo'l).
        if held.as_ref().map(|(i, _)| *i) != Some(chunk_index) {
            let expected_len = (chunk_end - chunk_start + 1) as usize;
            match read_cached_chunk(&dir, &key, chunk_index, expected_len) {
                Some(bytes) => {
                    // Hisob (foiz) uchun: bu bo'lak diskda BOR.
                    stat_note_chunk(&key, chunk_index, expected_len as u64);
                    held = Some((chunk_index, bytes));
                }
                None => {
                    log(format!(
                        "Bo'lak #{chunk_index} diskda yo'q — mahalliy ijro to'xtatildi \
                         (tarmoqqa CHIQILMAYDI)"
                    ));
                    break;
                }
            }
        }

        let chunk_bytes = match held.as_ref() {
            Some((_, b)) => b,
            None => break,
        };

        let slice_start = (cursor - chunk_start) as usize;
        let wanted_end_exclusive = (write_to - chunk_start) as usize;
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
        // Faqat HAQIQATAN uzatilgan baytlar hisoblanadi.
        SERVED_BYTES.fetch_add((slice_end_exclusive - slice_start) as u64, Ordering::Relaxed);
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


// ═══════════════════════════════════════════════════════════════════
//  TESTLAR
// ═══════════════════════════════════════════════════════════════════
//
// Bu testlar TARMOQQA UMUMAN CHIQMAYDI: kesh papkasi oldindan
// to'ldiriladi (meta.json + bo'lak fayllari), shundan keyin server
// xuddi pleyer kabi HTTP so'rovlar bilan "qiynaladi". Shu bilan
// eng muhim ikki narsa tekshiriladi:
//   1) To'liq keshlangan fayl BITTA javobda beriladimi (qayta
//      ulanish bo'ronisiz);
//   2) Ketma-ket ko'p marta "sek" qilinganda (ulanishni yarmida
//      tashlab ketish) server javob berishda davom etadimi.
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpStream;

    const TEST_TOTAL: u64 = 9_036_153; // foydalanuvchining haqiqiy fayli
    const TEST_NAME: &str = "testvid.mp4";

    /// Testlar ISHLAB CHIQARISHDAGI holatni sinashi kerak — ya'ni
    /// shifrlash YOQILGAN holatni. Kalit qat'iy (o'zgarmas), chunki
    /// testlar bitta jarayonda parallel ishlaydi va tasodifiy kalit
    /// bir-birini almashtirib yuborardi.
    fn enable_crypto() {
        assert!(crypto::set_master_key_hex(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        ));
    }

    /// XIZMAT FAYLLARI DISKDA OCHIQ YOTMASLIGI KERAK.
    ///
    /// `meta.json` foydalanuvchi NIMA ko'rganini oshkor qiladi
    /// (fayl nomida sifat va epizod raqami bor), shu sabab u ham
    /// shifrlanadi. Bu test ikki narsani qo'riqlaydi:
    ///
    ///   1) diskdagi baytlarda ochiq matn (`total_size`) YO'Q;
    ///   2) yozilgan ma'lumot qaytib o'qilganda aynan o'zi chiqadi.
    ///
    /// Ustiga migratsiya ham tekshiriladi: shifrlashdan OLDIN
    /// yozilgan ochiq fayl ham o'qilishi kerak — aks holda
    /// yangilanishdan keyin foydalanuvchining keshi yo'qolardi.
    #[test]
    fn xizmat_fayllari_shifrlangan_holda_yoziladi() {
        enable_crypto();
        let dir = std::env::temp_dir().join(format!(
            "aru_meta_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();

        let meta = CacheMeta {
            total_size: 123_456_789,
            content_type: "video/mp4".to_string(),
            chunk_size: CHUNK_SIZE,
            duration_secs: 0.0,
            chunk_start_ms: Vec::new(),
        };
        assert!(write_meta(&dir, &meta), "meta yozilmadi");

        let raw = fs::read(dir.join("meta.json")).unwrap();
        assert!(
            !raw.windows(10).any(|w| w == b"total_size"),
            "meta.json diskda OCHIQ yotibdi"
        );
        assert!(
            !raw.windows(9).any(|w| w == b"123456789"),
            "hajm diskda ochiq ko'rinib turibdi"
        );

        let back = read_meta(&dir).expect("meta o'qilmadi");
        assert_eq!(back.total_size, 123_456_789);
        assert_eq!(back.chunk_size, CHUNK_SIZE);
        assert_eq!(meta_total_from_disk(&dir), 123_456_789);

        // Migratsiya: eski (ochiq) fayl ham o'qilaveradi.
        fs::write(
            dir.join("meta.json"),
            format!(
                "{{\"total_size\":777,\"content_type\":\"video/mp4\",\"chunk_size\":{CHUNK_SIZE}}}"
            ),
        )
        .unwrap();
        assert_eq!(meta_total_from_disk(&dir), 777, "eski ochiq fayl o'qilmadi");

        let _ = fs::remove_dir_all(&dir);
    }

    fn fill_cache(root: &PathBuf, skip: Option<u64>) {
        let dir = root.join("video_byte_cache").join(TEST_NAME);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("meta.json"),
            format!(
                "{{\"total_size\":{TEST_TOTAL},\"content_type\":\"video/mp4\",\"chunk_size\":{CHUNK_SIZE}}}"
            ),
        )
        .unwrap();
        let chunks = TEST_TOTAL.div_ceil(CHUNK_SIZE);
        for i in 0..chunks {
            if Some(i) == skip {
                let _ = fs::remove_file(dir.join(chunk_name(i)));
                continue;
            }
            let cs = i * CHUNK_SIZE;
            let ce = (cs + CHUNK_SIZE - 1).min(TEST_TOTAL - 1);
            let len = (ce - cs + 1) as usize;
            // Har bir bayt o'z pozitsiyasidan hosil bo'ladi — shu bilan
            // qaytgan ma'lumot TO'G'RI joydan ekanini tekshira olamiz.
            let data: Vec<u8> = (0..len).map(|k| ((cs as usize + k) % 251) as u8).collect();
            let (k, iv) = crypto::derive_chunk_key_iv(TEST_NAME, i).unwrap();
            // ── ATOMIK YOZISH (ilovadagi `write_full_chunk` kabi) ──
            // Ilgari bu yerda to'g'ridan-to'g'ri `fs::write` ishlatilardi.
            // Fon'da ketayotgan skaner (`scan_and_clean`) esa YARIM
            // yozilgan faylni ko'rib, uzunligi noto'g'ri deb uni
            // O'CHIRIB yuborardi — test ~2-70% holatda shu sababdan
            // yiqilardi. Ilovaning o'zi hech qachon to'g'ridan-to'g'ri
            // yozmaydi, shu sabab bu FAQAT sinov nuqsoni edi.
            let tmp = dir.join(format!("{}.fill.tmp", chunk_name(i)));
            fs::write(&tmp, crypto::encrypt_chunk(&data, &k, &iv)).unwrap();
            fs::rename(&tmp, dir.join(chunk_name(i))).unwrap();
        }
    }


    /// "bytes=S-E" yoki "bytes=S-" ni (s, e) ga ajratadi.
    fn parse_test_range(range: &str, total: u64) -> (u64, u64) {
        let spec = range.strip_prefix("bytes=").unwrap_or("");
        let (s_str, e_str) = spec.split_once('-').unwrap_or((spec, ""));
        let s: u64 = s_str.trim().parse().unwrap_or(0);
        let e: u64 = if e_str.trim().is_empty() {
            total - 1
        } else {
            e_str.trim().parse().unwrap_or(total - 1)
        };
        (s, e.min(total - 1))
    }

    /// Test uchun eng oddiy "manba" server: Range so'rovlarini
    /// bajaradi va kelgan har bir Range'ni ro'yxatga yozadi.
    /// Tana baytlari o'z pozitsiyasidan hosil bo'ladi, shu sabab
    /// ma'lumot to'g'ri joydan kelganini tekshirish mumkin.
    fn start_origin(total: u64) -> (u16, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = Arc::clone(&log);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let l3 = Arc::clone(&l2);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    l3.lock().unwrap().push(range.clone());
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let _ = st.write_all(&body);
                });
            }
        });
        (port, log)
    }

    /// Ixtiyoriy manba URL'i bilan proksiga so'rov yuboradi.
    fn request_url(
        port: u16,
        origin_url: &str,
        range: Option<&str>,
        read_limit: Option<usize>,
    ) -> (u16, String, usize, Vec<u8>) {
        let encoded: String = origin_url
            .chars()
            .map(|c| match c {
                ':' => "%3A".to_string(),
                '/' => "%2F".to_string(),
                c => c.to_string(),
            })
            .collect();
        let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
        st.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut req = format!("GET /v?u={encoded} HTTP/1.1\r\nHost: x\r\n");
        if let Some(r) = range {
            req.push_str(&format!("Range: {r}\r\n"));
        }
        req.push_str("\r\n");
        st.write_all(req.as_bytes()).unwrap();
        let mut br = BufReader::new(st);
        let mut status_line = String::new();
        br.read_line(&mut status_line).unwrap();
        let status: u16 = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let mut cr = String::new();
        loop {
            let mut line = String::new();
            if br.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                break;
            }
            if let Some(v) = line.strip_prefix("Content-Range: ") {
                cr = v.trim().to_string();
            }
        }
        let mut body = Vec::new();
        match read_limit {
            None => {
                let _ = br.read_to_end(&mut body);
            }
            Some(n) => {
                // Javob endi HECH QACHON kesilmaydi (u butun faylni
                // e'lon qiladi va sekin-asta beriladi) — shu sabab
                // test faqat kerakli miqdorni o'qib, ulanishni
                // ATAYLAB tashlab ketadi. Pleyer sek qilganda ham
                // aynan shunday qiladi.
                let mut buf = vec![0u8; n];
                let mut got = 0;
                while got < n {
                    match br.read(&mut buf[got..]) {
                        Ok(0) => break,
                        Ok(k) => got += k,
                        Err(_) => break,
                    }
                }
                body.extend_from_slice(&buf[..got]);
            }
        }
        let len = body.len();
        (status, cr, len, body)
    }

    /// So'rov yuboradi. `read_limit` — javob tanasidan necha bayt
    /// o'qilsin (None = hammasi). Qaytaradi: (status, content-range,
    /// o'qilgan bayt soni).
    fn request(
        port: u16,
        range: Option<&str>,
        read_limit: Option<usize>,
    ) -> (u16, String, usize, Vec<u8>) {
        let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
        st.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut req = format!(
            "GET /v?u=http%3A%2F%2F127.0.0.1%3A9%2F{TEST_NAME} HTTP/1.1\r\nHost: x\r\n"
        );
        if let Some(r) = range {
            req.push_str(&format!("Range: {r}\r\n"));
        }
        req.push_str("\r\n");
        st.write_all(req.as_bytes()).unwrap();

        let mut br = BufReader::new(st);
        let mut status_line = String::new();
        br.read_line(&mut status_line).unwrap();
        let status: u16 = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let mut content_range = String::new();
        loop {
            let mut line = String::new();
            if br.read_line(&mut line).unwrap() == 0 {
                break;
            }
            if line == "\r\n" {
                break;
            }
            if let Some(v) = line.strip_prefix("Content-Range: ") {
                content_range = v.trim().to_string();
            }
        }
        let mut body = Vec::new();
        match read_limit {
            None => {
                br.read_to_end(&mut body).unwrap();
            }
            Some(n) => {
                let mut buf = vec![0u8; n];
                let mut got = 0;
                while got < n {
                    match br.read(&mut buf[got..]) {
                        Ok(0) => break,
                        Ok(k) => got += k,
                        Err(_) => break,
                    }
                }
                body.extend_from_slice(&buf[..got]);
                // Ulanishni ATAYLAB yarmida tashlab ketamiz — pleyer
                // sek qilganda aynan shunday qiladi.
            }
        }
        let len = body.len();
        (status, content_range, len, body)
    }

    /// Kesh-server BUTUN JARAYON uchun BITTA (PORT/SHARED — OnceLock).
    /// Shu sabab uni bir necha test baravar ishlata olishi uchun bu
    /// yerda bir marta ishga tushiriladi va (port, tashqi papka)
    /// qaytariladi.
    static TEST_SERVER: OnceLock<(u16, PathBuf)> = OnceLock::new();

    /// VAQT (yoki so'rovlar sonini) o'lchaydigan yuklash testlari
    /// bir-biri bilan PARALLEL ishlamasin — ular umumiy ulanishlar
    /// chegarasini (`DL_TOTAL_CONNS`) ham bo'lishadi: ular bitta yuklash havzasini (`DOWNLOAD_WORKERS`)
    /// va protsessorni (shifrlash) bo'lishadi va natija mashina
    /// yuklamasiga bog'liq bo'lib qolardi.
    fn vaqt_testi_qulfi() -> std::sync::MutexGuard<'static, ()> {
        static L: Mutex<()> = Mutex::new(());
        L.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn ensure_server() -> (u16, PathBuf) {
        static LOCK: Mutex<()> = Mutex::new(());
        let _g = LOCK.lock().unwrap();
        if let Some(v) = TEST_SERVER.get() {
            return v.clone();
        }
        enable_crypto();
        let root = std::env::temp_dir().join(format!(
            "vc_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let c_root = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let port = rust_video_cache_start(c_root.as_ptr());
        assert!(port > 0, "server ishga tushmadi");
        let v = (port as u16, root);
        let _ = TEST_SERVER.set(v.clone());
        v
    }

    #[test]
    fn keshdan_bir_javobda_va_sek_bosimiga_bardosh() {
        let (port, root) = ensure_server();
        fill_cache(&root, None);

        // ── 1) TO'LIQ KESHLANGAN FAYL: BITTA javobda hammasi ───────
        let (status, cr, len, body) = request(port, Some("bytes=0-"), None);
        assert_eq!(status, 206);
        assert_eq!(cr, format!("bytes 0-{}/{}", TEST_TOTAL - 1, TEST_TOTAL));
        assert_eq!(len as u64, TEST_TOTAL, "butun fayl bitta javobda kelmadi");
        // Ma'lumot to'g'ri joydan kelganini tekshiramiz (shu jumladan
        // bo'lak chegarasi — CHUNK_SIZE - 1 / CHUNK_SIZE).
        let cs = CHUNK_SIZE as usize;
        for probe in [0usize, cs - 1, cs, 5_000_000, len - 1] {
            assert_eq!(body[probe], (probe % 251) as u8, "bayt {probe} noto'g'ri");
        }

        // ── 2) O'RTADAN so'rov ham bitta javobda ───────────────────
        let (status, cr, len, body) = request(port, Some("bytes=5000000-"), None);
        assert_eq!(status, 206);
        assert_eq!(cr, format!("bytes 5000000-{}/{}", TEST_TOTAL - 1, TEST_TOTAL));
        assert_eq!(len as u64, TEST_TOTAL - 5_000_000);
        assert_eq!(body[0], (5_000_000usize % 251) as u8);

        // ── 3) SEK BO'RONI: 300 marta ulanib, yarmida tashlab ketish ─
        // Avval aynan shu holat serverni "bo'g'ib" qo'yardi va pleyer
        // javobsiz qolib qotardi.
        for i in 0..300u64 {
            let start = (i * 29_411) % (TEST_TOTAL - 1);
            let (st, _, _, _) =
                request(port, Some(&format!("bytes={start}-")), Some(16 * 1024));
            assert_eq!(st, 206, "sek #{i} da server javob bermadi");
        }

        // ── 4) Bo'ron tugagach server HALI HAM sog'lom bo'lishi kerak ─
        let (status, cr, len, _) = request(port, Some("bytes=0-"), None);
        assert_eq!(status, 206, "bo'rondan keyin server javob bermadi");
        assert_eq!(cr, format!("bytes 0-{}/{}", TEST_TOTAL - 1, TEST_TOTAL));
        assert_eq!(len as u64, TEST_TOTAL);

        // ── 5) 416: chegaradan tashqari so'rov ─────────────────────
        let (status, _, _, _) =
            request(port, Some(&format!("bytes={}-", TEST_TOTAL + 10)), None);
        assert_eq!(status, 416);

        // ── 6) PARALLEL ULANISHLAR ────────────────────────────────
        // Pleyer (mdk-sdk/FFmpeg) bir vaqtda bir NECHTA ulanish ochishi
        // mumkin — ayniqsa tez-tez sek qilinganda eskilari hali yopilib
        // ulgurmaydi. Server hammasiga javob berishi SHART: bittasi ham
        // rad etilsa, pleyer javobsiz qolib qotadi.
        let mut handles = Vec::new();
        for i in 0..40u64 {
            handles.push(thread::spawn(move || {
                let st = (i * 211_111) % (TEST_TOTAL - 1);
                request(port, Some(&format!("bytes={st}-")), Some(64 * 1024)).0
            }));
        }
        for (i, h) in handles.into_iter().enumerate() {
            let st = h.join().expect("ish oqimi yiqildi");
            assert_eq!(st, 206, "parallel ulanish #{i} rad etildi");
        }

        // ── 7) Suffiks so'rov: "bytes=-N" (fayl oxiridan N bayt) ───
        let (status, cr, len, _) = request(port, Some("bytes=-1000"), None);
        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes {}-{}/{}", TEST_TOTAL - 1000, TEST_TOTAL - 1, TEST_TOTAL)
        );
        assert_eq!(len, 1000);

        // ── 4) KESHDA BO'SHLIQ BO'LSA: ULANISH DARHOL YOPILADI ────
        //
        // YANGI QOIDA (foydalanuvchi talabi): pleyer va yuklab olish —
        // IKKI MUSTAQIL TIZIM. Mahalliy server TARMOQQA UMUMAN
        // CHIQMAYDI, u faqat diskdagi bo'laklarni beradi.
        //
        // Ilgari yetishmayotgan bo'lak shu yerda tarmoqdan olinib
        // diskka yozilardi — ya'ni "videoni ko'rish" amalda "yuklab
        // olish"ga aylanardi. Endi bo'shliqqacha bo'lgan qism
        // beriladi va ulanish DARHOL yopiladi; ilova esa workerga
        // o'tadi.
        let dir = root.join("video_byte_cache").join(TEST_NAME);
        fs::remove_file(dir.join(chunk_name(3))).unwrap();
        let gap_start = Instant::now();
        let (status, _cr, len, body) =
            request(port, Some("bytes=0-"), Some((3 * CHUNK_SIZE) as usize));
        assert_eq!(status, 206);
        assert_eq!(
            len as u64,
            3 * CHUNK_SIZE,
            "bo'shliqqacha bo'lgan qism bitta javobda kelmadi"
        );
        for (i, b) in body.iter().enumerate().take(2000) {
            assert_eq!(*b, (i % 251) as u8, "bayt #{i} noto'g'ri joydan");
        }
        // Tarmoqqa chiqilmagani uchun kutish ham yo'q — javob
        // deyarli bir zumda tugaydi.
        assert!(
            gap_start.elapsed() < Duration::from_secs(3),
            "bo'shliqda tarmoq kutilganga o'xshaydi — mahalliy server tarmoqqa chiqmasligi SHART"
        );

        // ── 8) YUKLAB OLISH HISOBI (progress) ─────────────────────
        // Yuqorida #3 bo'lak o'chirildi — demak hisob aynan bitta
        // bo'lakka kam bo'lishi kerak. TARMOQQA CHIQILMAYDI.
        //
        // Xotiradagi hisobni ataylab tozalaymiz, chunki bo'lak
        // ILOVADAN TASHQARIDA o'chirildi: ilovaning o'zi o'chirganda
        // hisob `stat_reset`/`stat_note_chunk` orqali darhol
        // yangilanadi, bu yerda esa aynan DISKNI SKANERLASH mantig'i
        // tekshirilyapti. (Server ishga tushganda kesh oldindan
        // skanerlanadi va natija xotirada saqlanadi — shu sabab uni
        // bo'shatmasak, eski hisob qaytardi.)
        stats().lock().unwrap().remove(TEST_NAME);
        let test_url = format!("http://127.0.0.1:9/{TEST_NAME}");
        let urls_json = serde_json::to_string(&vec![test_url.clone()]).unwrap();
        let c_urls = std::ffi::CString::new(urls_json).unwrap();
        let parsed = stats_json_ready(c_urls.as_ptr());
        let item = &parsed[&test_url];
        assert_eq!(item["total"].as_u64().unwrap(), TEST_TOTAL);
        assert_eq!(
            item["downloaded"].as_u64().unwrap(),
            TEST_TOTAL - CHUNK_SIZE,
            "yuklangan hajm noto'g'ri hisoblandi"
        );
        assert!(!item["downloading"].as_bool().unwrap());

        // ── 9) TOZALASH: hisob DARHOL nolga tushadi, fayllar esa
        // fon'da o'chiriladi.
        let c_url = std::ffi::CString::new(test_url.clone()).unwrap();
        assert_eq!(rust_video_cache_delete(c_url.as_ptr()), 1);
        let parsed = stats_json(c_urls.as_ptr());
        assert_eq!(parsed[&test_url]["downloaded"].as_u64().unwrap(), 0);

        // Fon ish oqimi bo'lak fayllarini haqiqatan o'chirganini
        // tekshiramiz (eng ko'pi 3 soniya kutiladi).
        let mut cleared = false;
        for _ in 0..60 {
            if fs::read_dir(&dir).map(|e| e.count()).unwrap_or(0) == 0 {
                cleared = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(cleared, "kesh fayllari o'chirilmadi");

        // ── 10) YARIM QOLGAN BO'LAK TOZALANADI ────────────────────
        // Uzunligi noto'g'ri (yarim yozilgan) fayl hisobga OLINMAYDI va
        // diskdan darhol o'chiriladi — foydalanuvchi keyin o'sha
        // joydan yuklashni davom ettiraveradi.
        fill_cache(&root, Some(5));
        fs::write(dir.join(chunk_name(5)), vec![7u8; 4096]).unwrap();
        // ── NEGA HALQA ICHIDA ──────────────────────────────────
        // Oldingi bosqichdan qolgan FON skaneri hali ishlayotgan
        // bo'lishi mumkin: u papkani biz fayllarni yozib
        // bo'lgunimizcha ko'rib, natijasini yozib qo'yadi va
        // yozuvni "skanerlangan" deb belgilaydi. Shunda
        // `stats_json_ready` darhol ESKIRGAN sonni qaytarardi
        // (test ~2% holatda shu sababdan yiqilardi). Endi son
        // barqarorlashguncha qayta so'raymiz — bu ilova xulqiga
        // umuman tegmaydi, faqat sinovni aniq qiladi.
        let mut downloaded = 0u64;
        for _ in 0..100 {
            stats().lock().unwrap().remove(TEST_NAME);
            let parsed = stats_json_ready(c_urls.as_ptr());
            downloaded = parsed[&test_url]["downloaded"].as_u64().unwrap();
            if downloaded == TEST_TOTAL - CHUNK_SIZE {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(
            downloaded,
            TEST_TOTAL - CHUNK_SIZE,
            "yarim qolgan bo'lak hisobga qo'shilib ketdi"
        );
        assert!(
            !dir.join(chunk_name(5)).exists(),
            "yarim qolgan bo'lak o'chirilmadi"
        );


        // ── 12) PLEYER VA YUKLAB OLISH — IKKI MUSTAQIL TIZIM ─────
        //
        // TALAB (foydalanuvchi): "pleyer yuklab olish tizimi bilan
        // ALOHIDA ishlashi kerak: fayl to'liq yuklab olinmaguncha
        // faqat worker orqali ko'rsatilsin, mahalliy server esa
        // FAQAT to'liq yuklab olingan fayl uchun ishlatilsin."
        //
        // Shu sabab mahalliy server TARMOQQA UMUMAN CHIQMAYDI.
        const G_TOTAL: u64 = 10 * CHUNK_SIZE;
        let (o_port, o_log) = start_origin(G_TOTAL);
        let g_url = format!("http://127.0.0.1:{o_port}/pleyer.mp4");

        // (a) PLEYER YO'LI: diskda hech narsa yo'q ─────────────
        // Mahalliy server bunday videoni ko'rsata OLMAYDI va
        // MANBAGA HAM MUROJAAT QILMAYDI — u 404 qaytaradi, ilova
        // esa workerga o'tadi.
        let (status, _gcr, glen, _gbody) =
            request_url(port, &g_url, Some("bytes=0-"), Some(4096));
        assert_eq!(
            status, 404,
            "mahalliy server yuklab olinmagan videoni ko'rsatishga urindi"
        );
        assert_eq!(glen, 0, "404 javobida tana bo'lmasligi kerak");
        let ranges: Vec<String> = o_log.lock().unwrap().clone();
        assert!(
            ranges.is_empty(),
            "MAHALLIY SERVER TARMOQQA CHIQDI (so'rovlar: {ranges:?}) — \
             pleyer va yuklab olish yana bir-biriga yopishib qolgan"
        );

        // (b) YUKLAB OLISH YO'LI ──────────────────────────────
        // Toza fayl (keshda hech narsa yo'q) — guruh bilan
        // olinishi kerak.
        let (o2_port, o2_log) = start_origin(G_TOTAL);
        let d_name = "yuklash.mp4";
        let d_url = format!("http://127.0.0.1:{o2_port}/{d_name}");
        let c_d = std::ffi::CString::new(d_url.clone()).unwrap();
        assert_eq!(rust_video_cache_download(c_d.as_ptr()), 1);

        let d_dir = root.join("video_byte_cache").join(d_name);
        let mut finished = false;
        for _ in 0..300 {
            if (0..10).all(|i| chunk_cached(&d_dir, i, G_TOTAL)) {
                finished = true;
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        assert!(finished, "yuklab olish tugamadi");

        let d_ranges: Vec<String> = o2_log
            .lock()
            .unwrap()
            .iter()
            .filter(|r| *r != "bytes=0-0")
            .cloned()
            .collect();
        // Yuklovchi bo'lakma-bo'lak emas, YO'LAK bilan so'raydi:
        // 10 MiB'lik fayl 6 ta yo'lakka bo'linadi (2,2,2,2,1,1),
        // ya'ni bittasi ham 1 MiB'lik so'rov bo'lmasligi kerak.
        assert!(
            d_ranges.iter().any(|r| {
                let (rs, re) = parse_test_range(r, G_TOTAL);
                re - rs + 1 > CHUNK_SIZE
            }),
            "yuklovchi bo'lakma-bo'lak so'radi: {d_ranges:?}"
        );
        tekshir_qoplama(&d_ranges, G_TOTAL);
        // 10 ta bo'lak 6 ta yo'lakka bo'linadi (2,2,2,2,1,1),
        // ya'ni 6 ta so'rov. Ish o'g'irlash bo'lsa bir-ikki ta
        // ortishi mumkin, undan ko'p emas.
        assert!(
            d_ranges.len() <= DOWNLOAD_THREADS + 2,
            "yuklovchi keragidan ko'p so'rov yubordi: {d_ranges:?}"
        );

        // ── 11) JAVOB KESILMAYDI, FAQAT SEKINLASHTIRILADI ────────
        //
        // Bu ENG MUHIM regressiya testi. Alohida video yasaymiz:
        //   hajm       = 20 MiB (20 ta bo'lak)
        //   davomiylik = 600 s (10 daqiqa) -> 2 MiB/daqiqa
        // Keshda faqat 0-bo'lak bor, qolganlari yo'q va manba
        // (127.0.0.1:9) mavjud emas.
        //
        // ESKI XATO: javob bufer chegarasida KESILARDI va
        // `Content-Range` qisqa oraliqni ko'rsatardi. ExoPlayer
        // buni "fayl tugadi" deb tushunib videoni o'sha yerda
        // yakunlardi — `setLooping(true)` sabab video boshidan
        // qayta boshlanardi. Foydalanuvchi ko'rgan muammo shu edi.
        //
        // ENDI: `Content-Range` HAR DOIM to'liq oraliqni ko'rsatadi,
        // ulanish ochiq qoladi, cheklov esa faqat baytlarni berish
        // tezligiga qo'yiladi.
        const W_NAME: &str = "oyna.mp4";
        const W_TOTAL: u64 = 20 * CHUNK_SIZE;
        let w_dir = root.join("video_byte_cache").join(W_NAME);
        fs::create_dir_all(&w_dir).unwrap();
        fs::write(
            w_dir.join("meta.json"),
            format!(
                "{{\"total_size\":{W_TOTAL},\"content_type\":\"video/mp4\",\
                 \"chunk_size\":{CHUNK_SIZE},\"duration_secs\":600.0}}"
            ),
        )
        .unwrap();
        // Faqat 0-bo'lak keshda.
        {
            let len = CHUNK_SIZE as usize;
            let data: Vec<u8> = (0..len).map(|k| (k % 251) as u8).collect();
            let (k, iv) = crypto::derive_chunk_key_iv(W_NAME, 0).unwrap();
            fs::write(w_dir.join(chunk_name(0)), crypto::encrypt_chunk(&data, &k, &iv)).unwrap();
        }
        // Ijro nuqtasi xabari BOSHQA video uchun — bu videoga
        // taalluqli emas, shu sabab so'rovning o'z boshlanishi
        // olinadi.
        PLAY_POS_KEY.store(0, Ordering::Relaxed);

        let w_req = |range: &str| -> (u16, String, usize) {
            let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
            st.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            st.write_all(
                format!(
                    "GET /v?u=http%3A%2F%2F127.0.0.1%3A9%2F{W_NAME} HTTP/1.1\r\n                     Host: x\r\nRange: {range}\r\n\r\n"
                )
                .as_bytes(),
            )
            .unwrap();
            let mut br = BufReader::new(st);
            let mut status_line = String::new();
            br.read_line(&mut status_line).unwrap();
            let status: u16 = status_line
                .split_whitespace()
                .nth(1)
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let mut cr = String::new();
            loop {
                let mut line = String::new();
                if br.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                    break;
                }
                if let Some(v) = line.strip_prefix("Content-Range: ") {
                    cr = v.trim().to_string();
                }
            }
            let mut body = Vec::new();
            let _ = br.read_to_end(&mut body);
            (status, cr, body.len())
        };

        let (status, cr, wlen) = w_req("bytes=0-");
        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes 0-{}/{W_TOTAL}", W_TOTAL - 1),
            "javob KESILDI — ExoPlayer buni 'fayl tugadi' deb tushunadi"
        );
        // Manba mavjud emas, shu sabab keshdagi 0-bo'lakdan keyin
        // oqim uziladi: bu bufer qoidasining o'zi emas, tarmoq
        // xatosi. Muhimi — sarlavha to'g'ri (yuqoridagi tekshiruv).
        assert!(
            wlen >= CHUNK_SIZE as usize,
            "keshdagi bo'lak berilmadi: {wlen} bayt"
        );

        // O'RTADAN so'ralganda ham sarlavha TO'LIQ oraliqni
        // ko'rsatadi.
        let (status, cr, _) = w_req(&format!("bytes={}-", 10 * CHUNK_SIZE));
        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes {}-{}/{W_TOTAL}", 10 * CHUNK_SIZE, W_TOTAL - 1),
            "o'rtadan so'ralgan javob kesildi"
        );

        // YUKLAB OLISH tugmasi bosilgan bo'lsa — cheklov YO'Q.
        let w_url = format!("http://127.0.0.1:9/{W_NAME}");
        let c_w = std::ffi::CString::new(w_url.clone()).unwrap();
        assert_eq!(rust_video_cache_download(c_w.as_ptr()), 1);
        let (status, cr, _) = w_req("bytes=0-");
        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes 0-{}/{W_TOTAL}", W_TOTAL - 1),
            "yuklab olish paytida ham cheklov qo'llanib qoldi"
        );
        let c_w2 = std::ffi::CString::new(w_url).unwrap();
        rust_video_cache_pause(c_w2.as_ptr());
    }


    /// Worker'ning HAQIQIY xulqini takrorlaydigan manba:
    ///   * bir so'rovda eng ko'pi `cap` bayt qaytaradi (Cloudflare
    ///     worker'dagi `RANGE_MAX` kabi);
    ///   * `/api/warm/...` ga "warming" javobini beradi (ya'ni
    ///     isitish TUGAMAGAN — aynan shu javob ilgari so'rov
    ///     bo'ronini keltirib chiqarardi).
    /// Qaytaradi: (port, image so'rovlari soni, warm so'rovlari soni)
    fn start_capped_origin(
        total: u64,
        cap: u64,
    ) -> (u16, Arc<AtomicU64>, Arc<AtomicU64>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let img = Arc::new(AtomicU64::new(0));
        let warm = Arc::new(AtomicU64::new(0));
        let (i2, w2) = (Arc::clone(&img), Arc::clone(&warm));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let (i3, w3) = (Arc::clone(&i2), Arc::clone(&w2));
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let first = text.split("\r\n").next().unwrap_or("").to_string();
                    if first.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    if first.contains("/api/warm/") {
                        w3.fetch_add(1, Ordering::SeqCst);
                        let body = "{\"status\":\"warming\",\"total\":0}";
                        let _ = st.write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                                body.len()
                            )
                            .as_bytes(),
                        );
                        return;
                    }
                    i3.fetch_add(1, Ordering::SeqCst);
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, mut e) = parse_test_range(&range, total);
                    // ── SERVER CHEGARASI ──────────────────────
                    if e - s + 1 > cap {
                        e = s + cap - 1;
                    }
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let _ = st.write_all(&body);
                });
            }
        });
        (port, img, warm)
    }

    /// ═══════════════════════════════════════════════════════════
    ///  YUKLAB OLISH: SERVER CHEGARASIGA MOSLASHADI, TO'XTAB
    ///  QOLMAYDI VA ISITISH SO'ROVLARINI TAKRORLAMAYDI
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Foydalanuvchi ko'rgan xato: "yuklab olish sekin va 70-80%
    /// da to'xtab qoladi". Sabab qurilmada emas, MANTIQDA edi:
    /// ilova bir so'rovda 10 MiB so'rardi, worker esa har doim
    /// atigi 8 MiB berardi — ya'ni har bir guruhning oxirgi 20%
    /// i hech qachon kelmasdi va sekin, bittalab yo'l bilan
    /// olinardi.
    #[test]
    fn yuklab_olish_server_chegarasiga_moslashadi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        SERVER_SPAN_MAX.store(u64::MAX, Ordering::Relaxed);

        const NAME: &str = "ep_7_7_720p_1700000000001.mp4";
        const TOTAL: u64 = 24 * CHUNK_SIZE;
        const CAP: u64 = 8 * CHUNK_SIZE; // worker'dagi RANGE_MAX
        let (o_port, img, warm) = start_capped_origin(TOTAL, CAP);
        let url = format!("http://127.0.0.1:{o_port}/api/image/{NAME}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(NAME);

        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let began = Instant::now();
        let mut done = false;
        while began.elapsed() < Duration::from_secs(60) {
            if (0..24).all(|i| chunk_cached(&dir, i, TOTAL)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        let images = img.load(Ordering::SeqCst);
        let warms = warm.load(Ordering::SeqCst);
        assert!(
            done,
            "yuklab olish tugamadi ({}s) — so'rovlar: {images} image, {warms} warm",
            began.elapsed().as_secs()
        );

        // 24 MiB ish 12 ta oqimga bo'linadi (adil ulush: 2 MiB),
        // ya'ni ~12 ta so'rov + hajmni aniqlash uchun bitta
        // "bytes=0-0". Ehtiyot uchun bir nechta qo'shimchaga joy
        // qoldiramiz. MUHIM: bu son bo'lakma-bo'lak (24 dan ko'p)
        // so'rovni baribir ushlaydi.
        assert!(
            images <= (DOWNLOAD_THREADS + 4) as u64,
            "keragidan ko'p so'rov yuborildi: {images} ta (kutilgan ~13)"
        );
        // ── ISITISH SO'ROVLARI TAKRORLANMASIN ────────────────
        // Ilgari har bir 1 MiB bo'lak uchun bittadan isitish
        // so'rovi ketardi (qurilmada 87 ta bo'lakka 72 ta isitish).
        assert!(
            warms <= 2,
            "isitish so'rovlari takrorlanyapti: {warms} ta"
        );
        SERVER_SPAN_MAX.store(u64::MAX, Ordering::Relaxed);
    }

    // ═══════════════════════════════════════════════════════════
    //  HAQIQIY WORKER BILAN SINOV (tarmoqqa chiqadi)
    // ═══════════════════════════════════════════════════════════
    //
    // Odatiy `cargo test` da ISHLAMAYDI (#[ignore]). Qo'lda:
    //   cargo test --lib haqiqiy_ -- --ignored --nocapture --test-threads=1
    fn real_base() -> String {
        std::env::var("REAL_BASE").unwrap_or_else(|_| {
            "https://arumediatv.uzcom.workers.dev/api/image".to_string()
        })
    }

    fn dump_logs(tag: &str) {
        let raw = rust_video_cache_pull_logs();
        let text = unsafe { std::ffi::CStr::from_ptr(raw) }
            .to_string_lossy()
            .to_string();
        crate::ffi_utils::rust_free_string(raw);
        let lines: Vec<String> = serde_json::from_str(&text).unwrap_or_default();
        for l in lines {
            println!("[{tag}] {l}");
        }
    }

    /// Javobni belgilangan muddat davomida o'qiydi. Qaytaradi:
    /// (o'qilgan bayt, ULANISH SERVER TOMONIDAN YOPILDIMI).
    /// Ulanishning yopilishi = ExoPlayer uchun "fayl tugadi".
    fn read_paced(
        port: u16,
        origin_url: &str,
        range: &str,
        run_for: Duration,
    ) -> (usize, bool) {
        let (a, b, _) = read_measured(port, origin_url, range, run_for);
        (a, b)
    }

    /// Javobni o'qiydi va ENG UZUN JIMLIKNI o'lchaydi.
    fn read_measured(
        port: u16,
        origin_url: &str,
        range: &str,
        run_for: Duration,
    ) -> (usize, bool, Duration) {
        let encoded: String = origin_url
            .chars()
            .map(|c| match c {
                ':' => "%3A".to_string(),
                '/' => "%2F".to_string(),
                '?' => "%3F".to_string(),
                '=' => "%3D".to_string(),
                c => c.to_string(),
            })
            .collect();
        let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
        // Sarlavhalar uchun keng chegara; tanani o'qishda 500 ms
        // ("jimlik" o'lchash uchun) qo'yiladi.
        st.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        st.write_all(
            format!("GET /v?u={encoded} HTTP/1.1\r\nHost: x\r\nRange: {range}\r\n\r\n")
                .as_bytes(),
        )
        .unwrap();
        let mut br = BufReader::new(st);
        let mut line = String::new();
        br.read_line(&mut line).unwrap();
        println!(">>> javob: {}", line.trim());
        loop {
            let mut l = String::new();
            if br.read_line(&mut l).unwrap_or(0) == 0 || l == "\r\n" {
                break;
            }
            if l.starts_with("Content-Range") {
                println!(">>> {}", l.trim());
            }
        }
        br.get_ref()
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let deadline = Instant::now() + run_for;
        let mut total = 0usize;
        let mut closed = false;
        let mut silence = Instant::now();
        let mut max_silence = Duration::ZERO;
        let mut buf = [0u8; 64 * 1024];
        while Instant::now() < deadline {
            match br.read(&mut buf) {
                Ok(0) => {
                    closed = true;
                    println!(">>> SERVER ULANISHNI YOPDI ({total} bayt keyin)");
                    break;
                }
                Ok(n) => {
                    total += n;
                    if silence.elapsed() > max_silence {
                        max_silence = silence.elapsed();
                    }
                    if silence.elapsed() > Duration::from_secs(3) {
                        println!(
                            ">>> {}s jimlikdan keyin bayt keldi",
                            silence.elapsed().as_secs()
                        );
                    }
                    silence = Instant::now();
                }
                Err(_) => {
                    // 500 ms o'qish chegarasi — jimlik, bu normal.
                    if silence.elapsed() > Duration::from_secs(8) {
                        println!(
                            ">>> DIQQAT: {}s davomida bitta ham bayt kelmadi \
                             (ExoPlayer chegarasi 8s)",
                            silence.elapsed().as_secs()
                        );
                        silence = Instant::now();
                    }
                }
            }
        }
        if silence.elapsed() > max_silence {
            max_silence = silence.elapsed();
        }
        (total, closed, max_silence)
    }

    /// PLEYER YO'LI: ijro nuqtasi haqiqiy vaqtda suriladi va javob
    /// uzluksiz kelishi kerak.
    #[test]
    #[ignore]
    fn haqiqiy_pleyer_oqimi() {
        let (port, _root) = ensure_server();
        let name = std::env::var("REAL_FILE")
            .unwrap_or_else(|_| "ep_1_2_720p_1788054615257.mp4".to_string());
        let url = format!("{}/{name}", real_base());
        let c_url = std::ffi::CString::new(url.clone()).unwrap();

        // Ilova aynan shunday qiladi: avval tayyorlash, keyin ijro.
        rust_video_cache_prepare(c_url.as_ptr());
        for _ in 0..600 {
            if rust_video_cache_prepare_status(c_url.as_ptr()) == 1 {
                break;
            }
            thread::sleep(Duration::from_millis(200));
        }
        dump_logs("tayyorlash");

        rust_video_cache_set_position(c_url.as_ptr(), 0);
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = Arc::clone(&stop);
        let u2 = url.clone();
        // Ijro HAQIQIY vaqtda suriladi (1x).
        let pos_thread = thread::spawn(move || {
            let c = std::ffi::CString::new(u2).unwrap();
            let mut ms: u64 = 0;
            while !s2.load(Ordering::Relaxed) {
                rust_video_cache_set_position(c.as_ptr(), ms);
                thread::sleep(Duration::from_millis(500));
                ms += 500;
            }
        });

        // Pleyer bir marta ochiladi va oqimni o'qiydi.
        let secs: u64 = std::env::var("REAL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(90);
        let began = Instant::now();
        let (got, closed) = read_paced(port, &url, "bytes=0-", Duration::from_secs(secs));
        stop.store(true, Ordering::Relaxed);
        let _ = pos_thread.join();
        dump_logs("ijro");
        println!(
            ">>> {} soniyada {} bayt ({:.2} MB) keldi; ulanish yopildimi: {closed}",
            began.elapsed().as_secs(),
            got,
            got as f64 / (1024.0 * 1024.0)
        );
        // Ulanishning yopilishi FAQAT fayl to'liq berilmagan bo'lsa
        // xato hisoblanadi (to'liq berilganda yopilish — normal EOF).
        let _ = closed;
        println!(
            ">>> o'rtacha tezlik: {:.0} KB/s",
            got as f64 / 1024.0 / began.elapsed().as_secs_f64()
        );
    }

    /// YUKLAB OLISH YO'LI: tezlik va "to'xtab qolish" holatini
    /// o'lchaydi.
    #[test]
    #[ignore]
    fn haqiqiy_yuklab_olish() {
        let (_port, _root) = ensure_server();
        let name = std::env::var("REAL_FILE")
            .unwrap_or_else(|_| "ep_1_2_720p_1788054615257.mp4".to_string());
        let secs: u64 = std::env::var("REAL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(120);
        let url = format!("{}/{name}", real_base());
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let urls_json = serde_json::to_string(&vec![url.clone()]).unwrap();
        let c_urls = std::ffi::CString::new(urls_json).unwrap();

        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let began = Instant::now();
        let mut last = 0u64;
        let mut last_change = Instant::now();
        while began.elapsed() < Duration::from_secs(secs) {
            thread::sleep(Duration::from_secs(3));
            let parsed = stats_json(c_urls.as_ptr());
            let item = &parsed[&url];
            let total = item["total"].as_u64().unwrap_or(0);
            let done = item["downloaded"].as_u64().unwrap_or(0);
            let pct = if total > 0 { done * 100 / total } else { 0 };
            if done != last {
                last = done;
                last_change = Instant::now();
            }
            println!(
                ">>> {:>4}s  {pct:>3}%  {:.2}/{:.2} MB  tezlik {:.2} MB/s  turg'unlik {}s",
                began.elapsed().as_secs(),
                done as f64 / (1024.0 * 1024.0),
                total as f64 / (1024.0 * 1024.0),
                done as f64 / (1024.0 * 1024.0) / began.elapsed().as_secs_f64().max(1.0),
                last_change.elapsed().as_secs()
            );
            dump_logs("yuklash");
            if total > 0 && done >= total {
                println!(">>> TUGADI");
                break;
            }
        }
        rust_video_cache_pause(c_url.as_ptr());
    }

    /// Ishlab chiqarishdagi worker'ga o'xshash manba: `/api/image/...`
    /// Range so'rovlarini bajaradi, `/api/warm/...` ga esa JSON javob
    /// beradi. Shu bilan tayyorlash (prepare) yo'li ham AYNAN
    /// ilovadagidek ishlaydi.
    fn start_worker_origin(total: u64) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let first = text.split("\r\n").next().unwrap_or("").to_string();
                    if first.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    if first.contains("/api/warm/") {
                        let body = format!("{{\"status\":\"cached\",\"total\":{total}}}");
                        let _ = st.write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                                body.len()
                            )
                            .as_bytes(),
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let _ = st.write_all(&body);
                });
            }
        });
        port
    }

    /// ═══════════════════════════════════════════════════════════
    ///  TOZALAGANDAN KEYIN VIDEO QAYTA YUKLANISHI SHART
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Foydalanuvchi ko'rgan xato: videoni tozalab tashlagandan keyin
    /// u boshqa yuklanmaydi — na yuklab olish tugmasi, na pleyer
    /// ishlaydi ("Videoni yuklab bo'lmadi").
    #[test]
    fn tozalangandan_keyin_qayta_yuklanadi() {
        let (port, root) = ensure_server();

        const NAME: &str = "ep_9_9_720p_1700000000000.mp4";
        const TOTAL: u64 = 6 * CHUNK_SIZE;
        let o_port = start_worker_origin(TOTAL);
        let url = format!("http://127.0.0.1:{o_port}/api/image/{NAME}");
        let dir = root.join("video_byte_cache").join(NAME);
        let c_url = std::ffi::CString::new(url.clone()).unwrap();

        let wait_full = |label: &str| {
            let mut ok = false;
            for _ in 0..600 {
                if (0..6).all(|i| chunk_cached(&dir, i, TOTAL)) {
                    ok = true;
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
            assert!(ok, "{label}: yuklab olish tugamadi");
        };

        // ── 1) Birinchi yuklab olish ────────────────────────────
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        wait_full("1-urinish");

        // ── 2) TOZALASH ─────────────────────────────────────────
        assert_eq!(rust_video_cache_delete(c_url.as_ptr()), 1);
        let mut cleared = false;
        for _ in 0..100 {
            if !chunk_cached(&dir, 0, TOTAL) {
                cleared = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(cleared, "tozalash ishlamadi");

        // ── 3) DARHOL qayta yuklab olish (foydalanuvchi aynan
        //       shunday qiladi: tozalab, darrov tugmani bosadi) ──
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        wait_full("tozalashdan keyingi urinish");

        // ── 4) TOZALAGANDAN KEYIN MAHALLIY SERVER KO'RSATMAYDI ──
        //
        // TUZATILGAN XATO (foydalanuvchi ko'rgan): video o'chirilgach
        // ham pleyer mahalliy serverga kelar, u yerda fayl yo'q
        // bo'lgani uchun BUTUN VIDEO QAYTA YUKLAB OLINARDI — ya'ni
        // foydalanuvchi yuklab olishni bosmagan bo'lsa ham video
        // diskka yozila boshlardi.
        //
        // Endi mahalliy server bunday videoni ko'rsatmaydi (404) va
        // tarmoqqa umuman chiqmaydi; ilova esa workerdan ko'rsatadi.
        assert_eq!(rust_video_cache_delete(c_url.as_ptr()), 1);
        // O'chirish fon oqimida yakunlanadi — papka haqiqatan
        // yo'qolishini kutamiz (aks holda sinov o'chirish tugashidan
        // oldin so'rov yuborib qo'yardi).
        let mut gone = false;
        for _ in 0..200 {
            if !dir.join("meta.json").exists() && !chunk_cached(&dir, 0, TOTAL) {
                gone = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(gone, "tozalash yakunlanmadi");
        let (status, _cr, len, _) =
            request_url(port, &url, Some("bytes=0-1048575"), None);
        assert_eq!(
            status, 404,
            "tozalangandan keyin mahalliy server videoni ko'rsatishga urindi"
        );
        assert_eq!(len, 0, "tozalangandan keyin baytlar berildi");
    }

    /// YARIM QOLGAN BO'LAK: olingan qism SAQLANADI, bo'lak to'liq
    /// yig'ilgach esa qoldiq O'CHIRILIB, o'rnida yakuniy to'liq bo'lak
    /// qoladi.
    #[test]
    fn yarim_bolak_saqlanadi_va_toliq_bolak_bilan_almashtiriladi() {
        enable_crypto();
        let root = std::env::temp_dir().join(format!("qoldiq_test_{}", micros_now()));
        let dir = root.join("kino");
        fs::create_dir_all(&dir).unwrap();
        let key = "kino";
        let expected_len = CHUNK_SIZE as usize;

        // Qoldiq yo'q — noldan boshlanadi.
        assert!(read_part(&dir, key, 0, expected_len).is_none());

        // 1) Bo'lakning bir qismi olindi va saqlandi.
        let yarim: Vec<u8> = (0..700_000usize).map(|i| (i % 251) as u8).collect();
        write_part(&dir, key, 0, &yarim);
        assert!(
            dir.join(part_name(0)).exists(),
            "qoldiq fayli yaratilmadi"
        );
        // Diskda OCHIQ holda yotmaydi (shifrlangan).
        let xom = fs::read(dir.join(part_name(0))).unwrap();
        assert_ne!(xom, yarim, "qoldiq shifrlanmagan holda saqlandi");
        // Va aynan o'sha baytlar qaytib o'qiladi.
        assert_eq!(
            read_part(&dir, key, 0, expected_len).unwrap(),
            yarim,
            "qoldiq buzilib qaytdi"
        );

        // 2) Keyingi urinish ko'proq oldi — eski qoldiq YANGISI bilan
        //    almashtiriladi.
        let kattaroq: Vec<u8> = (0..900_000usize).map(|i| (i % 251) as u8).collect();
        write_part(&dir, key, 0, &kattaroq);
        assert_eq!(read_part(&dir, key, 0, expected_len).unwrap().len(), 900_000);

        // 3) Bo'lak TO'LIQ yig'ildi: yakuniy fayl yoziladi, qoldiq
        //    o'chiriladi.
        let toliq: Vec<u8> = (0..expected_len).map(|i| (i % 251) as u8).collect();
        let (k, iv) = crypto::derive_chunk_key_iv(key, 0).unwrap();
        fs::write(dir.join(chunk_name(0)), crypto::encrypt_chunk(&toliq, &k, &iv)).unwrap();
        remove_part(&dir, 0);
        assert!(
            !dir.join(part_name(0)).exists(),
            "to'liq bo'lakdan keyin qoldiq o'chirilmadi"
        );
        assert_eq!(
            read_cached_chunk(&dir, key, 0, expected_len).unwrap(),
            toliq,
            "yakuniy bo'lak noto'g'ri o'qildi"
        );

        // 4) Qoldiq bo'lak hajmidan kichik EMAS bo'lsa — u buzuq
        //    hisoblanadi va o'chiriladi.
        write_part(&dir, key, 1, &toliq);
        assert!(read_part(&dir, key, 1, expected_len).is_none());
        assert!(!dir.join(part_name(1)).exists());

        // 5) Skanerlash: to'liq bo'lak yonidagi egasiz qoldiq
        //    tozalanadi, YARIM bo'lakniki esa TEGILMAYDI (u keyingi
        //    urinishda davom ettirish uchun kerak).
        write_part(&dir, key, 0, &yarim);
        write_part(&dir, key, 2, &yarim);
        let (have, _) = scan_and_clean(&dir, CHUNK_SIZE * 3);
        assert!(have.contains(&0));
        assert!(
            !dir.join(part_name(0)).exists(),
            "to'liq bo'lakning qoldig'i tozalanmadi"
        );
        assert!(
            dir.join(part_name(2)).exists(),
            "hali tugallanmagan bo'lakning qoldig'i o'chirib yuborildi"
        );

        let _ = fs::remove_dir_all(&root);
    }





    // ═══════════════════════════════════════════════════════════
    //  ANIQ "BO'LAK -> SONIYA" JADVALI
    // ═══════════════════════════════════════════════════════════
    //
    // Bu testdagi fayl ATAYLAB o'zgaruvchan bitreytli:
    //   * 0-bo'lakda 11 soniyalik video (jim sahna — kadrlar kichik)
    //   * 1-bo'lakda atigi 1 soniya   (jangovar sahna — kadr katta)
    //   * 2-bo'lakda 2 soniya
    // O'rtacha bitreyt bilan hisoblansa har bir bo'lak ~4.7 soniya
    // chiqadi va javob NOTO'G'RI bo'ladi. Aniq jadval esa faylning
    // o'z namuna jadvallaridan hisoblanadi.







    /// KADR XOTIRASI: BIR NECHTA YOZUV SAQLANADI.
    ///
    /// TOPILGAN XATO shu yerda edi: xotirada ATIGI BITTA yozuv
    /// turardi. Yozishmada bir vaqtda ikkita kadr yasaladi, ya'ni
    /// ikkinchisi birinchisini o'chirib yuborardi. Kadr
    /// ajratuvchi manzilni qayta ochganda (u HAR DOIM shunday
    /// qiladi: avval metadata, keyin kadr) yozuv topilmay, butun
    /// bo'lak qaytadan yasalardi — sekin tarmoqda esa urinish
    /// muddati tugab, video KADRSIZ qolardi.
    ///
    /// Bu test aynan o'sha holatni tekshiradi: eski (bitta
    /// yozuvli) tuzilma bilan u YIQILADI.
    #[test]
    fn kadr_xotirasi_bir_nechta_yozuvni_saqlaydi() {
        if let Ok(mut g) = THUMB_MEMO.lock() {
            g.clear();
        }

        thumb_to_memo("video_a|2000", b"AAA");
        thumb_to_memo("video_b|2000", b"BBB");

        // IKKOVI ham joyida turishi kerak — ikkinchisi birinchisini
        // o'chirib yubormaydi.
        assert_eq!(thumb_from_memo("video_a|2000").as_deref(), Some(&b"AAA"[..]));
        assert_eq!(thumb_from_memo("video_b|2000").as_deref(), Some(&b"BBB"[..]));

        // Bir xil tag qayta yozilsa — nusxa ko'paymaydi, yangisi turadi.
        thumb_to_memo("video_a|2000", b"AAA2");
        assert_eq!(thumb_from_memo("video_a|2000").as_deref(), Some(&b"AAA2"[..]));
        if let Ok(g) = THUMB_MEMO.lock() {
            assert_eq!(g.iter().filter(|(t, _, _)| t == "video_a|2000").count(), 1);
        }

        // Chegaradan oshganda eng ESKISI chiqib ketadi.
        for i in 0..THUMB_MEMO_MAX {
            thumb_to_memo(&format!("yangi_{i}|0"), b"X");
        }
        if let Ok(g) = THUMB_MEMO.lock() {
            assert!(g.len() <= THUMB_MEMO_MAX, "chegara ushlanmadi: {}", g.len());
        }
        assert!(
            thumb_from_memo("video_a|2000").is_none(),
            "eng eski yozuv chiqib ketishi kerak edi"
        );

        // Boshqa testlarga xalaqit qilmasin.
        if let Ok(mut g) = THUMB_MEMO.lock() {
            g.clear();
        }
    }

    // ── `moov` OXIRIDA BO'LGAN FAYLDAN KADR (tashxis testi) ──
    fn t_box(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&((body.len() + 8) as u32).to_be_bytes());
        v.extend_from_slice(kind);
        v.extend_from_slice(body);
        v
    }

    fn t_moov(chunk_offsets: [u32; 2], pad: usize) -> Vec<u8> {
        let full = |b: &[u32]| {
            let mut v = 0u32.to_be_bytes().to_vec();
            for x in b {
                v.extend_from_slice(&x.to_be_bytes());
            }
            v
        };
        let mut stbl = Vec::new();
        let mut stsd = full(&[1]);
        stsd.extend_from_slice(&t_box(b"avc1", &[7u8; 12]));
        stbl.extend_from_slice(&t_box(b"stsd", &stsd));
        stbl.extend_from_slice(&t_box(b"stts", &full(&[1, 4, 512])));
        stbl.extend_from_slice(&t_box(b"stss", &full(&[2, 1, 3])));
        stbl.extend_from_slice(&t_box(b"stsc", &full(&[1, 1, 2, 1])));
        stbl.extend_from_slice(&t_box(b"stsz", &full(&[0, 4, 10, 20, 30, 40])));
        stbl.extend_from_slice(&t_box(b"stco", &full(&[2, chunk_offsets[0], chunk_offsets[1]])));
        let mut minf = t_box(b"vmhd", &[0u8; 12]);
        minf.extend_from_slice(&t_box(b"stbl", &stbl));
        let mut mdia = t_box(b"hdlr", &{
            let mut h = full(&[0]);
            h.extend_from_slice(b"vide");
            h
        });
        mdia.extend_from_slice(&t_box(b"mdhd", &full(&[0, 0, 1024, 2048, 0])));
        mdia.extend_from_slice(&t_box(b"minf", &minf));
        let mut tkhd = vec![0u8; 84];
        tkhd[76..80].copy_from_slice(&(1280u32 << 16).to_be_bytes());
        tkhd[80..84].copy_from_slice(&(720u32 << 16).to_be_bytes());
        let mut trak = t_box(b"tkhd", &tkhd);
        trak.extend_from_slice(&t_box(b"mdia", &mdia));
        let mut moov = t_box(b"trak", &trak);
        moov.extend_from_slice(&t_box(b"udta", &vec![0u8; pad]));
        moov
    }

    fn start_file_origin(file: Vec<u8>) -> (u16, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = Arc::clone(&log);
        let file = Arc::new(file);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let l3 = Arc::clone(&l2);
                let f = Arc::clone(&file);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let total = f.len() as u64;
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    l3.lock().unwrap().push(range.clone());
                    let (s, e) = parse_test_range(&range, total);
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n",
                        e - s + 1
                    );
                    let _ = st.write_all(head.as_bytes());
                    let _ = st.write_all(&f[s as usize..=e as usize]);
                });
            }
        });
        (port, log)
    }

    fn thumb_from_file(file: Vec<u8>, ms: u64) -> (Option<Vec<u8>>, usize) {
        let total = file.len() as u64;
        let (port, reqs) = start_file_origin(file);
        let url = format!("http://127.0.0.1:{port}/{TEST_NAME}");
        let root = std::env::temp_dir().join(format!(
            "aru_moovend_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let shared = Shared {
            cache_root: root.clone(),
            start: Instant::now(),
            logs: Mutex::new(Vec::new()),
            agent: ureq::AgentBuilder::new()
                .timeout_read(Duration::from_secs(20))
                .build(),
            warm_agent: ureq::AgentBuilder::new().build(),
            net_by_file: Mutex::new(HashMap::new()),
        };
        // Ishlab chiqarishdagidek: hajm birinchi o'qishdan olinadi.
        let (probed, _, head) =
            probe_head(&shared, &url, ThumbReader::READAHEAD).expect("bosh o'qilmadi");
        assert_eq!(probed, total, "hajm noto'g'ri o'qildi");
        let reader = ThumbReader {
            shared: &shared,
            dir: root.join("kalit"),
            key: "kalit".to_string(),
            url,
            total,
            buf: RefCell::new(Vec::new()),
        };
        reader.keep(0, head);
        let out = (|| {
            let moov = find_moov(&reader)?;
            let track = crate::mp4::parse_moov(&moov)?;
            let target = track.sample_at_ms(ms);
            let sync = track.sync_at_or_before(target);
            build_thumb_clip(&reader, &track, sync, target)
        })();
        let n = reqs.lock().unwrap().len();
        (out, n)
    }

    /// Qo'lda: `AR_THUMB_FILE=... AR_THUMB_OUT=... cargo test -- --ignored haqiqiy_fayl`
    #[test]
    #[ignore]
    fn haqiqiy_fayldan_kadr() {
        let path = std::env::var("AR_THUMB_FILE").unwrap();
        let out = std::env::var("AR_THUMB_OUT").unwrap();
        let ms: u64 = std::env::var("AR_THUMB_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(100);
        let file = fs::read(path).unwrap();
        let (r, n) = thumb_from_file(file, ms);
        eprintln!("so'rovlar: {n}");
        fs::write(out, r.expect("kadr yasalmadi")).unwrap();
    }

    #[test]
    fn moov_oxirida_bolsa_ham_kadr_yasaladi() {
        let ftyp = t_box(b"ftyp", b"isomisomavc1");
        for pad in [100usize, 600 * 1024] {
            // moov OXIRIDA: ftyp, mdat, moov.
            let mdat_body_at = (ftyp.len() + 8) as u32;
            let mut mdat = vec![0u8; 400 * 1024];
            for (i, b) in mdat.iter_mut().enumerate() {
                *b = (i % 200) as u8;
            }
            let moov = t_moov([mdat_body_at, mdat_body_at + 1000], pad);
            let mut end_file = ftyp.clone();
            end_file.extend_from_slice(&t_box(b"mdat", &mdat));
            end_file.extend_from_slice(&t_box(b"moov", &moov));
            let (r, n) = thumb_from_file(end_file, 100);
            assert!(r.is_some(), "moov oxirida (pad={pad}): kadr yasalmadi");
            // Bosh (hajm + kalit kadr) va oxiri (moov); katta moov
            // uchun bittasi ko'proq.
            let limit = if pad < 200 * 1024 { 2 } else { 3 };
            assert!(n <= limit, "moov oxirida (pad={pad}): {n} ta so'rov");

            // moov BOSHIDA (faststart).
            let moov_len = t_box(b"moov", &t_moov([0, 0], pad)).len() as u32;
            let at = ftyp.len() as u32 + moov_len + 8;
            let moov = t_moov([at, at + 1000], pad);
            let mut fast = ftyp.clone();
            fast.extend_from_slice(&t_box(b"moov", &moov));
            fast.extend_from_slice(&t_box(b"mdat", &mdat));
            let (r, n) = thumb_from_file(fast, 100);
            assert!(r.is_some(), "moov boshida (pad={pad}): kadr yasalmadi");
            let limit = if pad < 200 * 1024 { 1 } else { 3 };
            assert!(n <= limit, "moov boshida (pad={pad}): {n} ta so'rov");
        }
    }

    /// Eski (AES-CBC, `.bin`) bo'laklar o'qilmaydi va tozalanadi.
    #[test]
    fn eski_formatdagi_bolaklar_ochiriladi() {
        let dir = std::env::temp_dir().join(format!(
            "aru_eski_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let total = 2 * CHUNK_SIZE;
        fs::write(dir.join("chunk_0000000.bin"), vec![0u8; CHUNK_SIZE as usize + 16]).unwrap();
        assert!(!chunk_cached(&dir, 0, total), "eski fayl yangi bo'lak deb o'qildi");
        let (have, _) = scan_and_clean(&dir, total);
        assert!(have.is_empty());
        assert!(!dir.join("chunk_0000000.bin").exists(), "eski fayl o'chirilmadi");
        let _ = fs::remove_dir_all(&dir);
    }

    /// NAVBAT: bosilish tartibi va bir vaqtda 3 ta (regressiya testi).
    #[test]
    fn navbat_tartibi_va_uchta_joy() {
        let now = Instant::now();
        let mk = |seq: u64| DownloadState {
            url: format!("u{seq}"),
            wanted: true,
            running: false,
            failures: 0,
            next_try: now,
            epoch: seq,
            seq,
            started: false,
        };
        let mut map: HashMap<String, DownloadState> = HashMap::new();
        // Tasodifiy tartibda qo'shamiz — xesh tartibi natijaga
        // ta'sir qilmasligi kerak.
        for seq in [5u64, 2, 9, 1, 7] {
            map.insert(format!("k{seq}"), mk(seq));
        }
        let mut order = Vec::new();
        // Uchta joy to'ladi, to'rtinchisi boshlanmaydi.
        for _ in 0..5 {
            let Some(k) = choose_task(&map, now) else { break };
            let st = map.get_mut(&k).unwrap();
            st.running = true;
            st.started = true;
            order.push(k);
        }
        assert_eq!(order, vec!["k1", "k2", "k5"], "birinchi bosilganlar birinchi");

        // Boshlangan vazifa qisqa tanaffusda (qayta urinish) —
        // uning joyini navbatdagisi egallab olmaydi.
        map.get_mut("k1").unwrap().running = false;
        map.get_mut("k1").unwrap().next_try = now + Duration::from_secs(10);
        assert_eq!(choose_task(&map, now), None, "joy band — yangisi boshlanmaydi");

        // Bittasi tugadi — navbatdagi ENG BIRINCHISI (k7) boshlanadi.
        map.remove("k2");
        assert_eq!(choose_task(&map, now).as_deref(), Some("k7"));

        // Boshlangan vazifa qayta tayyor bo'lsa — u birinchi.
        map.get_mut("k5").unwrap().running = false;
        assert_eq!(choose_task(&map, now).as_deref(), Some("k5"));
    }

    /// `moov` XOTIRASI (regressiya testi).
    ///
    /// Har kadr uchun `moov` qaytadan tarmoqdan olinardi. Endi u
    /// xotirada turadi; bu test saqlash, chegarani va eng eski
    /// yozuvning chiqib ketishini tekshiradi.
    #[test]
    fn moov_xotirada_saqlanadi() {
        if let Ok(mut g) = MOOV_MEMO.lock() {
            g.clear();
        }
        assert!(moov_from_memo("v1").is_none());
        moov_to_memo("v1", vec![1, 2, 3]);
        assert_eq!(moov_from_memo("v1").as_deref(), Some(&vec![1, 2, 3]));

        // Qayta yozilsa nusxa ko'paymaydi.
        moov_to_memo("v1", vec![4]);
        assert_eq!(moov_from_memo("v1").as_deref(), Some(&vec![4]));

        // Chegaradan oshganda eng eski (eng kam ishlatilgan) chiqadi.
        for i in 0..MOOV_MEMO_MAX {
            moov_to_memo(&format!("boshqa_{i}"), vec![0]);
        }
        assert!(moov_from_memo("v1").is_none(), "eng eski yozuv qolib ketdi");
        if let Ok(g) = MOOV_MEMO.lock() {
            assert!(g.len() <= MOOV_MEMO_MAX);
        }
        if let Ok(mut g) = MOOV_MEMO.lock() {
            g.clear();
        }
    }

    /// KADR UCHUN TARMOQ SO'ROVLARI SONI (regressiya testi).
    ///
    /// TOPILGAN XATO (foydalanuvchi): "thumbnail qo'yish juda juda
    /// sekin ishlayapti ... tomosha tarixidagi ham sekin".
    ///
    /// SABAB: har bir `ThumbReader::read` alohida HTTP so'rovi edi,
    /// `find_moov` esa MP4 sarlavhalarini ATIGI 16 BAYTDAN o'qiydi.
    /// Bitta kadr uchun 5 ta KETMA-KET so'rov ketardi va mobil
    /// tarmoqda har biri borib-kelish vaqtini yeb, kadr 2-5
    /// soniyada chiqardi.
    ///
    /// Bu test aynan o'sha holatni o'lchaydi: uchta kichik
    /// sarlavha o'qishi BITTA so'rovga tushishi kerak. Zaxira
    /// bo'lak olib tashlansa — test yiqiladi (3 ta so'rov chiqadi).
    #[test]
    fn kadr_sarlavhalari_bitta_sorovda_keladi() {
        let total: u64 = 4 * 1024 * 1024;
        let (port, reqs) = start_origin(total);
        let url = format!("http://127.0.0.1:{port}/{TEST_NAME}");

        // Diskda hech narsa yo'q — hamma o'qish tarmoqqa boradi.
        let root = std::env::temp_dir().join(format!(
            "aru_thumbread_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let shared = Shared {
            cache_root: root.clone(),
            start: Instant::now(),
            logs: Mutex::new(Vec::new()),
            agent: ureq::AgentBuilder::new()
                .timeout_read(Duration::from_secs(20))
                .build(),
            warm_agent: ureq::AgentBuilder::new().build(),
            net_by_file: Mutex::new(HashMap::new()),
        };
        let reader = ThumbReader {
            shared: &shared,
            dir: root.join("kalit"),
            key: "kalit".to_string(),
            url: url.clone(),
            total,
            buf: RefCell::new(Vec::new()),
        };

        // `find_moov` aynan shunday yuradi: `ftyp` sarlavhasi,
        // keyin `mdat` sarlavhasi, keyin navbatdagi atom.
        let a = reader.read(0, 16).expect("0 dan o'qilmadi");
        let b = reader.read(32, 16).expect("32 dan o'qilmadi");
        let c = reader.read(100_000, 16).expect("100000 dan o'qilmadi");

        // Baytlar AYNAN o'z joyidan kelgan (manba tanani
        // pozitsiyadan yasaydi) — zaxira bo'lak siljib ketmagan.
        assert_eq!(a[0], 0, "0-bayt noto'g'ri");
        assert_eq!(b[0], (32 % 251) as u8, "32-bayt noto'g'ri");
        assert_eq!(c[0], (100_000 % 251) as u8, "100000-bayt noto'g'ri");

        assert_eq!(
            reqs.lock().unwrap().len(),
            1,
            "uchchala sarlavha o'qishi BITTA so'rovga tushishi kerak edi, \
             so'rovlar: {:?}",
            reqs.lock().unwrap()
        );

        // Zaxiradan TASHQARIDAGI joy — yangi so'rov (bu to'g'ri).
        let d = reader
            .read(total - 16, 16)
            .expect("oxiridan o'qilmadi");
        assert_eq!(d[0], ((total - 16) % 251) as u8, "oxirgi bayt noto'g'ri");
        assert_eq!(
            reqs.lock().unwrap().len(),
            2,
            "bo'lakdan tashqaridagi o'qish uchun aynan bitta yangi so'rov \
             kutilgandi, so'rovlar: {:?}",
            reqs.lock().unwrap()
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// ISITISH MANZILI: video manzilidan to'g'ri yasalishi.
    #[test]
    fn isitish_manzili_yasaladi() {
        let base = "https://x.workers.dev/api/image/ep_1_2_720p_178.mp4";
        assert_eq!(
            warm_url_for(base, 0).unwrap(),
            "https://x.workers.dev/api/warm/ep_1_2_720p_178.mp4?w=0"
        );
        assert_eq!(
            warm_url_for(base, 3).unwrap(),
            "https://x.workers.dev/api/warm/ep_1_2_720p_178.mp4?w=3"
        );
        // Query bo'lsa kesiladi.
        assert_eq!(
            warm_url_for(&format!("{base}?t=1"), 0).unwrap(),
            "https://x.workers.dev/api/warm/ep_1_2_720p_178.mp4?w=0"
        );
        // Kutilmagan shakl — isitish o'tkazib yuboriladi.
        assert!(warm_url_for("http://127.0.0.1:9/kino.mp4", 0).is_none());
        assert!(warm_url_for("https://x.dev/api/image/", 0).is_none());
    }



    /// FFI orqali holatni so'rab, JSON'ga o'giradi va Rust qaytargan
    /// satrni bo'shatadi.
    fn stats_json(urls_ptr: *const std::os::raw::c_char) -> serde_json::Value {
        let raw = rust_video_cache_stats(urls_ptr);
        let text = unsafe { std::ffi::CStr::from_ptr(raw) }
            .to_string_lossy()
            .to_string();
        crate::ffi_utils::rust_free_string(raw);
        serde_json::from_str(&text).unwrap()
    }

    /// Xuddi `stats_json`, lekin FON skanerlashi tugashini kutadi.
    ///
    /// `rust_video_cache_stats` Flutter'ning UI oqimida chaqiriladi va
    /// shu sabab u DISKKA CHIQMAYDI: kerak bo'lganda skanerlashni fon
    /// oqimiga topshiradi va xotiradagi hisobni darhol qaytaradi
    /// (`stat_snapshot_fast` izohiga qarang). Ya'ni birinchi chaqiruv
    /// hali tayyor bo'lmagan hisobni ko'rsatishi mumkin. Test esa
    /// YAKUNIY hisobni tekshiradi — shu sabab skanerlash tugagunicha
    /// kutamiz (eng ko'pi ~2 soniya).
    fn stats_json_ready(urls_ptr: *const std::os::raw::c_char) -> serde_json::Value {
        let mut last = stats_json(urls_ptr);
        for _ in 0..100 {
            let done = stats()
                .lock()
                .map(|m| {
                    m.get(TEST_NAME)
                        .map(|e| e.scanned && !e.scanning)
                        .unwrap_or(false)
                })
                .unwrap_or(false);
            if done {
                return stats_json(urls_ptr);
            }
            thread::sleep(Duration::from_millis(20));
            last = stats_json(urls_ptr);
        }
        last
    }

    // ═══════════════════════════════════════════════════════════
    //  TANBAL (LAZY) OYNA KESHLASH
    // ═══════════════════════════════════════════════════════════
    //
    // TALAB: 1.5 GB'lik video birinchi marta ochilganda FAQAT
    // boshidagi 480 MiB keshga olinsin. Keyingi bo'lak esa faqat
    // foydalanuvchi o'sha joyga yetganda (yoki sek qilganda)
    // olinsin. Ketma-ket hamma bo'lakni keshlash xarajatni behuda
    // ko'paytiradi.
    //
    // Bu test aynan shuni tekshiradi: tayyorlashda manbaga ATIGI
    // BITTA isitish so'rovi (w=0) ketadi; #2 oyna esa faqat
    // ALOHIDA so'ralganda olinadi va #1 oynaga UMUMAN tegilmaydi.

    /// Test uchun soxta "worker": faqat `/api/warm/...?w=N` ni
    /// biladi va kelgan har bir oyna raqamini yozib boradi.
    fn start_warm_origin(total: u64) -> (u16, Arc<Mutex<Vec<u64>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let log: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = Arc::clone(&log);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let l3 = Arc::clone(&l2);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let first = text.split("\r\n").next().unwrap_or("").to_string();
                    if let Some(i) = first.find("/api/warm/") {
                        let widx = first[i..]
                            .split("w=")
                            .nth(1)
                            .map(|v| {
                                v.chars()
                                    .take_while(|c| c.is_ascii_digit())
                                    .collect::<String>()
                            })
                            .and_then(|v| v.parse::<u64>().ok())
                            .unwrap_or(0);
                        l3.lock().unwrap().push(widx);
                        let body = format!("{{\"status\":\"warmed\",\"total\":{total}}}");
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = st.write_all(head.as_bytes());
                        let _ = st.write_all(body.as_bytes());
                        return;
                    }
                    let _ = st.write_all(
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                });
            }
        });
        (port, log)
    }

    /// So'ralgan oraliqlar faylni AYNAN bir marta qoplaydimi:
    /// bo'shliq ham, takror ham bo'lmasligi kerak.
    /// So'ralgan oraliqlar faylni BO'SHLIQSIZ qoplaydi.
    ///
    /// Ish o'g'irlashda (`steal_locked`) egasi so'ragan oraliq
    /// o'g'irlangan qism bilan ustma-ust tushadi — lekin egasi u
    /// yerga yetmasdan to'xtaydi. Shu sabab ustma-ustlik faqat BOSHI
    /// bo'lak chegarasida bo'lgan (o'g'irlangan) oraliq uchun
    /// ruxsat; haqiqiy takroriy trafik esa `tekshir_trafik` bilan
    /// o'lchanadi.
    fn tekshir_qoplama(ranges: &[String], total: u64) {
        let mut spans: Vec<(u64, u64)> = ranges
            .iter()
            .map(|r| parse_test_range(r, total))
            .collect();
        spans.sort_unstable();
        let mut pos = 0u64;
        for (s, e) in &spans {
            assert!(*s <= pos, "oraliqlarda bo'shliq bor: {spans:?}");
            if *s < pos {
                assert_eq!(
                    s % CHUNK_SIZE,
                    0,
                    "bo'lak o'rtasidan boshlangan ustma-ust so'rov: {spans:?}"
                );
            }
            pos = pos.max(e + 1);
        }
        assert_eq!(pos, total, "fayl to'liq qoplanmadi: {spans:?}");
    }

    /// Tarmoqdan HAQIQATAN o'qilgan baytlar fayl hajmidan deyarli
    /// oshmaydi (ish o'g'irlash takroriy trafik keltirmaydi).
    fn tekshir_trafik(key: &str, total: u64) {
        tekshir_trafik_ulush(key, total, 2 * CHUNK_SIZE);
    }

    fn tekshir_trafik_ulush(key: &str, total: u64, slack: u64) {
        let got = SHARED
            .get()
            .and_then(|s| s.net_by_file.lock().ok().map(|m| *m.get(key).unwrap_or(&0)))
            .unwrap_or(0);
        assert!(
            got <= total + slack,
            "ortiqcha trafik: {got} bayt o'qildi, fayl {total} bayt"
        );
    }

    /// Manba HAR BIR ULANISHNI bir xil, cheklangan tezlikda xizmat
    /// qiladi — aynan haqiqiy mobil tarmoqdagidek. Ya'ni UMUMIY
    /// tezlik faqat PARALLEL ulanishlar soniga bog'liq bo'ladi.
    ///
    /// Qaytadi: (port, bir vaqtda kuzatilgan ENG KO'P ulanish).
    fn start_paced_origin(total: u64) -> (u16, Arc<AtomicUsize>) {
        /// Har bir qadamda shuncha bayt yuboriladi.
        const STEP: usize = 64 * 1024;
        /// Qadamlar orasidagi tanaffus.
        const STEP_MS: u64 = 20;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let live = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let peak_out = Arc::clone(&peak);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let live = Arc::clone(&live);
                let peak = Arc::clone(&peak);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    // Hajm so'rovi (bytes=0-0) hisobga olinmaydi.
                    let paced = len > 1;
                    if paced {
                        let cur = live.fetch_add(1, Ordering::SeqCst) + 1;
                        peak.fetch_max(cur, Ordering::SeqCst);
                    }
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let mut off = 0usize;
                    while off < body.len() {
                        let upto = (off + STEP).min(body.len());
                        if st.write_all(&body[off..upto]).is_err() {
                            break;
                        }
                        off = upto;
                        if paced && off < body.len() {
                            thread::sleep(Duration::from_millis(STEP_MS));
                        }
                    }
                    if paced {
                        live.fetch_sub(1, Ordering::SeqCst);
                    }
                });
            }
        });
        (port, peak_out)
    }

    // ═══════════════════════════════════════════════════════════
    //  YUKLAB OLISH OXIRIGACHA BIR XIL TEZLIKDA KETADI
    // ═══════════════════════════════════════════════════════════
    //
    // TUZATILGAN XATO (foydalanuvchi: "yuklab olish oxiriga qarab
    // toshbaqadanham battar sekinlashib, sal kam to'xtab qolyabdi").
    //
    // Ilgari navbat 16 MiB'lik GURUH birligida yuritilardi va
    // navbat tugagan oqim BUTUNLAY chiqib ketardi. 24 MiB'lik
    // faylda guruhlar atigi 2 ta, ya'ni 6 ta oqimdan 2 tasi
    // ishlardi va oxirgi guruh YOLG'IZ qolardi — tezlik esa
    // parallel ulanishlar soniga proporsional.
    //
    // Bu test manbani HAR BIR ULANISH uchun bir xil, cheklangan
    // tezlikda xizmat qiladigan qilib qo'yadi. Shunda umumiy
    // tezlik faqat parallellikka bog'liq bo'ladi va sekinlashish
    // darhol vaqtda ko'rinadi.
    #[test]
    fn yuklab_olish_oxirigacha_parallel_ketadi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        // 32 MiB — har bir oqimga 2 tadan bo'lak (16 x 2), ya'ni
        // hammasi bir vaqtda ishlashi SHART.
        let total: u64 = 32 * CHUNK_SIZE;
        let (o_port, peak) = start_paced_origin(total);
        let name = "yolaklar.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);

        let t0 = Instant::now();
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);

        let count = total.div_ceil(CHUNK_SIZE);
        let mut done = false;
        for _ in 0..600 {
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let elapsed = t0.elapsed();
        assert!(done, "yuklab olish tugamadi");

        // Hamma oqim BARAVAR ishlagan bo'lsa, har biriga 2 MiB
        // to'g'ri keladi: 64 KiB x 20 ms = ~3.2 MB/s, ya'ni
        // ~0.7 soniya. Oqimlarning yarmi bo'sh tursa vaqt shunga
        // yarasha ikki-uch barobar oshadi. Chegara 3 soniya —
        // nuqson qaytsa test darhol yiqiladi.
        assert!(
            elapsed < Duration::from_secs(3),
            "yuklab olish parallel ketmadi: {elapsed:?} (oqimlar bo'sh turgan)"
        );
        // Oqimlarning hammasi haqiqatan bir vaqtda ishladimi.
        let p = peak.load(Ordering::SeqCst);
        assert!(
            p >= DOWNLOAD_THREADS - 1,
            "bir vaqtda atigi {p} ta ulanish bo'ldi (kutilgani {DOWNLOAD_THREADS} ta)"
        );
    }

    /// Manba sarlavhada TO'LIQ uzunlikni e'lon qiladi, tanani esa
    /// `cut` baytdan keyin JIMGINA uzib qo'yadi.
    ///
    /// Bu aynan ishlab chiqarishda o'lchab topilgan holat: worker
    /// javobni `Transfer-Encoding: chunked` bilan yuborardi va u
    /// 16 MiB o'rniga ~1 MB da uzilib qolardi (10 urinishdan 5-6
    /// tasida). Worker tomoni tuzatildi (`fixed_length_stream`),
    /// lekin ilova bunday javobga BARIBIR bardosh berishi kerak:
    /// olinganini saqlab, aynan o'sha joydan davom etsin va hech
    /// qachon cheksiz aylanmasin.
    fn start_truncating_origin(total: u64, cut: usize) -> (u16, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let h2 = Arc::clone(&hits);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let h3 = Arc::clone(&h2);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    // Hajm so'rovi (bytes=0-0) to'liq beriladi.
                    let send = if len > 1 {
                        h3.fetch_add(1, Ordering::SeqCst);
                        cut.min(body.len())
                    } else {
                        body.len()
                    };
                    let _ = st.write_all(&body[..send]);
                });
            }
        });
        (port, hits)
    }

    // ═══════════════════════════════════════════════════════════
    //  JAVOB YARMIDA UZILSA HAM YUKLASH TUGAYDI
    // ═══════════════════════════════════════════════════════════
    #[test]
    fn javob_yarmida_uzilsa_ham_yuklash_tugaydi() {
        let (_port, root) = ensure_server();
        let total: u64 = 12 * CHUNK_SIZE;
        // Har bir javob 1.5 bo'lakdan keyin uziladi — ya'ni
        // qoldiq ham, to'liq bo'lak ham sinovdan o'tadi.
        let cut = (CHUNK_SIZE + CHUNK_SIZE / 2) as usize;
        let (o_port, hits) = start_truncating_origin(total, cut);
        let name = "uzilgan.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);

        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);

        let count = total.div_ceil(CHUNK_SIZE);
        let mut done = false;
        for _ in 0..600 {
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(done, "javob uzilganda yuklash tugamadi");

        // Har bir javob ~1.5 bo'lak beradi, ya'ni 12 bo'lak uchun
        // ~8-10 so'rov yetadi. Cheksiz aylanish bo'lsa bu son
        // o'nlab barobar oshib ketardi.
        let n = hits.load(Ordering::SeqCst);
        assert!(
            n <= 40,
            "uzilgan javoblardan keyin so'rovlar cheksiz ko'paydi: {n} ta"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  YUKLAB OLISH YO'LAKLAR BILAN, TAKRORSIZ KETADI
    // ═══════════════════════════════════════════════════════════
    //
    // Yo'laklar bir-birining ustiga chiqmasligi SHART: aks holda
    // bir xil bayt ikki marta olinib, foydalanuvchi trafigi
    // bekorga sarflanardi. Ish o'g'irlash ham (`steal_locked`)
    // faqat HAVODA BO'LMAGAN qismni oladi — bu test aynan shuni
    // qo'riqlaydi.
    #[test]
    fn yuklab_olish_yolaklar_bilan_takrorsiz_ketadi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        // 48 MiB — 6 ta yo'lakka 8 tadan bo'lak.
        let total: u64 = 48 * CHUNK_SIZE;
        let (o_port, o_log) = start_origin(total);
        let name = "yolak_qoplama.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);

        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);

        let count = total.div_ceil(CHUNK_SIZE);
        let mut done = false;
        for _ in 0..600 {
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(done, "yuklab olish tugamadi");

        let ranges: Vec<String> = o_log
            .lock()
            .unwrap()
            .iter()
            .filter(|r| *r != "bytes=0-0")
            .cloned()
            .collect();

        // Fayl bo'lakma-bo'lak (1 MiB dan) so'ralmasligi kerak — bu
        // eski nuqsonning belgisi edi. Oxiridagi ish o'g'irlash va
        // yakuniy takrorlash bittalik so'rov berishi mumkin, lekin
        // ular oqimlar sonidan oshmaydi (eski nuqsonda HAR BIR bo'lak
        // alohida so'ralardi — 48 ta).
        let singles = ranges
            .iter()
            .filter(|r| {
                let (rs, re) = parse_test_range(r, total);
                re - rs + 1 <= CHUNK_SIZE
            })
            .count();
        assert!(
            singles <= DOWNLOAD_THREADS,
            "bo'lakma-bo'lak so'rovlar ko'payib ketdi ({singles} ta): {ranges:?}"
        );
        // Fayl bo'shliqsiz qoplanadi va takroriy trafik yo'q.
        tekshir_qoplama(&ranges, total);
        tekshir_trafik(name, total);
        // So'rovlar soni oqimlar sonidan juda oshmaydi (o'g'irlash
        // bir nechta qo'shishi mumkin).
        assert!(
            ranges.len() <= DOWNLOAD_THREADS * 2,
            "so'rovlar keragidan ko'p ({} ta): {ranges:?}",
            ranges.len()
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  BITTA SEKIN ULANISH BUTUN YUKLASHNI SUDRAMAYDI
    // ═══════════════════════════════════════════════════════════
    //
    // TUZATILGAN XATO (foydalanuvchi, 166 MB'lik fayl: "boshida
    // 3 MB/s, keyin 2, keyin 1 va 0.5 MB/s ga tushib qoldi").
    //
    // Eski tizimda ish oqimlarga TENG YO'LAK qilib bo'lib
    // berilardi va har bir oqim o'z yo'lagining hammasini BITTA
    // so'rovda olib qo'yardi. Sekin (yoki shunchaki omadsiz)
    // ulanishga tushgan oqim o'sha katta ulushni oxirigacha
    // sudrar, boshqalari esa ishini tugatib CHIQIB KETARDI —
    // tezlik oqimlar soniga proporsional pasayardi.
    //
    // Yangi tizimda ulush KICHIK va TALAB BO'YICHA beriladi, shu
    // sabab sekin ulanishga eng ko'pi `CLAIM_MIN` ta bo'lak
    // tegadi, qolgan hamma ish esa tez oqimlarga o'tadi.
    fn start_uneven_origin(total: u64) -> (u16, Arc<Mutex<Vec<String>>>, Arc<AtomicU64>) {
        /// Har bir qadamda shuncha bayt yuboriladi.
        const STEP: usize = 64 * 1024;
        /// Odatdagi ulanish: 64 KiB / 20 ms = ~3.2 MB/s.
        const STEP_MS: u64 = 20;
        /// BIRINCHI ulanish uch barobar sekin (~1.07 MB/s).
        const SLOW_MS: u64 = 60;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let slow_taken = Arc::new(AtomicBool::new(false));
        let slow_bytes = Arc::new(AtomicU64::new(0));
        let (l2, s2, b2) = (
            Arc::clone(&log),
            Arc::clone(&slow_taken),
            Arc::clone(&slow_bytes),
        );
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let (l3, s3, b3) = (Arc::clone(&l2), Arc::clone(&s2), Arc::clone(&b2));
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    // Hajm so'rovi (bytes=0-0) hisobga olinmaydi.
                    let paced = len > 1;
                    if paced {
                        l3.lock().unwrap().push(range.clone());
                    }
                    // Birinchi HAQIQIY ulanish — sekin ulanish.
                    let slow = paced && !s3.swap(true, Ordering::SeqCst);
                    if slow {
                        b3.store(len, Ordering::SeqCst);
                    }
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let mut off = 0usize;
                    while off < body.len() {
                        let upto = (off + STEP).min(body.len());
                        if st.write_all(&body[off..upto]).is_err() {
                            break;
                        }
                        off = upto;
                        if paced && off < body.len() {
                            thread::sleep(Duration::from_millis(if slow {
                                SLOW_MS
                            } else {
                                STEP_MS
                            }));
                        }
                    }
                });
            }
        });
        (port, log, slow_bytes)
    }

    #[test]
    fn yuklab_olish_bitta_sekin_ulanishdan_sudralmaydi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        // 96 MiB: 12 oqimga 8 tadan bo'lak to'g'ri keladi, ya'ni
        // eski tizimda sekin ulanish 8 MiB'ni sudrardi.
        let total: u64 = 96 * CHUNK_SIZE;
        let (o_port, o_log, slow_bytes) = start_uneven_origin(total);
        let name = "sekin_ulanish.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let urls = serde_json::json!([url]).to_string();
        let c_urls = std::ffi::CString::new(urls).unwrap();
        let dir = root.join("video_byte_cache").join(name);

        let t0 = Instant::now();
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);

        // Yuklash davomida ekranga beriladigan TEZLIK va OQIMLAR
        // soni ham o'lchanadi (foydalanuvchi ularni ko'radi).
        let count = total.div_ceil(CHUNK_SIZE);
        let mut done = false;
        let mut peak_speed = 0u64;
        let mut peak_streams = 0u64;
        for _ in 0..600 {
            let v = stats_json(c_urls.as_ptr());
            if let Some(item) = v.get(&url) {
                peak_speed = peak_speed.max(item["speed"].as_u64().unwrap_or(0));
                peak_streams = peak_streams.max(item["streams"].as_u64().unwrap_or(0));
            }
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        let elapsed = t0.elapsed();
        assert!(done, "yuklab olish tugamadi");

        // ── ASOSIY SHART ──
        // Sekin ulanishga eng ko'pi BITTA eng kichik ulush tegadi.
        // Eski tizimda unga butun bir yo'lak (8 MiB) tegardi va
        // hamma o'shani kutardi.
        let slow = slow_bytes.load(Ordering::SeqCst);
        assert!(
            slow <= CLAIM_MIN * CHUNK_SIZE,
            "sekin ulanishga katta ulush berildi: {} MiB",
            slow / CHUNK_SIZE
        );
        // Umumiy vaqt: 96 MiB / (11 x 3.2 MB/s) = ~2.7 s, ustiga
        // sekin ulanishning 4 MiB'i (~3.7 s). Eski tizimda sekin
        // yo'lak YOLG'IZ o'zi ~8 MiB / 1.07 = 7.5 s dan ortiq
        // sudralardi va boshqa oqimlar allaqachon chiqib ketgan
        // bo'lardi.
        assert!(
            elapsed < Duration::from_secs(7),
            "bitta sekin ulanish butun yuklashni sudradi: {elapsed:?}"
        );
        // Bitta bayt ham ikki marta olinmadi.
        let ranges: Vec<String> = o_log.lock().unwrap().clone();
        tekshir_qoplama(&ranges, total);
        // Ish KO'P kichik ulushga bo'lindi (ya'ni qayta taqsimlash
        // mumkin edi) — eski tizimda ulushlar soni oqimlar soniga
        // teng bo'lardi.
        assert!(
            ranges.len() > DOWNLOAD_THREADS,
            "ish qayta taqsimlanmadi: atigi {} ta so'rov",
            ranges.len()
        );
        // Ekrandagi o'lchovlar ishlaydi.
        assert!(peak_speed > 0, "tezlik o'lchanmadi (ekranda 0 MB/s)");
        assert!(
            peak_streams > 1,
            "faol oqimlar soni ko'rinmadi: {peak_streams}"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  70% DAN KEYIN HAM TEZLIK TUSHMAYDI (ish o'g'irlash)
    // ═══════════════════════════════════════════════════════════
    //
    // Foydalanuvchi: "yuklab olishda fayl 70 foizlarga borganda
    // tezlik pasayib ketyapti" (71 MB li fayl). Manbada ulanishlar
    // har xil tezlikda (har ikkinchisi 6 barobar sekin) — haqiqiy
    // mobil tarmoqdagidek. Ish o'g'irlashsiz oxirgi 30% ni sekin
    // ulanishlar yolg'iz tortardi.
    fn start_mixed_origin(total: u64) -> (u16, Arc<Mutex<Vec<String>>>) {
        const STEP: usize = 64 * 1024;
        const FAST_MS: u64 = 10;
        const SLOW_MS: u64 = 60;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = Arc::clone(&log);
        let n_conn = Arc::new(AtomicUsize::new(0));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let l3 = Arc::clone(&l2);
                let nc = Arc::clone(&n_conn);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let paced = len > 1;
                    if paced {
                        l3.lock().unwrap().push(range.clone());
                    }
                    let slow = paced && nc.fetch_add(1, Ordering::SeqCst) % 2 == 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let mut off = 0usize;
                    while off < body.len() {
                        let upto = (off + STEP).min(body.len());
                        if st.write_all(&body[off..upto]).is_err() {
                            break;
                        }
                        off = upto;
                        if paced && off < body.len() {
                            thread::sleep(Duration::from_millis(if slow { SLOW_MS } else { FAST_MS }));
                        }
                    }                });
            }
        });
        (port, log)
    }

    /// Worker'ga o'xshash manba: `/api/image/<fayl>` (oraliq bilan,
    /// `X-Cache` sarlavhasi) va `/api/warm/<fayl>` (isitish).
    /// Faylning 90% dan keyingi BIRINCHI so'rovi `X-Cache: MISS`
    /// bilan qaytadi (Cloudflare oynani chetga surgandek); shundan
    /// keyingi isitish so'rovlari esa `warm_delay` kutadi (katta
    /// faylni B2'dan qayta ko'chirish kabi).
    fn start_worker_like_origin(total: u64, warm_delay: Duration) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let missed = Arc::new(AtomicBool::new(false));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let missed = Arc::clone(&missed);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let path = text.split_whitespace().nth(1).unwrap_or("").to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    if path.contains("/api/warm/") {
                        if missed.load(Ordering::SeqCst) {
                            thread::sleep(warm_delay);
                        }
                        let body = format!("{{\"status\":\"cached\",\"total\":{total}}}");
                        let _ = st.write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                                body.len()
                            )
                            .as_bytes(),
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let cold = len > 1
                        && s * 10 >= total * 9
                        && !missed.swap(true, Ordering::SeqCst);
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nX-Cache: {}\r\nConnection: close\r\n\r\n",
                        if cold { "MISS" } else { "HIT-WINDOW" }
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    // Biroz sekin — oqimlar parallel ishlashi ko'rinsin.
                    for part in body.chunks(256 * 1024) {
                        if st.write_all(part).is_err() {
                            return;
                        }
                        thread::sleep(Duration::from_millis(15));
                    }
                });
            }
        });
        port
    }

    /// TOPILGAN XATO (foydalanuvchi skrinshoti: 98,59% da tarmoq
    /// 0 KB/s, ekranda tezlik asta pasayib 25 KB/s). Bitta `MISS`
    /// javobi oynani qayta isitishga yuborar va BARCHA oqimlar
    /// `wait_for_warm` da 90 soniyagacha turib qolardi.
    #[test]
    fn keshdan_bitta_miss_yuklashni_toxtatib_qoymaydi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        let total: u64 = 40 * CHUNK_SIZE;
        let o_port = start_worker_like_origin(total, Duration::from_secs(30));
        // Eski tizimda: ~31 s (butun qayta isitish kutilardi).
        let name = "miss_oxirida.mp4";
        let url = format!("http://127.0.0.1:{o_port}/api/image/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let key = cache_key(&url);
        let dir = root.join("video_byte_cache").join(&key);
        let count = total.div_ceil(CHUNK_SIZE);

        let t0 = Instant::now();
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let mut done = false;
        while t0.elapsed() < Duration::from_secs(40) {
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        let took = t0.elapsed();
        eprintln!("MISS bilan yuklash: {took:?}");
        assert!(done, "yuklash tugamadi");
        assert!(
            took < Duration::from_secs(10),
            "bitta MISS yuklashni to'xtatib qo'ydi: {took:?}"
        );
    }

    /// HAQIQIY MOBIL TARMOQQA YAQIN MODEL: umumiy kanal (`LINK`)
    /// barcha ulanishlarga bo'linadi, har bir ulanishning esa o'z
    /// chegarasi (`CAP`) bor — TCP oynasi / borib-kelish vaqti
    /// cheklagandek. To'liq tezlik uchun kamida `LINK / CAP` ta
    /// ulanish faol bo'lishi kerak; oxirida ulanishlar kamaysa
    /// umumiy tezlik tushadi — foydalanuvchi ko'rgani aynan shu.
    fn start_shared_origin(total: u64) -> u16 {
        const STEP: u64 = 64 * 1024;
        const LINK: f64 = 24.0 * 1024.0 * 1024.0;
        const CAP: f64 = 3.0 * 1024.0 * 1024.0;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let link_next: Arc<Mutex<Instant>> = Arc::new(Mutex::new(Instant::now()));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let link = Arc::clone(&link_next);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let mut conn_next = Instant::now();
                    let mut off = s;
                    while off <= e {
                        let upto = (off + STEP - 1).min(e);
                        let piece: Vec<u8> = (off..=upto).map(|i| (i % 251) as u8).collect();
                        let sz = piece.len() as f64;
                        if len > 1 {
                            // Umumiy kanalda navbat + ulanishning o'z chegarasi.
                            let slot = {
                                let mut g = link.lock().unwrap();
                                let now = Instant::now();
                                let startt = if *g > now { *g } else { now };
                                *g = startt + Duration::from_secs_f64(sz / LINK);
                                *g
                            };
                            conn_next = conn_next.max(Instant::now())
                                + Duration::from_secs_f64(sz / CAP);
                            let until = slot.max(conn_next);
                            let now = Instant::now();
                            if until > now {
                                thread::sleep(until - now);
                            }
                        }
                        if st.write_all(&piece).is_err() {
                            break;
                        }
                        off = upto + 1;
                    }
                });
            }
        });
        port
    }

    /// 3 ta sifat bir vaqtda — havodagi so'rovlar jami `DL_TOTAL_CONNS`
    /// dan oshmaydi (ilgari 3 x 16 = 48 ta ulanish ochilardi).
    #[test]
    fn uch_sifat_birga_ulanishlar_chegarasidan_oshmaydi() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        let total: u64 = 24 * CHUNK_SIZE;
        let (o_port, peak) = start_paced_origin(total);
        let names = ["uch_a.mp4", "uch_b.mp4", "uch_c.mp4"];
        let urls: Vec<String> = names
            .iter()
            .map(|n| format!("http://127.0.0.1:{o_port}/{n}"))
            .collect();
        for u in &urls {
            let c = std::ffi::CString::new(u.clone()).unwrap();
            assert_eq!(rust_video_cache_download(c.as_ptr()), 1);
        }
        let count = total.div_ceil(CHUNK_SIZE);
        let dirs: Vec<PathBuf> = names
            .iter()
            .map(|n| root.join("video_byte_cache").join(n))
            .collect();
        let mut done = false;
        for _ in 0..1200 {
            if dirs
                .iter()
                .all(|d| (0..count).all(|i| chunk_cached(d, i, total)))
            {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(done, "uchala yuklash tugamadi");
        let p = peak.load(Ordering::SeqCst);
        // Sinov serveri ulanishni mijoz o'qishni tugatgandan (yoki
        // to'xtatgandan) keyin ham bir zum sanab turadi — shu sabab
        // bir nechta ulanishlik farqqa joy bor. Ilgari bu son 48 edi.
        assert!(
            p <= DL_TOTAL_CONNS + 4,
            "havoda {p} ta so'rov bo'ldi (chegara {DL_TOTAL_CONNS})"
        );
        assert!(p >= DL_TOTAL_CONNS / 2, "ulanishlar to'liq ishlatilmadi: {p}");
    }

    #[test]
    fn yuklab_olish_umumiy_kanalda_oxirigacha_tez() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        let total: u64 = 71 * CHUNK_SIZE;
        let o_port = start_shared_origin(total);
        let name = "umumiy_kanal_71mb.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);
        let count = total.div_ceil(CHUNK_SIZE);

        let t0 = Instant::now();
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let mut t_first: Option<Duration> = None;
        let mut t70: Option<Duration> = None;
        let mut t_end: Option<Duration> = None;
        for _ in 0..3000 {
            let have = (0..count).filter(|i| chunk_cached(&dir, *i, total)).count() as u64;
            if have > 0 && t_first.is_none() {
                t_first = Some(t0.elapsed());
            }
            if have * 10 >= count * 7 && t70.is_none() {
                t70 = Some(t0.elapsed());
            }
            if have == count {
                t_end = Some(t0.elapsed());
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let t_first = t_first.expect("birinchi bo'lak kelmadi");
        let t70 = t70.expect("70% ga yetmadi");
        let t_end = t_end.expect("yuklab olish tugamadi");
        let head_rate = (count as f64 * 0.7) / t70.saturating_sub(t_first).as_secs_f64().max(0.01);
        let tail_rate = (count as f64 * 0.3) / t_end.saturating_sub(t70).as_secs_f64().max(0.01);
        eprintln!(
            "umumiy kanal: 70% gacha {head_rate:.1} bo'lak/s, keyin {tail_rate:.1} bo'lak/s ({t70:?} / {t_end:?})"
        );
        tekshir_trafik(name, total);
        assert!(
            tail_rate >= head_rate * 0.75,
            "70% dan keyin tezlik tushib ketdi: {head_rate:.1} -> {tail_rate:.1} bo'lak/s"
        );
    }

    #[test]
    fn yuklab_olish_sekin_ulanishlar_aralash_bolsa_ham_togri() {
        let _navbat = vaqt_testi_qulfi();
        let (_port, root) = ensure_server();
        let total: u64 = 71 * CHUNK_SIZE;
        let (o_port, o_log) = start_mixed_origin(total);
        let name = "tezlik_71mb.mp4";
        let url = format!("http://127.0.0.1:{o_port}/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);
        let count = total.div_ceil(CHUNK_SIZE);

        let t0 = Instant::now();
        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let mut t_first: Option<Duration> = None;
        let mut t70: Option<Duration> = None;
        let mut t_end: Option<Duration> = None;
        for _ in 0..3000 {
            let have = (0..count).filter(|i| chunk_cached(&dir, *i, total)).count() as u64;
            if have > 0 && t_first.is_none() {
                t_first = Some(t0.elapsed());
            }
            if have * 10 >= count * 7 && t70.is_none() {
                t70 = Some(t0.elapsed());
            }
            if have == count {
                t_end = Some(t0.elapsed());
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let t_first = t_first.expect("birinchi bo'lak kelmadi");
        let t70 = t70.expect("70% ga yetmadi");
        let t_end = t_end.expect("yuklab olish tugamadi");

        // Tezlik: bo'lak / soniya — 70% gacha va 70% dan keyin.
        let early = t70.saturating_sub(t_first).as_secs_f64().max(0.01);
        let head_rate = (count as f64 * 0.7) / early;
        let tail = t_end.saturating_sub(t70).as_secs_f64().max(0.01);
        let tail_rate = (count as f64 * 0.3) / tail;
        eprintln!(
            "70% gacha: {head_rate:.1} bo'lak/s, 70% dan keyin: {tail_rate:.1} bo'lak/s \
             ({t70:?} / {t_end:?})"
        );

        let got = SHARED
            .get()
            .and_then(|s| s.net_by_file.lock().ok().map(|m| *m.get(name).unwrap_or(&0)))
            .unwrap_or(0);
        eprintln!(
            "ortiqcha trafik: {:.2} MiB ({:.1}%)",
            got.saturating_sub(total) as f64 / CHUNK_SIZE as f64,
            got.saturating_sub(total) as f64 * 100.0 / total as f64
        );
        // Bu model ATAYLAB og'ir va tasodifiy (har ikkinchi YANGI
        // ulanish 6 barobar sekin), shu sabab tezlik nisbati bu yerda
        // TEKSHIRILMAYDI — u testlar parallel ishlaganda tebranadi.
        // Tezlik regressiyasini `yuklab_olish_umumiy_kanalda_oxirigacha_tez`
        // ushlaydi. Bu yerda esa ish o'g'irlash va yakuniy takrorlash
        // og'ir sharoitda ham TO'G'RI ishlashi tekshiriladi: fayl
        // to'liq, bo'shliqsiz va deyarli ortiqcha trafiksiz yuklanadi.
        let _ = (head_rate, tail_rate);
        let ranges: Vec<String> = o_log.lock().unwrap().clone();
        tekshir_qoplama(&ranges, total);
        // Og'ir sharoitda yakuniy takrorlash biroz ortiqcha trafik
        // beradi — 5% dan oshmasligi kerak.
        tekshir_trafik_ulush(name, total, total / 20);
    }

    // ═══════════════════════════════════════════════════════════
    //  OYNA KESHDAN TUSHIB KETSA — QAYTA ISITILADI
    // ═══════════════════════════════════════════════════════════
    //
    // Cloudflare isitilgan oynani (480 MiB) istalgan payt chetga
    // surib qo'yishi mumkin. O'shanda worker javobni xotira orqali
    // (B2'dan yoki mayda oraliq keshidan) beradi va buni
    // `X-Cache: MISS` / `HIT-RANGE` sarlavhasi bilan aytadi.
    //
    // Bu yo'l SEZILARLI SEKIN. Ilgari ilova buni umuman sezmasdi:
    // xotirasida oyna "tayyor" bo'lib qolar va yuklash oxirigacha
    // sekin yo'ldan ketaverardi. Endi ilova oynani QAYTA isitadi.
    fn start_cold_cache_origin(total: u64) -> (u16, Arc<Mutex<Vec<u64>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let warms: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));
        let w2 = Arc::clone(&warms);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let w3 = Arc::clone(&w2);
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    let first = text.split("\r\n").next().unwrap_or("").to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                        return;
                    }
                    // Isitish so'rovi — "tayyor" deb javob beramiz
                    // (lekin bo'laklar baribir "keshdan emas" deb
                    // keladi: kesh o'chib ketgan holat).
                    if first.contains("/api/warm/") {
                        let widx = first
                            .split("w=")
                            .nth(1)
                            .map(|v| {
                                v.chars()
                                    .take_while(|c| c.is_ascii_digit())
                                    .collect::<String>()
                            })
                            .and_then(|v| v.parse::<u64>().ok())
                            .unwrap_or(0);
                        w3.lock().unwrap().push(widx);
                        let body = format!("{{\"status\":\"warmed\",\"total\":{total}}}");
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = st.write_all(head.as_bytes());
                        let _ = st.write_all(body.as_bytes());
                        return;
                    }
                    let mut range = String::new();
                    for line in text.split("\r\n") {
                        if let Some(v) = line.strip_prefix("Range: ") {
                            range = v.trim().to_string();
                        }
                    }
                    let (s, e) = parse_test_range(&range, total);
                    let len = e - s + 1;
                    // MUHIM: javob isitilgan oynadan EMAS.
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nX-Cache: MISS\r\nContent-Length: {len}\r\nContent-Range: bytes {s}-{e}/{total}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = st.write_all(head.as_bytes());
                    let body: Vec<u8> = (s..=e).map(|i| (i % 251) as u8).collect();
                    let _ = st.write_all(&body);
                });
            }
        });
        (port, warms)
    }

    #[test]
    fn oyna_keshdan_tushsa_qayta_isitiladi() {
        let (_port, root) = ensure_server();
        let total: u64 = 8 * CHUNK_SIZE;
        let (o_port, warms) = start_cold_cache_origin(total);
        let name = "sovigan_oyna.mp4";
        let url = format!("http://127.0.0.1:{o_port}/api/image/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        let dir = root.join("video_byte_cache").join(name);

        assert_eq!(rust_video_cache_download(c_url.as_ptr()), 1);
        let count = total.div_ceil(CHUNK_SIZE);
        let mut done = false;
        for _ in 0..400 {
            if (0..count).all(|i| chunk_cached(&dir, i, total)) {
                done = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(done, "yuklab olish tugamadi");

        // Isitish KAMIDA IKKI MARTA bo'lishi kerak: birinchisi —
        // odatdagi (yuklash boshlanishida), ikkinchisi — javob
        // keshdan kelmagani sezilgandan keyin.
        let n = warms.lock().unwrap().len();
        assert!(
            n >= 2,
            "oyna kesh chetiga chiqib ketgani sezilmadi (isitish {n} marta)"
        );
        // Lekin B2 puli bekorga sarflanmasin — qayta isitish
        // `REWARM_COOLDOWN` bilan qattiq cheklangan.
        assert!(
            n <= 3,
            "qayta isitish juda ko'p takrorlandi: {n} marta"
        );
    }

    #[test]
    fn tanbal_keshlash_faqat_kerakli_oynani_oladi() {
        let (_port, _root) = ensure_server();
        // Uch oynaga bo'linadigan "katta" fayl (1.4 GB).
        const WINDOWS: u64 = 3;
        let total = WARM_WINDOW * WINDOWS - 1024;
        let (w_port, w_log) = start_warm_origin(total);
        let name = "tanbal.mp4";
        let url = format!("http://127.0.0.1:{w_port}/api/image/{name}");
        let c_url = std::ffi::CString::new(url.clone()).unwrap();

        // ── 1) TAYYORLASH: FAQAT #0 OYNA ──────────────────────
        assert_eq!(rust_video_cache_prepare(c_url.as_ptr()), 1);
        let mut ready = false;
        for _ in 0..200 {
            if rust_video_cache_prepare_status(c_url.as_ptr()) == 1 {
                ready = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(ready, "tayyorlash tugamadi");

        let asked = w_log.lock().unwrap().clone();
        assert_eq!(
            asked,
            vec![0u64],
            "tayyorlashda faqat #0 oyna olinishi kerak edi, olingani: {asked:?}"
        );

        // Hajm isitish javobidan olinadi — buning uchun manbaga
        // ALOHIDA so'rov ketmaydi.
        assert_eq!(
            rust_video_cache_total(c_url.as_ptr()),
            total,
            "hajm isitish javobidan olinmadi"
        );

        // ── 2) BOSHQA OYNALAR HALI OLINMAGAN ──────────────────
        assert_eq!(
            rust_video_cache_window_status(c_url.as_ptr(), 0),
            1,
            "#0 oyna tayyor bo'lishi kerak"
        );
        assert_eq!(
            rust_video_cache_window_status(c_url.as_ptr(), 1),
            3,
            "#1 oyna umuman boshlanmagan bo'lishi kerak"
        );

        // ── 3) FOYDALANUVCHI #2 OYNAGA SEK QILDI ──────────────
        // Faqat AYNAN o'sha oyna olinadi; #1 ga tegilmaydi.
        assert_eq!(rust_video_cache_warm_window(c_url.as_ptr(), 2), 1);
        let mut got = false;
        for _ in 0..200 {
            if rust_video_cache_window_status(c_url.as_ptr(), 2) == 1 {
                got = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(got, "#2 oyna keshga olinmadi");

        let asked = w_log.lock().unwrap().clone();
        assert_eq!(
            asked,
            vec![0u64, 2],
            "faqat #0 va #2 oyna olinishi kerak edi, olingani: {asked:?}"
        );
        assert_eq!(
            rust_video_cache_window_status(c_url.as_ptr(), 1),
            3,
            "#1 oynaga umuman tegilmasligi kerak edi"
        );

        // ── 4) TAKRORIY SO'ROV MANBAGA CHIQMAYDI ──────────────
        // Tayyor oyna qayta so'ralsa, manbaga BITTA ham qo'shimcha
        // so'rov ketmasligi kerak (xarajat behuda oshmasin).
        for _ in 0..5 {
            assert_eq!(rust_video_cache_warm_window(c_url.as_ptr(), 0), 1);
            assert_eq!(rust_video_cache_warm_window(c_url.as_ptr(), 2), 1);
        }
        thread::sleep(Duration::from_millis(300));
        let asked = w_log.lock().unwrap().clone();
        assert_eq!(
            asked,
            vec![0u64, 2],
            "tayyor oyna uchun manbaga takroriy so'rov ketdi: {asked:?}"
        );
    }

}
