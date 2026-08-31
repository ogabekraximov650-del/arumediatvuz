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

// ═══════════════════════════════════════════════════════════════════
//  VIDEO: AES-128-CBC
// ═══════════════════════════════════════════════════════════════════

/// To'liq video faylni bir yo'la shifrlaydi (PKCS7 to'ldirish bilan).
/// FFmpeg'ning "crypto:" protokoli aynan shu formatni kutadi.
///
/// Ishlab chiqarishda `VideoEncryptor` (oqim bilan) ishlatiladi —
/// bu funksiya oqim natijasi TO'G'RI ekanini tekshiradigan test
/// uchun etalon sifatida qoladi.
#[cfg(test)]
pub fn encrypt_video(plain: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    Aes128CbcEnc::new(key.into(), iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain)
}

/// OQIM BILAN shifrlash — katta fayllarni xotiraga to'liq
/// yuklamasdan shifrlash uchun.
///
/// NEGA KERAK: bir soatlik film 1 GB bo'lishi mumkin. Uni butunlay
/// xotiraga o'qib shifrlash telefonni o'ldiradi. Bu tuzilma
/// ma'lumotni bo'lak-bo'lak (bizda 1 MiB) qabul qiladi va CBC
/// zanjirini uzluksiz davom ettiradi.
pub struct VideoEncryptor {
    enc: Aes128CbcEnc,
    /// 16 baytga to'lmagan qoldiq.
    tail: Vec<u8>,
}

impl VideoEncryptor {
    pub fn new(key: &[u8; 16], iv: &[u8; 16]) -> Self {
        Self {
            enc: Aes128CbcEnc::new(key.into(), iv.into()),
            tail: Vec::with_capacity(16),
        }
    }

    /// Navbatdagi bo'lakni shifrlaydi. 16 ga to'lmagan qoldiq keyingi
    /// chaqiruvga saqlanadi.
    pub fn update(&mut self, data: &[u8]) -> Vec<u8> {
        use aes::cipher::generic_array::GenericArray;
        let mut buf = std::mem::take(&mut self.tail);
        buf.extend_from_slice(data);
        let full = (buf.len() / 16) * 16;
        self.tail = buf[full..].to_vec();
        buf.truncate(full);
        for block in buf.chunks_exact_mut(16) {
            self.enc.encrypt_block_mut(GenericArray::from_mut_slice(block));
        }
        buf
    }

    /// Yakunlaydi: qoldiqqa PKCS7 to'ldirish qo'shib shifrlaydi.
    /// PKCS7 HAR DOIM to'ldirish qo'shadi — qoldiq bo'sh bo'lsa ham
    /// to'liq bitta blok qo'shiladi (FFmpeg aynan shuni kutadi).
    pub fn finish(mut self) -> Vec<u8> {
        use aes::cipher::generic_array::GenericArray;
        let pad = 16 - self.tail.len();
        let mut block = self.tail.clone();
        block.resize(16, pad as u8);
        self.enc.encrypt_block_mut(GenericArray::from_mut_slice(&mut block));
        block
    }
}

/// Shifrlangandan keyingi fayl hajmi (PKCS7 har doim to'ldirish
/// qo'shgani uchun har doim asl hajmdan katta).
pub fn encrypted_size(plain_total: u64) -> u64 {
    (plain_total / 16 + 1) * 16
}

