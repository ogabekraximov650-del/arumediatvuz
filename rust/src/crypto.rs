// rust/src/crypto.rs — Ilova ma'lumotlarini shifrlash yadrosi.
//
// ═══════════════════════════════════════════════════════════════════
//  UMUMIY G'OYA
// ═══════════════════════════════════════════════════════════════════
//
// Ilova diskda ikki xil ma'lumot saqlaydi va ularning talablari
// BUTUNLAY BOSHQACHA:
//
//   1) KATTA VIDEO FAYLLAR — 1 MiB lik mustaqil bo'laklar, har biri
//      AES-128-GCM (CTR rejimi + 16 baytlik yaxlitlik tegi) bilan.
//      Pastdagi "BO'LAK DARAJASIDA SHIFRLASH" izohiga qarang.
//
//   2) KICHIK FAYLLAR (epizod ro'yxati keshi, rasm keshi) — ular
//      har doim BUTUNLAY o'qiladi. Bu yerda AES-256-GCM eng to'g'ri
//      tanlov: u nafaqat yashiradi, balki fayl BUZILGANINI ham
//      aniqlaydi (autentifikatsiya tegi). CBC bunday tekshiruv
//      bermaydi.
//
// ═══════════════════════════════════════════════════════════════════
//  KALIT BOSHQARUVI
// ═══════════════════════════════════════════════════════════════════
//
//   Android Keystore (apparat himoyasi)
//        └── ASOSIY KALIT (32 bayt) — telefondan chiqmaydi
//              └── HKDF-SHA256 orqali har bir fayl uchun ALOHIDA kalit
//
// Asosiy kalit Dart tomonda `flutter_secure_storage` orqali saqlanadi
// (u Android'da Keystore bilan himoyalangan EncryptedSharedPreferences
// ishlatadi) va ilova ishga tushganda bir marta Rust'ga uzatiladi.
// Rust uni faqat XOTIRADA ushlab turadi — hech qachon diskka yozmaydi.
//
// Har bir fayl uchun kalit ASOSIY KALITDAN va fayl nomidan hosil
// qilinadi (HKDF). Bu ikki narsani beradi:
//   * bitta kalit hech qachon ikkita faylda qayta ishlatilmaydi;
//   * IV/kalitni alohida saqlash shart emas — ular fayl nomidan
//     har safar qayta hisoblanadi.

use hkdf::Hkdf;
use sha2::Sha256;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use crate::ffi_utils::{cstr_to_str, string_to_cptr};


/// Asovsiy kalit — FAQAT XOTIRADA. Diskka hech qachon yozilmaydi.
static MASTER_KEY: OnceLock<Mutex<Option<[u8; 32]>>> = OnceLock::new();

fn master_slot() -> &'static Mutex<Option<[u8; 32]>> {
    MASTER_KEY.get_or_init(|| Mutex::new(None))
}

