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

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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

/// Bir vaqtda TARMOQDAN yuklanadigan bo'laklarning eng ko'p soni.
///
/// Foydalanuvchi progress chizig'ini tez-tez surganda pleyer ketma-ket
/// bir necha yangi ulanish ochadi va ularning har biri o'z bo'lagini
/// yuklamoqchi bo'ladi. Chegarasiz holda o'nlab parallel yuklash
/// boshlanib, ular bir xil (cheklangan) tarmoq tezligini bo'lishib
/// oladi — natijada HECH BIRI o'z vaqtida tugamaydi, pleyer esa
/// javob kutib qotib qoladi. Endi bir vaqtda eng ko'pi 6 ta yuklash
/// bo'ladi; qolganlari navbat kutadi (rad etilmaydi).
///
/// 6 -> 8: yuklab olish endi DOWNLOAD_THREADS (4) ta oqimda ketadi,
/// shu sabab pleyerning oldindan yuklashi (3 ta oqim) bilan birga
/// 7 ta bo'ladi. Chegara 6 da qolsa, ular bir-birini navbatda ushlab
/// qolardi. 8 — ikkalasiga ham joy beradi, lekin xotira sarfi hamon
/// bashorat qilinadigan (eng ko'pi ~8 MiB bufer) bo'lib qoladi.
const MAX_NET_FETCHES: usize = 8;
static NET_FETCHES: AtomicUsize = AtomicUsize::new(0);






/// ── BO'LAK OLINMASA: QAYTA URINISH ────────────────────────────
///
/// Javobning erta tugashi ExoPlayer uchun "fayl tugadi" degani
/// (pastdagi `serve` ichidagi izohga qarang), shu sabab bitta
/// tarmoq xatosi sabab ulanishni yopish MUMKIN EMAS. Bo'lak shu
/// muddat davomida qayta-qayta so'raladi.
///
/// 20 soniya ATAYLAB tanlangan: mobil tarmoqda bir lahzalik
/// uzilish odatda 1-3 soniyada tuzaladi; 20 soniyadan ortiq
/// kutish esa ma'nosiz — bunda tarmoq haqiqatan yo'q va pleyerga
/// halol xato berilgani yaxshiroq (u holda ilova videoni AYNAN
/// O'SHA nuqtadan qayta ochadi, boshidan emas).
const CHUNK_RETRY_MAX: Duration = Duration::from_secs(20);
const CHUNK_RETRY_WAIT: Duration = Duration::from_millis(600);




/// O'chirilayotgan papkalar shu prefiks bilan nomlanadi. Ular
/// "video" emas — kesh skanerlash ularni e'tiborsiz qoldiradi, ilova
/// ishga tushganda esa qolib ketganlari tozalanadi (masalan ilova
/// o'chirish o'rtasida yopilgan bo'lsa).
const TRASH_PREFIX: &str = ".axlat_";

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
        in_flight: Mutex::new(HashSet::new()),
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

fn chunk_name(index: u64) -> String {
    format!("chunk_{index:07}.bin")
}

/// Diskdagi kutilgan bo'lak hajmi: shifrlash yoqilgan bo'lsa PKCS7
/// to'ldirish sabab asl (ochiq) hajmdan katta bo'ladi.
fn chunk_on_disk_len(plain_len: u64) -> u64 {
    if crypto::is_enabled() {
        crypto::encrypted_size(plain_len)
    } else {
        plain_len
    }
}

/// Bo'lak diskda TO'LIQ turibdimi (shifr ochilmaydi — faqat fayl
/// uzunligi tekshiriladi, ya'ni juda arzon).
fn chunk_cached(dir: &PathBuf, index: u64, total: u64) -> bool {
    let plain = chunk_plain_len(index, total);
    if plain == 0 {
        return false;
    }
    fs::metadata(dir.join(chunk_name(index)))
        .map(|m| m.len() == chunk_on_disk_len(plain))
        .unwrap_or(false)
}

