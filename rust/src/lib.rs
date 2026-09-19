// rust/src/lib.rs — Kirish nuqtasi.
//
// Har bir mexanizm o'z faylida (tahrirlash oson bo'lishi uchun):
//   ffi_utils.rs — pointer/string yordamchilari (boshqa modullar ishlatadi)
//   cache.rs     — lokal fayl-kesh (rust_cache_get/save/clear)
//   search.rs    — qidiruv va janr filtri (rust_search_filter, rust_filter_by_genre)
//   validate.rs  — forma validatsiyasi (rust_validate_anime_form)
//
// Bu fayl faqat modullarni e'lon qiladi va ilova versiyasini qaytaradi.

mod cache;
mod ffi_utils;
mod search;
mod validate;
mod crypto;
mod mp4;
mod video_cache;

use ffi_utils::string_to_cptr;
use std::os::raw::c_char;

/// Rust yadrosi versiyasi (diagnostika uchun, masalan Profil ekranida).
#[no_mangle]
pub extern "C" fn rust_core_version() -> *mut c_char {
    string_to_cptr("rust_core 0.1.0".to_string())
}

// ═══════════════════════════════════════════════════════════════
//  SO'ROV IMZOSI — "bu so'rov HAQIQIY ilovadan"
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "worker faqatgina ilovaga va tezchek
// apiga javob bersin ... har qanday tashqi so'rovlarni rad etsin".
//
// ── NEGA ILGARIGI USUL YETARLI EMAS EDI ───────────────────────
//
// Ilgari serverga APK sertifikatining hash'i yuborilardi. U SIR
// EMAS (APK'ni ochgan har kim hisoblab oladi) va O'ZGARMAYDI —
// bir marta nusxa ko'chirilgach abadiy ishlaydi.
//
// Endi har bir so'rov ALOHIDA imzolanadi:
//
//   imzolanadigan matn: "<vaqt>.<METOD>.<yo'l>"
//   natija:             HMAC-SHA256(sir, matn) -> hex
//
// Ya'ni ushlab olingan imzo 2 daqiqadan keyin o'lik va boshqa
// yo'lga yaramaydi.
//
// ── NEGA AYNAN RUST YADROSIDA ─────────────────────────────────
//
// Sir Dart kodida bo'lsa, u APK ichidagi Dart tasvirida oddiy
// satr bo'lib yotadi — `strings` buyrug'i bilan topiladi. Native
// `.so` ichidan chiqarib olish ancha ko'p mehnat talab qiladi.
//
// Mutlaq himoya EMAS (telefondagi ilova hech qachon sir saqlay
// olmaydi), lekin to'siq bir necha daraja balandlaydi.
//
// ── SIR QAYERDAN KELADI ───────────────────────────────────────
//
// Kompilyatsiya paytida `APP_SIGN_SECRET` muhit o'zgaruvchisidan
// (CI uni GitHub sirlaridan beradi). Berilmagan bo'lsa imzo BO'SH
// qaytadi va ilova sarlavhani umuman qo'ymaydi — ishlab chiqish
// rejimida server ham tekshiruvni o'chirib qo'ygan bo'ladi.
//
// ── NEGA KALIT OCHIQ SAQLANMAYDI ──────────────────────────────
//
// TEKSHIRIB KO'RILDI: kalit oddiy `&str` bo'lib turganda u tayyor
// `.so` faylning ichida OCHIQ bayt bo'lib yotardi va `strings`
// buyrug'i uni bir zumda topib berardi:
//
//     $ strings librust_core.so | grep -o "...KALIT..."
//     fulutter-video-v1janriDEADBEEF...TESTKALITRust kesh-server
//
// Ya'ni APK'ni ochgan odam uchun bu bir necha daqiqalik ish edi.
//
// Endi kalit XOR niqobi ostida saqlanadi va faqat ishlatilish
// payti tiklanadi. `strings` endi hech narsa topmaydi — kalitni
// olish uchun kodning o'zini disassembler bilan o'qish kerak.
//
// Bu MUTLAQ himoya emas (telefondagi ilova hech qachon mukammal
// sir saqlay olmaydi), lekin to'siq "bir necha daqiqa" dan
// "teskari muhandislik" darajasiga ko'tariladi.