/// Dart tomonidan ilova ishga tushganda bir marta chaqiriladi.
/// `hex` — 64 ta hex belgi (32 bayt).
pub fn set_master_key_hex(hex_str: &str) -> bool {
    let bytes = match hex::decode(hex_str.trim()) {
        Ok(b) => b,
        Err(_) => return false,
    };
    if bytes.len() != 32 {
        return false;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    *master_slot().lock().unwrap() = Some(key);
    true
}

/// Shifrlash yoqilganmi (asosiy kalit o'rnatilganmi)?
pub fn is_enabled() -> bool {
    master_slot().lock().unwrap().is_some()
}

fn master() -> Option<[u8; 32]> {
    *master_slot().lock().unwrap()
}

/// Yangi tasodifiy asosiy kalit hosil qiladi (hex satr sifatida).
/// Dart tomoni buni BIR MARTA chaqirib, natijani xavfsiz omborga
/// (flutter_secure_storage) saqlaydi.
pub fn generate_master_key_hex() -> String {
    let mut key = [0u8; 32];
    if getrandom::getrandom(&mut key).is_err() {
        return String::new();
    }
    hex::encode(key)
}

/// Bitta fayl uchun kalit va IV hosil qiladi.
///
/// `label` — fayl nomi (masalan "ep_1_2_720p_1788029552837.mp4").
/// Bir xil label har doim bir xil kalit beradi — shu sabab ularni
/// alohida saqlash shart emas.
///
/// Video uchun: 16 baytlik kalit (AES-128) + 16 baytlik IV.
pub fn derive_video_key_iv(label: &str) -> Option<([u8; 16], [u8; 16])> {
    let m = master()?;
    let hk = Hkdf::<Sha256>::new(Some(b"fulutter-video-v1"), &m);
    let mut out = [0u8; 32];
    hk.expand(label.as_bytes(), &mut out).ok()?;
    let mut key = [0u8; 16];
    let mut iv = [0u8; 16];
    key.copy_from_slice(&out[..16]);
    iv.copy_from_slice(&out[16..]);
    Some((key, iv))
}

/// Kichik fayllar (ro'yxat/rasm keshi) uchun 32 baytlik GCM kaliti.
fn derive_blob_key(label: &str) -> Option<[u8; 32]> {
    let m = master()?;
    let hk = Hkdf::<Sha256>::new(Some(b"fulutter-blob-v1"), &m);
    let mut out = [0u8; 32];
    hk.expand(label.as_bytes(), &mut out).ok()?;
    Some(out)
}

/// Bo'lak nonce'i (tasodifiy, fayl boshida saqlanadi).
const CHUNK_NONCE_LEN: usize = 12;
/// GCM yaxlitlik tegi (fayl oxirida).
const CHUNK_TAG_LEN: usize = 16;

/// Shifrlangan bo'lakning diskdagi hajmi: nonce + shifr + teg.
///
/// Hajm ASL hajmdan ANIQ farq qiladi — `video_cache` shifrlangan va
/// (kalit kechikkanda yozilgan) ochiq bo'lakni aynan hajmidan
/// ajratadi. Shu sabab toza CTR (hajmi o'zgarmaydi) yaramaydi.
pub fn encrypted_size(plain_total: u64) -> u64 {
    plain_total + (CHUNK_NONCE_LEN + CHUNK_TAG_LEN) as u64
}

// ═══════════════════════════════════════════════════════════════════
//  BO'LAK (chunk) DARAJASIDA SHIFRLASH — AES-128-GCM
// ═══════════════════════════════════════════════════════════════════
//
// Har bir bo'lak (video_cache.rs dagi CHUNK_SIZE) boshqalaridan
// MUSTAQIL, o'z kaliti bilan shifrlanadi — istalgan bo'lakni qolganlari
// hali yuklanmagan bo'lsa ham ochish mumkin.
//
// ── NEGA CBC EMAS (TOPILGAN XATO: yuklash tezligi) ─────────────────
//
// Ilgari AES-128-CBC edi (FFmpeg "crypto:" protokoli uchun; FFmpeg
// endi ishlatilmaydi — bo'laklarni faqat shu yadro ochadi). CBC da har
// bir blok OLDINGISINI kutadi, ya'ni protsessor bloklarni parallel
// ishlay olmaydi; apparat AES bo'lmasa (32-bit Android) juda sekin.
//
// GCM — bu CTR rejimi (bloklar MUSTAQIL, parallel) + 16 baytlik
// yaxlitlik tegi. `ring` (ilovada HTTPS uchun allaqachon bor) uni
// 64-bit da apparat AES bilan, 32-bit da NEON bilan bajaradi.
// Teg bonus beradi: buzilgan bo'lak aniqlanadi va qayta yuklanadi.
//
// Format: [12 bayt tasodifiy nonce][shifrlangan ma'lumot][16 bayt teg].
// Nonce har yozishda yangi — bir xil kalit+nonce hech qachon qayta
// ishlatilmaydi (bo'lak qayta yuklansa ham).

/// Bitta bo'lak uchun kalit — video darajasidagi kalitdan farqli
/// yorliq bilan (fayl nomi + bo'lak indeksi) hosil qilinadi.
/// (Ikkinchi qiymat — eski format IV'si, endi ishlatilmaydi.)
pub fn derive_chunk_key_iv(label: &str, index: u64) -> Option<([u8; 16], [u8; 16])> {
    derive_video_key_iv(&format!("{label}:chunk:{index}"))
}

fn chunk_cipher(key: &[u8; 16]) -> Option<ring::aead::LessSafeKey> {
    let k = ring::aead::UnboundKey::new(&ring::aead::AES_128_GCM, key).ok()?;
    Some(ring::aead::LessSafeKey::new(k))
}

/// Bitta bo'lakni shifrlaydi. `_iv` e'tiborsiz — nonce tasodifiy.
pub fn encrypt_chunk(plain: &[u8], key: &[u8; 16], _iv: &[u8; 16]) -> Vec<u8> {
    let mut nonce = [0u8; CHUNK_NONCE_LEN];
    let cipher = chunk_cipher(key);
    if getrandom::getrandom(&mut nonce).is_err() || cipher.is_none() {
        // Juda kam uchraydigan holat: bo'sh natija — chaqiruvchi
        // bo'lakni yozmaydi va keyinroq qaytadan yuklaydi.
        return Vec::new();
    }
    let cipher = cipher.unwrap();
    let mut out = Vec::with_capacity(plain.len() + CHUNK_NONCE_LEN + CHUNK_TAG_LEN);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(plain);
    let tag = cipher.seal_in_place_separate_tag(
        ring::aead::Nonce::assume_unique_for_key(nonce),
        ring::aead::Aad::empty(),
        &mut out[CHUNK_NONCE_LEN..],
    );
    match tag {
        Ok(t) => {
            out.extend_from_slice(t.as_ref());
            out
        }
        Err(_) => Vec::new(),
    }
}

/// Shifrlangan bo'lakni ochadi. Buzilgan yoki boshqa formatdagi
/// bo'lak uchun `None` — chaqiruvchi uni "keshda yo'q" deb bilib,
/// qaytadan yuklaydi.
pub fn decrypt_chunk(cipher: &[u8], key: &[u8; 16], _iv: &[u8; 16]) -> Option<Vec<u8>> {
    if cipher.len() < CHUNK_NONCE_LEN + CHUNK_TAG_LEN {
        return None;
    }
    let mut nonce = [0u8; CHUNK_NONCE_LEN];
    nonce.copy_from_slice(&cipher[..CHUNK_NONCE_LEN]);
    let mut buf = cipher[CHUNK_NONCE_LEN..].to_vec();
    let n = chunk_cipher(key)?
        .open_in_place(
            ring::aead::Nonce::assume_unique_for_key(nonce),
            ring::aead::Aad::empty(),
            &mut buf,
        )
        .ok()?
        .len();
    buf.truncate(n);
    Some(buf)
}

// ═══════════════════════════════════════════════════════════════════
//  KICHIK FAYLLAR: AES-256-GCM
// ═══════════════════════════════════════════════════════════════════
//
// Format: [12 bayt nonce][shifrlangan ma'lumot + 16 baytlik teg]

pub fn seal_blob(label: &str, plain: &[u8]) -> Option<Vec<u8>> {
    let key = derive_blob_key(label)?;
    let cipher = blob_cipher(&key)?;
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce).ok()?;
    let mut out = Vec::with_capacity(12 + plain.len() + 16);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(plain);
    let tag = cipher
        .seal_in_place_separate_tag(
            ring::aead::Nonce::assume_unique_for_key(nonce),
            ring::aead::Aad::empty(),
            &mut out[12..],
        )
        .ok()?;
    out.extend_from_slice(tag.as_ref());
    Some(out)
}

