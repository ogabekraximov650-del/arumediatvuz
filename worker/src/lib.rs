// src/lib.rs — Cloudflare Worker (Rust + WASM)
// worker crate v0.8.5
//
// Jadvallar:
// anime_db — anime registri.
// season_db — bo'limlar. PRIMARY KEY (anime_id, season_id). bolim_id — ko'rsatish raqami.
// epizod_db — epizodlar. PRIMARY KEY (anime_id, season_id, epizod_id).
//
// MUHIM: Turso'da photo_url / url_360p / url_480p / url_720p / url_1080p
// ustunlarida FAQAT B2 fayl nomi saqlanadi (masalan "abc123.mp4"), to'liq
// URL emas — shu tufayli worker domeni o'zgarsa ham eski yozuvlar buzilmaydi.
// Har bir GET/POST/PUT javobida to'liq URL SHU SO'ROVNING domeni asosida
// DINAMIK ravishda quriladi (resolve_url/resolve_fields). Eski (hali
// to'liq URL bilan saqlangan) qatorlar ham to'g'ri ishlaydi — resolve_url
// qiymat allaqachon "http" bilan boshlansa uni o'zgartirmasdan qaytaradi.
//
// /api/image/:filename — B2 proxy, 450MB'lik bo'laklarga bo'lib
// Cloudflare Cache API orqali keshlaydi (400 kunga). Bo'lak birinchi
// so'ralganda B2'dan OQIM (quvur) orqali — xotiraga to'liq yig'ilmasdan
// — olinib keshga yoziladi; keyingi barcha so'rovlar to'g'ridan-to'g'ri
// keshdan xizmat qiladi va B2'ga umuman murojaat qilinmaydi. Mijoz
// so'ragan 1 MB'lik oraliqni keshdan CLOUDFLARE'NING O'ZI kesib beradi
// (Range so'rovi orqali), shu sabab worker xotirasi bo'lak hajmidan
// mutlaqo mustaqil.
//
// Cascade delete:
// DELETE anime → barcha epizod videolari + season rasmlari B2dan → epizod_db → season_db → anime_db
// DELETE season → barcha epizod videolari B2dan → epizod_db → season rasmi B2dan → season_db
// DELETE epizod → barcha video B2dan → epizod_db

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use worker::*;

// ── CORS + JSON yordamchi ──────────────────────────────────────

fn set_cors(resp: &mut Response) {
    let h = resp.headers_mut();
    let _ = h.set("Access-Control-Allow-Origin", "*");
    let _ = h.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    let _ = h.set("Access-Control-Allow-Headers", "Content-Type, Authorization, Range");
    let _ = h.set("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges");
}

fn json_resp(data: &Value, status: u16) -> Result<Response> {
    let mut resp = Response::from_json(data)?.with_status(status);
    set_cors(&mut resp);
    Ok(resp)
}

fn ok(v: Value) -> Result<Response> { json_resp(&v, 200) }
fn created(v: Value) -> Result<Response> { json_resp(&v, 201) }
fn err404(msg: &str) -> Result<Response> { json_resp(&json!({"error": msg}), 404) }
fn err500(msg: &str) -> Result<Response> { json_resp(&json!({"error": msg}), 500) }

// ── Fayl nomi → to'liq URL (domendan mustaqil) ──────────────────
// Turso'da bare fayl nomi saqlanadi; har bir javobda joriy so'rov
// domeni asosida to'liq URL shu yerda quriladi. Agar qiymat
// allaqachon to'liq URL bo'lsa (eski yozuvlar), o'zgartirilmaydi.
fn resolve_url(origin: &str, value: &str) -> String {
    if value.is_empty() { return String::new(); }
    if value.starts_with("http://") || value.starts_with("https://") {
        value.to_string()
    } else {
        format!("{origin}/api/image/{value}")
    }
}

/// Berilgan JSON obyektdagi ko'rsatilgan kalitlarni (masalan "photo_url",
/// "url_720p") bare fayl nomidan to'liq URL'ga o'giradi.
fn resolve_fields(origin: &str, mut obj: Value, keys: &[&str]) -> Value {
    if let Some(map) = obj.as_object_mut() {
        for k in keys {
            if let Some(v) = map.get(*k).and_then(|v| v.as_str()) {
                let resolved = resolve_url(origin, v);
                map.insert(k.to_string(), json!(resolved));
            }
        }
    }
    obj
}

fn resolve_list(origin: &str, list: Vec<Value>, keys: &[&str]) -> Vec<Value> {
    list.into_iter().map(|o| resolve_fields(origin, o, keys)).collect()
}

const ANIME_URL_KEYS: &[&str] = &["photo_url"];
const SEASON_URL_KEYS: &[&str] = &["photo_url"];
const EPIZOD_URL_KEYS: &[&str] = &["url_360p", "url_480p", "url_720p", "url_1080p"];

// ── Turso ─────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Debug, Clone)]
struct TursoArg {
    #[serde(rename = "type")]
    type_: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<String>,
}

impl TursoArg {
    fn text(v: &str) -> Self { Self { type_: "text".into(), value: Some(v.into()) } }
    fn int(v: i64) -> Self { Self { type_: "integer".into(), value: Some(v.to_string()) } }
}

fn row_to_obj(cols: &[Value], row: &[Value]) -> Value {
    let mut map = serde_json::Map::new();
    for (i, col) in cols.iter().enumerate() {
        let name = col["name"].as_str().unwrap_or("").to_string();
        let cell = &row[i];
        let t = cell["type"].as_str().unwrap_or("null");
        let val = if t == "null" {
            Value::Null
        } else if t == "integer" || t == "float" {
            let s = cell["value"].as_str().unwrap_or("0");
            s.parse::<i64>().map(|n| json!(n))
                .or_else(|_| s.parse::<f64>().map(|f| json!(f)))
                .unwrap_or(Value::Null)
        } else {
            json!(cell["value"].as_str().unwrap_or(""))
        };
        map.insert(name, val);
    }
    Value::Object(map)
}

async fn turso_exec(env: &Env, sql: &str, args: Vec<TursoArg>) -> Result<Value> {
    let url = env.secret("TURSO_URL")?.to_string();
    let token = env.secret("TURSO_TOKEN")?.to_string();
    let body = json!({
        "requests": [
            {"type": "execute", "stmt": {"sql": sql, "args": args}},
            {"type": "close"}
        ]
    });
    let mut h = Headers::new();
    h.set("Authorization", &format!("Bearer {token}"))?;
    h.set("Content-Type", "application/json")?;
    let req = Request::new_with_init(
        &format!("{url}/v2/pipeline"),
        RequestInit::new().with_method(Method::Post).with_headers(h)
            .with_body(Some(body.to_string().into())),
    )?;
    let mut resp = Fetch::Request(req).send().await?;
    let data: Value = resp.json().await?;
    let r = &data["results"][0];
    if r["type"] == "error" {
        return Err(Error::RustError(
            r["error"]["message"].as_str().unwrap_or("Turso xato").to_string()
        ));
    }
    Ok(r["response"]["result"].clone())
}

