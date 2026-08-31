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

use crate::crypto;
use crate::ffi_utils::{cstr_to_str, string_to_cptr};

// 100 KB — har bir bo'lak diskda MUSTAQIL shifrlangan holda saqlanadi
// (crypto::encrypt_chunk/decrypt_chunk, har biri o'z kaliti bilan —
// video_cache_server.dart emas, crypto.rs'dagi izohga qarang). 100 KB
// 16 ga karrali (AES blok o'lchami), shu sabab bo'lak chegaralari
// shifrlash blok chegaralari bilan mos keladi.
const CHUNK_SIZE: u64 = 100 * 1024;

/// Bir vaqtda ochiq bo'lishi mumkin bo'lgan eng ko'p ulanish soni.
/// Har bir ulanish bitta OS ish oqimi + ~1 MiB bufer degani, shu sabab
/// bu chegara xotira sarfini bashorat qilinadigan darajada ushlab
/// turadi (tez-tez sek qilishda ilova o'chib qolishining oldini oladi).
/// 24 -> 64. Rad etilgan ulanish = pleyer javobsiz qoladi = qotib
/// qolish. Ish oqimi esa arzon (ayniqsa endi ular keshdan o'qiganda
/// millisekundlarda tugaydi), shu sabab chegara ancha kengaytirildi:
/// u endi faqat haqiqiy nosozlikdan himoya vazifasini bajaradi.
const MAX_CONNS: usize = 64;

/// ENG MUHIM ME'MORIY QAYTA KO'RIB CHIQISH.
///
/// Avval har bir HTTP javob QAT'IY chegara bilan kesilardi (4 MiB,
/// keyin 1 MiB). Bu KATTA XATO bo'lib chiqdi:
///
///   Javob tugashi bilan pleyer (FFmpeg) qolganini olish uchun YANGI
///   TCP ulanish + YANGI HTTP so'rov ochishga majbur bo'lardi. 9 MB
///   fayl uchun bu har bir ko'rishda 9 ta ulanish; sek qilinganda esa
///   har safar yangidan. Foydalanuvchining jurnalida "MAHALLIY" hisobi
///   9 MB fayl uchun 156 MB ga yetgani ham, sek qilganda pleyer qotib
///   qolgani ham AYNAN SHU ulanish bo'roni tufayli edi.
///
/// Endi chegara YO'Q. Uning o'rniga aqlliroq qoida ishlaydi
/// (`contiguous_cached_end` ga qarang): javob KESHDA UZLUKSIZ MAVJUD
/// bo'lgan oxirgi baytgacha davom etadi.
///
///   * Fayl to'liq keshda  -> BITTA so'rov, BITTA javob, tamom.
///                            Hech qanday qayta ulanish yo'q.
///   * Fayl qisman keshda  -> javob birinchi yetishmayotgan bo'lakda
///                            tugaydi; pleyer qayta ulanadi va biz
///                            AYNAN o'sha bo'lakni yuklab beramiz.
///
/// Bu ham HTTP standartiga to'liq mos (206 Partial Content), ham
/// ulanishlar sonini o'nlab barobar kamaytiradi.
/// Bitta javobda tekshiriladigan eng ko'p bo'lak soni. Uzun film
/// (masalan 2 GB) uchun har bir so'rovda minglab fayl tekshiruvi
/// qilmaslik va bitta javobni cheksiz uzaytirmaslik uchun.
/// ~256 MiB — qayta ulanish bo'ronini yo'q qilishga mo'l-ko'l yetadi.
/// MUHIM: CHUNK_SIZE 1 MiB'dan 100 KB'ga tushirilganda (~10x kichik)
/// bu son ~10x OSHIRILDI — aks holda bitta javobning eng ko'p hajmi
/// ~10x kichrayib, "ENG MUHIM ME'MORIY QAYTA KO'RIB CHIQISH" izohida
/// tasvirlangan qayta ulanish bo'roni xavfi qaytadan paydo bo'lardi.
const MAX_SCAN_CHUNKS: u64 = 2600;

