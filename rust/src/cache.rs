// rust/src/cache.rs — Lokal fayl-kesh mexanizmi (SQLite o'rniga).
//
// Muhim qoida: kesh MUDDATI faqat "internet bor bo'lganda fon-yangilash
// kerakmi?" degan savolga javob beradi. Offline holatda kesh HECH QACHON
// "eskirgan" deb hisoblanmasligi kerak — foydalanuvchi qancha vaqt
// internetsiz yursa ham, oxirgi ma'lumot ko'rsatilaveradi.
//
// Shu sabab ikkita funksiya bor:
//   rust_cache_get    — muddatidan qat'iy nazar, bor ma'lumotni qaytaradi
//   rust_cache_is_fresh — faqat "hozir fon-yangilash kerakmi" savoli uchun

use crate::ffi_utils::{cstr_to_str, string_to_cptr};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::os::raw::c_char;
use std::time::{SystemTime, UNIX_EPOCH};

const CACHE_TTL_MS: u64 = 5 * 60 * 1000; // 5 daqiqa — faqat fon-yangilash uchun

#[derive(Serialize, Deserialize)]
struct CacheEnvelope {
    saved_at_ms: u64,
    data: Value,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn read_envelope(path: &str) -> Option<CacheEnvelope> {
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Keshdan o'qiydi. Fayl yo'q yoki buzilgan bo'lsagina null qaytaradi —
/// MUDDATI TEKSHIRILMAYDI, offline holatda ham har doim ko'rsatiladi.
#[no_mangle]
pub extern "C" fn rust_cache_get(path_ptr: *const c_char) -> *mut c_char {
    let path = match unsafe { cstr_to_str(path_ptr) } {
        Some(p) => p,
        None => return std::ptr::null_mut(),
    };
    match read_envelope(path) {
        Some(envelope) => string_to_cptr(envelope.data.to_string()),
        None => std::ptr::null_mut(),
    }
}

/// Kesh "yangi" (5 daqiqadan yosh) bo'lsa 1, aks holda (yoki fayl yo'q
/// bo'lsa) 0 qaytaradi. Faqat online holatda "qayta so'rov kerakmi"ni
/// hal qilish uchun ishlatiladi — offline'da bu funksiya e'tiborga
/// olinmasligi kerak.
#[no_mangle]
pub extern "C" fn rust_cache_is_fresh(path_ptr: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(path_ptr) } {
        Some(p) => p,
        None => return 0,
    };
    match read_envelope(path) {
        Some(envelope) => {
            let age = now_ms().saturating_sub(envelope.saved_at_ms);
            if age <= CACHE_TTL_MS { 1 } else { 0 }
        }
        None => 0,
    }
}

/// Ma'lumotni keshga (diskka) yozadi, joriy vaqt bilan birga.
/// Muvaffaqiyatli bo'lsa 1, xato bo'lsa 0 qaytaradi.
#[no_mangle]
pub extern "C" fn rust_cache_save(path_ptr: *const c_char, json_ptr: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(path_ptr) } {
        Some(p) => p,
        None => return 0,
    };
    let json_str = match unsafe { cstr_to_str(json_ptr) } {
        Some(s) => s,
        None => return 0,
    };

    let data: Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => return 0,
    };

    let envelope = CacheEnvelope { saved_at_ms: now_ms(), data };
    let serialized = match serde_json::to_string(&envelope) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    match fs::write(path, serialized) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}

/// Keshni butunlay o'chiradi (majburiy yangilash — pull-to-refresh uchun).
#[no_mangle]
pub extern "C" fn rust_cache_clear(path_ptr: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(path_ptr) } {
        Some(p) => p,
        None => return 0,
    };
    match fs::remove_file(path) {
        Ok(_) => 1,
        Err(_) => 1, // fayl allaqachon yo'q bo'lsa ham "muvaffaqiyat"
    }
}