async fn turso_batch(env: &Env, stmts: &[(&str, Vec<TursoArg>)]) -> Result<()> {
    let url = env.secret("TURSO_URL")?.to_string();
    let token = env.secret("TURSO_TOKEN")?.to_string();
    let mut reqs: Vec<Value> = stmts.iter().map(|(sql, args)| {
        json!({"type": "execute", "stmt": {"sql": sql, "args": args}})
    }).collect();
    reqs.push(json!({"type": "close"}));
    let mut h = Headers::new();
    h.set("Authorization", &format!("Bearer {token}"))?;
    h.set("Content-Type", "application/json")?;
    let req = Request::new_with_init(
        &format!("{url}/v2/pipeline"),
        RequestInit::new().with_method(Method::Post).with_headers(h)
            .with_body(Some(json!({"requests": reqs}).to_string().into())),
    )?;
    Fetch::Request(req).send().await?;
    Ok(())
}

async fn init_db(env: &Env) {
    let _ = turso_batch(env, &[
        ("CREATE TABLE IF NOT EXISTS anime_db (
            id INTEGER PRIMARY KEY,
            photo_url TEXT, name TEXT, davlat TEXT, studiya TEXT,
            janri TEXT, tavsif TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_name ON anime_db(name)", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_janri ON anime_db(janri)", vec![]),
        ("CREATE TABLE IF NOT EXISTS season_db (
            anime_id INTEGER, bolim_id INTEGER, season_id INTEGER,
            photo_url TEXT, nomi TEXT, studio TEXT, tarjimon TEXT,
            yili TEXT, janri TEXT, turi TEXT, holati TEXT, tavsif TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (anime_id, season_id)
        )", vec![]),
        ("ALTER TABLE season_db ADD COLUMN bolim_id INTEGER", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_season_anime ON season_db(anime_id)", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_season_janri ON season_db(janri)", vec![]),
        ("CREATE TABLE IF NOT EXISTS epizod_db (
            anime_id INTEGER, season_id INTEGER, epizod_id INTEGER,
            epizod_number INTEGER, epizod_name TEXT,
            url_360p TEXT, size_360p TEXT,
            url_480p TEXT, size_480p TEXT,
            url_720p TEXT, size_720p TEXT,
            url_1080p TEXT, size_1080p TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (anime_id, season_id, epizod_id)
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_epizod_season ON epizod_db(anime_id, season_id)", vec![]),
    ]).await;
}

async fn next_anime_id(env: &Env) -> Result<i64> {
    let res = turso_exec(env, "SELECT COALESCE(MAX(id), 0) AS max_id FROM anime_db", vec![]).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() { return Ok(1); }
    Ok(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![]))["max_id"].as_i64().unwrap_or(0) + 1)
}

async fn next_epizod_id(env: &Env) -> Result<i64> {
    let res = turso_exec(env, "SELECT COALESCE(MAX(epizod_id), 0) AS max_id FROM epizod_db", vec![]).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() { return Ok(1); }
    Ok(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![]))["max_id"].as_i64().unwrap_or(0) + 1)
}

// ── B2 ─────────────────────────────────────────────────────────

fn b64(input: &str) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = input.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        let b0 = b[i] as u32;
        let b1 = if i+1 < b.len() { b[i+1] as u32 } else { 0 };
        let b2 = if i+2 < b.len() { b[i+2] as u32 } else { 0 };
        out.push(T[((b0>>2)&63) as usize] as char);
        out.push(T[(((b0<<4)|(b1>>4))&63) as usize] as char);
        out.push(if i+1 < b.len() { T[(((b1<<2)|(b2>>6))&63) as usize] as char } else { '=' });
        out.push(if i+2 < b.len() { T[(b2&63) as usize] as char } else { '=' });
        i += 3;
    }
    out
}

/// B2 avtorizatsiya tokeni 24 soat amal qiladi, shu sabab u
/// Cloudflare keshida 12 soatga saqlanadi.
///
/// NEGA: har bir kesh-miss uchun B2'ga alohida `b2_authorize_account`
/// so'rovi ketardi. Bu ham qo'shimcha kechikish (har bir bo'lak uchun
/// +1 tashqi so'rov), ham B2 tomonidagi keraksiz tranzaksiya edi.
/// Endi token bir marta olinadi va 12 soat davomida hamma so'rovlar
/// uni baham ko'radi.
const AUTH_CACHE_SECONDS: u64 = 12 * 60 * 60;

async fn b2_auth(env: &Env) -> Result<Value> {
    let cache = Cache::default();
    let key = Request::new("https://fulutter-chunk-cache.internal/_b2auth", Method::Get)?;
    if let Some(mut cached) = cache.get(&key, false).await? {
        if let Ok(v) = cached.json::<Value>().await {
            if v["authorizationToken"].is_string() {
                return Ok(v);
            }
        }
    }
    let fresh = b2_auth_fetch(env).await?;
    if let Ok(mut to_cache) = Response::from_json(&fresh) {
        let h = to_cache.headers_mut();
        let _ = h.set("Cache-Control", &format!("public, max-age={AUTH_CACHE_SECONDS}"));
        let _ = cache.put(&key, to_cache).await;
    }
    Ok(fresh)
}

async fn b2_auth_fetch(env: &Env) -> Result<Value> {
    let cred = b64(&format!("{}:{}", env.secret("B2_KEY_ID")?, env.secret("B2_APPLICATION_KEY")?));
    let mut h = Headers::new();
    h.set("Authorization", &format!("Basic {cred}"))?;
    let req = Request::new_with_init(
        "https://api.backblazeb2.com/b2api/v3/b2_authorize_account",
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    if r.status_code() != 200 {
        return Err(Error::RustError(format!("B2 auth xato: {}",
            d["message"].as_str().unwrap_or("unknown"))));
    }
    Ok(d)
}

async fn b2_bucket_id(api_url: &str, auth_token: &str, account_id: &str) -> Result<String> {
    let mut h = Headers::new();
    h.set("Authorization", auth_token)?;
    let req = Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_buckets?accountId={account_id}&bucketName=aniraxuz"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    if r.status_code() != 200 {
        return Err(Error::RustError(format!("B2 list_buckets xato: {}",
            d["message"].as_str().unwrap_or("unknown"))));
    }
    let bid = d["buckets"][0]["bucketId"].as_str().unwrap_or("").to_string();
    if bid.is_empty() { return Err(Error::RustError("B2 bucket 'aniraxuz' topilmadi".into())); }
    Ok(bid)
}

