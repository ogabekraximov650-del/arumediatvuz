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

/// ── OLDINDAN YUKLASH OYNASI: HAR DOIM 10 MB TAYYOR ──────────────
///
/// Qoida oddiy: ijro nuqtasidan keyin HAMISHA 10 ta bo'lak (10 MB)
/// keshda tayyor turadi, undan ortig'i EMAS.
///
///   * pleyer 1-bo'lakni ko'rsatayotgan bo'lsa — 11-bo'lakkacha
///     yuklanadi;
///   * pleyer 2-bo'lakka o'tsa — 12-bo'lak yuklanadi (oyna bir
///     qadam suriladi);
///   * foydalanuvchi 21-bo'lakka sek qilsa — oyna YANGI nuqtadan
///     qayta hisoblanadi va 31-bo'lakkacha yuklanadi, eskisi
///     (endi keraksiz) darhol to'xtatiladi.
///
/// NEGA AYNAN SHUNDAY: bu foydalanuvchi trafigini tejaydi. Video bir
/// necha soniya ko'rilib tashlansa ham, faqat shu ~10 MB sarflanadi —
/// butun fayl bekorga yuklab olinmaydi.
/// ZAXIRA qiymat: davomiylik hali aniqlanmagan paytda ishlatiladi
/// (masalan video endigina ochildi va 1-bo'lak hali keshda yo'q).
/// Odatiy holatda oyna videoning BITREYTIDAN hisoblanadi —
/// `prefetch_window_for` ga qarang.
const PREFETCH_WINDOW: u64 = 10;

/// Oynaning eng katta ruxsat etilgan kengligi (bo'lak = MiB).
/// Bitreytdan hisoblangan oyna "bir daqiqalik video" degani, ya'ni u
/// tabiiy ravishda kichik. Bu chegara faqat buzuq metadata (masalan
/// davomiyligi 1 soniya deb yozilgan katta fayl) xotira va trafikni
/// yeb yubormasligi uchun.
const MAX_PREFETCH_WINDOW: u64 = 64;

/// Oldindan yuklashda bir vaqtda ishlaydigan ish oqimlari soni.
///
/// SABAB: bitta bo'lak = bitta HTTP so'rov. Ular KETMA-KET olinganda
/// haqiqiy tezlik "bo'lak hajmi ÷ so'rov kechikishi" bilan cheklanadi:
/// 1 MiB va 200 ms kechikishda bu atigi ~5 MB/s, mobil tarmoqda esa
/// ancha kam. Natijada bufer to'lolmay, video to'xtab-to'xtab ketardi.
/// 3 ta oqim bilan bir vaqtda 3 ta bo'lak olinadi va tezlik shunga
/// mos ravishda oshadi. Oyna 10 MB bo'lgani uchun bundan ortig'i
/// keraksiz — u faqat trafikni oldinga surib yuborardi.
const PREFETCH_THREADS: usize = 3;

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
    // MUHIM (crash sababi): agar klient (mdk-sdk) sek qilib javobni
    // o'qishni to'xtatsa, TCP oqimi to'lib, write_all() ABADIY bloklanib
    // qolardi — ish oqimi hech qachon tugamay, o'zining 1 MiB buferi
    // bilan xotirada qolib ketardi. Tez-tez sek qilinganda bunday
    // "o'lik" ish oqimlari to'planib, ilova o'chib qolardi. Yozish
    // timeout'i bunday oqimni majburan xatoga uchratib, tozalanishini
    // kafolatlaydi.
    // YOZISH TIMEOUT'I: 60s.
    //
    // Muhim tushuncha: pleyer sek qilib ulanishni tashlab ketganda u
    // soketni YOPADI — bunda `write_all` timeout'ni KUTMASDAN, darhol
    // xato qaytaradi (ECONNRESET/EPIPE) va ish oqimi shu zahoti
    // tugaydi. Ya'ni "o'lik" ulanishlarni tozalash uchun qisqa timeout
    // KERAK EMAS.
    //
    // Timeout faqat bitta holatda ishlaydi: pleyer soketni ochiq
    // qoldirib, ma'lumot o'qishni to'xtatganda — ya'ni foydalanuvchi
    // videoni PAUZA qilganda. 2 soniya bunga juda kam edi: 2 soniyadan
    // uzoq pauza qilinsa, biz oqimni uzib qo'yardik va davom
    // ettirilganda video buzilardi. Endi javoblar UZLUKSIZ (bo'shliqda
    // qisqartirilmaydi), ya'ni pleyer buferi to'lganda o'qishni bir
    // muddat to'xtatib turishi butunlay normal — shu sabab 60 soniya.
    stream.set_write_timeout(Some(Duration::from_secs(60)))?;
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
            total: keep_total,
            have: HashSet::new(),
            have_bytes: 0,
            scanned: keep_total > 0,
            checked_at: Some(Instant::now()),
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
const DOWNLOAD_THREADS: usize = 12;

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
}