fn contiguous_cached_end(dir: &PathBuf, start: u64, end: u64, total: u64) -> u64 {
    // To'liq fayl mavjud — butun so'ralgan oraliq keshda bor.
    if full_is_complete(dir, total) {
        return end;
    }
    let chunk_count = total.div_ceil(CHUNK_SIZE);
    let first = start / CHUNK_SIZE;
    let last_wanted = (end / CHUNK_SIZE).min(first + MAX_SCAN_CHUNKS - 1);
    // Birinchi bo'lak har doim kiradi — pleyer aynan shuni so'rayapti,
    // keshda bo'lmasa uni tarmoqdan olib beramiz.
    let mut last = first;
    let mut i = first + 1;
    while i <= last_wanted && i < chunk_count {
        let cs = i * CHUNK_SIZE;
        let ce = (cs + CHUNK_SIZE - 1).min(total - 1);
        let expected = chunk_on_disk_len(ce - cs + 1);
        match fs::metadata(dir.join(chunk_name(i))) {
            Ok(m) if m.len() == expected => {
                last = i;
                i += 1;
            }
            _ => break,
        }
    }
    let last_byte = ((last + 1) * CHUNK_SIZE - 1).min(total - 1);
    end.min(last_byte)
}

/// Oldindan yuklash OYNASI: ijro nuqtasidan keyin ENG KO'PI BILAN shu
/// qadar bo'lak keshga olinadi. Avval butun fayl fon'da yuklab olinardi
/// — bu foydalanuvchining trafigini keraksiz "so'rib" olardi (u videoni
/// bir necha soniya ko'rib chiqib qo'ysa ham) va xotirani tez to'ldirardi.
/// Endi faqat oldinda turgan bo'laklar saqlanadi; pleyer oldinga
/// siljigan sari (yoki sek qilinganda) oyna ham u bilan birga suriladi.
/// ~10 MiB oldindan yuklash — CHUNK_SIZE 100 KB'ga tushirilgani sabab
/// bu son ~10x oshirildi (avval 10 × 1 MiB = 10 MiB edi).
const PREFETCH_WINDOW: u64 = 100;

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
/// Berilgan video uchun DISKDAGI TO'LIQ FAYL yo'lini qaytaradi
/// (agar hamma bo'lak yuklab bo'lingan bo'lsa). Aks holda bo'sh satr.
///
/// MUHIM: bu funksiya TARMOQQA UMUMAN CHIQMAYDI — faqat diskdagi
/// meta.json va bo'lak fayllariga qaraydi. Pleyer (Dart tomoni) shu
/// yo'lni olsa, videoni HTTP'siz, to'g'ridan-to'g'ri fayldan
/// o'ynatadi: hech qanday ulanish, hech qanday timeout, sek esa
/// oddiy fayl ichida siljish — ya'ni bir zumda va xatosiz.
#[no_mangle]
pub extern "C" fn rust_video_cache_local_file(url_ptr: *const c_char) -> *mut c_char {
    let url = match unsafe { cstr_to_str(url_ptr) } {
        Some(u) => u,
        None => return string_to_cptr(String::new()),
    };
    let shared = match SHARED.get() {
        Some(s) => s,
        None => return string_to_cptr(String::new()),
    };
    let dir = shared.cache_root.join(cache_key(url));
    // meta.json faqat DISKDAN — tarmoqqa chiqmaymiz.
    let total = fs::read_to_string(dir.join("meta.json"))
        .ok()
        .and_then(|raw| serde_json::from_str::<CacheMeta>(&raw).ok())
        .map(|m| m.total_size)
        .unwrap_or(0);
    if total == 0 {
        return string_to_cptr(String::new());
    }
    if try_assemble_full(&dir, total) {
        let p = full_file_path(&dir).to_string_lossy().to_string();
        // Shifrlangan bo'lsa, pleyer (FFmpeg "crypto:" protokoli) uchun
        // kalit va IV ham qaytariladi. Ular DISKKA YOZILMAYDI —
        // har safar asosiy kalitdan qaytadan hisoblanadi va faqat
        // xotirada, pleyerga uzatish uchun ishlatiladi.
        let (key_hex, iv_hex) = if crypto::is_enabled() {
            let label = dir
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            match crypto::derive_video_key_iv(&label) {
                Some((k, iv)) => (hex::encode(k), hex::encode(iv)),
                None => (String::new(), String::new()),
            }
        } else {
            (String::new(), String::new())
        };
        log(format!("Mahalliy to'liq fayl topildi — HTTP'siz ijro (shifrlangan={})", crypto::is_enabled()));
        let json = serde_json::json!({
            "path": p,
            "key": key_hex,
            "iv": iv_hex,
            "encrypted": crypto::is_enabled(),
        });
        return string_to_cptr(json.to_string());
    }
    string_to_cptr(String::new())
}

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
    // YOZISH TIMEOUT'I QAYTA KO'RIB CHIQILDI: 2s -> 20s.
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
    // ettirilganda video buzilardi. 20 soniya odatdagi pauzalarni
    // bemalol qoplaydi.
    stream.set_write_timeout(Some(Duration::from_secs(20)))?;
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
//  TO'LIQ FAYL ("full.bin") — HTTP QATLAMINI BUTUNLAY CHETLAB O'TISH
// ═══════════════════════════════════════════════════════════════════
//
// NEGA BU ENG MUHIM O'ZGARISH.
//
// Server tomonini ancha yaxshiladik (bitta uzun javob, tez jurnal,
// parallel ulanishlar) va u endi testlarda 300 marta "sek bo'roni"ga
// ham bardosh beradi. Lekin haqiqiy qurilmada pleyer HALI HAM qotardi.
// Sabab endi bizning serverimizda emas — mdk-sdk/FFmpeg'ning HTTP
// manbadan TEZ-TEZ SEK QILISHNI qanday bajarishida. Har bir sek:
// eski TCP ulanishni uzish, yangisini ochish, sarlavhalarni almashish,
// demuxer'ni qaytadan sozlash. Bularning har biri xato qilishi mumkin
// bo'lgan nuqta.
//
// YECHIM: fayl to'liq yuklab bo'lingach, bo'laklarni BITTA oddiy
// faylga yig'amiz va pleyerga to'g'ridan-to'g'ri SHU FAYLNI beramiz
// (file:// — HTTP emas). Shunda:
//
//   * hech qanday TCP ulanish yo'q;
//   * sek — bu shunchaki fayl ichida `seek()`, millisekundlarda;
//   * uzilish, timeout, qayta ulanish degan tushunchalarning O'ZI yo'q.
//
// Bu aynan YouTube'ning yuklab olingan videoni ko'rsatish usuli va
// Telegram'ning FileStreamLoadOperation'i bilan bir xil g'oya.
//
// Disk sarfi oshmaydi: to'liq fayl yaratilgach, bo'lak fayllari
// O'CHIRILADI. Yuklab olish jarayonida esa bo'laklar saqlanadi —
// internet uzilsa, qayta boshlamasdan davom ettirish uchun.
//
// KELAJAK (AES): bo'lak-darajasidagi shifrlash joriy qilinganda bu
// yo'l qayta ko'rib chiqiladi — shifrlangan faylni pleyer to'g'ridan
// o'qiy olmaydi, o'shanda yana HTTP proksi kerak bo'ladi.
const FULL_NAME: &str = "full.bin";
const FULL_ENC_NAME: &str = "full.enc";