async fn b2_get_upload_url(env: &Env) -> Result<Value> {
    let auth = b2_auth(env).await?;
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let acct = auth["accountId"].as_str().unwrap_or("").to_string();
    let bucket_id = b2_bucket_id(&api_url, &token, &acct).await?;
    let mut h = Headers::new();
    h.set("Authorization", &token)?;
    h.set("Content-Type", "application/json")?;
    let req = Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_get_upload_url"),
        RequestInit::new().with_method(Method::Post).with_headers(h)
            .with_body(Some(json!({"bucketId": bucket_id}).to_string().into())),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    if r.status_code() != 200 || d["uploadUrl"].is_null() {
        return Err(Error::RustError(format!("B2 upload URL xato: {}",
            d["message"].as_str().unwrap_or("uploadUrl topilmadi"))));
    }
    Ok(d)
}

// ── SO'RALGAN ORALIQNI KESHLASH TIZIMI ────────────────────────
//
// Video fayllar Cloudflare Cache API'da MIJOZ SO'RAGAN oraliqlar
// bo'yicha saqlanadi: ilova har doim aniq 1 MiB'lik, tekislangan
// oraliqni so'raydi, shu sabab kesh kalitlari barqaror va qayta
// ishlatiladi. Oraliq birinchi so'ralganda B2'dan BIR MARTA
// olinadi, mijozga darhol beriladi va fon'da (`wait_until`) keshga
// yoziladi (400 kunga). Keyingi barcha so'rovlar — boshqa
// foydalanuvchilardan ham — B2'ga umuman chiqmasdan Cloudflare
// chekkasidan xizmat qiladi.
//
// Xotira: bir so'rovda eng ko'pi 4 MB (RANGE_MAX) — worker'ning
// 128 MB chegarasidan juda uzoq. Fayl 166 MB bo'lsin, 10 GB
// bo'lsin, xotira sarfi bir xil.
//
// ✅ NIMA TUZATILDI (yuklab olish 0.2-0.5 MB/s da sudralardi):
//
// Avval fayl 450 MB'lik "virtual oynalarga" bo'linar va kesh bo'sh
// bo'lganda worker fon'da butun oynani B2'dan tortib keshga
// yozishga urinardi ("isitish"). BIRINCHI yuklab olishda bu sof
// zarar edi: har bir bayt baribir bir marta so'raladi, isitish esa
// AYNAN o'sha baytlarni ikkinchi marta B2'dan tortib, mijozning 12
// ta parallel so'rovi bilan bir xil kanalni bo'lishardi. Ustiga
// 450 MB'lik isitish ko'pincha tugamasdan uzilar, "isitish
// belgisi" esa 30 daqiqa qayta urinishni bloklardi — natijada
// yarim soat davomida har bir so'rov B2'ga borardi.
//
// Endi isitish umuman yo'q: B2'dan har bir bayt ATIGI BIR MARTA
// olinadi va mijozning barcha oqimlari to'liq tezlikda ishlaydi.
//
// Diagnostika uchun har bir javobda `X-Cache: HIT|MISS` sarlavhasi
// bo'ladi.

/// Range'siz (butunlay) keshlanadigan eng katta fayl — rasmlar uchun.
const FULL_CACHE_MAX: u64 = 12 * 1024 * 1024; // 12 MiB
const CHUNK_CACHE_SECONDS: u64 = 400 * 24 * 60 * 60; // 400 kun

/// "bytes=START-END?" ni (start, end_yoki_None) ga ajratadi.
fn parse_range(range: &str) -> Option<(u64, Option<u64>)> {
    let r = range.strip_prefix("bytes=")?;
    let mut parts = r.splitn(2, '-');
    let start: u64 = parts.next()?.trim().parse().ok()?;
    let end_str = parts.next().unwrap_or("").trim();
    let end = if end_str.is_empty() { None } else { end_str.parse().ok() };
    Some((start, end))
}

/// "bytes X-Y/Z" formatidagi Content-Range headerini (start, end, total) ga ajratadi.
fn parse_content_range(cr: &str) -> Option<(u64, u64, u64)> {
    let rest = cr.strip_prefix("bytes ")?;
    let (range_part, total_part) = rest.split_once('/')?;
    let (start_s, end_s) = range_part.split_once('-')?;
    let start: u64 = start_s.trim().parse().ok()?;
    let end: u64 = end_s.trim().parse().ok()?;
    let total: u64 = total_part.trim().parse().ok()?;
    Some((start, end, total))
}

/// B2 yuklab olish manzili va tokeni (fon vazifasiga uzatish uchun).
struct B2Access {
    dl_url: String,
    token: String,
}

