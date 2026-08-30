// rust/src/validate.rs — Forma validatsiyasi mexanizmi.

use crate::ffi_utils::cstr_to_str;
use std::os::raw::c_char;

/// Anime formasi to'ldirilganini tekshiradi (barcha maydonlar bo'sh emas).
/// 1 — to'g'ri, 0 — kamida bitta maydon bo'sh.
#[no_mangle]
pub extern "C" fn rust_validate_anime_form(
    name_ptr: *const c_char,
    davlat_ptr: *const c_char,
    studiya_ptr: *const c_char,
    janri_ptr: *const c_char,
    tavsif_ptr: *const c_char,
) -> i32 {
    let fields = [name_ptr, davlat_ptr, studiya_ptr, janri_ptr, tavsif_ptr];
    for f in fields {
        match unsafe { cstr_to_str(f) } {
            Some(s) if !s.trim().is_empty() => continue,
            _ => return 0,
        }
    }
    1
}