/// Shifrlangan video faylning ISTALGAN OG'IRLIGIDAGI qismini ochadi.
///
/// Bu funksiya zaxira yo'l (mahalliy HTTP proksi) uchun: agar biror
/// sababdan "crypto:" protokoli ishlamasa, biz baytlarni o'zimiz
/// ochib, pleyerga ochiq holda uzatamiz.
///
/// CBC'da N-blokni ochish uchun (N-1)-blok kerak, shu sabab kerakli
/// joydan bitta blok oldindan boshlaymiz.
pub fn decrypt_video_range(
    cipher: &[u8],
    key: &[u8; 16],
    iv: &[u8; 16],
    plain_start: u64,
    plain_len: usize,
    total_plain: u64,
) -> Option<Vec<u8>> {
    const B: u64 = 16;
    if plain_start >= total_plain {
        return Some(Vec::new());
    }
    let want_end = (plain_start + plain_len as u64).min(total_plain);
    // Ochish blok chegarasidan boshlanishi kerak.
    let block_start = (plain_start / B) * B;
    // Oldingi blok IV vazifasini bajaradi (birinchi blokda esa asl IV).
    let (chunk_iv, read_from) = if block_start == 0 {
        (*iv, 0u64)
    } else {
        let prev = (block_start - B) as usize;
        let mut v = [0u8; 16];
        v.copy_from_slice(cipher.get(prev..prev + 16)?);
        (v, block_start)
    };
    // Oxirigacha (yoki kerakli joygacha) blok chegarasiga tekislab olamiz.
    let block_end = ((want_end + B - 1) / B) * B;
    let is_tail = block_end >= total_plain;
    let cipher_end = if is_tail {
        cipher.len()
    } else {
        (block_end as usize).min(cipher.len())
    };
    let slice = cipher.get(read_from as usize..cipher_end)?;

    let dec = Aes128CbcDec::new(key.into(), (&chunk_iv).into());
    let plain = if is_tail {
        // Oxirgi qism — PKCS7 to'ldirishi olib tashlanadi.
        dec.decrypt_padded_vec_mut::<Pkcs7>(slice).ok()?
    } else {
        // O'rta qism — to'ldirish yo'q, blokma-blok ochiladi.
        let mut buf = slice.to_vec();
        use aes::cipher::BlockDecryptMut as _;
        let mut d = Aes128CbcDec::new(key.into(), (&chunk_iv).into());
        {
            use aes::cipher::generic_array::GenericArray;
            for block in buf.chunks_exact_mut(16) {
                let b = GenericArray::from_mut_slice(block);
                d.decrypt_block_mut(b);
            }
        }
        let _ = dec;
        buf
    };
    let offset = (plain_start - read_from) as usize;
    let end = (offset + (want_end - plain_start) as usize).min(plain.len());
    if offset > end {
        return Some(Vec::new());
    }
    Some(plain[offset..end].to_vec())
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

    #[test]
    fn video_shifrlash_va_istalgan_joydan_ochish() {
        with_key();
        let (key, iv) = derive_video_key_iv("ep_1_720p.mp4").unwrap();

        // 100 003 bayt — ataylab 16 ga bo'linmaydigan hajm.
        let total = 100_003usize;
        let plain: Vec<u8> = (0..total).map(|i| (i % 251) as u8).collect();
        let cipher = encrypt_video(&plain, &key, &iv);
        // PKCS7 to'ldirishi bilan hajm 16 ga karrali bo'lishi kerak.
        assert_eq!(cipher.len() % 16, 0);
        assert!(cipher.len() > total);

        // Turli joylardan o'qib, asl bilan solishtiramiz —
        // ayniqsa blok chegarasiga tushmaydigan joylardan.
        for (start, len) in [
            (0usize, 100usize),
            (1, 31),
            (15, 2),
            (16, 16),
            (12_345, 5_000),
            (99_000, 1_003),      // oxirigacha
            (total - 1, 1),       // eng oxirgi bayt
        ] {
            let got = decrypt_video_range(
                &cipher, &key, &iv, start as u64, len, total as u64,
            )
            .unwrap_or_else(|| panic!("ochib bo'lmadi: {start}+{len}"));
            assert_eq!(got, &plain[start..start + len], "noto'g'ri: {start}+{len}");
        }
    }

    #[test]
    fn oqim_bilan_shifrlash_bir_martalik_bilan_bir_xil() {
        with_key();
        let (key, iv) = derive_video_key_iv("oqim.mp4").unwrap();
        let total = 3 * 1024 * 1024 + 12_345usize; // bir necha bo'lak + qoldiq
        let plain: Vec<u8> = (0..total).map(|i| (i % 251) as u8).collect();

        let one_shot = encrypt_video(&plain, &key, &iv);

        // Endi xuddi shu narsani 1 MiB'lik bo'laklar bilan.
        let mut enc = VideoEncryptor::new(&key, &iv);
        let mut streamed = Vec::new();
        for part in plain.chunks(1024 * 1024) {
            streamed.extend_from_slice(&enc.update(part));
        }
        streamed.extend_from_slice(&enc.finish());

        assert_eq!(streamed.len(), one_shot.len(), "hajm mos emas");
        assert_eq!(streamed, one_shot, "oqim natijasi boshqacha");
        assert_eq!(streamed.len() as u64, encrypted_size(total as u64));

        // Va oqim natijasidan ham to'g'ri o'qish mumkin bo'lishi kerak.
        let got = decrypt_video_range(&streamed, &key, &iv, 2_000_000, 4096, total as u64).unwrap();
        assert_eq!(got, &plain[2_000_000..2_004_096]);
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