async fn b2_access(env: &Env) -> Result<B2Access> {
    let auth = b2_auth(env).await?;
    Ok(B2Access {
        dl_url: auth["apiInfo"]["storageApi"]["downloadUrl"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        token: auth["authorizationToken"].as_str().unwrap_or("").to_string(),
    })
}

fn b2_range_request(acc: &B2Access, file_name: &str, start: u64, end: u64) -> Result<Request> {
    let mut h = Headers::new();
    h.set("Authorization", &acc.token)?;
    h.set("Range", &format!("bytes={start}-{end}"))?;
    Request::new_with_init(
        &format!("{}/file/aniraxuz/{file_name}", acc.dl_url),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )
}

/// B2'dan berilgan ABSOLYUT byte oralig'ini o'qiydi.
/// Qaytaradi: (B2 javobi, faylning umumiy hajmi).
async fn b2_fetch_range(env: &Env, file_name: &str, start: u64, end: u64) -> Result<(Response, u64)> {
    let acc = b2_access(env).await?;
    let req = b2_range_request(&acc, file_name, start, end)?;
    let b2_resp = Fetch::Request(req).send().await?;
    let status = b2_resp.status_code();
    if status != 200 && status != 206 {
        return Err(Error::RustError(format!("B2 range xato: {status}")));
    }
    let cr = b2_resp.headers().get("Content-Range")?.unwrap_or_default();
    let total = parse_content_range(&cr).map(|(_, _, t)| t).unwrap_or(0);
    Ok((b2_resp, total))
}

fn cache_key_url(file_name: &str, suffix: &str) -> String {
    format!("https://fulutter-chunk-cache.internal/{file_name}/{suffix}")
}


/// B2 proxy. Range bor-yo'qligiga qarab ikki yo'ldan biri tanlanadi.
async fn b2_proxy(
    env: &Env,
    ctx: &Context,
    file_name: &str,
    range: Option<String>,
) -> Result<Response> {
    match range.as_deref().and_then(parse_range) {
        Some((start, end_opt)) => b2_proxy_range(env, ctx, file_name, start, end_opt).await,
        None => b2_proxy_full(env, file_name).await,
    }
}

/// ── RANGE BILAN (video) ──────────────────────────────────────
///
/// ═════════════════════════════════════════════════════════════
///  NEGA YUKLAB OLISH SEKIN EDI VA NIMA O'ZGARDI
/// ═════════════════════════════════════════════════════════════
///
/// ── ESKI TIZIM ───────────────────────────────────────────────
/// Fayl 450 MB'lik "virtual oynalarga" bo'linardi. Mijoz 1 MiB
/// so'raganda:
///   1) o'sha oyna keshdan qidirilardi (Range bilan kesib);
///   2) topilmasa — mijozga kerakli 1 MiB B2'dan olib berilardi;
///   3) VA YANA fon'da butun 450 MB'lik oyna B2'dan tortilib
///      keshga yozishga urinilardi ("isitish").
///
/// Muammolar:
///   * BIRINCHI yuklab olishda kesh umuman yordam bermaydi —
///     har bir bayt bir marta so'raladi. Isitish esa AYNAN O'SHA
///     baytlarni IKKINCHI marta B2'dan tortadi, ya'ni B2 kanalini
///     ikki barobar band qiladi va mijozning 12 ta parallel
///     so'rovi bilan raqobatlashadi;
///   * 450 MB'lik isitish ko'pincha tugamasdan uzilardi, "isitish
///     belgisi" esa 30 daqiqa yashab, qayta urinishni bloklardi —
///     natijada 30 daqiqa davomida HAR BIR so'rov B2'ga borardi.
///
/// Aynan shu sabab yuklab olish 0.2-0.5 MB/s da sudralardi.
///
/// ── YANGI TIZIM: SODDA VA TO'G'RI ────────────────────────────
/// Endi hech qanday "oyna" ham, "isitish" ham yo'q. Mijoz qaysi
/// oraliqni so'rasa, AYNAN O'SHA oraliq:
///   * keshdan qidiriladi (kalit — oraliqning o'zi);
///   * topilmasa B2'dan BIR MARTA olinadi, mijozga beriladi va
///     shu zahoti (fon'da) keshga yoziladi.
///
/// Ya'ni B2'dan har bir bayt ATIGI BIR MARTA olinadi — mijozning
/// barcha oqimlari to'liq tezlikda ishlaydi. Keyingi ko'rishlarda
/// (va boshqa foydalanuvchilarda) esa hammasi Cloudflare
/// chekkasidan, B2'ga umuman chiqmasdan xizmat qilinadi.
///
/// Ilova har doim aniq 1 MiB'lik, tekislangan oraliqlarni
/// so'raydi — shu sabab kesh kalitlari barqaror va qayta
/// ishlatiladi.
async fn b2_proxy_range(
    env: &Env,
    ctx: &Context,
    file_name: &str,
    req_start: u64,
    req_end_opt: Option<u64>,
) -> Result<Response> {
    // Bir so'rovda xotiraga olinadigan eng katta hajm. Ilova 1 MiB
    // so'raydi; ochiq (oxiri ko'rsatilmagan) so'rov shu chegaragacha
    // qisqartiriladi — bu HTTP jihatidan mutlaqo to'g'ri 206 javob.
    const RANGE_MAX: u64 = 4 * 1024 * 1024;

    let req_end = req_end_opt
        .unwrap_or(req_start + RANGE_MAX - 1)
        .min(req_start + RANGE_MAX - 1);

    let cache = Cache::default();
    let cache_url = cache_key_url(file_name, &format!("r{req_start}-{req_end}"));
    let key = Request::new(&cache_url, Method::Get)?;

    // ── KESH HIT ─────────────────────────────────────────────
    if let Some(mut hit) = cache.get(&key, false).await? {
        let ct = hit
            .headers()
            .get("Content-Type")?
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let cl = hit.headers().get("Content-Length")?;
        let total = hit
            .headers()
            .get("X-Total-Size")?
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0);
        // Keshda oraliqning O'ZI yotibdi — kesish kerak emas.
        let stream = hit.stream()?;
        let mut resp = Response::from_stream(stream)?.with_status(206);
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "public, max-age=86400")?;
        if let Some(l) = cl {
            h.set("Content-Length", &l)?;
        }
        let total_str = if total > 0 {
            total.to_string()
        } else {
            (req_end + 1).to_string()
        };
        h.set("Content-Range", &format!("bytes {req_start}-{req_end}/{total_str}"))?;
        // Diagnostika: javob Cloudflare keshidan keldimi yoki B2'dan.
        h.set("X-Cache", "HIT")?;
        return Ok(resp);
    }

    // ── KESH MISS: B2'dan BIR MARTA olamiz ───────────────────
    let (mut b2, total) = b2_fetch_range(env, file_name, req_start, req_end).await?;
    let ct = b2
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());
    // Eng ko'pi RANGE_MAX (4 MB) — worker xotirasi uchun mutlaqo
    // xavfsiz. Katta oyna endi HECH QACHON xotiraga olinmaydi.
    let bytes = b2.bytes().await?;
    let got = bytes.len() as u64;
    if got == 0 {
        return Err(Error::RustError("B2 bo'sh javob qaytardi".into()));
    }
    let actual_end = req_start + got - 1;
    let total_str = if total > 0 {
        total.to_string()
    } else {
        (actual_end + 1).to_string()
    };

    // Keshga yozish MIJOZNI KUTTIRMAYDI (wait_until).
    // MUHIM: Cache API 206 statusli javobni qabul qilmaydi, shu
    // sabab kesh nusxasi 200 sifatida saqlanadi; oraliq ma'lumoti
    // kalitning o'zida va X-Total-Size'da turadi.
    if got == req_end - req_start + 1 {
        let mut to_cache = Response::from_bytes(bytes.clone())?;
        {
            let h = to_cache.headers_mut();
            h.set("Content-Type", &ct)?;
            h.set("Content-Length", &got.to_string())?;
            h.set("Accept-Ranges", "bytes")?;
            h.set("Cache-Control", &format!("public, max-age={CHUNK_CACHE_SECONDS}"))?;
            h.set("X-Total-Size", &total_str)?;
        }
        ctx.wait_until(async move {
            if let Ok(k) = Request::new(&cache_url, Method::Get) {
                let _ = Cache::default().put(&k, to_cache).await;
            }
        });
    }

    let mut resp = Response::from_bytes(bytes)?.with_status(206);
    set_cors(&mut resp);
    let h = resp.headers_mut();
    h.set("Content-Type", &ct)?;
    h.set("Accept-Ranges", "bytes")?;
    h.set("Cache-Control", "public, max-age=86400")?;
    h.set("Content-Length", &got.to_string())?;
    h.set("Content-Range", &format!("bytes {req_start}-{actual_end}/{total_str}"))?;
    h.set("X-Cache", "MISS")?;
    Ok(resp)
}