pub fn open_blob(label: &str, sealed: &[u8]) -> Option<Vec<u8>> {
    if sealed.len() < 12 + 16 {
        return None;
    }
    let key = derive_blob_key(label)?;
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&sealed[..12]);
    let mut buf = sealed[12..].to_vec();
    let n = blob_cipher(&key)?
        .open_in_place(
            ring::aead::Nonce::assume_unique_for_key(nonce),
            ring::aead::Aad::empty(),
            &mut buf,
        )
        .ok()?
        .len();
    buf.truncate(n);
    Some(buf)
}

/// Kichik fayllar shifri: AES-256-GCM (`ring`). Format o'zgarmagan —
/// `[12 bayt nonce][shifr][16 bayt teg]`, ya'ni ilgari (`aes-gcm`
/// kutubxonasi bilan) yozilgan fayllar ham ochiladi.
fn blob_cipher(key: &[u8; 32]) -> Option<ring::aead::LessSafeKey> {
    let k = ring::aead::UnboundKey::new(&ring::aead::AES_256_GCM, key).ok()?;
    Some(ring::aead::LessSafeKey::new(k))
}

// ═══════════════════════════════════════════════════════════════════
//  TESTLAR
// ═══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    /// Ikkilik FFI: muhrlash -> ochish -> bo'shatish.
    #[test]
    fn baytlar_ffi_orqali_muhrlanadi() {
        with_key();
        let label = std::ffi::CString::new("img:abc").unwrap();
        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 253) as u8).collect();
        let mut n = 0usize;
        let sealed = super::rust_seal_bytes(label.as_ptr(), data.as_ptr(), data.len(), &mut n);
        assert!(!sealed.is_null());
        assert_eq!(n, data.len() + 28);
        let mut m = 0usize;
        let opened = super::rust_open_bytes(label.as_ptr(), sealed, n, &mut m);
        assert!(!opened.is_null());
        let back = unsafe { std::slice::from_raw_parts(opened, m) }.to_vec();
        assert_eq!(back, data);
        // Ochiq (shifrlanmagan) ma'lumot — ochilmaydi.
        let raw = super::rust_open_bytes(label.as_ptr(), data.as_ptr(), data.len(), &mut m);
        assert!(raw.is_null());
        super::rust_free_bytes(sealed, n);
        super::rust_free_bytes(opened, back.len());
    }


    /// Bo'lak shifri: hajm, ochilish va buzilishni aniqlash.
    #[test]
    fn bolak_gcm_buzilganini_aniqlaydi() {
        let key = [9u8; 16];
        let plain = vec![5u8; 1024 * 1024];
        let c = super::encrypt_chunk(&plain, &key, &[0u8; 16]);
        assert_eq!(c.len() as u64, super::encrypted_size(plain.len() as u64));
        assert_ne!(c.len(), plain.len(), "shifrlangan va ochiq bo'lak hajmi farq qilishi SHART");
        assert_eq!(super::decrypt_chunk(&c, &key, &[0u8; 16]).as_deref(), Some(&plain[..]));
        // Har yozishda yangi nonce — bir xil ma'lumot ham boshqacha shifr.
        let c2 = super::encrypt_chunk(&plain, &key, &[0u8; 16]);
        assert_ne!(c, c2);
        // Bitta bayt buzilsa — ochilmaydi.
        let mut bad = c.clone();
        bad[500] ^= 1;
        assert!(super::decrypt_chunk(&bad, &key, &[0u8; 16]).is_none());
        // Boshqa kalit — ochilmaydi.
        assert!(super::decrypt_chunk(&c, &[8u8; 16], &[0u8; 16]).is_none());
    }

    /// Qo'lda o'lchov: `cargo test --release -- --ignored shifr_tezligi --nocapture`
    #[test]
    #[ignore]
    fn shifr_tezligi() {
        let plain = vec![7u8; 1024 * 1024];
        let key = [1u8; 16];
        let iv = [2u8; 16];
        let n = 64;
        let t = std::time::Instant::now();
        for _ in 0..n {
            std::hint::black_box(super::encrypt_chunk(&plain, &key, &iv));
        }
        let enc = n as f64 / t.elapsed().as_secs_f64();
        let c = super::encrypt_chunk(&plain, &key, &iv);
        let t = std::time::Instant::now();
        for _ in 0..n {
            std::hint::black_box(super::decrypt_chunk(&c, &key, &iv));
        }
        let dec = n as f64 / t.elapsed().as_secs_f64();
        eprintln!("bo'lak shifri: shifrlash {enc:.0} MB/s, ochish {dec:.0} MB/s");
    }

    use super::*;

    /// DIQQAT: testlar bitta jarayonda PARALLEL ishlaydi, asosiy kalit
    /// esa global. Shu sabab har bir test TASODIFIY kalit o'rnatsa,
    /// ular bir-birining kalitini almashtirib yuboradi va natijalar
    /// chalkashadi. Testlarda QAT'IY (o'zgarmas) kalit ishlatiladi.
    fn with_key() {
        assert!(set_master_key_hex(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        ));
    }

    #[test]
    fn asosiy_kalit_tasodifiy_va_togri_uzunlikda() {
        let a = generate_master_key_hex();
        let b = generate_master_key_hex();
        assert_eq!(a.len(), 64, "32 bayt = 64 hex belgi bo'lishi kerak");
        assert_ne!(a, b, "kalit tasodifiy emas");
        assert!(hex::decode(&a).is_ok());
        // Noto'g'ri uzunlik qabul qilinmasligi kerak.
        assert!(!set_master_key_hex("00112233"));
        assert!(!set_master_key_hex("bu hex emas"));
    }

    /// Kutilayotgan kirish tokeni diskda MUHRLANGAN holda yotadi va
    /// qaytib o'qilganda aynan o'zi chiqadi.
    ///
    /// Nega muhim: ilova Telegramga o'tganda Android uni yopib
    /// qo'yishi mumkin. Token faqat xotirada bo'lsa kirish uzilib
    /// qoladi va har bir yangi urinish serverda YANGI sessiya
    /// ochadi. Bu test o'sha yo'lni qo'riqlaydi.
    #[test]
    fn maxfiy_fayl_yoziladi_va_qaytib_ochiladi() {
        use std::ffi::CString;
        with_key();

        let dir = std::env::temp_dir().join(format!("aru_secure_{}", now_test_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pending_login.bin");
        let p = CString::new(path.to_string_lossy().to_string()).unwrap();
        let label = CString::new("pending_login").unwrap();
        let text = CString::new(r#"{"token":"abc123","deep_link":"https://t.me/bot?start=abc123"}"#).unwrap();

        assert_eq!(rust_secure_save(p.as_ptr(), label.as_ptr(), text.as_ptr()), 1);

        // Diskdagi fayl OCHIQ MATN bo'lmasligi shart.
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !String::from_utf8_lossy(&raw).contains("abc123"),
            "token diskda ochiq matnda yotibdi"
        );

        // O'qib qaytarsak — aynan o'sha matn.
        let got = unsafe { CString::from_raw(rust_secure_load(p.as_ptr(), label.as_ptr())) };
        assert_eq!(got.to_str().unwrap(), text.to_str().unwrap());

        // Boshqa yorliq bilan ochilmasligi kerak (kalit har bir
        // fayl uchun alohida hosil qilinadi).
        let other = CString::new("boshqa_yorliq").unwrap();
        let bad = unsafe { CString::from_raw(rust_secure_load(p.as_ptr(), other.as_ptr())) };
        assert_eq!(bad.to_str().unwrap(), "");

        // O'chirish, keyin yo'q faylni o'chirish ham xato emas.
        assert_eq!(rust_secure_clear(p.as_ptr()), 1);
        assert_eq!(rust_secure_clear(p.as_ptr()), 1);
        let gone = unsafe { CString::from_raw(rust_secure_load(p.as_ptr(), label.as_ptr())) };
        assert_eq!(gone.to_str().unwrap(), "");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Testlar parallel ishlaydi — har biriga o'z papkasi kerak.
    fn now_test_id() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    #[test]
    fn har_bir_fayl_uchun_alohida_kalit() {
        with_key();
        let a = derive_video_key_iv("bir.mp4").unwrap();
        let b = derive_video_key_iv("ikki.mp4").unwrap();
        assert_ne!(a.0, b.0, "ikki fayl bir xil kalit oldi");
        assert_ne!(a.1, b.1, "ikki fayl bir xil IV oldi");
        // Bir xil nom — bir xil kalit (qayta hisoblab olish uchun).
        let a2 = derive_video_key_iv("bir.mp4").unwrap();
        assert_eq!(a, a2);
    }

    #[test]
    fn bolak_mustaqil_shifrlanadi_va_ochiladi() {
        with_key();
        let (k0, iv0) = derive_chunk_key_iv("video.mp4", 0).unwrap();
        let (k5, iv5) = derive_chunk_key_iv("video.mp4", 5).unwrap();
        // Har bir bo'lak (indeks) o'ziga xos kalit/IV oladi — video
        // darajasidagi kalitdan ham FARQLI.
        let (video_key, video_iv) = derive_video_key_iv("video.mp4").unwrap();
        assert_ne!(k0, k5, "ikki bo'lak bir xil kalit oldi");
        assert_ne!((k0, iv0), (video_key, video_iv), "bo'lak kaliti video kaliti bilan bir xil");

        let plain: Vec<u8> = (0..100_000usize).map(|i| (i % 251) as u8).collect();
        let cipher = encrypt_chunk(&plain, &k0, &iv0);
        assert_ne!(cipher.len(), plain.len(), "nonce va teg qo'shilmagan");
        assert_eq!(cipher.len() as u64, encrypted_size(plain.len() as u64));

        let opened = decrypt_chunk(&cipher, &k0, &iv0).unwrap();
        assert_eq!(opened, plain);

        // Boshqa bo'lak (indeks) kaliti bilan ochib bo'lmasligi kerak.
        assert_ne!(decrypt_chunk(&cipher, &k5, &iv5), Some(plain));

        // Bo'laklar bir-biridan MUSTAQIL: 5-bo'lak 0-bo'lak hali
        // yo'q bo'lsa ham mustaqil ochilishi kerak (haqiqiy zanjir
        // bog'liqligi yo'q).
        let plain5: Vec<u8> = (0..50_000usize).map(|i| ((i * 3) % 251) as u8).collect();
        let cipher5 = encrypt_chunk(&plain5, &k5, &iv5);
        assert_eq!(decrypt_chunk(&cipher5, &k5, &iv5).unwrap(), plain5);
    }

    #[test]
    fn kichik_fayl_gcm_va_buzilganini_aniqlash() {
        with_key();
        let data = b"{\"epizodlar\":[1,2,3]}";
        let sealed = seal_blob("eps_1_2", data).unwrap();
        assert_ne!(&sealed[12..], &data[..], "shifrlanmagan");
        assert_eq!(open_blob("eps_1_2", &sealed).unwrap(), data);

        // Boshqa yorliq bilan ochilmasligi kerak.
        assert!(open_blob("boshqa", &sealed).is_none());

        // Bitta bayt o'zgartirilsa — aniqlanishi kerak.
        let mut buzuq = sealed.clone();
        let n = buzuq.len() - 1;
        buzuq[n] ^= 1;
        assert!(open_blob("eps_1_2", &buzuq).is_none(), "buzilgan fayl aniqlanmadi");
    }
}

// ═══════════════════════════════════════════════════════════════════
//  FFI — Dart tomoni bilan bog'lanish
// ═══════════════════════════════════════════════════════════════════

/// Yangi tasodifiy asosiy kalit (64 ta hex belgi).
///
/// Dart tomoni buni FAQAT BIR MARTA, ilova birinchi ishga
/// tushganda chaqiradi va natijani `flutter_secure_storage` ga
/// saqlaydi (u Android'da Keystore bilan himoyalangan). Keyingi
/// ishga tushishlarda kalit o'sha yerdan o'qib, `rust_crypto_set_key`
/// orqali qaytariladi.
#[no_mangle]
pub extern "C" fn rust_crypto_generate_key() -> *mut c_char {
    string_to_cptr(generate_master_key_hex())
}

/// Asosiy kalitni o'rnatadi. 1 — muvaffaqiyat, 0 — xato.
/// Bu chaqirilmaguncha shifrlash O'CHIQ bo'ladi va hamma narsa
/// avvalgidek ochiq saqlanadi (eski o'rnatmalar buzilmasligi uchun).
#[no_mangle]
pub extern "C" fn rust_crypto_set_key(hex_ptr: *const c_char) -> i32 {
    match unsafe { cstr_to_str(hex_ptr) } {
        Some(h) if set_master_key_hex(h) => 1,
        _ => 0,
    }
}

/// Shifrlash yoqilganmi (1/0) — diagnostika uchun.
#[no_mangle]
pub extern "C" fn rust_crypto_is_enabled() -> i32 {
    if is_enabled() { 1 } else { 0 }
}

// ═══════════════════════════════════════════════════════════════════
//  MAXFIY KICHIK FAYL (AES-256-GCM)
// ═══════════════════════════════════════════════════════════════════
//
// NIMA UCHUN. Telegram orqali kirishda ilova serverdan bir martalik
// token oladi va foydalanuvchi Telegramga o'tadi. Xotirasi kam
// telefonlarda Android bu paytda ilovani BUTUNLAY yopib qo'yishi
// mumkin — token esa faqat xotirada edi va yo'qolardi. Foydalanuvchi
// qaytganda kirish tugamagan bo'lardi, u qaytadan urinardi va HAR BIR
// urinish serverda YANGI sessiya ochardi (foydalanuvchi bir marta ham
// kira olmagani holda "Qurilmalar" ro'yxatida 4 ta sessiya paydo
// bo'lgani shundan).
//
// Endi token diskka — AES-256-GCM bilan MUHRLANGAN faylga yoziladi.
// Kalit `crypto` modulining asosiy kalitidan (Android Keystore bilan
// himoyalangan) HKDF orqali olinadi, ya'ni fayl boshqa qurilmada ham,
// ilovadan tashqarida ham ochilmaydi.
//
// GCM tanlangani sabab: fayl har doim BUTUNLAY o'qiladi va GCM
// maxfiylikdan tashqari BUTUNLIK tekshiruvini ham beradi — buzilgan
// yoki almashtirilgan fayl darhol "yaroqsiz" deb qaraladi.
//
// MUHIM QOIDA: shifrlash o'chiq bo'lsa (asosiy kalit hali
// o'rnatilmagan) fayl UMUMAN YOZILMAYDI. Sessiya tokenini ochiq
// matnda diskka yozgandan ko'ra, kutilayotgan kirishni yo'qotgan
// yaxshi.

/// Maxfiy matnni AES-256-GCM bilan muhrlab faylga yozadi.
// ── IKKILIK MA'LUMOT (rasmlar va boshqa fayllar) ──────────────────
//
// TALAB (foydalanuvchi): "diskda saqlanadigan HAMMA narsa shifrlansin".
// `rust_secure_save` faqat MATN qabul qiladi — rasmni base64 ga
// o'girish uni 33% kattalashtirar va sekinlashtirardi. Bu ikki
// funksiya baytlarni to'g'ridan-to'g'ri muhrlaydi/ochadi (AES-256-GCM,
// `seal_blob` bilan bir xil format). Natija Rust xotirasida ajratiladi
// va chaqiruvchi uni `rust_free_bytes` bilan bo'shatadi.

fn bytes_out(v: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    let boxed = v.into_boxed_slice();
    let len = boxed.len();
    if !out_len.is_null() {
        unsafe { *out_len = len };
    }
    Box::into_raw(boxed) as *mut u8
}

/// Baytlarni muhrlaydi. Xato bo'lsa (kalit yo'q) — null.
#[no_mangle]
pub extern "C" fn rust_seal_bytes(
    label_ptr: *const c_char,
    data_ptr: *const u8,
    len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let Some(label) = (unsafe { cstr_to_str(label_ptr) }) else {
        return std::ptr::null_mut();
    };
    if data_ptr.is_null() && len > 0 {
        return std::ptr::null_mut();
    }
    let data: &[u8] = if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data_ptr, len) }
    };
    match seal_blob(label, data) {
        Some(v) => bytes_out(v, out_len),
        None => std::ptr::null_mut(),
    }
}

