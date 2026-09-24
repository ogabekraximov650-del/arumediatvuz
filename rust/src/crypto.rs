// rust/src/crypto.rs — Ilova ma'lumotlarini shifrlash yadrosi.
//
// ═══════════════════════════════════════════════════════════════════
//  UMUMIY G'OYA
// ═══════════════════════════════════════════════════════════════════
//
// Ilova diskda ikki xil ma'lumot saqlaydi va ularning talablari
// BUTUNLAY BOSHQACHA:
//
//   1) KATTA VIDEO FAYLLAR — pleyer ularning O'RTASIDAN o'qishi kerak
//      (sek qilinganda). Ularni faqat butunlay ochib o'qib bo'lmaydi.
//      Shu sabab: AES-128-CBC.
//
//      Nega aynan CBC va nega 128 bit? Chunki shifrni BIZ emas,
//      FFmpeg'ning "crypto:" protokoli ochadi (pleyerning o'zida,
//      HTTP qatlamisiz). U esa faqat AES-128-CBC'ni biladi. CBC'da
//      fayl o'rtasidan o'qish mumkin: FFmpeg kerakli joydan oldingi
//      bitta 16-baytlik blokni o'qib, uni IV sifatida ishlatadi.
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

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use crate::ffi_utils::{cstr_to_str, string_to_cptr};

type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;
type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;

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

/// Shifrlangandan keyingi fayl hajmi (PKCS7 har doim to'ldirish
/// qo'shgani uchun har doim asl hajmdan katta). Har bir bo'lak
/// mustaqil PKCS7 bilan shifrlangani uchun ham shu formula amal
/// qiladi (pastga, BO'LAK shifrlashga qarang).
pub fn encrypted_size(plain_total: u64) -> u64 {
    (plain_total / 16 + 1) * 16
}

// ═══════════════════════════════════════════════════════════════════
//  BO'LAK (chunk) DARAJASIDA SHIFRLASH
// ═══════════════════════════════════════════════════════════════════
//
// Video diskda endi bitta uzluksiz CBC oqimi sifatida emas, balki
// alohida (video_cache.rs'dagi CHUNK_SIZE hajmidagi) fayllar sifatida
// keshlanadi — va ular foydalanuvchi sek qilganda TASODIFIY tartibda
// yuklanishi/o'qilishi mumkin. Shu sabab har bir bo'lak boshqalaridan
// MUSTAQIL, o'ziga xos kalit+IV bilan shifrlanadi (video darajasidagi
// bitta umumiy CBC zanjiriga bog'liq emas) — istalgan bo'lakni, qolgan
// bo'laklar hali yuklanmagan bo'lsa ham, mustaqil ochish mumkin.

/// Bitta bo'lak uchun kalit+IV — video darajasidagi kalitdan farqli
/// yorliq bilan (fayl nomi + bo'lak indeksi) hosil qilinadi.
pub fn derive_chunk_key_iv(label: &str, index: u64) -> Option<([u8; 16], [u8; 16])> {
    derive_video_key_iv(&format!("{label}:chunk:{index}"))
}

/// Bitta bo'lakni mustaqil shifrlaydi (bir yo'la — bo'laklar kichik,
/// odatda 100 KB, xotiraga muammosiz sig'adi).
pub fn encrypt_chunk(plain: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    Aes128CbcEnc::new(key.into(), iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain)
}

/// Mustaqil shifrlangan bo'lakni ochadi. Format noto'g'ri/buzilgan
/// bo'lsa (masalan eski, boshqa o'lchamdagi qoldiq fayl) `None`
/// qaytaradi — chaqiruvchi buni "keshda yo'q" deb talqin qilib,
/// bo'lakni qaytadan yuklab oladi.
pub fn decrypt_chunk(cipher: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Option<Vec<u8>> {
    Aes128CbcDec::new(key.into(), iv.into())
        .decrypt_padded_vec_mut::<Pkcs7>(cipher)
        .ok()
}

// ═══════════════════════════════════════════════════════════════════
//  KICHIK FAYLLAR: AES-256-GCM
// ═══════════════════════════════════════════════════════════════════
//
// Format: [12 bayt nonce][shifrlangan ma'lumot + 16 baytlik teg]

pub fn seal_blob(label: &str, plain: &[u8]) -> Option<Vec<u8>> {
    let key = derive_blob_key(label)?;
    let cipher = Aes256Gcm::new((&key).into());
    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes).ok()?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut out = nonce_bytes.to_vec();
    out.extend_from_slice(&cipher.encrypt(nonce, plain).ok()?);
    Some(out)
}

pub fn open_blob(label: &str, sealed: &[u8]) -> Option<Vec<u8>> {
    if sealed.len() < 12 + 16 {
        return None;
    }
    let key = derive_blob_key(label)?;
    let cipher = Aes256Gcm::new((&key).into());
    let nonce = Nonce::from_slice(&sealed[..12]);
    cipher.decrypt(nonce, &sealed[12..]).ok()
}

// ═══════════════════════════════════════════════════════════════════
//  TESTLAR
// ═══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
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
        eprintln!("AES-128-CBC: shifrlash {enc:.0} MB/s, ochish {dec:.0} MB/s");
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
        assert_ne!(cipher.len(), plain.len(), "PKCS7 to'ldirish qo'shilmagan");
        assert_eq!(cipher.len() % 16, 0);

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