/// Kompilyatsiya paytida kiritilgan kalit (xom ko'rinishda —
/// pastda darhol niqoblanadi va binarga tushmaydi).
const RAW_SECRET: &str = match option_env!("APP_SIGN_SECRET") {
    Some(v) => v,
    None => "",
};

const SECRET_LEN: usize = RAW_SECRET.len();

/// Har bir bayt uchun boshqacha niqob — bir xil bayt ketma-ket
/// kelsa ham natijada takrorlanuvchi naqsh chiqmaydi.
const fn mask_at(i: usize) -> u8 {
    0x5Au8 ^ (i as u8).wrapping_mul(31).wrapping_add(7)
}

/// Niqoblangan kalit — binarda AYNAN shu baytlar turadi.
const OBFUSCATED: [u8; SECRET_LEN] = {
    let src = RAW_SECRET.as_bytes();
    let mut out = [0u8; SECRET_LEN];
    let mut i = 0;
    while i < SECRET_LEN {
        out[i] = src[i] ^ mask_at(i);
        i += 1;
    }
    out
};

/// Kalitni ishlatish paytida tiklaydi.
fn app_secret() -> Vec<u8> {
    let mut out = Vec::with_capacity(SECRET_LEN);
    let mut i = 0;
    while i < SECRET_LEN {
        out.push(OBFUSCATED[i] ^ mask_at(i));
        i += 1;
    }
    out
}

/// Hozirgi vaqt (Unix soniya).
fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Manzildan yo'lni ajratadi: `https://host/api/play/x?a=b` -> `/api/play/x`.
///
/// Imzo AYNAN yo'l ustidan qo'yiladi (so'rov qismisiz), chunki
/// worker ham shunday hisoblaydi.
fn path_of(url: &str) -> &str {
    let rest = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let path = match rest.find('/') {
        Some(i) => &rest[i..],
        None => "/",
    };
    match path.find('?') {
        Some(i) => &path[..i],
        None => path,
    }
}

/// So'rov imzosi — `v2.<vaqt>.<hex>`. Sir yo'q bo'lsa `None`.
///
/// Bu FFI (`app_sign`) va yadroning O'Z so'rovlari (video keshi)
/// uchun BITTA joy: ikkovi ham aynan bir xil imzo yasashi shart.
pub(crate) fn sign_v2(method: &str, url_or_path: &str) -> Option<String> {
    use hmac::Mac;

    if SECRET_LEN == 0 {
        return None;
    }
    let ts = unix_now();
    let path = path_of(url_or_path);
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(&app_secret()).ok()?;
    mac.update(format!("{ts}.{}.{path}", method.to_uppercase()).as_bytes());
    Some(format!("v2.{ts}.{}", hex::encode(mac.finalize().into_bytes())))
}

// ── PLEYER UCHUN MUDDATLI TOKEN ────────────────────────────────
//
// TOPILGAN XATO (video ochilmay qoldi): `/api/play/...` manzilini
// bizning kodimiz EMAS, ExoPlayer'ning o'zi ochadi
// (`VideoPlayerController.networkUrl`). Unga sarlavha qo'shib
// bo'lmaydi va u har so'rovda imzo hisoblay olmaydi — ya'ni
// yo'l yopilgach video butunlay ishlamay qoldi.
//
// Sarlavha o'rniga MANZILNING O'ZIGA token qo'yiladi:
//
//     /api/play/<fayl>?t=<muddat>.<hex HMAC>
//     imzolanadigan matn: "play.<yo'l>.<muddat>"
//
// Nega alohida token, oddiy imzo emas: oddiy imzo 2 daqiqada
// o'ladi, ijro esa soatlab davom etadi va ExoPlayer butun
// davomida oraliq so'rovlar yuboradi — ular 403 olardi.
//
// Token AYNAN SHU faylga bog'langan va muddati bor. Uni yasash
// uchun kalit kerak, ya'ni begona dastur o'zi yasay olmaydi.
//
// CLOUDFLARE KESHIGA TA'SIR QILMAYDI: worker kesh kalitini
// so'rov qismidan emas, fayl nomidan quradi (`cache_key_url`).