/// SHIFRLANGAN va OCHIQ to'liq fayl ATAYLAB turli nomda saqlanadi.
/// Shu bilan kalit yo'qolgan yoki shifrlash o'chirilgan holatda
/// shifrlangan faylni xato ravishda "ochiq" deb o'qib yuborish
/// mumkin emas.
/// Vaqtinchalik fayl nomlari uchun noyob qo'shimcha.
fn unique_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn full_file_path(dir: &PathBuf) -> PathBuf {
    if crypto::is_enabled() {
        dir.join(FULL_ENC_NAME)
    } else {
        dir.join(FULL_NAME)
    }
}

/// To'liq fayl mavjud va hajmi to'g'rimi?
///
/// Shifrlangan holatda hajm PKCS7 to'ldirishi sabab asl hajmdan
/// katta bo'ladi — shuni hisobga olamiz.
fn full_is_complete(dir: &PathBuf, total: u64) -> bool {
    if total == 0 {
        return false;
    }
    let expected = if crypto::is_enabled() {
        crypto::encrypted_size(total)
    } else {
        total
    };
    fs::metadata(full_file_path(dir))
        .map(|m| m.len() == expected)
        .unwrap_or(false)
}

/// Barcha bo'laklar joyida bo'lsa, ularni BITTA faylga yig'adi va
/// bo'lak fayllarini o'chiradi. Muvaffaqiyatli bo'lsa `true`.
///
/// Yozish avval `.tmp` ga, keyin ATOM `rename` bilan yakuniy nomga —
/// shu sabab jarayon o'rtada uzilsa ham yarim fayl "to'liq" deb
/// qabul qilinmaydi.
/// Hozir yig'ilayotgan papkalar. Ikki oqim BIR VAQTDA bitta faylni
/// yig'ishga urinmasligi uchun.
///
/// BU HIMOYA TEST BILAN TOPILDI: oldindan yuklash oqimi faylni
/// yig'ayotganda, foydalanuvchi o'sha videoni ochsa,
/// `rust_video_cache_local_file` ham yig'ishni boshlardi. Ikkalasi
/// BIR XIL vaqtinchalik faylga yozib, natijada CHALA fayl paydo
/// bo'lardi ("to'liq" deb belgilangan, lekin qismi yo'q) — video
/// buzilib ko'rinardi.
static ASSEMBLING: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();