/// Muhrlangan baytlarni ochadi. Buzilgan, boshqa kalit yoki ochiq
/// (eski) ma'lumot bo'lsa — null.
#[no_mangle]
pub extern "C" fn rust_open_bytes(
    label_ptr: *const c_char,
    data_ptr: *const u8,
    len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let Some(label) = (unsafe { cstr_to_str(label_ptr) }) else {
        return std::ptr::null_mut();
    };
    if data_ptr.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let data = unsafe { std::slice::from_raw_parts(data_ptr, len) };
    match open_blob(label, data) {
        Some(v) => bytes_out(v, out_len),
        None => std::ptr::null_mut(),
    }
}

/// `rust_seal_bytes`/`rust_open_bytes` natijasini bo'shatadi.
#[no_mangle]
pub extern "C" fn rust_free_bytes(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

/// 1 — muvaffaqiyat, 0 — xato (jumladan shifrlash o'chiq bo'lsa).
#[no_mangle]
pub extern "C" fn rust_secure_save(
    path_ptr: *const c_char,
    label_ptr: *const c_char,
    text_ptr: *const c_char,
) -> i32 {
    let (Some(path), Some(label), Some(text)) = (
        unsafe { cstr_to_str(path_ptr) },
        unsafe { cstr_to_str(label_ptr) },
        unsafe { cstr_to_str(text_ptr) },
    ) else {
        return 0;
    };
    let Some(sealed) = seal_blob(label, text.as_bytes()) else {
        return 0;
    };
    // Avval vaqtinchalik faylga, keyin almashtirish (atom amal) —
    // yozish yarmida uzilsa yarim fayl qolib ketmasin.
    let tmp = format!("{path}.tmp");
    if std::fs::write(&tmp, &sealed).is_err() {
        return 0;
    }
    match std::fs::rename(&tmp, path) {
        Ok(_) => 1,
        Err(_) => {
            let _ = std::fs::remove_file(&tmp);
            0
        }
    }
}

/// Muhrlangan fayldan matnni o'qiydi. Fayl yo'q, buzilgan yoki
/// boshqa kalit bilan yozilgan bo'lsa — bo'sh satr qaytadi.
#[no_mangle]
pub extern "C" fn rust_secure_load(
    path_ptr: *const c_char,
    label_ptr: *const c_char,
) -> *mut c_char {
    let (Some(path), Some(label)) = (
        unsafe { cstr_to_str(path_ptr) },
        unsafe { cstr_to_str(label_ptr) },
    ) else {
        return string_to_cptr(String::new());
    };
    let text = std::fs::read(path)
        .ok()
        .and_then(|raw| open_blob(label, &raw))
        .and_then(|plain| String::from_utf8(plain).ok())
        .unwrap_or_default();
    string_to_cptr(text)
}

/// Faylni o'chiradi. Fayl allaqachon yo'q bo'lsa ham 1 qaytadi.
#[no_mangle]
pub extern "C" fn rust_secure_clear(path_ptr: *const c_char) -> i32 {
    let Some(path) = (unsafe { cstr_to_str(path_ptr) }) else {
        return 0;
    };
    let _ = std::fs::remove_file(format!("{path}.tmp"));
    match std::fs::remove_file(path) {
        Ok(_) => 1,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => 1,
        Err(_) => 0,
    }
}