/// Keshdagi bo'lak faylini o'qiydi va (shifrlash yoqilgan bo'lsa)
/// ochadi. Hajm yoki shifr mos kelmasa (masalan eski, boshqa
/// o'lchamdagi qoldiq fayl) — `None`: chaqiruvchi buni "keshda yo'q"
/// deb talqin qilib, bo'lakni qaytadan yuklab oladi.
fn read_cached_chunk(dir: &PathBuf, key: &str, index: u64, expected_len: usize) -> Option<Vec<u8>> {
    let raw = fs::read(dir.join(chunk_name(index))).ok()?;
    if raw.len() as u64 != chunk_on_disk_len(expected_len as u64) {
        return None;
    }
    if !crypto::is_enabled() {
        return Some(raw);
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
    let meta_path = dir.join("meta.json");
    if let Ok(raw) = fs::read_to_string(&meta_path) {
        if let Ok(meta) = serde_json::from_str::<CacheMeta>(&raw) {
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
        chunk_size: CHUNK_SIZE,
        // Davomiylik va bo'lak-vaqt jadvali faylning ICHIDA —
        // ular 1-bo'lak keshga tushgandan keyin hisoblanib, shu
        // yerga qayta yoziladi.
        duration_secs: 0.0,
        chunk_start_ms: Vec::new(),
    };
    if let Ok(json) = serde_json::to_string(&meta) {
        let _ = fs::write(&meta_path, json);
    }
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
        }
    }
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
    let Ok(raw) = fs::read_to_string(dir.join("meta.json")) else {
        return 0;
    };
    match serde_json::from_str::<CacheMeta>(&raw) {
        Ok(m) if m.chunk_size == CHUNK_SIZE => m.total_size,
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
        if m.len() == chunk_on_disk_len(plain) {
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

/// Butun ilova bo'yicha bir vaqtda yuklanadigan videolar soni.
/// Ijro (pleyer) har doim ustuvor bo'lishi uchun ataylab kichik.
const DOWNLOAD_WORKERS: usize = 2;

/// BITTA videoni yuklab olishda bir vaqtda ishlaydigan oqimlar soni.
///
/// NEGA KERAK: ilgari bo'laklar KETMA-KET olinardi — bitta so'rov
/// tugamaguncha keyingisi boshlanmasdi. Bunda haqiqiy tezlik
/// "bo'lak hajmi / so'rov kechikishi" bilan cheklanadi: 1 MiB va
/// 200 ms kechikishda bu atigi ~5 MB/s, mobil tarmoqda ancha kam.
/// Shu sabab VIDEONI KO'RISH (u 3 ta oqimda oldindan yuklaydi)
/// yuklab olish tugmasidan TEZROQ ishlardi — foydalanuvchi buni
/// to'g'ri ravishda teskari deb hisobladi.
///
/// TALAB: "yuklab olish tugmasi bosilsa, fayl hech qanday cheklovsiz,
/// foydalanuvchi interneti qancha tez bo'lsa shuncha tez olinsin".
///
/// Shu sabab yuklab olish oqimlari:
///   * 8 ta (mobil tarmoqdagi yuqori kechikishni "yashirish" uchun —
///     tezlik amalda oqimlar soniga proporsional o'sadi);
///   * NAVBATDA KUTMAYDI: `fetch_and_store_chunk` ga `no_queue = true`
///     bilan boradi, ya'ni MAX_NET_FETCHES ularni ushlab qolmaydi.
///
/// Yagona chegara — oqimlar soni, va u xotira uchun kerak: bir vaqtda
/// eng ko'pi 12 x 1 MiB bufer bo'ladi. Tezlikni esa endi faqat
/// foydalanuvchining tarmog'i belgilaydi.
const DOWNLOAD_THREADS: usize = 6;

/// ── BITTA USTKI SO'ROVDA NECHTA BO'LAK OLINADI ────────────────
///
/// Diskda bo'laklar avvalgidek 1 MiB bo'lib, alohida shifrlangan
/// holda saqlanadi — sek, foiz hisobi va uzilishdan keyin davom
/// ettirish shunga tayanadi va o'zgarmaydi.
///
/// LEKIN worker'ga (va u orqali B2'ga) so'rov endi bo'lakma-bo'lak
/// emas, GURUH bilan yuboriladi.
///
/// NEGA: har bir ustki so'rov B2'da bitta "Class B" tranzaksiya —
/// ya'ni PUL. 1 MiB bo'lak bilan 166 MB'lik video = 166 ta so'rov
/// edi. 10 tadan guruh bilan bu 17 ga tushadi, ya'ni B2 xarajati
/// O'N BAROBAR kamayadi. Ustiga har bir so'rovning yo'l vaqti
/// (latency) endi 1 MiB'ga emas, 10 MiB'ga taqsimlanadi — shu sabab
/// yuklab olish TEZLIGI ham oshadi.
///
/// Xotira oshmaydi: javob oqimi bo'lakma-bo'lak o'qiladi, bir vaqtda
/// faqat bitta 1 MiB bufer turadi (`fetch_and_store_chunk` ga
/// qarang).
///
/// 4 -> 10 (foydalanuvchi talabi: "4 tasi sekin ekan"). Bu FAQAT
/// YUKLAB OLISH TUGMASI yo'liga tegishli. PLEYER avvalgidek
/// bittadan 1 MiB bo'lak oladi (`span = 1`) — u 15 soniyalik bufer
/// qoidasi bilan ishlaydi va guruh bilan olsa keragidan ko'p
/// yuklab qo'yardi.
///
/// Guruh kattalashgani sayin "pauza"da havoda qolgan oqim ham
/// kattalashadi — shu sabab pauza endi oqimni O'RTASIDAN uzadi
/// (pastdagi `'outer` sikliga qarang), ya'ni pauzadan keyin bitta
/// ham ortiqcha bayt kelmaydi.
const GROUP_CHUNKS: u64 = 8;

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
///   1) `GROUP_CHUNKS = 8` — so'rov worker chegarasiga aynan mos;
///   2) shunga qaramay server so'ralganidan KAM qaytarsa, uning
///      haqiqiy chegarasi shu yerda ESLAB QOLINADI va keyingi
///      so'rovlar o'sha o'lchamda yuboriladi. Ya'ni server
///      chegarasi kelajakda o'zgarsa ham, ilova unga o'zi
///      moslashadi va bu xato QAYTA TAKRORLANMAYDI.
static SERVER_SPAN_MAX: AtomicU64 = AtomicU64::new(u64::MAX);

/// Serverning kuzatilgan chegarasi bo'yicha oraliqni qisqartiradi.
fn clamp_span(range_start: u64, range_end: u64) -> u64 {
    let cap = SERVER_SPAN_MAX.load(Ordering::Relaxed);
    if cap == u64::MAX {
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
}

static DOWNLOADS: OnceLock<Mutex<HashMap<String, DownloadState>>> = OnceLock::new();
static DL_POOL: AtomicBool = AtomicBool::new(false);
/// Har bir yangi yuklash buyrug'i uchun o'sib boradigan raqam
/// (`DownloadState::epoch` izohiga qarang).
static DL_EPOCH: AtomicU64 = AtomicU64::new(0);

fn downloads() -> &'static Mutex<HashMap<String, DownloadState>> {
    DOWNLOADS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Shu bo'lakni AYNI PAYTDA boshqa ish oqimi olayaptimi.
///
/// Yuklab olish uchun kerak: pleyer (yoki oldindan yuklash) allaqachon
/// olayotgan bo'lakni KUTIB o'tirmaymiz — uni chetga qo'yib, keyingi
/// bo'lakka o'tamiz va oxirida qaytib kelamiz.
///
/// NEGA: `fetch_and_store_chunk` bir xil bo'lakni ikki marta
/// yuklamaslik uchun 6 SONIYAGACHA kutadi. Video ochiq turganda
/// foydalanuvchi yuklab olishni bosса, yuklovchining hamma oqimlari
/// aynan pleyer olayotgan birinchi bo'laklarga urilib, o'sha yerda
/// kutib qolardi — yuklab olish shu sabab sudralib ketardi.
fn chunk_in_flight(shared: &Shared, key: &str, index: u64) -> bool {
    // Yuklovchi guruh bilan ishlaydi, shu sabab uning "uchish"
    // kaliti ham guruh boshiga tekislangan bo'ladi.
    let first = (index / GROUP_CHUNKS) * GROUP_CHUNKS;
    let flight_key = format!("{key}#s{GROUP_CHUNKS}:{first}");
    shared
        .in_flight
        .lock()
        .map(|s| s.contains(&flight_key))
        .unwrap_or(false)
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
fn pick_task() -> Option<(String, String, u64)> {
    let now = Instant::now();
    let mut map = downloads().lock().ok()?;
    let key = map
        .iter()
        .find(|(_, s)| s.wanted && !s.running && s.next_try <= now)
        .map(|(k, _)| k.clone())?;
    let st = map.get_mut(&key)?;
    st.running = true;
    Some((key, st.url.clone(), st.epoch))
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
                log(format!("Yuklab olish TUGADI: {key}"));
            }
            // Foydalanuvchi pauza qildi.
            Ok(DlOutcome::Paused) => {
                map.remove(&key);
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
                    let wait = 2u64.saturating_pow(st.failures.min(5)).min(60);
                    st.next_try = Instant::now() + Duration::from_secs(wait);
                    log(format!(
                        "Yuklab olish uzildi ({key}): {e} — {wait}s dan keyin davom etadi"
                    ));
                }
            }
        }
    }
}

/// Bitta bo'lakni olishga urinishning natijasi.
enum ChunkRes {
    /// Tarmoqdan olindi va diskka tushdi.
    Ok,
    /// Ayni payt boshqa oqim (pleyer) olyapti — chetga qo'yiladi va
    /// navbat oxirida qaytib olinadi. XATO EMAS.
    Deferred,
    /// Bir necha urinishdan keyin ham olinmadi.
    Failed(String),
}

/// Bitta videoni yuklaydi (bitta bosqich).
///
/// Bo'laklar DOWNLOAD_THREADS ta oqimda PARALLEL olinadi: navbat —
/// oddiy atomik hisoblagich, har bir oqim keyingi raqamni olib o'sha
/// bo'lakni yuklaydi. Shu bilan tarmoq kechikishi "yashiriladi" va
/// tezlik faqat foydalanuvchining internetiga bog'liq bo'ladi.
///
/// ── QAT'IY QOIDA: BITTA BO'LAKNING XATOSI QOLGANINI TO'XTATMAYDI ──
/// Ilgari birinchi xatoda 12 ta oqimning HAMMASI to'xtardi va butun
/// vazifa uzoq kutishga ketardi. Endi xato bo'lgan bo'lak uchun
/// o'sha oqimning O'ZI qisqa tanaffus bilan 3 marta urinib ko'radi;
/// baribir olinmasa — chetga yoziladi va oqim KEYINGI bo'lakka
/// o'tadi. Bosqich oxirida yetishmaganlari bo'lsa, vazifa darhol
/// yangi bosqich bilan davom etadi.
fn run_download(key: &str, url: &str) -> Result<DlOutcome, String> {
    let Some(shared) = SHARED.get() else {
        return Err("kesh-server ishga tushmagan".to_string());
    };
    let dir = shared.cache_root.join(key);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

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
    // Navbat: keyingi olinadigan bo'lak indeksi.
    let cursor = Arc::new(AtomicU64::new(0));
    // AYNI PAYTDA boshqa ish oqimi (pleyer yoki oldindan yuklash)
    // olayotgan bo'laklar shu yerga chetga qo'yiladi va navbat
    // tugagach qaytib olinadi — ular ustida KUTIB turilmaydi.
    let deferred: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));
    // Foydalanuvchi pauza bosdimi (oqimlar buni ko'rib chiqadi).
    let paused = Arc::new(AtomicBool::new(false));
    // Birinchi xato — faqat jurnal va xabar uchun; u endi qolgan
    // oqimlarni TO'XTATMAYDI.
    let first_err: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    // Shu bosqichda TARMOQDAN muvaffaqiyatli olingan bo'laklar soni.
    let done_count = Arc::new(AtomicU64::new(0));
    // Uch urinishdan keyin ham olinmagan bo'laklar soni.
    let failed_count = Arc::new(AtomicU64::new(0));

    let mut workers = Vec::with_capacity(DOWNLOAD_THREADS);
    for _ in 0..DOWNLOAD_THREADS {
        let cursor = Arc::clone(&cursor);
        let deferred = Arc::clone(&deferred);
        let paused = Arc::clone(&paused);
        let first_err = Arc::clone(&first_err);
        let done_count = Arc::clone(&done_count);
        let failed_count = Arc::clone(&failed_count);
        let (k, d, u) = (key.to_string(), dir.clone(), url.to_string());
        let h = thread::Builder::new()
            .name("video-download-w".into())
            // Kichik stek yetarli: oqim faqat bitta bo'lakni oladi
            // va diskka yozadi.
            .stack_size(256 * 1024)
            .spawn(move || loop {
                if paused.load(Ordering::SeqCst) {
                    break;
                }
                // ── IKKI BOSQICH ─────────────────────────────────
                // 1) Navbat bo'yicha: band bo'lak chetga qo'yiladi.
                // 2) Navbat tugagach: chetga qo'yilganlari olinadi
                //    (endi kutish ham mumkin — bu oxirgi qoldiq).
                let n = cursor.fetch_add(1, Ordering::SeqCst);
                let (i, second_pass) = if n < count {
                    (n, false)
                } else {
                    match deferred.lock().ok().and_then(|mut d| d.pop()) {
                        Some(x) => (x, true),
                        None => break,
                    }
                };
                if !download_active(&k) {
                    paused.store(true, Ordering::SeqCst);
                    break;
                }

                let chunk_start = i * CHUNK_SIZE;
                let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);
                let expected_len = (chunk_end - chunk_start + 1) as usize;
                let on_disk_len = chunk_on_disk_len(expected_len as u64);
                let path = d.join(chunk_name(i));

                // Diskda TO'LIQ bor bo'lsa — tarmoqqa umuman
                // chiqilmaydi (yuklash to'xtagan joyidan davom etadi).
                if let Ok(m) = fs::metadata(&path) {
                    if m.len() == on_disk_len {
                        stat_note_chunk(&k, i, expected_len as u64);
                        continue;
                    }
                }

                // Bo'lakni AYNI PAYTDA pleyer (yoki oldindan yuklash)
                // olayotgan bo'lsa, uni KUTMAYMIZ: chetga qo'yamiz va
                // keyingi bo'lakka o'tamiz.
                if !second_pass && chunk_in_flight(shared, &k, i) {
                    if let Ok(mut dd) = deferred.lock() {
                        dd.push(i);
                    }
                    continue;
                }

                // ── CHETGA QO'YILGAN BO'LAK (ikkinchi bosqich) ──
                // Uni boshqa oqim GURUH bilan olayotgan bo'lishi
                // mumkin. Shu sabab avval diskda paydo bo'lishini
                // kutamiz. Ilgari bu yerda darhol bitta bo'lak
                // so'ralardi va natijada bir xil ma'lumot ikki marta
                // olinardi (guruh + alohida bo'lak).
                if second_pass {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    while Instant::now() < deadline {
                        if chunk_cached(&d, i, total)
                            || !download_active(&k)
                            || !chunk_in_flight(shared, &k, i)
                        {
                            break;
                        }
                        thread::sleep(Duration::from_millis(100));
                    }
                    if chunk_cached(&d, i, total) {
                        stat_note_chunk(&k, i, expected_len as u64);
                        continue;
                    }
                }
                let prio = FetchPrio::Download;

                let mut res = ChunkRes::Failed("urinilmadi".to_string());
                for attempt in 0..3u32 {
                    if !download_active(&k) {
                        paused.store(true, Ordering::SeqCst);
                        break;
                    }
                    match fetch_and_store_chunk(
                        shared,
                        &k,
                        &d,
                        &u,
                        i,
                        chunk_start,
                        chunk_end,
                        expected_len,
                        total,
                        prio,
                        None,
                    ) {
                        Ok(_) => {
                            // Bo'lak QAYTDI, lekin diskda to'liq
                            // turibdimi? Yarim olingan bo'lsa qoldiq
                            // saqlangan bo'ladi va keyingi urinish
                            // o'sha joydan davom etadi.
                            let landed = fs::metadata(&path)
                                .map(|m| m.len() == on_disk_len)
                                .unwrap_or(false);
                            if landed {
                                res = ChunkRes::Ok;
                                break;
                            }
                            res = ChunkRes::Failed(format!("bo'lak #{i} to'liq olinmadi"));
                        }
                        Err(e) if e == BUSY_ERR => {
                            res = ChunkRes::Deferred;
                            break;
                        }
                        Err(e) => {
                            res = ChunkRes::Failed(e);
                        }
                    }
                    // Qisqa tanaffus — tarmoq bir lahzaga uzilgan
                    // bo'lsa shu yerda tiklanadi (uzoq kutish YO'Q).
                    // Oxirgi urinishdan keyin kutish MA'NOSIZ.
                    if attempt < 2 {
                        thread::sleep(Duration::from_millis(300 * (attempt as u64 + 1)));
                    }
                }

                match res {
                    ChunkRes::Ok => {
                        done_count.fetch_add(1, Ordering::SeqCst);
                    }
                    ChunkRes::Deferred => {
                        if let Ok(mut dd) = deferred.lock() {
                            dd.push(i);
                        }
                    }
                    ChunkRes::Failed(e) => {
                        failed_count.fetch_add(1, Ordering::SeqCst);
                        if let Ok(mut slot) = first_err.lock() {
                            if slot.is_none() {
                                *slot = Some(e);
                            }
                        }
                        // TO'XTAMAYMIZ — keyingi bo'lakka o'tamiz.
                    }
                }
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

    if paused.load(Ordering::SeqCst) || !download_active(key) {
        return Ok(DlOutcome::Paused);
    }

    // YAKUNIY HAQIQAT — DISK. Chetga qo'yilgan bo'lak poyga sabab
    // e'tibordan chetda qolgan bo'lsa ham, bu tekshiruv uni ko'radi.
    let missing = (0..count).filter(|i| !chunk_cached(&dir, *i, total)).count() as u64;
    if missing == 0 {
        return Ok(DlOutcome::Done);
    }
    let done = done_count.load(Ordering::SeqCst);
    let failed = failed_count.load(Ordering::SeqCst);
    if done > 0 || failed == 0 {
        // Ilgarilash bor (yoki xato umuman bo'lmagan, faqat band
        // bo'laklar qolgan) — kutmasdan davom etamiz.
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
    // B2'ga bitta ham ortiqcha so'rov ketmasligi uchun: avval oyna
    // keshga isitiladi (va hajm ham o'sha javobdan olinadi), keyin
    // yuklash BUTUNLAY keshdan ketadi.
    start_prepare(url);
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
                },
            );
        }
    }
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
/// {"total":<bayt>,"downloaded":<bayt>,"downloading":<bool>}.
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
        // Tarmoq uzilgan va qayta urinish kutilayotgan bo'lsa — UI
        // buni ko'rsatishi mumkin (yuklash TO'XTAGANI YO'Q).
        item.insert(
            "retrying".to_string(),
            serde_json::json!(download_failing(&key)),
        );
        out.insert(url, serde_json::Value::Object(item));
    }
    string_to_cptr(serde_json::Value::Object(out).to_string())
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
    sink: Option<&mut dyn FnMut(u64, &[u8]) -> bool>,
) -> Result<Vec<u8>, String> {
    let expected_len = (end - start + 1) as usize;
    if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
        // MUHIM (diagnostika): diskdan o'qilgan bo'lak uchun TARMOQQA
        // umuman chiqilmaydi. Bu log ekranda ko'rinib turishi kerak —
        // shu bilan "qayta yuklanyaptimi yoki keshdanmi" degan savolga
        // to'g'ridan-to'g'ri javob beradi.
        log(format!("Bo'lak #{index} KESHDAN o'qildi (tarmoqsiz)"));
        // Yuklab olish hisobi (foiz ko'rsatkichi) uchun: bu bo'lak
        // diskda BOR — hisobda ham shunday turishi kerak.
        stat_note_chunk(key, index, expected_len as u64);
        return Ok(bytes);
    }
    // Bu yo'l — PLEYERGA xizmat ko'rsatish yo'li, ya'ni ustuvor.
    fetch_and_store_chunk(
        shared,
        key,
        dir,
        url,
        index,
        start,
        end,
        expected_len,
        expected_total,
        FetchPrio::Player,
        sink,
    )
}

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