static DOWNLOADS: OnceLock<Mutex<HashMap<String, DownloadState>>> = OnceLock::new();
static DL_POOL: AtomicBool = AtomicBool::new(false);

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
    let flight_key = format!("{key}#{index}");
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
fn pick_task() -> Option<(String, String)> {
    let now = Instant::now();
    let mut map = downloads().lock().ok()?;
    let key = map
        .iter()
        .find(|(_, s)| s.wanted && !s.running && s.next_try <= now)
        .map(|(k, _)| k.clone())?;
    let st = map.get_mut(&key)?;
    st.running = true;
    Some((key, st.url.clone()))
}

fn pool_worker() {
    loop {
        let Some((key, url)) = pick_task() else {
            // Ish yo'q — havza tinch turadi (protsessor sarflanmaydi).
            thread::sleep(Duration::from_millis(400));
            continue;
        };

        let outcome = run_download(&key, &url);

        let mut map = match downloads().lock() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let still_wanted = map.get(&key).map(|s| s.wanted).unwrap_or(false);
        match outcome {
            // To'liq yuklandi — vazifa navbatdan chiqadi.
            Ok(true) => {
                map.remove(&key);
                log(format!("Yuklab olish TUGADI: {key}"));
            }
            // Foydalanuvchi pauza qildi.
            Ok(false) => {
                map.remove(&key);
            }
            // Xato — TO'XTATILMAYDI: kechikib qayta uriniladi va
            // aynan to'xtagan bo'lagidan davom etadi.
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

/// Bitta videoni yuklaydi. Qaytaradi:
///   Ok(true)  — to'liq yuklandi;
///   Ok(false) — foydalanuvchi to'xtatdi;
///   Err(..)   — xato (keyinroq qayta uriniladi).
///
/// Bo'laklar DOWNLOAD_THREADS ta oqimda PARALLEL olinadi: navbat —
/// oddiy atomik hisoblagich, har bir oqim keyingi raqamni olib o'sha
/// bo'lakni yuklaydi. Shu bilan tarmoq kechikishi "yashiriladi" va
/// tezlik ijro uchun ishlatiladigan oldindan yuklashdan ham yuqori
/// bo'ladi. Xotira global MAX_NET_FETCHES chegarasi bilan himoyalangan.
fn run_download(key: &str, url: &str) -> Result<bool, String> {
    let Some(shared) = SHARED.get() else {
        return Err("kesh-server ishga tushmagan".to_string());
    };
    let dir = shared.cache_root.join(key);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

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
    // Birinchi xato — u butun vazifani to'xtatadi va yuqoriga
    // qaytariladi, ya'ni qayta urinish mantig'i avvalgidek ishlaydi.
    let first_err: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    let mut workers = Vec::with_capacity(DOWNLOAD_THREADS);
    for _ in 0..DOWNLOAD_THREADS {
        let cursor = Arc::clone(&cursor);
        let deferred = Arc::clone(&deferred);
        let paused = Arc::clone(&paused);
        let first_err = Arc::clone(&first_err);
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
                // Sherik oqimlardan biri xatoga uchragan bo'lsa —
                // qolganlari ham to'xtaydi (qayta urinish yuqorida).
                if first_err.lock().map(|e| e.is_some()).unwrap_or(true) {
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
                // keyingi bo'lakka o'tamiz. Aks holda video ochiq
                // turganda yuklab olishning hamma oqimlari birinchi
                // bo'laklarda 6 soniyagacha kutib qolardi va yuklash
                // sudralib ketardi (`chunk_in_flight` izohiga qarang).
                if !second_pass && chunk_in_flight(shared, &k, i) {
                    if let Ok(mut d) = deferred.lock() {
                        d.push(i);
                    }
                    continue;
                }

                let fetched = fetch_and_store_chunk(
                    shared,
                    &k,
                    &d,
                    &u,
                    i,
                    chunk_start,
                    chunk_end,
                    expected_len,
                    total,
                    // `true` — navbatda kutmaydi (yuqoridagi
                    // DOWNLOAD_THREADS izohiga qarang).
                    true,
                );
                let problem = match fetched {
                    Err(e) => Some(e),
                    // Bo'lak QAYTDI, lekin diskda to'liq turibdimi?
                    // Yarim olingan bo'lsa qoldiq saqlangan bo'ladi va
                    // keyingi urinish o'sha joydan davom etadi — shu
                    // sabab buni xato deb belgilaymiz.
                    Ok(_) => {
                        let landed = fs::metadata(&path)
                            .map(|m| m.len() == on_disk_len)
                            .unwrap_or(false);
                        if landed {
                            None
                        } else {
                            Some(format!("bo'lak #{i} to'liq olinmadi"))
                        }
                    }
                };
                if let Some(e) = problem {
                    if let Ok(mut slot) = first_err.lock() {
                        if slot.is_none() {
                            *slot = Some(e);
                        }
                    }
                    break;
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

    if let Some(e) = first_err.lock().ok().and_then(|mut s| s.take()) {
        return Err(e);
    }
    if paused.load(Ordering::SeqCst) || !download_active(key) {
        return Ok(false);
    }
    Ok(true)
}

/// Yuklab olishni boshlaydi yoki davom ettiradi. DARHOL qaytadi.
/// Bir necha marta bosilsa ham yangi ish oqimi ochilmaydi.
fn start_download(url: &str) -> bool {
    if SHARED.get().is_none() {
        return false;
    }
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
    // Hajm saqlanadi (u manbadan olingan, o'chirilishi shart emas) —
    // shu bilan ro'yxatda "0% / 0 / 240MB" ko'rinadi.
    let total = {
        let map = stats().lock().unwrap();
        map.get(&key).map(|e| e.total).unwrap_or(0)
    };
    stat_reset(&key, total);

    let dir = shared.cache_root.join(&key);
    let key2 = key.clone();
    let spawned = thread::Builder::new()
        .name("video-cache-delete".into())
        .spawn(move || {
            // Yuklab olish ish oqimlari to'xtashini kutamiz (eng ko'pi
            // 5 soniya) — aks holda ular o'chirilgandan keyin yana yozib
            // qo'yishi mumkin.
            for _ in 0..200 {
                let busy = downloads()
                    .lock()
                    .map(|m| m.get(&key2).map(|s| s.running).unwrap_or(false))
                    .unwrap_or(false);
                if !busy {
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
            // Vazifa qolgan bo'lsa — butunlay olib tashlanadi.
            if let Ok(mut m) = downloads().lock() {
                m.remove(&key2);
            }
            // Bo'lak fayllari va meta.json o'chiriladi, papkaning o'zi
            // qoladi (keyingi ochilishda qaytadan ishlatiladi).
            if let Ok(entries) = fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let _ = fs::remove_file(entry.path());
                }
            }
            stats().lock().unwrap().remove(&key2);
            log(format!("Kesh tozalandi: {key2}"));
        });
    spawned.is_ok()
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
        shared, key, dir, url, index, start, end, expected_len, expected_total, true,
    )
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

/// `no_queue` — bu so'rov navbatda KUTMAYDI, darhol tarmoqqa chiqadi.
///
/// Ikki holatda `true` bo'ladi:
///   * PLEYER bo'lakni hozir kutyapti — kutish videoni to'xtatadi;
///   * FOYDALANUVCHI yuklab olish tugmasini bosgan — talab bo'yicha
///     u hech qanday cheklovga uchramasligi kerak.
///
/// `false` faqat OLDINDAN yuklash (prefetch) uchun qoladi: u fon
/// ishi bo'lgani uchun MAX_NET_FETCHES navbatida kutishi mumkin.
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
    no_queue: bool,
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
        if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
            return Ok(bytes);
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
        if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
            return Ok(bytes);
        }

        // ── Parallel yuklashlar chegarasi (MAX_NET_FETCHES izohiga
        // qarang). Navbat 8 soniyadan ortiq kutilmaydi — undan keyin
        // baribir yuklab olinadi, chunki javobsiz qolish eng yomon
        // holat.
        let queue_deadline = Instant::now() + Duration::from_secs(8);
        if no_queue {
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
                // Kutish paytida bo'lak boshqa oqim tomonidan yuklanib
                // qolgan bo'lishi mumkin.
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

        // ── QOLDIQDAN DAVOM ETISH ────────────────────────────────
        // Oldingi urinishda bu bo'lakning bir qismi olinib, tarmoq
        // uzilgan bo'lishi mumkin. O'sha qism diskda saqlangan: uni
        // o'qib olamiz va tarmoqdan FAQAT yetishmayotgan dumini
        // so'raymiz. Shu bilan har bir urinish oldingisining ustiga
        // qo'shiladi va bo'lak oxir-oqibat albatta tugaydi.
        let prefix = read_part(dir, key, index, expected_len).unwrap_or_default();
        let resume_from = start + prefix.len() as u64;
        if !prefix.is_empty() {
            log(format!(
                "Bo'lak #{index}: qoldiqdan davom — {} bayt tayyor, {resume_from}-{end} so'raladi",
                prefix.len()
            ));
        }
        log(format!(
            "Bo'lak #{index} worker'dan yuklanmoqda ({resume_from}-{end})..."
        ));
        let range = format!("bytes={resume_from}-{end}");
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
        // Manba Range'ni e'tiborsiz qoldirsa, javob 0-baytdan
        // boshlanadi — bunday holda bizda ALLAQACHON bor bo'lgan
        // qoldiq ham tashlab yuboriladi (`resume_from`, `start` emas).
        let ignores_range = status == 200;
        let skip_bytes = if ignores_range { resume_from as usize } else { 0 };

        let mut reader = resp.into_reader();
        let mut collected: Vec<u8> = Vec::with_capacity(expected_len);
        // Diskdagi qoldiq — yangi baytlar aynan uning ustiga qo'shiladi.
        collected.extend_from_slice(&prefix);
        let mut skipped = 0usize;
        let mut buf = [0u8; 64 * 1024];
        // O'qish o'rtada uzilsa DARHOL chiqmaymiz: avval shu paytgacha
        // yig'ilgan qismni diskka saqlab qo'yamiz (pastda), xatoni esa
        // shundan keyin qaytaramiz.
        let mut read_err: Option<String> = None;
        loop {
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
        // DIQQAT: bu son faqat HOZIR tarmoqdan olingan baytlar —
        // diskdagi qoldiq ikkinchi marta sanalmaydi.
        let got = (collected.len() - prefix.len()) as u64;
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
            // Diskka YOZISHDAN OLDIN shifrlanadi (bo'lak o'ziga xos
            // kalit bilan — crypto.rs'ga qarang). Pleyerga (chaqiruvchi
            // funksiyaga) esa OCHIQ bayt qaytariladi (pastdagi
            // `Ok(collected)`) — u hech qachon shifrlangan holatni
            // ko'rmaydi.
            let on_disk: Vec<u8> = match crypto::derive_chunk_key_iv(key, index) {
                Some((k, iv)) => crypto::encrypt_chunk(&collected, &k, &iv),
                None => collected.clone(),
            };
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
            fs::write(&tmp_path, &on_disk).map_err(|e| e.to_string())?;
            if fs::rename(&tmp_path, &final_path).is_err() {
                let _ = fs::remove_file(&tmp_path);
            } else {
                // YAKUNIY, TO'LIQ bo'lak joyiga tushdi — endi eski
                // qoldiq keraksiz va O'CHIRILADI. Ya'ni qoldiq har doim
                // yangi to'liq bo'lak bilan ALMASHTIRILADI.
                remove_part(dir, index);
                // Progress ko'rsatkichi REAL VAQTDA shu yerdan
                // yangilanadi — video ko'rilayotganda ham, alohida
                // yuklab olinayotganda ham.
                stat_note_chunk(key, index, expected_len as u64);
            }
        } else if collected.len() > prefix.len() {
            // TO'LIQ EMAS — lekin oldingi urinishdan ko'proq olindi.
            // Yig'ilgan qism saqlanadi: keyingi urinish AYNAN shu
            // joydan davom etadi, noldan emas.
            write_part(dir, key, index, &collected);
            log(format!(
                "Bo'lak #{index} to'liq emas ({}/{expected_len}) — qoldiq saqlandi",
                collected.len()
            ));
        }
        if let Some(e) = read_err {
            if collected.len() != expected_len {
                return Err(e);
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

/// Pleyer hozir ko'rsatayotgan BO'LAK indeksi (aniq bo'lsa).
///
/// Vaqtdan baytga o'tish videoning o'rtacha bitreyti bo'yicha
/// hisoblanadi: bu H.265 uchun yetarli aniq va hech qanday
/// qo'shimcha metadata talab qilmaydi.
fn playing_chunk(key: &str, total: u64, secs: f64) -> Option<u64> {
    if secs <= 0.0 || total == 0 {
        return None;
    }
    if PLAY_POS_KEY.load(Ordering::Relaxed) != key_tag(key) {
        return None;
    }
    let pos_s = PLAY_POS_MS.load(Ordering::Relaxed) as f64 / 1000.0;
    if pos_s < 0.0 {
        return None;
    }
    let byte = (total as f64 * (pos_s / secs)).clamp(0.0, (total - 1) as f64);
    Some(byte as u64 / CHUNK_SIZE)
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
    1
}

/// Xotiradagi hisob: kalit -> (davomiylik soniya, oxirgi urinish).
/// Davomiylik 0.0 = hali aniqlanmadi.
static DURATIONS: OnceLock<Mutex<HashMap<String, (f64, Instant)>>> = OnceLock::new();

fn durations() -> &'static Mutex<HashMap<String, (f64, Instant)>> {
    DURATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn be_u32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

fn be_u64(b: &[u8]) -> u64 {
    u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}

/// `moov` atomining ichidan `mvhd` ni topib, davomiylikni qaytaradi.
fn mvhd_duration_secs(moov: &[u8]) -> Option<f64> {
    let mut pos = 0usize;
    while pos + 8 <= moov.len() {
        let size = be_u32(&moov[pos..pos + 4]) as usize;
        let typ = &moov[pos + 4..pos + 8];
        if typ == b"mvhd" {
            let b = &moov[pos + 8..];
            if b.is_empty() {
                return None;
            }
            // mvhd tuzilishi (ISO/IEC 14496-12):
            //   v0: version(1) flags(3) created(4) modified(4)
            //       timescale(4) duration(4)
            //   v1: version(1) flags(3) created(8) modified(8)
            //       timescale(4) duration(8)
            let (timescale, duration) = if b[0] == 0 {
                if b.len() < 20 {
                    return None;
                }
                (be_u32(&b[12..16]) as u64, be_u32(&b[16..20]) as u64)
            } else {
                if b.len() < 32 {
                    return None;
                }
                (be_u32(&b[20..24]) as u64, be_u64(&b[24..32]))
            };
            if timescale == 0 || duration == 0 {
                return None;
            }
            return Some(duration as f64 / timescale as f64);
        }
        // Hajm 0 yoki juda kichik bo'lsa — buzuq, to'xtaymiz.
        if size < 8 {
            return None;
        }
        pos = pos.saturating_add(size);
    }
    None
}

/// MP4 faylining boshidan davomiylikni (soniya) o'qiydi.
/// Faqat yuqori darajadagi atomlar bo'ylab yuriladi.
fn mp4_duration_secs(data: &[u8]) -> Option<f64> {
    let mut pos = 0usize;
    while pos + 8 <= data.len() {
        let raw = be_u32(&data[pos..pos + 4]) as u64;
        let typ = [
            data[pos + 4],
            data[pos + 5],
            data[pos + 6],
            data[pos + 7],
        ];
        // Hajm 1 bo'lsa — haqiqiy hajm keyingi 8 baytda (64-bit).
        // Hajm 0 bo'lsa — atom fayl oxirigacha davom etadi.
        let (header, size) = if raw == 1 {
            if pos + 16 > data.len() {
                return None;
            }
            (16usize, be_u64(&data[pos + 8..pos + 16]))
        } else if raw == 0 {
            (8usize, (data.len() - pos) as u64)
        } else {
            (8usize, raw)
        };
        if size < header as u64 {
            return None;
        }
        if &typ == b"moov" {
            // Bizda bor bo'lgan qismgacha qisamiz: moov to'liq
            // yuklanmagan bo'lsa ham `mvhd` odatda uning ENG BOSHIDA
            // turadi, ya'ni baribir topiladi.
            let from = pos + header;
            let to = ((pos as u64 + size) as usize).min(data.len());
            if from >= to {
                return None;
            }
            return mvhd_duration_secs(&data[from..to]);
        }
        pos = pos.saturating_add(size as usize);
    }
    None
}

/// Videoning davomiyligi (soniya). Bir marta hisoblanib, xotirada
/// saqlanadi. TARMOQQA CHIQMAYDI — faqat diskdagi 1-bo'lakni o'qiydi.
/// Bo'lak hali yo'q bo'lsa 0.0 qaytadi (keyingi urinishda aniqlanadi).
fn duration_secs(key: &str, dir: &PathBuf, total: u64) -> f64 {
    if let Ok(m) = durations().lock() {
        if let Some((d, at)) = m.get(key) {
            // Muvaffaqiyatli aniqlangan qiymat — abadiy.
            if *d > 0.0 {
                return *d;
            }
            // ANIQLANMAGANI esa VAQTINCHA eslab qolinadi. Ilgari u
            // ham abadiy saqlanardi: birinchi urinish 1-bo'lak hali
            // diskka tushmasdan oldin bo'lsa, oyna butun sessiya
            // davomida zaxira qiymatda (10) qolib ketardi.
            if at.elapsed() < Duration::from_secs(3) {
                return 0.0;
            }
        }
    }
    let first_len = chunk_plain_len(0, total) as usize;
    let Some(head) = read_cached_chunk(dir, key, 0, first_len) else {
        if let Ok(mut m) = durations().lock() {
            m.insert(key.to_string(), (0.0, Instant::now()));
        }
        return 0.0;
    };
    let secs = mp4_duration_secs(&head).unwrap_or(0.0);
    if let Ok(mut m) = durations().lock() {
        m.insert(key.to_string(), (secs, Instant::now()));
    }
    if secs > 0.0 {
        log(format!(
            "Davomiylik aniqlandi: {key} = {:.0} soniya ({:.1} daqiqa)",
            secs,
            secs / 60.0
        ));
    }
    secs
}

/// Oldindan yuklash oynasi (bo'laklarda) — videoning bitreytiga
/// qarab: bir daqiqalik video necha MiB bo'lsa, shuncha.
///
/// Davomiylik hali aniqlanmagan bo'lsa (1-bo'lak keshda yo'q) —
/// zaxira qiymat PREFETCH_WINDOW ishlatiladi.
fn prefetch_window_for(total: u64, secs: f64) -> u64 {
    if secs <= 0.0 || total == 0 {
        return PREFETCH_WINDOW;
    }
    let mib = total as f64 / (1024.0 * 1024.0);
    let minutes = secs / 60.0;
    if minutes <= 0.0 {
        return PREFETCH_WINDOW;
    }
    let w = (mib / minutes).floor() as u64;
    w.clamp(1, MAX_PREFETCH_WINDOW)
}

/// Oldindan yuklash OYNASINI hisoblaydi: pleyer HOZIR o'qiyotgan
/// bo'lakdan keyin ENG KO'PI `PREFETCH_WINDOW` ta bo'lak olinadi.
/// Qaytaradi: `[from, until)` — ya'ni `until` OYNAGA KIRMAYDI.
///
/// Foydalanuvchi tilida (bo'laklar 1 dan sanalganda):
///   * pleyer 1-bo'lakni ko'rsatyapti -> 11-bo'lakkacha yuklanadi;
///   * pleyer 2-bo'lakka o'tdi        -> 12-bo'lakkacha;
///   * 21-bo'lakka sek qilindi        -> 31-bo'lakkacha.
/// Kodda indeks 0 dan boshlanadi, shu sabab "1-bo'lak" = indeks 0.
///
/// Oyna HAR DOIM pleyer bilan birga suriladi va HECH QACHON undan
/// kengroq bo'lmaydi — ya'ni worker'dan oldindan 10 MB dan ortiq
/// olinmaydi.
fn prefetch_range(current_chunk: u64, chunk_count: u64, window: u64) -> (u64, u64) {
    let from = current_chunk + 1;
    let until = from.saturating_add(window).min(chunk_count);
    (from, until)
}

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
            let secs = duration_secs(&key2, &dir2, total);
            // Oyna videoning bitreytidan hisoblanadi: "bir daqiqalik
            // video necha MiB bo'lsa, shuncha bo'lak oldinda tursin".
            let window = prefetch_window_for(total, secs);
            // ── OYNANING BOSHLANISH NUQTASI ───────────────────────
            // Oyna IJRO nuqtasidan hisoblanadi, bufer uchidan EMAS.
            // Pleyer o'zi ijro nuqtasidan bir necha bo'lak oldinga
            // o'qib qo'yadi; agar biz oynani o'sha buferning UCHIDAN
            // boshlasak, ikkalasi qo'shilib ketadi va oyna ikki
            // barobar kengayadi (PLAY_POS_MS izohiga qarang).
            let origin = playing_chunk(&key2, total, secs).unwrap_or(current_chunk);
            let (from, until) = prefetch_range(origin, chunk_count, window);

            // ── PARALLEL YUKLASH ──────────────────────────────────
            // Oynadagi bo'laklar ketma-ket emas, BIR NECHTA ish oqimi
            // bilan bir vaqtda olinadi. Navbat — oddiy atomik
            // hisoblagich: har bir oqim keyingi raqamni olib, o'sha
            // bo'lakni yuklaydi. Bu tarmoq kechikishini "yashiradi"
            // va bufer ijro nuqtasidan oldinda turishini ta'minlaydi.
            let cursor = Arc::new(AtomicU64::new(from));
            let mut workers = Vec::with_capacity(PREFETCH_THREADS);
            for _ in 0..PREFETCH_THREADS {
                let cursor = Arc::clone(&cursor);
                let (k, d, u) = (key2.clone(), dir2.clone(), url2.clone());
                let h = thread::Builder::new()
                    .name("video-cache-prefetch-w".into())
                    .stack_size(256 * 1024)
                    .spawn(move || loop {
                        let i = cursor.fetch_add(1, Ordering::SeqCst);
                        if i >= until {
                            break;
                        }
                        // Boshqa video ochilgan bo'lsa — darhol to'xtaymiz.
                        if *shared.active_key.lock().unwrap() != k {
                            break;
                        }
                        // ESKIRGAN OYNANI TASHLASH: foydalanuvchi sek
                        // qilib butunlay boshqa joyga o'tgan bo'lishi
                        // mumkin — bunday holda bu oyna endi keraksiz va
                        // uni davom ettirish pleyer HOZIR so'rayotgan
                        // bo'lak bilan tarmoq uchun raqobatlashadi.
                        let live = CURRENT_CHUNK.load(Ordering::Relaxed);
                        if live < origin || live >= origin + window + 1 {
                            break;
                        }
                        let chunk_start = i * CHUNK_SIZE;
                        let chunk_end = (chunk_start + CHUNK_SIZE - 1).min(total - 1);
                        let expected_len = (chunk_end - chunk_start + 1) as usize;

                        // Diskda bor bo'lsa — TARMOQQA UMUMAN CHIQILMAYDI.
                        if let Ok(m) = fs::metadata(d.join(chunk_name(i))) {
                            if m.len() == chunk_on_disk_len(expected_len as u64) {
                                continue;
                            }
                        }
                        let _ = fetch_and_store_chunk(
                            shared, &k, &d, &u, i, chunk_start, chunk_end, expected_len,
                            total, false,
                        );
                    });
                if let Ok(h) = h {
                    workers.push(h);
                }
            }
            for w in workers {
                let _ = w.join();
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

    // ── JAVOB QISQARTIRILMAYDI ────────────────────────────────
    //
    // Avval javob "keshda uzluksiz mavjud" joygacha qisqartirilardi:
    // yetishmayotgan birinchi bo'lakda javob tugar, pleyer esa qolganini
    // olish uchun YANGI ulanish ochishga majbur bo'lardi. Har bir
    // qayta ulanish — bu yangi TCP + HTTP so'rov, ya'ni qo'shimcha
    // kechikish; ijro davomida ular yig'ilib, videoni "to'xtab-to'xtab"
    // ko'rsatardi.
    //
    // Endi server oddiy HTTP serverdek ishlaydi: so'ralgan oraliq
    // BITTA javobda, uzluksiz beriladi. Yetishmayotgan bo'laklar
    // javob yozilayotgan payt, shu yerning o'zida yuklab olinadi
    // (pastdagi tsiklga qarang), oldindan yuklash esa ijro nuqtasidan
    // oldinda ishlab, ularning ko'pini allaqachon tayyorlab qo'yadi.

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

    #[test]
    fn keshdan_bir_javobda_va_sek_bosimiga_bardosh() {
        enable_crypto();
        let root = std::env::temp_dir().join(format!(
            "vc_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fill_cache(&root, None);

        let c_root = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let port = rust_video_cache_start(c_root.as_ptr());
        assert!(port > 0, "server ishga tushmadi");
        let port = port as u16;

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
        // Javob endi bo'shliqda QISQARTIRILMAYDI: server yetishmayotgan
        // bo'lakni javob yozilayotgan payt yuklab olishga urinadi. Bu
        // testda manba mavjud emas (127.0.0.1:9), shu sabab javob aynan
        // o'sha bo'shliqda uziladi — ya'ni undan OLDINGI hamma narsa
        // BITTA javobda kelgani tasdiqlanadi.
        let dir = root.join("video_byte_cache").join(TEST_NAME);
        fs::remove_file(dir.join(chunk_name(3))).unwrap();
        let (status, _cr, len, body) = request(port, Some("bytes=0-"), None);
        assert_eq!(status, 206);
        assert_eq!(
            len as u64,
            3 * CHUNK_SIZE,
            "bo'shliqqacha bo'lgan qism bitta javobda kelmadi"
        );
        for (i, b) in body.iter().enumerate().take(2000) {
            assert_eq!(*b, (i % 251) as u8, "bayt #{i} noto'g'ri joydan");
        }

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

        let _ = fs::remove_dir_all(&root);
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

    /// OLDINDAN YUKLASH OYNASI: oyna kengligi berilganda u aynan
    /// shuncha bo'lakni qamraydi va fayl chegarasidan chiqmaydi.
    /// Bo'laklar kodda 0 dan sanaladi, ya'ni "1-bo'lak" = indeks 0.
    #[test]
    fn oldindan_yuklash_oynasi() {
        // Butun fayl juda uzun (1000 bo'lak) — chegara faqat oyna.
        let n = 1000;
        let w = 10;

        // 1-bo'lak ko'rsatilyapti (indeks 0) -> 2..11-bo'laklar
        // (indeks 1..=10) olinadi, ya'ni 11-bo'lakkacha.
        assert_eq!(prefetch_range(0, n, w), (1, 11));
        // 2-bo'lakka o'tdi -> 12-bo'lakkacha (indeks 11).
        assert_eq!(prefetch_range(1, n, w), (2, 12));
        // 21-bo'lakka sek qilindi (indeks 20) -> 31-bo'lakkacha.
        assert_eq!(prefetch_range(20, n, w), (21, 31));

        for cur in 0..50u64 {
            let (from, until) = prefetch_range(cur, n, w);
            assert_eq!(until - from, w, "oyna kengligi noto'g'ri");
        }

        // Fayl oxirida oyna qisqaradi va HECH QACHON fayldan
        // chiqib ketmaydi.
        assert_eq!(prefetch_range(995, 1000, w), (996, 1000));
        assert_eq!(prefetch_range(999, 1000, w), (1000, 1000));

        // Oyna 6 bo'lsa: 11-bo'lak (indeks 10) ko'rsatilayotganda
        // 17-bo'lakkacha (indeks 16) olinadi — undan ortiq EMAS.
        assert_eq!(prefetch_range(10, n, 6), (11, 17));
    }

    /// OYNA VIDEONING BITREYTIDAN HISOBLANADI.
    /// Foydalanuvchi bergan misol: 166.54 MiB / 24:05 -> 6 bo'lak.
    #[test]
    fn oyna_bitreytdan_hisoblanadi() {
        let total = (166.54 * 1024.0 * 1024.0) as u64; // 166.54 MiB
        let secs = 24.0 * 60.0 + 5.0; // 24:05 = 1445 soniya
        // 166.54 / 24.0833 = 6.91... -> 6 (7 ga YETMAGANI uchun)
        assert_eq!(prefetch_window_for(total, secs), 6);

        // Davomiylik hali noma'lum — zaxira qiymat.
        assert_eq!(prefetch_window_for(total, 0.0), PREFETCH_WINDOW);
        assert_eq!(prefetch_window_for(0, secs), PREFETCH_WINDOW);

        // Juda past bitreyt ham kamida 1 bo'lak beradi.
        assert_eq!(prefetch_window_for(1024 * 1024, 3600.0), 1);

        // Buzuq metadata (1 soniyalik "1 GB" video) chegaralanadi.
        assert_eq!(
            prefetch_window_for(1024 * 1024 * 1024, 1.0),
            MAX_PREFETCH_WINDOW
        );
    }

    /// IJRO NUQTASI: oyna bufer uchidan emas, PLEYER KO'RSATAYOTGAN
    /// joydan hisoblanishi kerak.
    #[test]
    fn ijro_nuqtasi_bolakka_ogiriladi() {
        let total = 166 * 1024 * 1024; // ~166 MiB
        let secs = 24.0 * 60.0 + 5.0; // 24:05

        // Hali hech narsa xabar qilinmagan — nuqta noma'lum.
        PLAY_POS_KEY.store(0, Ordering::Relaxed);
        assert!(playing_chunk("kino", total, secs).is_none());

        // Dart tomoni ijro nuqtasini xabar qildi.
        let url = "http://127.0.0.1:9/kino";
        let key = cache_key(url);
        let c_url = std::ffi::CString::new(url).unwrap();

        // Boshida (0 ms) -> 0-bo'lak.
        assert_eq!(rust_video_cache_set_position(c_url.as_ptr(), 0), 1);
        assert_eq!(playing_chunk(&key, total, secs), Some(0));

        // Yarmida -> taxminan yarim bo'lak.
        let half_ms = (secs * 1000.0 / 2.0) as u64;
        rust_video_cache_set_position(c_url.as_ptr(), half_ms);
        let mid = playing_chunk(&key, total, secs).unwrap();
        let kutilgan = (total / 2) / CHUNK_SIZE;
        assert!(
            (mid as i64 - kutilgan as i64).abs() <= 1,
            "o'rtadagi bo'lak: {mid}, kutilgan ~{kutilgan}"
        );

        // BOSHQA videoning nuqtasi bu videoga TAALLUQLI EMAS.
        assert!(playing_chunk("boshqa_kino", total, secs).is_none());

        // Oyna aynan shu nuqtadan boshlanadi: 10-bo'lakda turgan
        // pleyer uchun 6 lik oyna 11..17 ni qamraydi (16-bo'lak
        // KIRADI, 17-si yo'q).
        let n = total.div_ceil(CHUNK_SIZE);
        assert_eq!(prefetch_range(10, n, 6), (11, 17));

        // Test global holatni o'zgartirdi — tozalab qo'yamiz.
        PLAY_POS_KEY.store(0, Ordering::Relaxed);
        PLAY_POS_MS.store(0, Ordering::Relaxed);
    }

    /// MP4 `moov` -> `mvhd` dan davomiylik o'qilishi.
    #[test]
    fn mp4_davomiyligi_oqiladi() {
        /// mvhd (v0) qutisini yasaydi: 8 bayt sarlavha + 100 bayt tana.
        fn mvhd_v0(timescale: u32, duration: u32) -> Vec<u8> {
            let mut body = vec![0u8; 100];
            body[0] = 0; // version
            body[12..16].copy_from_slice(&timescale.to_be_bytes());
            body[16..20].copy_from_slice(&duration.to_be_bytes());
            let mut out = ((8 + body.len()) as u32).to_be_bytes().to_vec();
            out.extend_from_slice(b"mvhd");
            out.extend_from_slice(&body);
            out
        }

        fn mvhd_v1(timescale: u32, duration: u64) -> Vec<u8> {
            let mut body = vec![0u8; 112];
            body[0] = 1; // version
            body[20..24].copy_from_slice(&timescale.to_be_bytes());
            body[24..32].copy_from_slice(&duration.to_be_bytes());
            let mut out = ((8 + body.len()) as u32).to_be_bytes().to_vec();
            out.extend_from_slice(b"mvhd");
            out.extend_from_slice(&body);
            out
        }

        /// ftyp + moov(mvhd) — "faststart" bilan tayyorlangan fayl
        /// aynan shunday boshlanadi.
        fn faststart(mvhd: Vec<u8>) -> Vec<u8> {
            let mut out: Vec<u8> = Vec::new();
            out.extend_from_slice(&16u32.to_be_bytes());
            out.extend_from_slice(b"ftypisom");
            out.extend_from_slice(&[0, 0, 2, 0]);
            out.extend_from_slice(&((8 + mvhd.len()) as u32).to_be_bytes());
            out.extend_from_slice(b"moov");
            out.extend_from_slice(&mvhd);
            out
        }

        // 24:05 = 1445 soniya (timescale 1000).
        let d = mp4_duration_secs(&faststart(mvhd_v0(1000, 1_445_000))).unwrap();
        assert!((d - 1445.0).abs() < 0.001, "v0 davomiylik: {d}");

        // 64-bitli (version 1) variant ham o'qilishi kerak.
        let d = mp4_duration_secs(&faststart(mvhd_v1(90_000, 130_050_000))).unwrap();
        assert!((d - 1445.0).abs() < 0.001, "v1 davomiylik: {d}");

        // moov TO'LIQ yuklanmagan bo'lsa ham, mvhd uning boshida
        // bo'lgani uchun baribir o'qiladi (moov hajmi katta deb
        // ko'rsatilgan, lekin baytlar yetishmaydi).
        let mut kesik = faststart(mvhd_v0(1000, 1_445_000));
        let moov_at = 16;
        kesik[moov_at..moov_at + 4].copy_from_slice(&50_000u32.to_be_bytes());
        let d = mp4_duration_secs(&kesik).unwrap();
        assert!((d - 1445.0).abs() < 0.001, "kesik moov: {d}");

        // Aniqlab bo'lmaydigan ma'lumot — panic emas, `None`.
        assert!(mp4_duration_secs(&[]).is_none());
        assert!(mp4_duration_secs(&[0u8; 7]).is_none());
        assert!(mp4_duration_secs(&[0u8; 64]).is_none());
        assert!(mp4_duration_secs(b"bu umuman mp4 emas, shunchaki matn").is_none());
        // timescale 0 — bo'lishga urinilmaydi.
        assert!(mp4_duration_secs(&faststart(mvhd_v0(0, 1000))).is_none());
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
