// rust/src/search.rs — Qidiruv va janr bo'yicha filtrlash mexanizmi.

use crate::ffi_utils::{cstr_to_str, string_to_cptr};
use serde_json::Value;
use std::os::raw::c_char;

/// Anime ro'yxatini (JSON massiv) `name` maydoni bo'yicha, katta-kichik
/// harfga sezgir bo'lmagan holda filtrlaydi.
#[no_mangle]
pub extern "C" fn rust_search_filter(
    list_json_ptr: *const c_char,
    query_ptr: *const c_char,
) -> *mut c_char {
    let list_json = match unsafe { cstr_to_str(list_json_ptr) } {
        Some(s) => s,
        None => return string_to_cptr("[]".to_string()),
    };
    let query = match unsafe { cstr_to_str(query_ptr) } {
        Some(s) => s.to_lowercase(),
        None => return string_to_cptr("[]".to_string()),
    };

    let list: Vec<Value> = match serde_json::from_str(list_json) {
        Ok(v) => v,
        Err(_) => return string_to_cptr("[]".to_string()),
    };

    if query.trim().is_empty() {
        return string_to_cptr("[]".to_string());
    }

    let filtered: Vec<&Value> = list
        .iter()
        .filter(|item| {
            item.get("name")
                .and_then(|n| n.as_str())
                .map(|name| name.to_lowercase().contains(&query))
                .unwrap_or(false)
        })
        .collect();

    string_to_cptr(serde_json::to_string(&filtered).unwrap_or_else(|_| "[]".to_string()))
}

/// Anime ro'yxatini `janri` maydoni bo'yicha aniq (exact match) filtrlaydi.
#[no_mangle]
pub extern "C" fn rust_filter_by_genre(
    list_json_ptr: *const c_char,
    genre_ptr: *const c_char,
) -> *mut c_char {
    let list_json = match unsafe { cstr_to_str(list_json_ptr) } {
        Some(s) => s,
        None => return string_to_cptr("[]".to_string()),
    };
    let genre = match unsafe { cstr_to_str(genre_ptr) } {
        Some(s) => s,
        None => return string_to_cptr("[]".to_string()),
    };

    let list: Vec<Value> = match serde_json::from_str(list_json) {
        Ok(v) => v,
        Err(_) => return string_to_cptr("[]".to_string()),
    };

    let filtered: Vec<&Value> = list
        .iter()
        .filter(|item| item.get("janri").and_then(|j| j.as_str()) == Some(genre))
        .collect();

    string_to_cptr(serde_json::to_string(&filtered).unwrap_or_else(|_| "[]".to_string()))
}
