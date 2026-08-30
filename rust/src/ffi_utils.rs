// rust/src/ffi_utils.rs — FFI pointer/string yordamchi funksiyalari.
// Boshqa barcha modullar (cache, search, validate) shu faylni ishlatadi.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// C tomonidan kelgan pointer'ni Rust &str ga aylantiradi.
/// Null yoki noto'g'ri UTF-8 bo'lsa None qaytaradi (panic qilmaydi).
pub unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

/// Rust String'ni Dart'ga qaytarish uchun C pointer'ga aylantiradi.
pub fn string_to_cptr(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Rust qaytargan har qanday satrni Dart tomoni shu funksiya orqali
/// bo'shatishi SHART — aks holda xotira sizib chiqadi (memory leak).
#[no_mangle]
pub extern "C" fn rust_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}