fn assembling_set() -> &'static Mutex<HashSet<PathBuf>> {
    ASSEMBLING.get_or_init(|| Mutex::new(HashSet::new()))
}

fn try_assemble_full(dir: &PathBuf, total: u64) -> bool {
    if total == 0 {
        return false;
    }
    // Boshqa oqim shu papkani yig'ayotgan bo'lsa — aralashmaymiz.
    {
        let mut set = assembling_set().lock().unwrap();
        if !set.insert(dir.clone()) {
            return full_is_complete(dir, total);
        }
    }
    let result = assemble_full_inner(dir, total);
    assembling_set().lock().unwrap().remove(dir);
    result
}

fn assemble_full_inner(dir: &PathBuf, total: u64) -> bool {
    // Ilova yig'ish o'rtasida o'ldirilgan bo'lsa, papkada "yetim"
    // .tmp fayl qolishi mumkin. Qulf sabab bu yerda faqat BIZ
    // ishlayapmiz, ya'ni ularni xavfsiz o'chirsa bo'ladi.
    if let Ok(entries) = fs::read_dir(dir) {
        for e in entries.flatten() {
            if e.file_name().to_string_lossy().ends_with(".tmp") {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    if full_is_complete(dir, total) {
        return true;
    }
    // ── MIGRATSIYA ────────────────────────────────────────────────
    // Shifrlash YOQILGANIDAN OLDIN yig'ilgan ochiq `full.bin` bo'lishi
    // mumkin. Bo'lak fayllari o'sha paytda o'chirilgan, ya'ni uni
    // qaytadan yig'ib bo'lmaydi. Agar buni hisobga olmasak, ilova
    // butun videoni internetdan QAYTA yuklab olardi.
    // Shu sabab mavjud ochiq faylni JOYIDA shifrlab, yangi nomga
    // o'tkazamiz — foydalanuvchi hech narsa yo'qotmaydi.
    if crypto::is_enabled() && migrate_plain_to_encrypted(dir, total) {
        return true;
    }
    let chunk_count = total.div_ceil(CHUNK_SIZE);
    // Avval HAMMA bo'lak joyidami — tekshiramiz (arzon, faqat metadata).
    for i in 0..chunk_count {
        let cs = i * CHUNK_SIZE;
        let ce = (cs + CHUNK_SIZE - 1).min(total - 1);
        let expected = chunk_on_disk_len(ce - cs + 1);
        match fs::metadata(dir.join(chunk_name(i))) {
            Ok(m) if m.len() == expected => {}
            _ => return false,
        }
    }

    // Vaqtinchalik nom NOYOB — kutilmagan holatda ham ikki yozuvchi
    // bir xil faylga tushib qolmasligi uchun (bo'lak fayllarida ham
    // xuddi shunday qilingan).
    let tmp = dir.join(format!("{FULL_NAME}.{}.tmp", unique_suffix()));
    let mut out = match fs::File::create(&tmp) {
        Ok(f) => f,
        Err(e) => {
            log(format!("To'liq faylni yaratib bo'lmadi: {e}"));
            return false;
        }
    };

    // Shifrlash yoqilgan bo'lsa — OQIM bilan shifrlaymiz. Butun fayl
    // hech qachon xotiraga yuklanmaydi: bo'lak o'qiladi, shifrlanadi,
    // yoziladi va tashlanadi. Shu sabab 1 GB'lik film ham xotirani
    // to'ldirmaydi.
    let label = dir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut encryptor = if crypto::is_enabled() {
        match crypto::derive_video_key_iv(&label) {
            Some((k, iv)) => Some(crypto::VideoEncryptor::new(&k, &iv)),
            None => {
                let _ = fs::remove_file(&tmp);
                return false;
            }
        }
    } else {
        None
    };

    for i in 0..chunk_count {
        match fs::read(dir.join(chunk_name(i))) {
            Ok(raw) => {
                // Bo'lak fayllari diskda MUSTAQIL shifrlangan (har biri
                // o'z kaliti bilan, crypto.rs'ga qarang) — to'liq fayl
                // esa BITTA umumiy CBC zanjiri, shu sabab avval har bir
                // bo'lakni o'z holicha ochamiz, keyin qaytadan (butun
                // fayl kaliti bilan) uzluksiz shifrlaymiz.
                let bytes = if crypto::is_enabled() {
                    match crypto::derive_chunk_key_iv(&label, i)
                        .and_then(|(k, iv)| crypto::decrypt_chunk(&raw, &k, &iv))
                    {
                        Some(p) => p,
                        None => {
                            let _ = fs::remove_file(&tmp);
                            return false;
                        }
                    }
                } else {
                    raw
                };
                let piece = match encryptor.as_mut() {
                    Some(e) => e.update(&bytes),
                    None => bytes,
                };
                if !piece.is_empty() && out.write_all(&piece).is_err() {
                    let _ = fs::remove_file(&tmp);
                    return false;
                }
            }
            Err(_) => {
                let _ = fs::remove_file(&tmp);
                return false;
            }
        }
    }
    if let Some(e) = encryptor {
        if out.write_all(&e.finish()).is_err() {
            let _ = fs::remove_file(&tmp);
            return false;
        }
    }
    drop(out);
    if fs::rename(&tmp, full_file_path(dir)).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    // Endi bo'laklar keraksiz — disk sarfi ikki barobar bo'lmasligi
    // uchun o'chiriladi.
    for i in 0..chunk_count {
        let _ = fs::remove_file(dir.join(chunk_name(i)));
    }
    log(format!(
        "TO'LIQ FAYL yig'ildi ({total} bayt, shifrlangan={}) — pleyer uni HTTP'siz o'qiydi",
        crypto::is_enabled()
    ));
    true
}

/// Ochiq `full.bin` ni shifrlab `full.enc` ga o'tkazadi va eskisini
/// o'chiradi. Oqim bilan ishlaydi — katta fayl xotiraga sig'masligi
/// mumkin.
fn migrate_plain_to_encrypted(dir: &PathBuf, total: u64) -> bool {
    let plain_path = dir.join(FULL_NAME);
    match fs::metadata(&plain_path) {
        Ok(m) if m.len() == total => {}
        _ => return false,
    }
    let label = match dir.file_name() {
        Some(n) => n.to_string_lossy().to_string(),
        None => return false,
    };
    let (key, iv) = match crypto::derive_video_key_iv(&label) {
        Some(v) => v,
        None => return false,
    };
    let mut input = match fs::File::open(&plain_path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let tmp = dir.join(format!("{FULL_ENC_NAME}.{}.tmp", unique_suffix()));
    let mut out = match fs::File::create(&tmp) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut enc = crypto::VideoEncryptor::new(&key, &iv);
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        match input.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let piece = enc.update(&buf[..n]);
                if !piece.is_empty() && out.write_all(&piece).is_err() {
                    let _ = fs::remove_file(&tmp);
                    return false;
                }
            }
            Err(_) => {
                let _ = fs::remove_file(&tmp);
                return false;
            }
        }
    }
    if out.write_all(&enc.finish()).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    drop(out);
    drop(input);
    if fs::rename(&tmp, dir.join(FULL_ENC_NAME)).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    let _ = fs::remove_file(&plain_path);
    log("Mavjud ochiq fayl shifrlangan holatga o'tkazildi".to_string());
    true
}

/// To'liq fayldan kerakli bo'lakni o'qiydi (HTTP yo'li uchun zaxira:
/// bo'laklar o'chirilgan, lekin kimdir baribir Range so'rov yuborsa).
fn read_from_full(dir: &PathBuf, start: u64, len: usize, total: u64) -> Option<Vec<u8>> {
    use std::io::{Seek, SeekFrom};
    let path = full_file_path(dir);
    if !crypto::is_enabled() {
        let mut f = fs::File::open(path).ok()?;
        f.seek(SeekFrom::Start(start)).ok()?;
        let mut buf = vec![0u8; len];
        f.read_exact(&mut buf).ok()?;
        return Some(buf);
    }

    // ── SHIFRLANGAN: kerakli qismni ochamiz ────────────────────────
    // Bu zaxira yo'l — odatda pleyer faylni FFmpeg'ning "crypto:"
    // protokoli orqali O'ZI ochadi va bu yerga umuman kelmaydi. Lekin
    // biror sababdan mahalliy HTTP proksi ishlatilsa, baytlarni biz
    // ochib beramiz.
    //
    // CBC'da N-blokni ochish uchun (N-1)-blok kerak, shu sabab
    // kerakli joydan bitta blok OLDINDAN o'qiymiz.
    let label = dir.file_name().map(|n| n.to_string_lossy().to_string())?;
    let (key, iv) = crypto::derive_video_key_iv(&label)?;
    let block_start = (start / 16) * 16;
    let read_from = block_start.saturating_sub(if block_start == 0 { 0 } else { 16 });
    let want_end = (start + len as u64).min(total);
    let block_end = ((want_end + 15) / 16) * 16;
    let enc_total = crypto::encrypted_size(total);
    let read_to = if block_end >= total { enc_total } else { block_end };

    let mut f = fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(read_from)).ok()?;
    let mut raw = vec![0u8; (read_to - read_from) as usize];
    f.read_exact(&mut raw).ok()?;

    // decrypt_video_range butun fayl bo'yicha ofsetlar bilan ishlaydi,
    // shu sabab o'qilgan qismni to'g'ri joyga qo'yamiz.
    let mut window = vec![0u8; read_from as usize];
    window.extend_from_slice(&raw);
    crypto::decrypt_video_range(&window, &key, &iv, start, len, total)
}

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
    // To'liq fayl yig'ilgan bo'lsa (bo'laklar o'chirilgan) — undan
    // o'qiymiz.
    if full_is_complete(dir, expected_total) {
        if let Some(bytes) = read_from_full(dir, start, expected_len, expected_total) {
            log(format!("Bo'lak #{index} TO'LIQ FAYLDAN o'qildi (tarmoqsiz)"));
            return Ok(bytes);
        }
    }
    if let Some(bytes) = read_cached_chunk(dir, key, index, expected_len) {
        // MUHIM (diagnostika): diskdan o'qilgan bo'lak uchun TARMOQQA
        // umuman chiqilmaydi. Bu log ekranda ko'rinib turishi kerak —
        // shu bilan "qayta yuklanyaptimi yoki keshdanmi" degan savolga
        // to'g'ridan-to'g'ri javob beradi.
        log(format!("Bo'lak #{index} KESHDAN o'qildi (tarmoqsiz)"));
        return Ok(bytes);
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
            // Oyna tugadi — hamma bo'lak yig'ilgan bo'lsa, ularni
            // BITTA faylga birlashtiramiz. Keyingi ochilishda pleyer
            // HTTP'siz, to'g'ridan-to'g'ri shu fayldan o'ynaydi.
            try_assemble_full(&dir2, total);
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

    // Javob KESHDA UZLUKSIZ MAVJUD bo'lgan joygacha davom etadi
    // (yuqoridagi `contiguous_cached_end` izohiga qarang). To'liq
    // keshlangan faylda bu butun so'ralgan oraliq bo'ladi — ya'ni
    // BITTA javob, hech qanday qayta ulanishsiz.
    //
    // Bu faqat Range so'rovlariga qo'llaniladi: Range'siz (200 OK)
    // javobda Content-Length butun faylni bildiradi va uni qisqartirish
    // HTTP qoidasini buzgan bo'lardi.
    if is_range {
        end = contiguous_cached_end(&dir, start, end, total);
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
                "{{\"total_size\":{TEST_TOTAL},\"content_type\":\"video/mp4\"}}"
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

        // ── 7) SHIFRLANGAN TO'LIQ FAYL orqali xizmat ko'rsatish ───
        // Bu ZAXIRA yo'l: odatda pleyer shifrni "crypto:" protokoli
        // bilan o'zi ochadi va bu yerga kelmaydi. Ammo agar u
        // qurilmada ishlamasa, biz baytlarni O'ZIMIZ ochib berishimiz
        // kerak — va ular asl ma'lumot bilan AYNAN bir xil bo'lishi
        // shart.
        let cache_dir = root.join("video_byte_cache").join(TEST_NAME);
        // Fon oqimi hozir yig'ayotgan bo'lishi mumkin — qulf sabab
        // bizning chaqiruvimiz "hali tayyor emas" deb qaytadi. Bu
        // TO'G'RI xatti-harakat (ishlab chiqarishda ham shunday:
        // o'sha safar HTTP yo'lidan o'ynatiladi, keyingisida fayldan).
        // Testda esa tugashini kutamiz.
        let mut ready = false;
        for _ in 0..100 {
            if try_assemble_full(&cache_dir, TEST_TOTAL) {
                ready = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(ready, "to'liq fayl yig'ilmadi");
        assert!(
            cache_dir.join("full.enc").exists(),
            "fayl shifrlangan holatda saqlanmadi"
        );
        assert!(
            !cache_dir.join(chunk_name(0)).exists(),
            "bo'laklar o'chirilmagan"
        );

        for (start, len) in [
            (0u64, 4096usize),
            (1, 33),                       // blok chegarasiga tushmaydi
            (CHUNK_SIZE, 65_536),          // bo'lak chegarasi
            (5_000_001, 100_000),
            (TEST_TOTAL - 10, 10),         // eng oxiri
        ] {
            let (st, _, got_len, body) = request(
                port,
                Some(&format!("bytes={}-{}", start, start + len as u64 - 1)),
                None,
            );
            assert_eq!(st, 206, "shifrlangan fayldan so'rov ({start}+{len})");
            assert_eq!(got_len, len, "uzunlik mos emas ({start}+{len})");
            for (i, b) in body.iter().enumerate() {
                let pos = start as usize + i;
                assert_eq!(
                    *b,
                    (pos % 251) as u8,
                    "shifr ochishda XATO: bayt {pos} noto'g'ri"
                );
            }
        }

        // ── 8) Suffiks so'rov: "bytes=-N" (fayl oxiridan N bayt) ───
        let (status, cr, len, _) = request(port, Some("bytes=-1000"), None);
        assert_eq!(status, 206);
        assert_eq!(
            cr,
            format!("bytes {}-{}/{}", TEST_TOTAL - 1000, TEST_TOTAL - 1, TEST_TOTAL)
        );
        assert_eq!(len, 1000);

        let _ = fs::remove_dir_all(&root);
    }

    /// Hamma bo'lak joyida bo'lsa, ular BITTA faylga yig'ilishi va
    /// bo'lak fayllari o'chirilishi kerak (disk ikki barobar
    /// egallanmasligi uchun). Undan keyin o'qish shu fayldan boradi.
    #[test]
    fn toliq_fayl_yigiladi_va_bolaklar_ochiriladi() {
        enable_crypto();
        let dir = std::env::temp_dir().join("vc_full_test");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let chunks = TEST_TOTAL.div_ceil(CHUNK_SIZE);
        // assemble_full_inner bo'lak kalitini papka NOMIDAN hosil qiladi
        // (dir.file_name()) — testda ham shu yorliq bilan shifrlaymiz.
        let label = dir.file_name().unwrap().to_string_lossy().to_string();

        // Bitta bo'lak yetishmasa — yig'ilmasligi kerak.
        for i in 1..chunks {
            let cs = i * CHUNK_SIZE;
            let ce = (cs + CHUNK_SIZE - 1).min(TEST_TOTAL - 1);
            let plain = vec![7u8; (ce - cs + 1) as usize];
            let (k, iv) = crypto::derive_chunk_key_iv(&label, i).unwrap();
            fs::write(dir.join(chunk_name(i)), crypto::encrypt_chunk(&plain, &k, &iv)).unwrap();
        }
        assert!(!try_assemble_full(&dir, TEST_TOTAL), "chala keshda yig'ilmasligi kerak");
        assert!(!full_is_complete(&dir, TEST_TOTAL));

        // Yetishmayotgan bo'lak qo'shilgach — yig'ilishi kerak.
        let data0: Vec<u8> = (0..CHUNK_SIZE as usize).map(|k| (k % 251) as u8).collect();
        let (k0, iv0) = crypto::derive_chunk_key_iv(&label, 0).unwrap();
        fs::write(dir.join(chunk_name(0)), crypto::encrypt_chunk(&data0, &k0, &iv0)).unwrap();
        assert!(try_assemble_full(&dir, TEST_TOTAL), "to'liq keshda yig'ilishi kerak");
        assert!(full_is_complete(&dir, TEST_TOTAL));
        // Shifrlangan fayl PKCS7 to'ldirishi sabab asl hajmdan katta.
        assert_eq!(
            fs::metadata(full_file_path(&dir)).unwrap().len(),
            crypto::encrypted_size(TEST_TOTAL)
        );
        assert!(full_file_path(&dir).to_string_lossy().ends_with(".enc"));
        // Bo'lak fayllari o'chirilgan bo'lishi kerak.
        for i in 0..chunks {
            assert!(
                !dir.join(chunk_name(i)).exists(),
                "bo'lak #{i} o'chirilmagan — disk ikki barobar egallanadi"
            );
        }
        // To'liq fayldan o'qish to'g'ri joydan kelishi kerak.
        let part = read_from_full(&dir, 100, 16, TEST_TOTAL).unwrap();
        assert_eq!(part[0], 100u8 % 251);
        assert_eq!(part[15], 115u8 % 251);
        // Ikkinchi chaqiruv ham `true` (allaqachon tayyor).
        assert!(try_assemble_full(&dir, TEST_TOTAL));

        let _ = fs::remove_dir_all(&dir);
    }

    /// Bo'lak yetishmasa, javob AYNAN o'sha bo'shliqda tugashi kerak —
    /// keyin pleyer qayta ulanadi va biz faqat o'sha bo'lakni olamiz.
    #[test]
    fn yetishmayotgan_bolakda_javob_tugaydi() {
        enable_crypto();
        let dir = std::env::temp_dir().join("vc_gap_test");
        let _ = fs::remove_dir_all(&dir);
        let cache = dir.join("video_byte_cache").join(TEST_NAME);
        fs::create_dir_all(&cache).unwrap();
        let chunks = TEST_TOTAL.div_ceil(CHUNK_SIZE);
        for i in 0..chunks {
            if i == 3 {
                continue; // 3-bo'lak ATAYLAB yo'q
            }
            let cs = i * CHUNK_SIZE;
            let ce = (cs + CHUNK_SIZE - 1).min(TEST_TOTAL - 1);
            let plain = vec![0u8; (ce - cs + 1) as usize];
            let (k, iv) = crypto::derive_chunk_key_iv(TEST_NAME, i).unwrap();
            fs::write(cache.join(chunk_name(i)), crypto::encrypt_chunk(&plain, &k, &iv)).unwrap();
        }
        // 0-dan boshlansa, javob 3-bo'lakdan OLDIN tugashi kerak.
        assert_eq!(
            contiguous_cached_end(&cache, 0, TEST_TOTAL - 1, TEST_TOTAL),
            3 * CHUNK_SIZE - 1
        );
        // 4-bo'lakdan boshlansa, oxirigacha uzluksiz.
        assert_eq!(
            contiguous_cached_end(&cache, 4 * CHUNK_SIZE, TEST_TOTAL - 1, TEST_TOTAL),
            TEST_TOTAL - 1
        );
        // Yetishmayotgan bo'lakning O'ZIDAN boshlansa: o'sha bo'lak
        // tarmoqdan olinadi, undan KEYINGILARI esa keshda bo'lgani
        // uchun O'SHA JAVOBDA davom ettiriladi — ya'ni bitta so'rov
        // bilan oxirigacha. Bu ataylab shunday: keraksiz qayta
        // ulanishning oldini oladi.
        assert_eq!(
            contiguous_cached_end(&cache, 3 * CHUNK_SIZE, TEST_TOTAL - 1, TEST_TOTAL),
            TEST_TOTAL - 1
        );
        let _ = fs::remove_dir_all(&dir);
    }

}