/// Bo'lakni kim so'rayotgani — kutish qoidalari shunga qarab
/// belgilanadi.
#[derive(Clone, Copy, PartialEq, Eq)]
enum FetchPrio {
    /// PLEYER bo'lakni HOZIR kutyapti. Navbatda turmaydi; bo'lakni
    /// boshqa oqim olayotgan bo'lsa uni 6 soniyagacha kutadi (ikki
    /// marta yuklab olmaslik uchun), keyin o'zi oladi.
    Player,
    /// FOYDALANUVCHI yuklab olish tugmasini bosgan. Navbatda ham
    /// turmaydi, band bo'lakni ham UMUMAN kutmaydi — `BUSY_ERR`
    /// qaytadi va yuklovchi uni chetga qo'yib keyingi bo'lakka
    /// o'tadi. Shu bilan yuklab olish oqimlari pleyer olayotgan
    /// bo'laklarda kutib qolmaydi.
    Download,
    /// Fon'da OLDINDAN yuklash. Yagona qatlam — u MAX_NET_FETCHES
    /// navbatida kutishi mumkin.
    Prefetch,
}

/// "Bo'lakni ayni payt boshqa oqim olyapti" — bu XATO EMAS, faqat
/// "keyinroq qaytib kel" degan belgi.
const BUSY_ERR: &str = "__band__";

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
// ── ILOVA KUTMAYDI ────────────────────────────────────────────
//
// Isitish FON ish oqimida ketadi. Video shu payt odatdagidek,
// darhol ochiladi va birinchi soniyalar uchun kerakli 2-3 guruh
// to'g'ridan-to'g'ri olinadi. Isitish tugashi bilan (odatda yarim
// daqiqa ichida) qolgan hamma narsa keshdan keladi.
//
// Agar ilova yopilsa yoki tarmoq uzilsa — belgisi olib tashlanadi
// va keyingi ochilishda qaytadan uriniladi.

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