/// Pleyer manzili uchun muddatli token: `<muddat>.<hex>`.
///
/// # Safety
/// `path` nol bilan tugaydigan UTF-8 satrga ishora qilishi shart.
#[no_mangle]
pub unsafe extern "C" fn app_play_token(path: *const c_char, ttl_secs: u64) -> *mut c_char {
    use hmac::Mac;

    if SECRET_LEN == 0 || path.is_null() {
        return string_to_cptr(String::new());
    }
    let path = std::ffi::CStr::from_ptr(path).to_string_lossy().into_owned();
    if path.is_empty() {
        return string_to_cptr(String::new());
    }
    let exp = unix_now() + ttl_secs.clamp(60, 24 * 60 * 60);
    let Ok(mut mac) = hmac::Hmac::<sha2::Sha256>::new_from_slice(&app_secret()) else {
        return string_to_cptr(String::new());
    };
    mac.update(format!("play.{path}.{exp}").as_bytes());
    string_to_cptr(format!("{exp}.{}", hex::encode(mac.finalize().into_bytes())))
}

// ── ILOVA VERSIYASI ────────────────────────────────────────────
//
// Yadro o'z so'rovlariga `X-App-Version` ni ham qo'yishi kerak:
// aks holda admin oynasidan "eng past versiya" tekshiruvi
// yoqilgan zahoti VIDEO ishlamay qolardi (yadro versiyasini
// aytmagani uchun "eski ilova" deb rad etilardi).
//
// Qiymatni ilova ishga tushganda beradi (`rust_set_app_version`).
static APP_VERSION: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

/// Ilova versiyasini yadroga bildiradi (`0.0.9+230`).
///
/// # Safety
/// `v` nol bilan tugaydigan UTF-8 satrga ishora qilishi shart.
#[no_mangle]
pub unsafe extern "C" fn rust_set_app_version(v: *const c_char) {
    if v.is_null() {
        return;
    }
    let s = std::ffi::CStr::from_ptr(v).to_string_lossy().into_owned();
    if let Ok(mut g) = APP_VERSION.lock() {
        *g = s;
    }
}

/// Yadro so'rovlariga qo'yiladigan versiya (bo'sh bo'lishi mumkin).
pub(crate) fn app_version() -> String {
    APP_VERSION.lock().map(|g| g.clone()).unwrap_or_default()
}

/// `<vaqt>.<METOD>.<yo'l>` matnini imzolaydi.
///
/// Qaytaradi: `v2.<vaqt>.<hex>` yoki bo'sh satr (sir yo'q).
///
/// # Safety
/// Uchala ko'rsatkich ham to'g'ri, nol bilan tugaydigan UTF-8
/// satrga ishora qilishi shart.
#[no_mangle]
pub unsafe extern "C" fn app_sign(
    ts: *const c_char,
    method: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    use hmac::Mac;

    if SECRET_LEN == 0 {
        return string_to_cptr(String::new());
    }
    let read = |p: *const c_char| -> String {
        if p.is_null() {
            return String::new();
        }
        std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
    };
    let (ts, method, path) = (read(ts), read(method), read(path));
    if ts.is_empty() || method.is_empty() || path.is_empty() {
        return string_to_cptr(String::new());
    }

    // Vaqtni Dart beradi (u so'rov yuborishdan oldin oladi), qolgani
    // `sign_v2` bilan bir xil qoida.
    let Ok(mut mac) = hmac::Hmac::<sha2::Sha256>::new_from_slice(&app_secret()) else {
        return string_to_cptr(String::new());
    };
    hmac::Mac::update(&mut mac, format!("{ts}.{}.{path}", method.to_uppercase()).as_bytes());
    string_to_cptr(format!("v2.{ts}.{}", hex::encode(hmac::Mac::finalize(mac).into_bytes())))
}
