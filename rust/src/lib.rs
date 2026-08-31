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
mod video_cache;

use ffi_utils::string_to_cptr;
use std::os::raw::c_char;

/// Rust yadrosi versiyasi (diagnostika uchun, masalan Profil ekranida).
#[no_mangle]
pub extern "C" fn rust_core_version() -> *mut c_char {
    string_to_cptr("rust_core 0.1.0".to_string())
}