/// ── RANGE'SIZ (rasmlar va oddiy yuklashlar) ──────────────────
///
/// Kichik fayl butunligicha keshlanadi. Katta fayl esa XOTIRAGA
/// YIG'ILMASDAN, oqim orqali o'tkaziladi.
async fn b2_proxy_full(env: &Env, file_name: &str) -> Result<Response> {
    let cache = Cache::default();
    let key = Request::new(&cache_key_url(file_name, "full"), Method::Get)?;

    if let Some(mut cached) = cache.get(&key, false).await? {
        let ct = cached
            .headers()
            .get("Content-Type")?
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let cl = cached.headers().get("Content-Length")?;
        let stream = cached.stream()?;
        let mut resp = Response::from_stream(stream)?.with_status(200);
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "public, max-age=86400")?;
        if let Some(cl) = cl {
            h.set("Content-Length", &cl)?;
        }
        return Ok(resp);
    }

    // Birinchi so'rov: eng ko'pi FULL_CACHE_MAX so'raymiz. Javobning
    // Content-Range'i faylning HAQIQIY hajmini aytadi.
    let (mut probe, total) = b2_fetch_range(env, file_name, 0, FULL_CACHE_MAX - 1).await?;
    let ct = probe
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());

    if total > 0 && total <= FULL_CACHE_MAX {
        // Butun fayl qo'limizda (eng ko'pi 12 MB) — keshlaymiz.
        let bytes = probe.bytes().await?;
        let len = bytes.len();
        if !bytes.is_empty() {
            let mut to_cache = Response::from_bytes(bytes.clone())?;
            {
                let h = to_cache.headers_mut();
                h.set("Content-Type", &ct)?;
                h.set("Content-Length", &len.to_string())?;
                h.set("Accept-Ranges", "bytes")?;
                h.set("Cache-Control", &format!("public, max-age={CHUNK_CACHE_SECONDS}"))?;
                h.set("X-Total-Size", &total.to_string())?;
            }
            let _ = cache.put(&key, to_cache).await;
        }
        let mut resp = Response::from_bytes(bytes)?.with_status(200);
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "public, max-age=86400")?;
        h.set("Content-Length", &len.to_string())?;
        return Ok(resp);
    }

    // Katta fayl Range'siz so'ralgan — oqim orqali o'tkazamiz.
    let last = total.saturating_sub(1);
    let (mut b2, _) = b2_fetch_range(env, file_name, 0, last).await?;
    let stream = b2.stream()?;
    let mut resp = Response::from_stream(stream)?.with_status(200);
    set_cors(&mut resp);
    let h = resp.headers_mut();
    h.set("Content-Type", &ct)?;
    h.set("Accept-Ranges", "bytes")?;
    h.set("Cache-Control", "public, max-age=86400")?;
    if total > 0 {
        h.set("Content-Length", &total.to_string())?;
    }
    Ok(resp)
}

/// B2'dan bitta faylni o'chirish. Qiymat bare fayl nomi (yangi format)
/// yoki eski to'liq URL bo'lishi mumkin — ikkalasi ham qo'llab-quvvatlanadi.
async fn b2_delete(env: &Env, value: &str) {
    if value.is_empty() { return; }
    let file_name = match value.find("/api/image/") {
        Some(p) => &value[p + 11..],
        None => value,
    };
    let auth = match b2_auth(env).await { Ok(a) => a, Err(_) => return };
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let acct = auth["accountId"].as_str().unwrap_or("").to_string();
    let bid = match b2_bucket_id(&api_url, &token, &acct).await { Ok(id) => id, Err(_) => return };

    let mut h = Headers::new();
    let _ = h.set("Authorization", &token);
    let req = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_file_names?bucketId={bid}&prefix={file_name}&maxFileCount=1"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    ) { Ok(r) => r, Err(_) => return };
    let mut r = match Fetch::Request(req).send().await { Ok(r) => r, Err(_) => return };
    let d: Value = match r.json().await { Ok(d) => d, Err(_) => return };
    let fid = match d["files"][0]["fileId"].as_str() { Some(id) => id.to_string(), None => return };

    let mut h2 = Headers::new();
    let _ = h2.set("Authorization", &token);
    let _ = h2.set("Content-Type", "application/json");
    let req2 = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_delete_file_version"),
        RequestInit::new().with_method(Method::Post).with_headers(h2)
            .with_body(Some(json!({"fileName": file_name, "fileId": fid}).to_string().into())),
    ) { Ok(r) => r, Err(_) => return };
    let _ = Fetch::Request(req2).send().await;
}

async fn b2_delete_epizod_files(env: &Env, ep: &Value) {
    for k in &["url_360p", "url_480p", "url_720p", "url_1080p"] {
        let u = ep[k].as_str().unwrap_or("");
        if !u.is_empty() { b2_delete(env, u).await; }
    }
}

// ── season_db yordamchi ──────────────────────────────────────

fn season_fields(b: &Value) -> (i64, i64, String, String, String, String, String, String, String, String, String, String) {
    (
        b["bolim_id"].as_i64().unwrap_or(0),
        b["season_id"].as_i64().unwrap_or(0),
        b["photo_url"].as_str().unwrap_or("").to_string(),
        b["nomi"].as_str().unwrap_or("").to_string(),
        b["studio"].as_str().unwrap_or("").to_string(),
        b["tarjimon"].as_str().unwrap_or("").to_string(),
        b["yili"].as_str().unwrap_or("").to_string(),
        b["janri"].as_str().unwrap_or("").to_string(),
        b["turi"].as_str().unwrap_or("").to_string(),
        b["holati"].as_str().unwrap_or("").to_string(),
        b["tavsif"].as_str().unwrap_or("").to_string(),
        b["anime_id"].as_str().map(|s| s.to_string())
            .or_else(|| b["anime_id"].as_i64().map(|n| n.to_string()))
            .unwrap_or_default(),
    )
}

fn epizod_fields(b: &Value) -> (i64, String, String, String, String, String, String, String, String, String) {
    (
        b["epizod_number"].as_i64().unwrap_or(0),
        b["epizod_name"].as_str().unwrap_or("").to_string(),
        b["url_360p"].as_str().unwrap_or("").to_string(),
        b["size_360p"].as_str().unwrap_or("").to_string(),
        b["url_480p"].as_str().unwrap_or("").to_string(),
        b["size_480p"].as_str().unwrap_or("").to_string(),
        b["url_720p"].as_str().unwrap_or("").to_string(),
        b["size_720p"].as_str().unwrap_or("").to_string(),
        b["url_1080p"].as_str().unwrap_or("").to_string(),
        b["size_1080p"].as_str().unwrap_or("").to_string(),
    )
}