/// Video manzilidan isitish manzilini yasaydi:
///   .../api/image/ep_1_2_720p.mp4  ->  .../api/warm/ep_1_2_720p.mp4?w=0
/// Manzil kutilgan shaklda bo'lmasa `None` (isitish o'tkazib
/// yuboriladi, qolgan hamma narsa avvalgidek ishlaydi).
fn warm_url_for(url: &str, widx: u64) -> Option<String> {
    const MARK: &str = "/api/image/";
    let i = url.find(MARK)?;
    let head = &url[..i];
    let tail = &url[i + MARK.len()..];
    let name = tail.split('?').next().unwrap_or(tail);
    if name.is_empty() {
        return None;
    }
    Some(format!("{head}/api/warm/{name}?w={widx}"))
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
            match shared.warm_agent.get(&warm_url).call() {
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

/// Tayyorlash holati: 0 = ketyapti, 1 = tayyor.
static PREPARE: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();

fn prepares() -> &'static Mutex<HashMap<String, bool>> {
    PREPARE.get_or_init(|| Mutex::new(HashMap::new()))
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
fn start_prepare(url: &str) -> bool {
    let Some(shared) = SHARED.get() else {
        return false;
    };
    let key = cache_key(url);
    {
        let Ok(mut m) = prepares().lock() else {
            return false;
        };
        // Allaqachon ketyapti yoki tayyor.
        if m.contains_key(&key) {
            return true;
        }
        m.insert(key.clone(), false);
    }
    let dir = shared.cache_root.join(&key);
    let (k, u) = (key.clone(), url.to_string());
    let spawned = thread::Builder::new()
        .name("video-cache-prepare".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let done = || {
                if let Ok(mut m) = prepares().lock() {
                    m.insert(k.clone(), true);
                }
            };
            let _ = fs::create_dir_all(&dir);

            // 1) Fayl butunlay diskda bo'lsa — hech narsa kerak emas.
            let known_total = meta_total_from_disk(&dir);
            if known_total > 0 {
                let count = known_total.div_ceil(CHUNK_SIZE);
                if (0..count).all(|i| chunk_cached(&dir, i, known_total)) {
                    log(format!("Tayyorlash: {k} allaqachon to'liq diskda"));
                    done();
                    return;
                }
            }

            // 2) Oynani keshga isitamiz VA TUGASHINI KUTAMIZ.
            //    B2'ga ketadigan yagona so'rov aynan shu.
            let Some(shared) = SHARED.get() else {
                done();
                return;
            };
            let Some(warm_url) = warm_url_for(&u, 0) else {
                // Manzil kutilmagan shaklda — odatdagi yo'l bilan
                // davom etamiz.
                done();
                return;
            };
            log(format!("Tayyorlash: oyna keshga isitilmoqda — {warm_url}"));
            let total = match shared.warm_agent.get(&warm_url).call() {
                Ok(resp) => {
                    let body = resp.into_string().unwrap_or_default();
                    log(format!("Tayyorlash javobi: {body}"));
                    if let Ok(mut m) = warm_state().lock() {
                        let tag = format!("{k}#w0");
                        let ok = body.contains("cached") || body.contains("warmed");
                        let st = if ok { WarmState::Done } else { WarmState::Failed };
                        m.insert(tag, (st, Instant::now()));
                    }
                    parse_warm_total(&body)
                }
                Err(e) => {
                    log(format!("Tayyorlash uzildi: {e}"));
                    0
                }
            };

            // 3) Hajm isitish javobidan olindi — meta.json shu
            //    yerda yoziladi, ya'ni hajmni aniqlash uchun ham
            //    B2'ga alohida so'rov KETMAYDI.
            if total > 0 && meta_total_from_disk(&dir) == 0 {
                let meta = CacheMeta {
                    total_size: total,
                    content_type: "video/mp4".to_string(),
                    chunk_size: CHUNK_SIZE,
                    duration_secs: 0.0,
                    chunk_start_ms: Vec::new(),
                };
                if let Ok(json) = serde_json::to_string(&meta) {
                    let _ = fs::write(dir.join("meta.json"), json);
                }
                log(format!("Tayyorlash: hajm aniqlandi — {total} bayt"));
            }
            done();
        });
    if spawned.is_err() {
        if let Ok(mut m) = prepares().lock() {
            m.insert(key, true);
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

/// Tayyorlash tugadimi (kalit bo'yicha).
fn prepare_ready(key: &str) -> bool {
    prepares()
        .lock()
        .map(|m| m.get(key).copied().unwrap_or(true))
        .unwrap_or(true)
}

/// Tayyorlash holati: 1 = tayyor, 0 = hali ketyapti/boshlanmagan.
#[no_mangle]
pub extern "C" fn rust_video_cache_prepare_status(url_ptr: *const c_char) -> i32 {
    let Some(url) = (unsafe { cstr_to_str(url_ptr) }) else {
        return 1;
    };
    if prepare_ready(&cache_key(url)) {
        1
    } else {
        0
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
/// Pleyer (ijro) HECH QACHON kutmaydi — video darhol ochilishi kerak.
const WARM_WAIT_MAX: Duration = Duration::from_secs(90);

fn wait_for_warm(key: &str, byte_pos: u64) {
    let widx = byte_pos / WARM_WINDOW;
    let tag = format!("{key}#w{widx}");
    let deadline = Instant::now() + WARM_WAIT_MAX;
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

/// Bo'lakni diskka YAKUNIY holda yozadi (shifrlab, atom ravishda).
fn write_full_chunk(dir: &PathBuf, key: &str, index: u64, plain: &[u8]) -> bool {
    let on_disk: Vec<u8> = match crypto::derive_chunk_key_iv(key, index) {
        Some((k, iv)) => crypto::encrypt_chunk(plain, &k, &iv),
        None => plain.to_vec(),
    };
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

fn fetch_and_store_chunk(
    shared: &Shared,
    key: &str,
    dir: &PathBuf,
    url: &str,
    index: u64,
    _start: u64,
    _end: u64,
    expected_len: usize,
    expected_total: u64,
    prio: FetchPrio,
    // ── OQIM: BAYTLAR KELISHI BILAN PLEYERGA UZATILADI ─────────
    //
    // TUZATILGAN XATO (sekin tarmoqda pleyer qotishi):
    // ilgari server BUTUN 1 MiB bo'lak yuklanib bo'lgunicha
    // pleyerga BIRORTA ham bayt bermasdi. Sekin mobil tarmoqda
    // (masalan 1 Mbit/s) bitta bo'lak 8 soniyagacha kelardi —
    // ExoPlayer'ning HTTP o'qish chegarasi esa AYNAN 8 soniya.
    // Ya'ni bo'lak kech kelgan zahoti pleyer ulanishni xato deb
    // uzardi.
    //
    // Endi baytlar tarmoqdan kelishi bilan DARHOL pleyerga
    // uzatiladi (va bir vaqtda diskka ham yoziladi). Pleyer
    // uchun oqim hech qachon jim qolmaydi. Telegram ham aynan
    // shunday ishlaydi: uning ExoPlayer uchun yozgan manbasi
    // (FileStreamLoadOperation) mavjud baytlarni darhol beradi,
    // butun bo'lakni kutmaydi.
    mut sink: Option<&mut dyn FnMut(u64, &[u8]) -> bool>,
) -> Result<Vec<u8>, String> {
    let total = expected_total;
    if total == 0 {
        return Err("hajm noma'lum".to_string());
    }
    let chunk_count = total.div_ceil(CHUNK_SIZE);
    if index >= chunk_count {
        return Err(format!("bo'lak #{index} fayldan tashqarida"));
    }

    // ── QANCHA OLINADI: PLEYER 1 MiB, YUKLOVCHI GURUH ──────────
    //
    // MUHIM QOIDA (foydalanuvchi trafigini tejash):
    //   * PLEYER (va oldindan yuklash) har safar ATIGI BITTA 1 MiB
    //     bo'lak oladi. Guruh bilan olinsa, 30 soniyalik bufer
    //     chegarasi guruh chegarasigacha yaxlitlanib, keragidan
    //     ko'p yuklanardi: 1 daqiqalik 10 MB'lik videoda pleyer
    //     hali ishga tushmasidan butun fayl olinib qolardi.
    //   * YUKLAB OLISH esa baribir butun faylni oladi, shu sabab u
    //     4 tadan guruh bilan ishlaydi (kamroq so'rov, tezroq).
    //
    // Bu B2 xarajatiga TA'SIR QILMAYDI: fayl allaqachon Cloudflare
    // keshiga isitilgan bo'ladi, ya'ni pleyerning bo'lak-bo'lak
    // so'rovlari B2'ga umuman bormaydi — chekkadan xizmat qilinadi.
    let span = if prio == FetchPrio::Download {
        GROUP_CHUNKS
    } else {
        1
    };
    let g_first = (index / span) * span;
    let g_last = (g_first + span - 1).min(chunk_count - 1);
    // "Uchish" belgisi: bir xil oraliqni ikkita oqim baravar tortib
    // olmasligi uchun. Kalitga `span` ham kiradi — pleyerning bitta
    // bo'lagi bilan yuklovchining guruhi bir-birini chalkashtirmasin.
    let flight_key = format!("{key}#s{span}:{g_first}");

    // Boshqa ish oqimi bu guruhni bizdan oldin allaqachon yuklab
    // boshlagan bo'lishi mumkin — bunday holda kerakli bo'lak diskda
    // paydo bo'lishini kutamiz, ikkinchi marta tarmoqqa chiqmaymiz.
    //
    // Kutish 6 soniya bilan chegaralangan: shu vaqt ichida bo'lak
    // paydo bo'lmasa, biz uni O'ZIMIZ olamiz. Ikki marta yuklab olish
    // — pleyerning qotib qolishidan ming marta yaxshiroq, ustiga
    // diskka yozish atom (tmp -> rename) bo'lgani uchun xavfsiz.
    // ── BAND BO'LAKNI KUTISH MUDDATI ──────────────────────────
    //
    // PLEYER uchun 6 -> 2 soniya. Sabab: kutish davomida pleyerga
    // BITTA HAM BAYT bormaydi, ExoPlayer'ning chegarasi esa 8
    // soniya. 2 soniya tez tarmoqda ikkilanishning oldini olishga
    // yetadi; undan uzog'ida bo'lakni o'zimiz olganimiz — pleyerni
    // qotirib qo'yishdan yaxshiroq.
    let wait_deadline = Instant::now()
        + if prio == FetchPrio::Player {
            Duration::from_secs(2)
        } else {
            Duration::from_secs(6)
        };
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
        if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
            return Ok(bytes);
        }
        // YUKLAB OLISH hech qachon kutmaydi: band guruh chetga
        // qo'yiladi va oqim darhol keyingi bo'lakka o'tadi.
        if prio == FetchPrio::Download {
            return Err(BUSY_ERR.to_string());
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
        // Boshqa ish oqimi biz kutayotganimizda ulgurgan bo'lishi
        // mumkin — yana bir bor tekshiramiz.
        if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
            return Ok(bytes);
        }

        // ── Parallel yuklashlar chegarasi (MAX_NET_FETCHES izohiga
        // qarang). Navbat 8 soniyadan ortiq kutilmaydi — undan keyin
        // baribir yuklab olinadi, chunki javobsiz qolish eng yomon
        // holat.
        let queue_deadline = Instant::now() + Duration::from_secs(8);
        if prio != FetchPrio::Prefetch {
            // Pleyer kutyapti yoki foydalanuvchi yuklab olishni
            // boshlagan — navbatga umuman turmaymiz.
            NET_FETCHES.fetch_add(1, Ordering::SeqCst);
        } else {
            loop {
                let cur = NET_FETCHES.load(Ordering::SeqCst);
                if cur < MAX_NET_FETCHES {
                    if NET_FETCHES
                        .compare_exchange(cur, cur + 1, Ordering::SeqCst, Ordering::SeqCst)
                        .is_ok()
                    {
                        break;
                    }
                    continue;
                }
                if Instant::now() >= queue_deadline {
                    NET_FETCHES.fetch_add(1, Ordering::SeqCst);
                    break;
                }
                if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
                    return Ok(bytes);
                }
                thread::sleep(Duration::from_millis(30));
            }
        }
        // Chegara hisoblagichi bu blok qanday tugashidan qat'i nazar
        // albatta kamaytiriladi.
        struct FetchGuard;
        impl Drop for FetchGuard {
            fn drop(&mut self) {
                NET_FETCHES.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let _guard = FetchGuard;

        // ── GURUHNING QAYSI JOYIDAN BOSHLAYMIZ ─────────────────
        // Guruh boshidagi TAYYOR bo'laklar qayta so'ralmaydi.
        let mut from = g_first;
        while from < index && chunk_cached(dir, from, total) {
            from += 1;
        }
        // ── QOLDIQDAN DAVOM ETISH ──────────────────────────────
        // Oldingi urinishda shu bo'lakning bir qismi olinib, tarmoq
        // uzilgan bo'lishi mumkin. O'sha qism diskda saqlangan: uni
        // o'qib, tarmoqdan FAQAT yetishmayotgan dumini so'raymiz.
        let from_len = chunk_plain_len(from, total) as usize;
        let prefix = read_part(dir, key, from, from_len).unwrap_or_default();
        let range_start = from * CHUNK_SIZE + prefix.len() as u64;
        let range_end = clamp_span(
            range_start,
            ((g_last + 1) * CHUNK_SIZE).saturating_sub(1).min(total - 1),
        );
        if range_start > range_end {
            return read_cached_chunk(dir, key, index, expected_len)
                .ok_or_else(|| format!("bo'lak #{index} topilmadi"));
        }

        // ── OYNANI ISITISHNI BOSHLAYMIZ ────────────────────────
        // Aynan shu yerda: demak biz haqiqatan tarmoqqa chiqyapmiz.
        // Diskda hamma narsa bor bo'lsa bu yergacha yetib kelinmaydi
        // va worker bekorga bezovta qilinmaydi.
        maybe_warm(url, key, range_start);
        // Yuklab olish tugmasi bosilgan bo'lsa — isitish tugashini
        // kutamiz va keyin hammasini keshdan olamiz (yuqoridagi
        // `wait_for_warm` izohiga qarang). Pleyer kutmaydi.
        if prio == FetchPrio::Download {
            wait_for_warm(key, range_start);
        }

        log(format!(
            "Bo'laklar {from}..={g_last} worker'dan olinmoqda ({range_start}-{range_end})..."
        ));
        let resp = shared
            .agent
            .get(url)
            .set("Range", &format!("bytes={range_start}-{range_end}"))
            .call()
            .map_err(|e| e.to_string())?;
        let status = resp.status();

        // ── BUTUNLIK TEKSHIRUVI ────────────────────────────────
        // Serverning e'lon qilgan UMUMIY fayl hajmi diskdagi
        // meta.json bilan mos kelmasa — manbadagi fayl o'zgargan va
        // keshimiz ESKIRGAN. Bunday holda eski bo'laklarni saqlash
        // videoni buzib ko'rsatishga olib kelardi.
        // Server so'ralgan ORALIQNI qisqartirdimi — chegarasini
        // eslab qolamiz (yuqoridagi `SERVER_SPAN_MAX` izohiga
        // qarang). Faqat `Content-Range`ga ishoniladi.
        if let Some(cr) = resp.header("Content-Range") {
            if let Some((s_str, e_str)) = cr
                .trim()
                .strip_prefix("bytes ")
                .and_then(|r| r.split('/').next())
                .and_then(|r| r.split_once('-'))
            {
                if let (Ok(rs), Ok(re)) = (s_str.trim().parse::<u64>(), e_str.trim().parse::<u64>())
                {
                    if re >= rs {
                        note_server_span(range_end - range_start + 1, re - rs + 1);
                    }
                }
            }
        }
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

        // ── OQIMNI BO'LAKMA-BO'LAK DISKKA YOZAMIZ ──────────────
        // Xotirada bir vaqtda faqat BITTA bo'lak (1 MiB) turadi —
        // guruh 4 MiB bo'lsa ham. To'lgan bo'lak darhol shifrlanib
        // diskka tushadi, keyingisi noldan yig'iladi.
        let mut cur = from;
        let mut want = from_len;
        let mut acc: Vec<u8> = prefix;
        let mut wanted_bytes: Option<Vec<u8>> = None;
        let mut reader = resp.into_reader();
        let mut buf = [0u8; 64 * 1024];
        let mut read_err: Option<String> = None;
        let mut got_net: u64 = 0;
        // Oqimga uzatilgan baytning MUTLAQ o'rni.
        let mut abs = range_start;

        'outer: loop {
            // ── PAUZA: TARMOQ OQIMI DARHOL UZILADI ─────────────
            //
            // MUAMMO EDI: pauza bosilganda ish oqimi faqat
            // NAVBATDAGI bo'lakdan oldin to'xtardi. Havoda qolgan
            // HTTP javob esa oxirigacha o'qilib bo'linardi — ya'ni
            // 6 ta oqim x bitta guruh trafigi pauzadan keyin ham
            // ketaverardi. Guruh 10 MiB bo'lgach bu yanada
            // sezilarli bo'lardi.
            //
            // Endi bayroq HAR 64 KB da tekshiriladi: pauza bosilsa
            // o'qish shu yerda to'xtaydi, `reader` tashlanadi va
            // TCP ulanish uziladi — trafik butunlay to'xtaydi.
            // Yarim olingan bo'lak qoldiq sifatida diskda qoladi,
            // shu sabab davom ettirilganda aynan o'sha joydan
            // boshlanadi (bitta bayt ham qayta olinmaydi).
            if prio == FetchPrio::Download && !download_active(key) {
                read_err = Some("pauza — oqim uzildi".to_string());
                break;
            }
            let n = match reader.read(&mut buf) {
                Ok(n) => n,
                Err(e) => {
                    read_err = Some(e.to_string());
                    break;
                }
            };
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
            // Baytlar kelishi bilan pleyerga (agar u kutayotgan
            // bo'lsa) DARHOL uzatiladi.
            if let Some(sk) = sink.as_deref_mut() {
                if !sk(abs, piece) {
                    read_err = Some("pleyer ulanishi uzildi".to_string());
                    // Olinganini diskka saqlash uchun tsikldan
                    // odatdagidek chiqamiz.
                    break;
                }
            }
            abs += piece.len() as u64;
            while !piece.is_empty() {
                if want == 0 || acc.len() >= want {
                    break;
                }
                let take = (want - acc.len()).min(piece.len());
                acc.extend_from_slice(&piece[..take]);
                piece = &piece[take..];
                if acc.len() < want {
                    continue;
                }
                // Bo'lak to'ldi — diskka yozamiz.
                if write_full_chunk(dir, key, cur, &acc) {
                    stat_note_chunk(key, cur, want as u64);
                }
                if cur == index {
                    wanted_bytes = Some(acc.clone());
                }
                if cur >= g_last {
                    break 'outer;
                }
                cur += 1;
                want = chunk_plain_len(cur, total) as usize;
                acc = Vec::with_capacity(want);
            }
        }

        // Yarim qolgan bo'lak — qoldiq sifatida saqlanadi, keyingi
        // urinish AYNAN shu joydan davom etadi.
        if cur <= g_last && !acc.is_empty() && acc.len() < want {
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
            "TARMOQDAN >>> fayl='{key}' bo'laklar {from}..={g_last} ({range_start}-{range_end}) {got_net} bayt | shu fayl: {:.2} MB | jami: {:.2} MB",
            file_net as f64 / (1024.0 * 1024.0),
            total_net as f64 / (1024.0 * 1024.0)
        ));

        match wanted_bytes {
            Some(b) => Ok(b),
            None => read_cached_chunk(dir, key, index, expected_len).ok_or_else(|| {
                read_err.unwrap_or_else(|| format!("bo'lak #{index} to'liq olinmadi"))
            }),
        }
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

        // ── BO'LAKNI OLAMIZ (kerak bo'lsa TARMOQDAN) ────────────
        // Bu chaqiruv aynan shu daqiqada bo'ladi: darvoza ochilgan,
        // ya'ni yuklab olingan bo'laklar 15 soniyalik buferga
        // yetmagan. Boshqa paytda tarmoqqa umuman chiqilmaydi.
        if held.as_ref().map(|(i, _)| *i) != Some(chunk_index) {
            // ── BIR MARTALIK TARMOQ XATOSI JAVOBNI UZMASLIGI KERAK ──
            //
            // TUZATILGAN XATO (foydalanuvchi ko'rgan asosiy muammo:
            // "video 15 soniya ishlab, boshidan qayta boshlanadi"):
            // bo'lakni olishda BITTA xato bo'lsa ham javob shu yerda
            // to'xtardi va ulanish yopilardi. ExoPlayer uchun esa
            // javobning erta tugashi "FAYL TUGADI" degani —
            // `ProgressiveMediaPeriod` yuklashni yakunlangan deb
            // biladi va video shu yerda tamom bo'ladi. Takrorlash
            // (looping) yoqilgani sabab u darhol BOSHIDAN
            // boshlanardi. Ya'ni bir lahzalik tarmoq uzilishi
            // videoni noldan qayta boshlatib yuborardi.
            //
            // Endi bo'lak bir necha marta, qisqa tanaffuslar bilan
            // qayta so'raladi. Mobil tarmoqdagi bir martalik xato
            // odatda ikkinchi urinishda tuzaladi va foydalanuvchi
            // hech narsa sezmaydi. Faqat tarmoq HAQIQATAN uzilgan
            // bo'lsa (chegara tugasa) ulanish yopiladi — bu holatda
            // pleyer xato oladi va ilova o'sha nuqtadan qayta
            // ochadi (video boshidan boshlanmaydi).
            let retry_deadline = Instant::now() + CHUNK_RETRY_MAX;
            let mut attempt = 0u32;
            // Oqim orqali pleyerga ALLAQACHON uzatilgan bayt chegarasi.
            let mut streamed_to = cursor;
            let mut sink_err: Option<std::io::Error> = None;
            // Pleyer ulanishni yopgan bo'lsa — hech narsani davom
            // ettirmaymiz.
            let mut client_gone = false;
            let bytes = loop {
                let res = {
                    // Baytlar tarmoqdan kelishi bilan darhol
                    // pleyerga uzatiladi (izohni `fetch_and_store_chunk`
                    // ichidan qarang). Faqat UZLUKSIZ oqim uzatiladi:
                    // agar so'rov bo'lak o'rtasidan boshlangan bo'lsa
                    // (diskda yarim qoldiq bor edi), oqim tashlanadi va
                    // bo'lak odatdagidek diskdan o'qiladi.
                    let mut sink = |abs: u64, data: &[u8]| -> bool {
                        if abs > streamed_to {
                            return true; // uzilish — oqim bilan bermaymiz
                        }
                        let s_from = streamed_to.max(abs);
                        let s_to = (abs + data.len() as u64).min(stop + 1);
                        if s_to <= s_from {
                            return true;
                        }
                        let off = (s_from - abs) as usize;
                        let len = (s_to - s_from) as usize;
                        if let Err(e) = stream.write_all(&data[off..off + len]) {
                            sink_err = Some(e);
                            return false;
                        }
                        SERVED_BYTES.fetch_add(len as u64, Ordering::Relaxed);
                        streamed_to = s_to;
                        true
                    };
                    read_or_fetch_chunk(
                        shared,
                        &key,
                        &dir,
                        url,
                        chunk_index,
                        chunk_start,
                        chunk_end,
                        total,
                        Some(&mut sink),
                    )
                };
                if let Some(e) = sink_err.take() {
                    // Pleyerga yozib bo'lmadi — u ulanishni yopgan
                    // (sek qildi, epizod almashdi yoki ilova yopildi).
                    // Bunday holatda QAYTA URINISH ma'nosiz: shu
                    // yerda ish tugaydi.
                    log(format!("Pleyer ulanishni yopdi ({start}-{end}): {e}"));
                    client_gone = true;
                    break None;
                }
                match res {
                    Ok(b) => break Some(b),
                    Err(e) => {
                        // Oqim bilan bir necha bayt yetkazilgan bo'lsa,
                        // ish bekorga ketmadi: kursor o'sha yergacha
                        // suriladi va qolgani keyingi aylanishda
                        // olinadi.
                        if streamed_to > cursor {
                            break None;
                        }
                        attempt += 1;
                        if Instant::now() >= retry_deadline {
                            log(format!(
                                "Bo'lak #{chunk_index} {attempt} urinishdan keyin ham olinmadi ({e}) — ulanish yopiladi"
                            ));
                            break None;
                        }
                        log(format!(
                            "Bo'lak #{chunk_index} olinmadi ({e}) — {attempt}-urinish, qayta uriniladi"
                        ));
                        thread::sleep(CHUNK_RETRY_WAIT);
                    }
                }
            };

            // Baytlar oqim orqali ketgan bo'lsa — ularni QAYTA
            // yozmaymiz: kursorni surib, keyingi aylanishga o'tamiz.
            if client_gone {
                break;
            }
            if streamed_to > cursor {
                cursor = streamed_to;
                held = None;
                // Oqim yarmida uzilgan bo'lsa ham ULANISH YOPILMAYDI:
                // qolgan baytlar keyingi aylanishda qayta so'raladi.
                continue;
            }

            let Some(bytes) = bytes else { break };
            log(format!(
                "Bo'lak #{chunk_index} tayyor ({} bayt)",
                bytes.len()
            ));
            held = Some((chunk_index, bytes));

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
            fs::write(dir.join(chunk_name(i)), crypto::encrypt_chunk(&data, &k, &iv)).unwrap();
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

        // ── 4) KESHDA BO'SHLIQ BO'LSA ─────────────────────────────
        // Javob bo'shliqda QISQARTIRILMAYDI: server yetishmayotgan
        // bo'lakni javob yozilayotgan payt yuklab olishga urinadi va
        // BIR MARTALIK xatoda ulanishni YOPMAYDI — u qayta uriniladi
        // (`CHUNK_RETRY_MAX`). Bu testda manba umuman mavjud emas
        // (127.0.0.1:9), shu sabab tekshiriladigan narsa: bo'shliqqacha
        // bo'lgan hamma narsa BITTA javobda kelgan va ulanish
        // bo'shliqda DARHOL yopilib qolmagan.
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
        assert!(
            gap_start.elapsed() < CHUNK_RETRY_MAX,
            "bo'shliqqacha bo'lgan qism kechikib keldi"
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
        stats().lock().unwrap().remove(TEST_NAME);
        let parsed = stats_json_ready(c_urls.as_ptr());
        assert_eq!(
            parsed[&test_url]["downloaded"].as_u64().unwrap(),
            TEST_TOTAL - CHUNK_SIZE,
            "yarim qolgan bo'lak hisobga qo'shilib ketdi"
        );
        assert!(
            !dir.join(chunk_name(5)).exists(),
            "yarim qolgan bo'lak o'chirilmadi"
        );


        // ── 12) PLEYER 1 MiB OLADI, YUKLOVCHI GURUH BILAN ────────
        //
        // Bu ikkalasi ATAYLAB har xil:
        //   * pleyer har safar ATIGI bitta 1 MiB bo'lak oladi —
        //     aks holda 30 soniyalik chegara guruh chegarasigacha
        //     yaxlitlanib, kichik faylda butun video yuklanib
        //     qolardi (foydalanuvchi trafigi behuda ketardi);
        //   * yuklab olish esa baribir butun faylni oladi, shu
        //     sabab 4 tadan guruh bilan ishlaydi (kamroq so'rov).
        const G_TOTAL: u64 = 10 * CHUNK_SIZE;
        let (o_port, o_log) = start_origin(G_TOTAL);
        let g_url = format!("http://127.0.0.1:{o_port}/pleyer.mp4");

        // (a) PLEYER YO'LI ────────────────────────────────────
        // Davomiylik hali noma'lum (1-bo'lak keshda yo'q), shu
        // sabab zaxira oyna ishlaydi: 0 + PREFETCH_WINDOW.
        //
        // MUHIM: javob endi KESILMAYDI — u butun faylni e'lon
        // qiladi va baytlarni asta-sekin beradi (izohni `serve`
        // ichidan qarang). Shu sabab test oynaga to'g'ri keladigan
        // qismini o'qib, ulanishni tashlab ketadi.
        let read_len = (5 * CHUNK_SIZE) as usize;
        let (status, gcr, glen, gbody) =
            request_url(port, &g_url, Some("bytes=0-"), Some(read_len));
        assert_eq!(status, 206);
        assert_eq!(
            gcr,
            format!("bytes 0-{}/{G_TOTAL}", G_TOTAL - 1),
            "javob KESILDI — ExoPlayer buni 'fayl tugadi' deb tushunadi"
        );
        assert_eq!(glen, read_len, "oynadagi baytlar to'liq berilmadi");
        let cs = CHUNK_SIZE as usize;
        for probe in [0usize, cs - 1, cs, 2 * cs, glen - 1] {
            assert_eq!(gbody[probe], (probe % 251) as u8, "bayt {probe} noto'g'ri");
        }
        let ranges: Vec<String> = o_log
            .lock()
            .unwrap()
            .iter()
            .filter(|r| *r != "bytes=0-0")
            .cloned()
            .collect();
        assert!(!ranges.is_empty(), "manbaga birorta so'rov ketmadi");
        for r in &ranges {
            let (rs, re) = parse_test_range(r, G_TOTAL);
            assert_eq!(
                re - rs + 1,
                CHUNK_SIZE,
                "pleyer 1 MiB'dan ortiq so'radi: {r}"
            );
        }

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
        let group_bytes = GROUP_CHUNKS * CHUNK_SIZE;
        assert!(
            d_ranges.iter().any(|r| {
                let (rs, re) = parse_test_range(r, G_TOTAL);
                re - rs + 1 == group_bytes
            }),
            "yuklovchi guruh bilan so'ramadi: {d_ranges:?}"
        );
        // 10 ta bo'lak bitta guruhga sig'adi, ya'ni bitta so'rov
        // yetadi. Ehtiyot uchun chegara 3 da qoldirilgan.
        assert!(
            d_ranges.len() <= 3,
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

    // ═══════════════════════════════════════════════════════════
    //  IJRO PAYTIDAGI HAQIQIY HOLAT (asosiy regressiya testi)
    // ═══════════════════════════════════════════════════════════
    //
    // Foydalanuvchi ko'rgan xato: video ochilib, 15 soniyalik bufer
    // yig'ilgach video 15 soniya ishlaydi va QAYTADAN BOSHLANADI.
    // Sabab: javob oxirigacha yetkazilmasa (ulanish erta yopilsa),
    // ExoPlayer buni "fayl tugadi" deb tushunadi va setLooping(true)
    // sabab video boshidan boshlanadi.
    //
    // Bu test AYNAN shu holatni taqlid qiladi: manba ishlaydi, ijro
    // nuqtasi esa HAQIQIY VAQTDA oldinga suriladi (Dart tomoni
    // qiladigan ish). Server javobni OXIRIGACHA yetkazishi SHART.
    #[test]
    fn ijro_surilganda_javob_oxirigacha_yetkaziladi() {
        let (port, root) = ensure_server();

        const NAME: &str = "oqim.mp4";
        const TOTAL: u64 = 12 * CHUNK_SIZE; // 12 MiB
        const DUR_S: u64 = 120; // 120 s -> ~100 KiB/s -> 15 s ~ 1.5 MiB

        let (o_port, _log) = start_origin(TOTAL);
        let url = format!("http://127.0.0.1:{o_port}/{NAME}");

        let dir = root.join("video_byte_cache").join(NAME);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("meta.json"),
            format!(
                "{{\"total_size\":{TOTAL},\"content_type\":\"video/mp4\",\
                 \"chunk_size\":{CHUNK_SIZE},\"duration_secs\":{DUR_S}.0}}"
            ),
        )
        .unwrap();

        // Ijro nuqtasi: 10x tezlikda oldinga suriladi (test tez
        // tugashi uchun). Bu Dart tomonining `videoSetPosition`
        // chaqiruvlariga aynan mos keladi.
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = Arc::clone(&stop);
        let u2 = url.clone();
        let c_url0 = std::ffi::CString::new(url.clone()).unwrap();
        rust_video_cache_set_position(c_url0.as_ptr(), 0);
        let pos_thread = thread::spawn(move || {
            let c = std::ffi::CString::new(u2).unwrap();
            let mut ms: u64 = 0;
            while !s2.load(Ordering::Relaxed) && ms <= DUR_S * 1000 {
                rust_video_cache_set_position(c.as_ptr(), ms);
                thread::sleep(Duration::from_millis(50));
                ms += 500;
            }
        });

        let (status, cr, len, body) = request_url(port, &url, Some("bytes=0-"), None);
        stop.store(true, Ordering::Relaxed);
        let _ = pos_thread.join();

        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes 0-{}/{TOTAL}", TOTAL - 1),
            "javob sarlavhasi kesildi"
        );
        assert_eq!(
            len as u64, TOTAL,
            "javob OXIRIGACHA yetkazilmadi ({len}/{TOTAL}) — ExoPlayer buni \
             'fayl tugadi' deb tushunadi va video boshidan boshlanadi"
        );
        for probe in [0usize, 1, (CHUNK_SIZE as usize) - 1, CHUNK_SIZE as usize, len - 1] {
            assert_eq!(body[probe], (probe % 251) as u8, "bayt {probe} noto'g'ri");
        }
    }


    /// Manba: berilgan bo'lak uchun dastlabki `fail_times` so'rovni
    /// ATAYLAB yiqitadi (ulanishni javobsiz uzadi), keyin odatdagidek
    /// ishlaydi. Mobil tarmoqdagi bir lahzalik uzilishning aynan o'zi.
    fn start_flaky_origin(total: u64, fail_from: u64, fail_times: u64) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let failed = Arc::new(AtomicU64::new(0));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                let failed = Arc::clone(&failed);
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
                    if s == fail_from && failed.load(Ordering::SeqCst) < fail_times {
                        failed.fetch_add(1, Ordering::SeqCst);
                        // Javobsiz uzamiz — ureq buni tarmoq xatosi deb biladi.
                        return;
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
        port
    }

    /// ═══════════════════════════════════════════════════════════
    ///  BIR MARTALIK TARMOQ XATOSI JAVOBNI UZMASLIGI KERAK
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Foydalanuvchi ko'rgan xato: video 15 soniyadan keyin BOSHIDAN
    /// boshlanardi. Sabab: bitta bo'lak olinmasa, mahalliy server
    /// javobni shu yerda TO'XTATARDI; ExoPlayer uchun esa javobning
    /// erta tugashi "fayl tugadi" degani va u videoni takrorlash
    /// (looping) bilan noldan boshlab yuborardi.
    ///
    /// Endi bo'lak qayta so'raladi va javob OXIRIGACHA yetkaziladi.
    #[test]
    fn bir_martalik_tarmoq_xatosi_javobni_uzmaydi() {
        let (port, root) = ensure_server();

        const NAME: &str = "uzilish.mp4";
        const TOTAL: u64 = 5 * CHUNK_SIZE;
        const DUR_S: u64 = 5; // 1 MiB/s -> 15 s butun faylni qamraydi
        // 3-bo'lak (2 MiB dan boshlanadi) uchun dastlabki 2 so'rov
        // ataylab yiqiladi.
        let o_port = start_flaky_origin(TOTAL, 2 * CHUNK_SIZE, 2);
        let url = format!("http://127.0.0.1:{o_port}/{NAME}");

        let dir = root.join("video_byte_cache").join(NAME);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("meta.json"),
            format!(
                "{{\"total_size\":{TOTAL},\"content_type\":\"video/mp4\",\
                 \"chunk_size\":{CHUNK_SIZE},\"duration_secs\":{DUR_S}.0}}"
            ),
        )
        .unwrap();

        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        rust_video_cache_set_position(c_url.as_ptr(), 0);

        let (status, cr, len, body) = request_url(port, &url, Some("bytes=0-"), None);
        assert_eq!(status, 206);
        assert_eq!(cr, format!("bytes 0-{}/{TOTAL}", TOTAL - 1));
        assert_eq!(
            len as u64, TOTAL,
            "bir martalik tarmoq xatosi javobni uzib qo'ydi ({len}/{TOTAL}) — \
             ExoPlayer buni 'fayl tugadi' deb tushunadi va video boshidan boshlanadi"
        );
        // Ma'lumot to'g'ri joydan kelgani (xatodan keyin ham).
        for probe in [0usize, (2 * CHUNK_SIZE) as usize, len - 1] {
            assert_eq!(body[probe], (probe % 251) as u8, "bayt {probe} noto'g'ri");
        }
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

        // 24 MiB / 8 MiB = 3 ta so'rov yetadi. Hajmni aniqlash
        // uchun bitta "bytes=0-0" va ehtiyot uchun bir nechta
        // qo'shimchaga joy qoldiramiz.
        assert!(
            images <= 8,
            "keragidan ko'p so'rov yuborildi: {images} ta (kutilgan ~4)"
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

    /// SEKIN manba: baytlarni sekundiga `kbps` KB tezlikda beradi.
    /// Sekin mobil tarmoqning aynan o'zi.
    fn start_slow_origin(total: u64, kbps: u64) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut st) = stream else { continue };
                thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = st.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HEAD") {
                        let _ = st.write_all(
                            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
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
                    if st.write_all(head.as_bytes()).is_err() {
                        return;
                    }
                    // 50 ms lik bo'laklar bilan sekin uzatamiz.
                    let step = ((kbps * 1024) / 20).max(1024) as usize;
                    let mut off = s;
                    while off <= e {
                        let upto = (off + step as u64 - 1).min(e);
                        let piece: Vec<u8> = (off..=upto).map(|i| (i % 251) as u8).collect();
                        if st.write_all(&piece).is_err() {
                            return;
                        }
                        off = upto + 1;
                        thread::sleep(Duration::from_millis(50));
                    }
                });
            }
        });
        port
    }

    /// ═══════════════════════════════════════════════════════════
    ///  UZOQ PAUZADA SERVER ULANISHNI YOPMASLIGI KERAK
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Foydalanuvchi o'lchagan xato: "videoni pauza qildim, 31 MB
    /// yuklandi va video o'sha joydan qayta boshlandi".
    ///
    /// Sabab: soketda 60 soniyalik YOZISH CHEGARASI bor edi. Pleyer
    /// pauzada o'qishni to'xtatgach (normal xulq) server 60 soniya
    /// kutar, keyin xato olib ulanishni YOPARDI. ExoPlayer uchun
    /// bu "fayl tugadi" degani — ilova videoni qayta ochar, pleyer
    /// yana 50 soniyalik buferni to'ldirar, trafik esa har safar
    /// qaytadan sarflanardi.
    ///
    /// Bu test 75 soniya (eski chegaradan uzoq) UMUMAN o'qimaydi va
    /// shundan keyin ham ulanish TIRIK ekanini tekshiradi.
    #[test]
    fn uzoq_pauzada_ulanish_yopilmaydi() {
        let (port, _root) = ensure_server();

        const NAME: &str = "pauza.mp4";
        const TOTAL: u64 = 40 * CHUNK_SIZE;
        let (o_port, _log) = start_origin(TOTAL);
        let url = format!("http://127.0.0.1:{o_port}/{NAME}");
        let encoded: String = url
            .chars()
            .map(|c| match c {
                ':' => "%3A".to_string(),
                '/' => "%2F".to_string(),
                c => c.to_string(),
            })
            .collect();

        let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
        st.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        st.write_all(
            format!("GET /v?u={encoded} HTTP/1.1\r\nHost: x\r\nRange: bytes=0-\r\n\r\n").as_bytes(),
        )
        .unwrap();
        let mut br = BufReader::new(st);
        let mut line = String::new();
        br.read_line(&mut line).unwrap();
        loop {
            let mut l = String::new();
            if br.read_line(&mut l).unwrap_or(0) == 0 || l == "\r\n" {
                break;
            }
        }
        // Bir oz o'qiymiz (pleyer ochilgan holat).
        let mut buf = vec![0u8; 256 * 1024];
        let mut got = 0usize;
        while got < buf.len() {
            match br.read(&mut buf[got..]) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(_) => break,
            }
        }
        assert!(got > 0, "birinchi baytlar kelmadi");

        // ── PAUZA: 75 soniya UMUMAN o'qimaymiz ────────────────
        thread::sleep(Duration::from_secs(75));

        // Ulanish TIRIK bo'lishi kerak: yana o'qiy olamiz.
        br.get_ref()
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut probe = [0u8; 64 * 1024];
        let n = br.read(&mut probe).unwrap_or(0);
        assert!(
            n > 0,
            "SERVER PAUZADAN KEYIN ULANISHNI YOPDI — ExoPlayer buni \
             'fayl tugadi' deb tushunadi va video qayta ochiladi"
        );
    }

    /// ═══════════════════════════════════════════════════════════
    ///  PLEYER O'QISHNI TO'XTATSA — TRAFIK HAM TO'XTAYDI
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Server endi hech narsani ushlab turmaydi. Savol: unda butun
    /// fayl yuklanib ketmaydimi?
    ///
    /// YO'Q. ExoPlayer buferi to'lgach (DefaultLoadControl,
    /// DEFAULT_MAX_BUFFER_MS = 50_000) `loadCondition.block()` da
    /// to'xtaydi va soketdan O'QISHNI to'xtatadi. Shunda TCP
    /// bizning `write_all`imizni bloklaydi — ya'ni tarmoqdan ham
    /// hech narsa olinmaydi.
    ///
    /// Bu test aynan shuni tekshiradi: mijoz bir oz o'qib, keyin
    /// o'qishni TO'XTATADI (lekin ulanishni yopmaydi). Manbadan
    /// olingan hajm kichik bo'lib qolishi SHART.
    #[test]
    fn pleyer_toxtasa_trafik_ham_toxtaydi() {
        let (port, _root) = ensure_server();

        const NAME: &str = "toxtash.mp4";
        const TOTAL: u64 = 40 * CHUNK_SIZE;
        let (o_port, o_log) = start_origin(TOTAL);
        let url = format!("http://127.0.0.1:{o_port}/{NAME}");

        let encoded: String = url
            .chars()
            .map(|c| match c {
                ':' => "%3A".to_string(),
                '/' => "%2F".to_string(),
                c => c.to_string(),
            })
            .collect();
        let mut st = TcpStream::connect(("127.0.0.1", port)).unwrap();
        st.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        st.write_all(
            format!("GET /v?u={encoded} HTTP/1.1\r\nHost: x\r\nRange: bytes=0-\r\n\r\n").as_bytes(),
        )
        .unwrap();
        let mut br = BufReader::new(st);
        let mut line = String::new();
        br.read_line(&mut line).unwrap();
        loop {
            let mut l = String::new();
            if br.read_line(&mut l).unwrap_or(0) == 0 || l == "\r\n" {
                break;
            }
        }
        // 2 MiB o'qiymiz, keyin O'QISHNI TO'XTATAMIZ (ulanish ochiq).
        let mut buf = vec![0u8; 2 * CHUNK_SIZE as usize];
        let mut got = 0usize;
        while got < buf.len() {
            match br.read(&mut buf[got..]) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(_) => break,
            }
        }
        assert_eq!(got, buf.len(), "birinchi 2 MiB berilmadi");

        // Pleyer buferi to'lgan holat: 5 soniya umuman o'qimaymiz.
        thread::sleep(Duration::from_secs(5));

        let asked: u64 = o_log
            .lock()
            .unwrap()
            .iter()
            .filter(|r| *r != "bytes=0-0")
            .map(|r| {
                let (s, e) = parse_test_range(r, TOTAL);
                e - s + 1
            })
            .sum();
        drop(br);
        assert!(
            asked < 12 * CHUNK_SIZE,
            "pleyer o'qimay turganda ham {:.1} MiB yuklandi — TCP tormozi ishlamadi",
            asked as f64 / 1048576.0
        );
    }

    /// ═══════════════════════════════════════════════════════════
    ///  SEKIN TARMOQDA HAM OQIM JIM QOLMAYDI
    /// ═══════════════════════════════════════════════════════════
    ///
    /// Foydalanuvchi ko'rgan xato: telefonda video to'xtab qolar
    /// yoki boshidan boshlanardi, tez internetda esa hammasi
    /// joyida edi.
    ///
    /// SABAB (o'lchov bilan aniqlangan): server BUTUN 1 MiB
    /// bo'lak yuklanib bo'lgunicha pleyerga bitta ham bayt
    /// bermasdi. Sekin tarmoqda bu 5-10 soniyalik JIMLIK degani,
    /// ExoPlayer'ning HTTP o'qish chegarasi esa 8 soniya.
    ///
    /// Endi baytlar kelishi bilan darhol uzatiladi.
    #[test]
    fn sekin_tarmoqda_oqim_jim_qolmaydi() {
        let (port, root) = ensure_server();

        const NAME: &str = "sekin.mp4";
        const TOTAL: u64 = 8 * CHUNK_SIZE;
        const DUR_S: u64 = 40; // ~200 KiB/s
        let o_port = start_slow_origin(TOTAL, 120); // 120 KB/s
        let url = format!("http://127.0.0.1:{o_port}/{NAME}");

        let dir = root.join("video_byte_cache").join(NAME);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("meta.json"),
            format!(
                "{{\"total_size\":{TOTAL},\"content_type\":\"video/mp4\",\
                 \"chunk_size\":{CHUNK_SIZE},\"duration_secs\":{DUR_S}.0}}"
            ),
        )
        .unwrap();

        let c_url = std::ffi::CString::new(url.clone()).unwrap();
        rust_video_cache_set_position(c_url.as_ptr(), 0);

        let stop = Arc::new(AtomicBool::new(false));
        let s2 = Arc::clone(&stop);
        let u2 = url.clone();
        let pos_thread = thread::spawn(move || {
            let c = std::ffi::CString::new(u2).unwrap();
            let mut ms: u64 = 0;
            while !s2.load(Ordering::Relaxed) {
                rust_video_cache_set_position(c.as_ptr(), ms);
                thread::sleep(Duration::from_millis(250));
                ms += 250;
            }
        });

        let (got, closed, max_silence) =
            read_measured(port, &url, "bytes=0-", Duration::from_secs(25));
        stop.store(true, Ordering::Relaxed);
        let _ = pos_thread.join();

        assert!(!closed, "server ulanishni yopdi ({got} bayt)");
        assert!(got > 0, "bitta ham bayt kelmadi");
        assert!(
            max_silence < Duration::from_secs(5),
            "oqim {} ms jim qoldi — ExoPlayer chegarasi 8000 ms, ya'ni pleyer \
             ulanishni uzib videoni to'xtatardi",
            max_silence.as_millis()
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  HAQIQIY WORKER BILAN SINOV (tarmoqqa chiqadi)
    // ═══════════════════════════════════════════════════════════
    //
    // Odatiy `cargo test` da ISHLAMAYDI (#[ignore]). Qo'lda:
    //   cargo test --lib haqiqiy_ -- --ignored --nocapture --test-threads=1
    fn real_base() -> String {
        std::env::var("REAL_BASE").unwrap_or_else(|_| {
            "https://aniraxuzapp.ogabekraximov650.workers.dev/api/image".to_string()
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

        // ── 4) Tozalab, PLEYERNI ochish ham ishlashi kerak ──────
        assert_eq!(rust_video_cache_delete(c_url.as_ptr()), 1);
        thread::sleep(Duration::from_millis(300));
        rust_video_cache_set_position(c_url.as_ptr(), 0);
        let (status, cr, len, _) =
            request_url(port, &url, Some("bytes=0-1048575"), None);
        assert_eq!(status, 206, "tozalashdan keyin pleyer javob olmadi");
        assert_eq!(cr, format!("bytes 0-1048575/{TOTAL}"), "hajm noto'g'ri aniqlandi");
        assert_eq!(len, CHUNK_SIZE as usize, "tozalashdan keyin video berilmadi");
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
}