// ── Router ─────────────────────────────────────────────────────

#[event(fetch)]
async fn main(req: Request, env: Env, ctx: Context) -> Result<Response> {
    let url = req.url()?;
    let path = url.path();
    let method = req.method();
    // Range headerini erta olib qo'yamiz (req move bo'lishidan oldin)
    let range_header = req.headers().get("Range").ok().flatten();
    // Joriy so'rov domeni — Turso'da saqlangan bare fayl nomlaridan
    // to'liq URL qurish uchun (domen o'zgarsa ham ishlayveradi).
    let origin = format!("{}://{}", url.scheme(), url.host_str().unwrap_or(""));

    if method == Method::Options {
        let mut r = Response::empty()?;
        set_cors(&mut r);
        return Ok(r);
    }

    // B2 proxy — Range header bilan uzatiladi (video seek)
    if method == Method::Get {
        if let Some(fname) = path.strip_prefix("/api/image/") {
            return b2_proxy(&env, &ctx, fname, range_header).await;
        }
    }

    init_db(&env).await;

    match (method.clone(), path) {

        // ── anime_db ──────────────────────────────────────────
        (Method::Get, "/api/anime") => {
            let res = turso_exec(&env, "SELECT * FROM anime_db ORDER BY id DESC LIMIT 100", vec![]).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            let items = rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>();
            ok(json!(resolve_list(&origin, items, ANIME_URL_KEYS)))
        }

        (Method::Post, "/api/anime") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let new_id = next_anime_id(&env).await?;
            let res = turso_exec(&env,
                "INSERT INTO anime_db (id,photo_url,name,davlat,studiya,janri,tavsif) VALUES (?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::int(new_id),
                    TursoArg::text(b["photo_url"].as_str().unwrap_or("")),
                    TursoArg::text(b["name"].as_str().unwrap_or("")),
                    TursoArg::text(b["davlat"].as_str().unwrap_or("")),
                    TursoArg::text(b["studiya"].as_str().unwrap_or("")),
                    TursoArg::text(b["janri"].as_str().unwrap_or("")),
                    TursoArg::text(b["tavsif"].as_str().unwrap_or("")),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Qo'shib bo'lmadi"); }
            created(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), ANIME_URL_KEYS))
        }

        (Method::Post, "/api/upload-token") => {
            match b2_get_upload_url(&env).await {
                Ok(d) => ok(d),
                Err(e) => err500(&format!("B2 xatosi: {e}")),
            }
        }

        // ── season_db ──────────────────────────────────────────
        (Method::Get, "/api/seasons") => {
            let res = turso_exec(&env, "SELECT * FROM season_db ORDER BY anime_id DESC, season_id ASC LIMIT 200", vec![]).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            let items = rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>();
            ok(json!(resolve_list(&origin, items, SEASON_URL_KEYS)))
        }

        (Method::Post, "/api/seasons") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let (bid, sid, pu, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, animeidval) = season_fields(&b);
            let res = turso_exec(&env,
                "INSERT INTO season_db (anime_id,bolim_id,season_id,photo_url,nomi,studio,tarjimon,yili,janri,turi,holati,tavsif)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::text(&animeidval), TursoArg::int(bid), TursoArg::int(sid),
                    TursoArg::text(&pu), TursoArg::text(&nomi), TursoArg::text(&studio),
                    TursoArg::text(&tarjimon), TursoArg::text(&yili), TursoArg::text(&janri),
                    TursoArg::text(&turi), TursoArg::text(&holati), TursoArg::text(&tavsif),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Bo'lim qo'shib bo'lmadi"); }
            created(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), SEASON_URL_KEYS))
        }

        // ── epizod_db ──────────────────────────────────────────
        (Method::Post, "/api/epizods") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let anime_id = b["anime_id"].as_str().map(|s| s.to_string())
                .or_else(|| b["anime_id"].as_i64().map(|n| n.to_string())).unwrap_or_default();
            let season_id = b["season_id"].as_str().map(|s| s.to_string())
                .or_else(|| b["season_id"].as_i64().map(|n| n.to_string())).unwrap_or_default();
            let (ep_num, ep_name, u360, s360, u480, s480, u720, s720, u1080, s1080) = epizod_fields(&b);
            let new_id = next_epizod_id(&env).await?;
            let res = turso_exec(&env,
                "INSERT INTO epizod_db (anime_id,season_id,epizod_id,epizod_number,epizod_name,url_360p,size_360p,url_480p,size_480p,url_720p,size_720p,url_1080p,size_1080p)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::text(&anime_id), TursoArg::text(&season_id), TursoArg::int(new_id),
                    TursoArg::int(ep_num), TursoArg::text(&ep_name),
                    TursoArg::text(&u360), TursoArg::text(&s360), TursoArg::text(&u480), TursoArg::text(&s480),
                    TursoArg::text(&u720), TursoArg::text(&s720), TursoArg::text(&u1080), TursoArg::text(&s1080),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Epizod qo'shib bo'lmadi"); }
            created(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), EPIZOD_URL_KEYS))
        }

        _ => {
            if method == Method::Get {
                if let Some(janr) = path.strip_prefix("/api/anime/janr/") {
                    let res = turso_exec(&env, "SELECT * FROM anime_db WHERE janri = ? ORDER BY id DESC",
                        vec![TursoArg::text(janr)]).await?;
                    let cols = res["cols"].as_array().cloned().unwrap_or_default();
                    let rows = res["rows"].as_array().cloned().unwrap_or_default();
                    let items = rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>();
                    return ok(json!(resolve_list(&origin, items, ANIME_URL_KEYS)));
                }
            }

            if method == Method::Get {
                if let Some(aid) = path.strip_prefix("/api/seasons/anime/") {
                    let res = turso_exec(&env, "SELECT * FROM season_db WHERE anime_id = ? ORDER BY season_id ASC",
                        vec![TursoArg::text(aid)]).await?;
                    let cols = res["cols"].as_array().cloned().unwrap_or_default();
                    let rows = res["rows"].as_array().cloned().unwrap_or_default();
                    let items = rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>();
                    return ok(json!(resolve_list(&origin, items, SEASON_URL_KEYS)));
                }
            }

            // ── /api/epizods/... ──────────────────────────────
            if let Some(rest) = path.strip_prefix("/api/epizods/") {
                let parts: Vec<&str> = rest.split('/').collect();

                if parts.len() == 2 && method == Method::Get {
                    let res = turso_exec(&env,
                        "SELECT * FROM epizod_db WHERE anime_id = ? AND season_id = ? ORDER BY epizod_number ASC",
                        vec![TursoArg::text(parts[0]), TursoArg::text(parts[1])]).await?;
                    let cols = res["cols"].as_array().cloned().unwrap_or_default();
                    let rows = res["rows"].as_array().cloned().unwrap_or_default();
                    let items = rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>();
                    return ok(json!(resolve_list(&origin, items, EPIZOD_URL_KEYS)));
                }

                if parts.len() == 3 {
                    if let (Ok(aid), Ok(sid), Ok(eid)) = (
                        parts[0].parse::<i64>(), parts[1].parse::<i64>(), parts[2].parse::<i64>()
                    ) {
                        if method == Method::Put {
                            let mut req = req;
                            let b: Value = req.json().await?;
                            let (en, ename, u360, s360, u480, s480, u720, s720, u1080, s1080) = epizod_fields(&b);
                            let res = turso_exec(&env,
                                "UPDATE epizod_db SET epizod_number=?,epizod_name=?,url_360p=?,size_360p=?,url_480p=?,size_480p=?,url_720p=?,size_720p=?,url_1080p=?,size_1080p=?
                                 WHERE anime_id=? AND season_id=? AND epizod_id=? RETURNING *",
                                vec![
                                    TursoArg::int(en), TursoArg::text(&ename),
                                    TursoArg::text(&u360), TursoArg::text(&s360), TursoArg::text(&u480), TursoArg::text(&s480),
                                    TursoArg::text(&u720), TursoArg::text(&s720), TursoArg::text(&u1080), TursoArg::text(&s1080),
                                    TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid),
                                ],
                            ).await?;
                            let cols = res["cols"].as_array().cloned().unwrap_or_default();
                            let rows = res["rows"].as_array().cloned().unwrap_or_default();
                            if rows.is_empty() { return err500("Yangilashda xato"); }
                            return ok(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), EPIZOD_URL_KEYS));
                        }

                        if method == Method::Delete {
                            let old = turso_exec(&env,
                                "SELECT url_360p,url_480p,url_720p,url_1080p FROM epizod_db WHERE anime_id=? AND season_id=? AND epizod_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid)]).await?;
                            let ec = old["cols"].as_array().cloned().unwrap_or_default();
                            let er = old["rows"].as_array().cloned().unwrap_or_default();
                            if !er.is_empty() {
                                b2_delete_epizod_files(&env, &row_to_obj(&ec, er[0].as_array().unwrap_or(&vec![]))).await;
                            }
                            turso_exec(&env, "DELETE FROM epizod_db WHERE anime_id=? AND season_id=? AND epizod_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid)]).await?;
                            return ok(json!({"success": true}));
                        }
                    }
                }

                // DELETE bitta sifat: /api/epizods/:a/:s/:e/:quality
                if parts.len() == 4 && method == Method::Delete {
                    if let (Ok(aid), Ok(sid), Ok(eid)) = (
                        parts[0].parse::<i64>(), parts[1].parse::<i64>(), parts[2].parse::<i64>()
                    ) {
                        let (uc, sc) = match parts[3] {
                            "360p" => ("url_360p", "size_360p"),
                            "480p" => ("url_480p", "size_480p"),
                            "720p" => ("url_720p", "size_720p"),
                            "1080p" => ("url_1080p", "size_1080p"),
                            _ => return err404("Noto'g'ri sifat"),
                        };
                        let old = turso_exec(&env,
                            &format!("SELECT {uc} FROM epizod_db WHERE anime_id=? AND season_id=? AND epizod_id=?"),
                            vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid)]).await?;
                        let ec = old["cols"].as_array().cloned().unwrap_or_default();
                        let er = old["rows"].as_array().cloned().unwrap_or_default();
                        if !er.is_empty() {
                            let fu = row_to_obj(&ec, er[0].as_array().unwrap_or(&vec![]))[uc].as_str().unwrap_or("").to_string();
                            if !fu.is_empty() { b2_delete(&env, &fu).await; }
                        }
                        turso_exec(&env,
                            &format!("UPDATE epizod_db SET {uc}='',{sc}='' WHERE anime_id=? AND season_id=? AND epizod_id=?"),
                            vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid)]).await?;
                        return ok(json!({"success": true}));
                    }
                }
            }

            // ── /api/seasons/:a/:s ──────────────────────────────
            if let Some(rest) = path.strip_prefix("/api/seasons/") {
                let parts: Vec<&str> = rest.split('/').collect();
                if parts.len() == 2 {
                    if let (Ok(aid), Ok(sid)) = (parts[0].parse::<i64>(), parts[1].parse::<i64>()) {

                        if method == Method::Put {
                            let mut req = req;
                            let b: Value = req.json().await?;
                            let (bid, _, pu, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, _) = season_fields(&b);
                            let old = turso_exec(&env, "SELECT photo_url FROM season_db WHERE anime_id=? AND season_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid)]).await?;
                            let or_ = old["rows"].as_array().cloned().unwrap_or_default();
                            if or_.is_empty() { return err404("Bo'lim topilmadi"); }
                            let oc = old["cols"].as_array().cloned().unwrap_or_default();
                            let op = row_to_obj(&oc, or_[0].as_array().unwrap_or(&vec![]))["photo_url"].as_str().unwrap_or("").to_string();
                            if !op.is_empty() && op != pu { b2_delete(&env, &op).await; }
                            let res = turso_exec(&env,
                                "UPDATE season_db SET bolim_id=?,photo_url=?,nomi=?,studio=?,tarjimon=?,yili=?,janri=?,turi=?,holati=?,tavsif=?
                                 WHERE anime_id=? AND season_id=? RETURNING *",
                                vec![
                                    TursoArg::int(bid), TursoArg::text(&pu), TursoArg::text(&nomi),
                                    TursoArg::text(&studio), TursoArg::text(&tarjimon), TursoArg::text(&yili),
                                    TursoArg::text(&janri), TursoArg::text(&turi), TursoArg::text(&holati),
                                    TursoArg::text(&tavsif), TursoArg::int(aid), TursoArg::int(sid),
                                ],
                            ).await?;
                            let cols = res["cols"].as_array().cloned().unwrap_or_default();
                            let rows = res["rows"].as_array().cloned().unwrap_or_default();
                            if rows.is_empty() { return err500("Yangilashda xato"); }
                            return ok(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), SEASON_URL_KEYS));
                        }

                        if method == Method::Delete {
                            // 1. Epizod videolarini B2dan o'chirish
                            let eps = turso_exec(&env,
                                "SELECT url_360p,url_480p,url_720p,url_1080p FROM epizod_db WHERE anime_id=? AND season_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid)]).await?;
                            let ec = eps["cols"].as_array().cloned().unwrap_or_default();
                            let er = eps["rows"].as_array().cloned().unwrap_or_default();
                            for row in &er {
                                b2_delete_epizod_files(&env, &row_to_obj(&ec, row.as_array().unwrap_or(&vec![]))).await;
                            }
                            // 2. epizod_db dan o'chirish
                            turso_exec(&env, "DELETE FROM epizod_db WHERE anime_id=? AND season_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid)]).await?;
                            // 3. Bo'lim rasmini B2dan o'chirish
                            let old = turso_exec(&env, "SELECT photo_url FROM season_db WHERE anime_id=? AND season_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid)]).await?;
                            let or_ = old["rows"].as_array().cloned().unwrap_or_default();
                            if or_.is_empty() { return err404("Bo'lim topilmadi"); }
                            let oc = old["cols"].as_array().cloned().unwrap_or_default();
                            let op = row_to_obj(&oc, or_[0].as_array().unwrap_or(&vec![]))["photo_url"].as_str().unwrap_or("").to_string();
                            if !op.is_empty() { b2_delete(&env, &op).await; }
                            // 4. season_db dan o'chirish
                            turso_exec(&env, "DELETE FROM season_db WHERE anime_id=? AND season_id=?",
                                vec![TursoArg::int(aid), TursoArg::int(sid)]).await?;
                            return ok(json!({"success": true}));
                        }
                    }
                }
            }

            // ── /api/anime/:id ──────────────────────────────────
            if let Some(ids) = path.strip_prefix("/api/anime/") {
                if let Ok(id) = ids.parse::<i64>() {

                    if method == Method::Get {
                        let res = turso_exec(&env, "SELECT * FROM anime_db WHERE id=?", vec![TursoArg::int(id)]).await?;
                        let cols = res["cols"].as_array().cloned().unwrap_or_default();
                        let rows = res["rows"].as_array().cloned().unwrap_or_default();
                        if rows.is_empty() { return err404("Anime topilmadi"); }
                        return ok(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), ANIME_URL_KEYS));
                    }

                    if method == Method::Put {
                        let mut req = req;
                        let b: Value = req.json().await?;
                        let (pu, na, da, st, ja, ta) = (
                            b["photo_url"].as_str().unwrap_or("").to_string(),
                            b["name"].as_str().unwrap_or("").to_string(),
                            b["davlat"].as_str().unwrap_or("").to_string(),
                            b["studiya"].as_str().unwrap_or("").to_string(),
                            b["janri"].as_str().unwrap_or("").to_string(),
                            b["tavsif"].as_str().unwrap_or("").to_string(),
                        );
                        let old = turso_exec(&env, "SELECT photo_url FROM anime_db WHERE id=?", vec![TursoArg::int(id)]).await?;
                        let or_ = old["rows"].as_array().cloned().unwrap_or_default();
                        if or_.is_empty() { return err404("Anime topilmadi"); }
                        let oc = old["cols"].as_array().cloned().unwrap_or_default();
                        let op = row_to_obj(&oc, or_[0].as_array().unwrap_or(&vec![]))["photo_url"].as_str().unwrap_or("").to_string();
                        if !op.is_empty() && op != pu { b2_delete(&env, &op).await; }
                        let res = turso_exec(&env,
                            "UPDATE anime_db SET photo_url=?,name=?,davlat=?,studiya=?,janri=?,tavsif=? WHERE id=? RETURNING *",
                            vec![TursoArg::text(&pu), TursoArg::text(&na), TursoArg::text(&da),
                                 TursoArg::text(&st), TursoArg::text(&ja), TursoArg::text(&ta), TursoArg::int(id)],
                        ).await?;
                        let cols = res["cols"].as_array().cloned().unwrap_or_default();
                        let rows = res["rows"].as_array().cloned().unwrap_or_default();
                        if rows.is_empty() { return err500("Yangilashda xato"); }
                        return ok(resolve_fields(&origin, row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])), ANIME_URL_KEYS));
                    }

                    if method == Method::Delete {
                        // CASCADE: anime + barcha bo'limlar + barcha epizodlar (B2 + DB)
                        // 1. Barcha epizod videolarini B2dan o'chirish
                        let eps = turso_exec(&env,
                            "SELECT url_360p,url_480p,url_720p,url_1080p FROM epizod_db WHERE anime_id=?",
                            vec![TursoArg::int(id)]).await?;
                        let ec = eps["cols"].as_array().cloned().unwrap_or_default();
                        let er = eps["rows"].as_array().cloned().unwrap_or_default();
                        for row in &er { b2_delete_epizod_files(&env, &row_to_obj(&ec, row.as_array().unwrap_or(&vec![]))).await; }
                        turso_exec(&env, "DELETE FROM epizod_db WHERE anime_id=?", vec![TursoArg::int(id)]).await?;
                        // 2. Barcha bo'lim rasmlarini B2dan o'chirish
                        let ss = turso_exec(&env, "SELECT photo_url FROM season_db WHERE anime_id=?", vec![TursoArg::int(id)]).await?;
                        let sc = ss["cols"].as_array().cloned().unwrap_or_default();
                        let sr = ss["rows"].as_array().cloned().unwrap_or_default();
                        for row in &sr {
                            let u = row_to_obj(&sc, row.as_array().unwrap_or(&vec![]))["photo_url"].as_str().unwrap_or("").to_string();
                            if !u.is_empty() { b2_delete(&env, &u).await; }
                        }
                        turso_exec(&env, "DELETE FROM season_db WHERE anime_id=?", vec![TursoArg::int(id)]).await?;
                        // 3. Anime rasmini B2dan o'chirish + anime_db dan o'chirish
                        let old = turso_exec(&env, "SELECT photo_url FROM anime_db WHERE id=?", vec![TursoArg::int(id)]).await?;
                        let or_ = old["rows"].as_array().cloned().unwrap_or_default();
                        if or_.is_empty() { return err404("Anime topilmadi"); }
                        let oc = old["cols"].as_array().cloned().unwrap_or_default();
                        let op = row_to_obj(&oc, or_[0].as_array().unwrap_or(&vec![]))["photo_url"].as_str().unwrap_or("").to_string();
                        if !op.is_empty() { b2_delete(&env, &op).await; }
                        turso_exec(&env, "DELETE FROM anime_db WHERE id=?", vec![TursoArg::int(id)]).await?;
                        return ok(json!({"success": true}));
                    }
                }
            }

            err404("Not found")
        }
    }
}
