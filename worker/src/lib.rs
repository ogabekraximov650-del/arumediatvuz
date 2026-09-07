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

/// Jadvallar SHU IZOLYATDA allaqachon tekshirilganmi.
///
/// ═══════════════════════════════════════════════════════════════
///  MIQYOS UCHUN ENG MUHIM TUZATISH
/// ═══════════════════════════════════════════════════════════════
///
/// TOPILGAN XATO: `init_db` HAR BIR API so'rovida chaqirilardi va
/// har safar 10 ta DDL buyrug'ini (CREATE TABLE / CREATE INDEX /
/// ALTER TABLE) Turso'ga yuborardi. Ya'ni foydalanuvchi ilovani
/// ochib ro'yxatni ko'rgani uchun ham bazaga 10 ta ortiqcha
/// so'rov ketardi.
///
/// 1000 foydalanuvchida bu sezilmaydi. 100 ming (yoki 1 million)
/// foydalanuvchida esa bu Turso'ni butunlay to'xtatib qo'yadi:
/// har bir oddiy ro'yxat so'rovi 11 ta baza so'roviga aylanadi va
/// javob vaqti bir necha soniyagacha cho'ziladi.
///
/// YECHIM: jadvallar bir marta yaratilsa yetarli. Cloudflare bitta
/// "izolyat"ni minglab so'rov uchun qayta ishlatadi, shu sabab bu
/// bayroq amalda DDL so'rovlarini MINGLAB BAROBAR kamaytiradi
/// (yangi izolyat ko'tarilganda atigi bir marta ishlaydi).
static DB_READY: core::sync::atomic::AtomicBool =
    core::sync::atomic::AtomicBool::new(false);

/// Jadvallar borligiga BIR MARTA ishonch hosil qiladi.
async fn ensure_db(env: &Env) {
    use core::sync::atomic::Ordering;
    if DB_READY.load(Ordering::Relaxed) {
        return;
    }
    init_db(env).await;
    DB_READY.store(true, Ordering::Relaxed);
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
// bo'yicha saqlanadi: ilova har doim aniq 4 MiB'lik, tekislangan
// "guruh" so'raydi, shu sabab kesh kalitlari barqaror va qayta
// ishlatiladi. Oraliq birinchi so'ralganda B2'dan BIR MARTA
// olinadi, mijozga darhol beriladi va fon'da (`wait_until`) keshga
// yoziladi (400 kunga). Keyingi barcha so'rovlar — boshqa
// foydalanuvchilardan ham — B2'ga umuman chiqmasdan Cloudflare
// chekkasidan xizmat qiladi.
//
// Xotira: bir so'rovda eng ko'pi 8 MB (RANGE_MAX) — worker'ning
// 128 MB chegarasidan uzoq. Fayl 166 MB bo'lsin, 10 GB bo'lsin,
// xotira sarfi bir xil.
//
// ── B2 XARAJATI ──────────────────────────────────────────────
// B2'da har bir yuklab olish so'rovi "Class B" tranzaksiya, ya'ni
// pul. Ilova bo'laklarni 4 tadan guruh qilib so'ragani uchun
// 166 MB'lik video B2'ga ATIGI ~42 ta so'rov qiladi (bo'lakma-bo'lak
// bo'lganda 166 ta bo'lardi). Ustiga bu so'rovlar FAQAT keshda
// bo'lmagan oraliqlar uchun ketadi — bir marta keshga tushgach,
// o'sha oraliq 400 kun davomida barcha foydalanuvchilarga
// Cloudflare chekkasidan, B2'ga umuman chiqmasdan xizmat qiladi.
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

/// ── ISITISH OYNASI: BITTA KESH YOZUVI ─────────────────────────
///
/// Butun fayl (yoki uning 480 MB'lik bo'lagi) BITTA kesh yozuviga
/// yoziladi. Shundan keyin ilova so'raydigan har qanday oraliq
/// AYNAN SHU yozuvdan, Cloudflare chekkasidan kesib beriladi va
/// B2'ga umuman chiqilmaydi.
///
/// NEGA AYNAN 480 MB:
///   * kesh yozuvi qancha KATTA bo'lsa, bitta faylni to'liq
///     qoplash uchun shuncha KAM isitish so'rovi kerak, ya'ni B2
///     tranzaksiyalari shuncha kam;
///   * Cloudflare Cache API'ning eng katta obyekt chegarasi
///     512 MB — 480 bilan 32 MB zaxira qoladi;
///   * 480 MiB aynan 4 MiB'ga karrali (480 / 4 = 120), shu sabab
///     ilovaning 4 MiB'lik guruhlari oyna chegarasini HECH QACHON
///     kesib o'tmaydi.
const WARM_WINDOW: u64 = 480 * 1024 * 1024;

/// Isitish belgisi shu muddat yashaydi — bir vaqtda bitta oyna
/// uchun faqat BITTA isitish ketishini ta'minlaydi.
///
/// AVVAL 15 DAQIQA EDI va bu xato edi: isitish o'rtada uzilib
/// qolsa (tarmoq uzildi, ilova yopildi), belgi yana 15 daqiqa
/// turar va SHU DAVOMIDA qayta isitish umuman boshlanmasdi —
/// kesh esa bo'sh qolaverardi. Endi 2 daqiqa: uzilgan isitish
/// tezda qayta boshlanadi. Bitta isitishning o'zi (480 MiB)
/// odatda 10-30 soniyada tugaydi, ya'ni 2 daqiqa yetarli
/// zaxira.
const WARM_MARKER_SECONDS: u64 = 120;

/// Boshqa birov isitayotganda kutish qadami va qadamlar soni.
///
/// ── NEGA 110 SONIYA (avval 60 edi) ────────────────────────────
///
/// Bir vaqtda minglab foydalanuvchi bitta yangi qismni ochsa,
/// birinchisi "isitish belgisi"ni qo'yadi va oynani keshga
/// ko'chiradi; qolganlari esa kutadi. Kutish belgining muddatidan
/// (`WARM_MARKER_SECONDS` = 120 s) QISQA bo'lsa, kutayotganlar
/// vaqtidan oldin taslim bo'lib, O'ZLARI ham isitishni boshlab
/// yuborardi — ya'ni bitta oyna B2'dan bir necha marta o'qilardi
/// (bu esa to'g'ridan-to'g'ri pul).
///
/// 110 soniya belgining muddatidan bir oz qisqa: hali tirik
/// isitish har doim kutib olinadi, o'lib qolgani esa (belgi
/// muddati o'tgach) qaytadan boshlanadi.
const WARM_WAIT_STEP_MS: u64 = 1000;
const WARM_WAIT_TICKS: u32 = 110;

/// Keshga yozilgandan keyin uni o'qib tasdiqlash urinishlari.
/// Yozuv chekkada ko'rinishi uchun ba'zan bir-ikki soniya kerak.
const WARM_VERIFY_TICKS: u32 = 5;

fn warm_marker_url(file_name: &str, widx: u64) -> String {
    cache_key_url(file_name, &format!("warm{widx}"))
}

fn warm_window_url(file_name: &str, widx: u64) -> String {
    cache_key_url(file_name, &format!("w{widx}"))
}

/// Oyna keshda bo'lsa — faylning umumiy hajmini qaytaradi.
/// Bitta bayt so'raladi, ya'ni tekshiruv juda arzon.
async fn warm_window_total(file_name: &str, widx: u64) -> Option<u64> {
    let mut h = Headers::new();
    h.set("Range", "bytes=0-0").ok()?;
    let probe = Request::new_with_init(
        &warm_window_url(file_name, widx),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )
    .ok()?;
    let hit = Cache::default().get(&probe, false).await.ok()??;
    let total = hit
        .headers()
        .get("X-Total-Size")
        .ok()
        .flatten()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    Some(total)
}

/// ── UZUNLIGI MA'LUM OQIM (FixedLengthStream) ────────────────────
///
/// MUAMMO: Cloudflare keshidagi yozuvdan ORALIQ kesib olish (206)
/// faqat yozuvning UZUNLIGI ma'lum bo'lsagina ishlaydi. Oqim bilan
/// uzatilayotgan javobga esa `Content-Length` sarlavhasini qo'lda
/// yozib bo'lmaydi — runtime uni tashlab yuboradi (o'lchab
/// tekshirildi: yozib ko'rildi, kesh baribir 200 qaytardi).
///
/// YECHIM: Cloudflare aynan shu holat uchun `FixedLengthStream`
/// beradi — bu uzunligi OLDINDAN e'lon qilingan quvur. Undan
/// o'tgan javobga runtime `Content-Length`ni O'ZI qo'yadi va
/// xotiraga hech narsa yig'ilmaydi.
///
/// Baytlar quvurdan fon'da oqadi (`pipeTo` kutilmaydi) — biz esa
/// o'qish tomonini (readable) javob tanasi sifatida beramiz.
/// `FixedLengthStream` obyektini yaratadi va (readable, writable)
/// juftligini qaytaradi.
///
/// `fixed_length_stream` bundan faqat `readable` tomonini oladi;
/// bir nechta manbani KETMA-KET bitta javobga ulash uchun esa
/// `writable` ham kerak bo'ladi (`stitched_window_stream`ga qarang).
fn fixed_length_pipe(
    len: u64,
) -> Result<(web_sys::ReadableStream, web_sys::WritableStream)> {
    use worker::wasm_bindgen::{JsCast, JsValue};

    let global = js_sys::global();
    let ctor = js_sys::Reflect::get(&global, &JsValue::from_str("FixedLengthStream"))
        .map_err(|_| Error::RustError("FixedLengthStream topilmadi".into()))?;
    let ctor: js_sys::Function = ctor
        .dyn_into()
        .map_err(|_| Error::RustError("FixedLengthStream funksiya emas".into()))?;
    let args = js_sys::Array::new();
    args.push(&JsValue::from_f64(len as f64));
    let obj = js_sys::Reflect::construct(&ctor, &args)
        .map_err(|_| Error::RustError("FixedLengthStream yaratilmadi".into()))?;
    let readable = js_sys::Reflect::get(&obj, &JsValue::from_str("readable"))
        .map_err(|_| Error::RustError("readable yo'q".into()))?
        .dyn_into::<web_sys::ReadableStream>()
        .map_err(|_| Error::RustError("readable noto'g'ri turda".into()))?;
    let writable = js_sys::Reflect::get(&obj, &JsValue::from_str("writable"))
        .map_err(|_| Error::RustError("writable yo'q".into()))?
        .dyn_into::<web_sys::WritableStream>()
        .map_err(|_| Error::RustError("writable noto'g'ri turda".into()))?;
    Ok((readable, writable))
}

fn fixed_length_stream(
    src: &web_sys::ReadableStream,
    len: u64,
) -> Result<web_sys::ReadableStream> {
    use worker::wasm_bindgen::{JsCast, JsValue};

    let global = js_sys::global();
    let ctor = js_sys::Reflect::get(&global, &JsValue::from_str("FixedLengthStream"))
        .map_err(|_| Error::RustError("FixedLengthStream topilmadi".into()))?;
    let ctor: js_sys::Function = ctor
        .dyn_into()
        .map_err(|_| Error::RustError("FixedLengthStream funksiya emas".into()))?;
    let args = js_sys::Array::new();
    args.push(&JsValue::from_f64(len as f64));
    let obj = js_sys::Reflect::construct(&ctor, &args)
        .map_err(|_| Error::RustError("FixedLengthStream yaratilmadi".into()))?;
    let readable = js_sys::Reflect::get(&obj, &JsValue::from_str("readable"))
        .map_err(|_| Error::RustError("readable yo'q".into()))?;
    let writable = js_sys::Reflect::get(&obj, &JsValue::from_str("writable"))
        .map_err(|_| Error::RustError("writable yo'q".into()))?;

    // `pipeTo` dinamik chaqiriladi (WritableStream turi web-sys'da
    // yoqilmagan bo'lishi mumkin). Qaytgan Promise KUTILMAYDI.
    let pipe_to = js_sys::Reflect::get(src, &JsValue::from_str("pipeTo"))
        .map_err(|_| Error::RustError("pipeTo yo'q".into()))?;
    let pipe_to: js_sys::Function = pipe_to
        .dyn_into()
        .map_err(|_| Error::RustError("pipeTo funksiya emas".into()))?;
    pipe_to
        .call1(src, &writable)
        .map_err(|_| Error::RustError("pipeTo ishlamadi".into()))?;

    readable
        .dyn_into::<web_sys::ReadableStream>()
        .map_err(|_| Error::RustError("readable ReadableStream emas".into()))
}

/// ═══════════════════════════════════════════════════════════════
///  GET /api/warm/:filename[?w=N]  — OYNANI KESHGA ISITISH
/// ═══════════════════════════════════════════════════════════════
///
/// ── NEGA ALOHIDA SO'ROV ─────────────────────────────────────────
///
/// Isitish ilgari `wait_until` (fon vazifasi) bilan qilinardi va
/// AYNAN SHU uni buzardi: Cloudflare `waitUntil` uchun javob
/// yuborilgandan keyin ATIGI 30 SONIYA beradi. 450 MB'ni 30
/// soniyada ko'chirib bo'lmasdi — isitish o'rtada uzilar, keshga
/// hech narsa tushmas, "isitish belgisi" esa qayta urinishni
/// bloklab turardi. Natijada kesh HECH QACHON to'lmasdi va har bir
/// so'rov B2'ga borardi.
///
/// Cloudflare qoidasi esa boshqacha: MIJOZ ULANIB TURGANDA
/// so'rovning davomiyligiga CHEGARA YO'Q. Shu sabab isitish endi
/// ALOHIDA, ODDIY so'rov sifatida bajariladi — ilova uni ochadi va
/// tugaguncha ulanib turadi. Worker esa o'sha davomida "uyg'oq"
/// qoladi va 448 MB'ni bemalol ko'chiradi.
///
/// Tana OQIM (quvur) orqali o'tadi — xotiraga umuman yig'ilmaydi,
/// shu sabab worker'ning 128 MB chegarasi muammo bo'lmaydi.
///
/// Javob: {"status":"cached"|"warmed"|"error ...","total":N}
///
/// "warming" holati BOSHQA YO'Q: boshqa birov isitayotgan bo'lsa
/// bu so'rov o'sha isitish tugashini KUTADI va natijani qaytaradi.
/// Faqat "cached"/"warmed" javobi oyna keshda ekanini bildiradi va
/// ilova AYNAN shunga qarab pleyerni ochadi.
async fn b2_warm(env: &Env, file_name: &str, widx: u64, force: bool) -> Result<Response> {
    // Javobda faylning UMUMIY hajmi ham qaytariladi — shu bilan
    // ilova hajmni bilish uchun ALOHIDA so'rov yubormaydi, ya'ni
    // B2'ga bitta ham ortiqcha murojaat bo'lmaydi.
    let reply = |status: &str, total: u64| -> Result<Response> {
        // Diagnostika matni JSON'ni buzmasin.
        let status: String = status
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || " :-_.,()".contains(*c))
            .collect();
        let mut r = Response::ok(format!(
            "{{\"status\":\"{status}\",\"total\":{total}}}"
        ))?;
        set_cors(&mut r);
        r.headers_mut().set("Content-Type", "application/json")?;
        r.headers_mut().set("Cache-Control", "no-store")?;
        Ok(r)
    };

    // 1) Allaqachon keshdami — ish tamom (hajmni keshdagi
    //    yozuvning o'zidan olamiz).
    //
    // `force=1` bo'lsa bu tekshiruvlar o'tkazib yuboriladi: keshdagi
    // yozuv eskirgan yoki noto'g'ri shaklda bo'lsa, uni QAYTADAN
    // yozish uchun kerak.
    if !force {
        // MUHIM: hajmi 0 bo'lgan yozuv "keshda bor" hisoblanmaydi —
        // undan pleyerga oraliq kesib berib bo'lmaydi
        // (`play_from_warm_cache` ham uni rad etadi). Aks holda
        // isitish "cached" deb yolg'on javob qaytarardi.
        if let Some(total) = warm_window_total(file_name, widx).await {
            if total > 0 {
                return reply("cached", total);
            }
        }
    }

    // ── 2) BOSHQA BIROV AYNAN HOZIR ISITAYAPTIMI ─────────────
    //
    // TUZATILGAN XATO (onlayn video ochilmasligining asosiy
    // sababi): ilgari bu yerda shunchaki `{"status":"warming"}`
    // qaytarilardi. Ilova esa buni "tayyor" deb hisoblab pleyerni
    // ochar, `/api/play/...` hali keshsiz bo'lgani uchun 503
    // qaytarar va ekranda "Videoni yuklab bo'lmadi" chiqardi.
    // Bundan ham yomoni: birinchi isitish uzilib qolgan bo'lsa,
    // belgi qayta urinishni bloklab turar va muammo o'z-o'zidan
    // tuzalmasdi.
    //
    // ENDI: belgi turgan bo'lsa, biz KUTAMIZ — oyna keshda paydo
    // bo'lishini har soniyada tekshirib turamiz va paydo bo'lishi
    // bilan "cached" deb javob beramiz. Ya'ni ikkinchi chaqiruvchi
    // ham HAQIQIY natijani oladi va B2'ga BITTA ham qo'shimcha
    // so'rov ketmaydi.
    //
    // Belgi turgani bilan oyna kutish muddati ichida paydo
    // bo'lmasa — demak o'sha isitish o'lgan. Bunday holatda belgi
    // e'tiborsiz qoldiriladi va isitish O'ZIMIZ tomonidan
    // qaytadan boshlanadi (aks holda video hech qachon
    // ochilmasdi).
    let cache = Cache::default();
    let marker_key = Request::new(&warm_marker_url(file_name, widx), Method::Get)?;
    if !force && cache.get(&marker_key, false).await?.is_some() {
        for _ in 0..WARM_WAIT_TICKS {
            Delay::from(core::time::Duration::from_millis(WARM_WAIT_STEP_MS)).await;
            if let Some(total) = warm_window_total(file_name, widx).await {
                if total > 0 {
                    return reply("cached", total);
                }
            }
        }
        // Belgi bor, lekin oyna paydo bo'lmadi — o'sha isitish
        // o'lgan. Pastda o'zimiz isitamiz.
    }
    let mut marker = Response::ok("1")?;
    marker
        .headers_mut()
        .set("Cache-Control", &format!("public, max-age={WARM_MARKER_SECONDS}"))?;
    let _ = cache.put(&marker_key, marker).await;

    let key = Request::new(&warm_window_url(file_name, widx), Method::Get)?;
    let acc = b2_access(env).await?;

    // ── FAYL BITTA OYNAGA SIG'ADIMI ──────────────────────────
    //
    // 3) Oynani B2'dan ORALIQ bilan olamiz va OQIM bilan keshga
    //    yozamiz (xotiraga yig'ilmaydi).
    let win_start = widx * WARM_WINDOW;
    let win_end = win_start + WARM_WINDOW - 1;
    let req = b2_range_request(&acc, file_name, win_start, win_end)?;
    let mut resp = Fetch::Request(req).send().await?;
    let status = resp.status_code();
    if status != 200 && status != 206 {
        return reply("error", 0);
    }
    let ct = resp
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());

    // ── FAYLNING UMUMIY HAJMINI ANIQLASH ─────────────────────
    //
    // TUZATILGAN XATO (qurilmada emas, worker'da o'lchandi):
    // hajm FAQAT `Content-Range` dan olinardi. B2 esa oraliq
    // butun faylni qoplaganda (biz har doim 480 MiB so'raymiz,
    // fayl esa odatda undan kichik) javobni `206 + Content-Range`
    // emas, `200` bilan — Content-Range'siz — qaytarishi mumkin.
    // O'shanda hajm 0 bo'lib chiqar, isitish esa
    // "error hajm noma'lum" bilan tugardi. `?force=1` yo'li AYNAN
    // shu sabab HAR DOIM yiqilardi — ya'ni ilovaning "majburan
    // qayta isitish" yo'li umuman ishlamasdi.
    //
    // Endi uch manba ketma-ket sinaladi:
    //   1) `Content-Range` (206 javob) — eng ishonchlisi;
    //   2) 200 javobda `Content-Length` = FAYLNING to'liq hajmi;
    //   3) 206 bo'lsa-yu Content-Range o'qilmasa — oyna boshi +
    //      uzatilayotgan uzunlik.
    let cr_total = resp
        .headers()
        .get("Content-Range")?
        .and_then(|c| parse_content_range(&c))
        .map(|(_, _, t)| t)
        .filter(|t| *t > 0);
    let content_len = resp
        .headers()
        .get("Content-Length")?
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|v| *v > 0);
    let total = match cr_total {
        Some(t) => t,
        None if status == 200 => content_len.unwrap_or(0),
        None => content_len.map(|l| win_start + l).unwrap_or(0),
    };

    // 200 javob BUTUN faylni beradi (0-baytdan boshlab). Bu faqat
    // birinchi oyna uchun to'g'ri keladi; keyingi oynalar uchun
    // baytlar noto'g'ri joydan bo'lardi, shu sabab bunday holatda
    // isitmaymiz (bu amalda faqat 480 MiB'dan katta fayllarda va
    // faqat B2 Range'ni e'tiborsiz qoldirsa yuz beradi).
    if status == 200 && win_start > 0 {
        return reply("error 200 javob oyna uchun yaramaydi", total);
    }

    // ── ENG MUHIM SARLAVHA: `Content-Length` ─────────────────
    //
    // Tekshirib ko'rildi: Cloudflare keshi yozuvdan ORALIQ kesib,
    // 206 bilan qaytara OLADI — lekin faqat yozuvning uzunligi
    // ma'lum bo'lsa. Aks holda u butun javobni 200 bilan beradi va
    // "isitilgan oyna" keshi amalda ishlamaydi (har bir so'rov
    // B2'ga tushadi).
    //
    // B2'ning javobidagi `Content-Length` bu yergacha yetib
    // kelmasligi mumkin (oqim sifatida uzatilganda yo'qoladi), shu
    // sabab uzunlikni O'ZIMIZ hisoblaymiz: oynaning haqiqiy
    // uzunligi = min(oyna oxiri, fayl hajmi) - oyna boshi.
    let win_len = if total > 0 {
        total.min(win_start + WARM_WINDOW).saturating_sub(win_start)
    } else {
        0
    };

    if win_len == 0 {
        // Diagnostika: kelasi safar sabab darhol ko'rinsin.
        return reply(
            &format!(
                "error hajm noma'lum (status {status}, content-length {})",
                content_len.unwrap_or(0)
            ),
            total,
        );
    }
    let src = match resp.body() {
        ResponseBody::Stream(rs) => rs.clone(),
        _ => return reply("error oqim yo'q", total),
    };
    // Uzunligi e'lon qilingan quvur — keshdagi yozuvda
    // `Content-Length` shu tufayli paydo bo'ladi.
    let readable = match fixed_length_stream(&src, win_len) {
        Ok(r) => r,
        Err(e) => return reply(&format!("error {e}"), total),
    };
    let headers = Headers::new();
    headers.set("Content-Type", &ct)?;
    headers.set("Accept-Ranges", "bytes")?;
    headers.set("Cache-Control", &format!("public, max-age={CHUNK_CACHE_SECONDS}"))?;
    headers.set("X-Total-Size", &total.to_string())?;
    headers.set("X-Window-Start", &win_start.to_string())?;
    let to_cache = Response::from_body(ResponseBody::Stream(readable))?
        .with_headers(headers)
        .with_status(200);
    if cache.put(&key, to_cache).await.is_err() {
        return reply("error keshga yozilmadi", total);
    }

    // ── YOZILGANINI TEKSHIRAMIZ ──────────────────────────────
    //
    // `cache.put` xatosiz tugashi yozuv HAQIQATAN o'qiladigan
    // bo'ldi degani emas: Cloudflare uni darhol chetga surib
    // qo'yishi ham mumkin. Ilgari bu tekshirilmasdi va ilova
    // "warmed" javobiga ishonib pleyerni ochar, `/api/play/...`
    // esa 503 qaytarardi.
    //
    // Endi oyna keshdan O'QIB ko'riladi. Tekshiruv juda arzon —
    // atigi bitta bayt so'raladi va u ham keshdan (B2'ga
    // chiqilmaydi).
    for _ in 0..WARM_VERIFY_TICKS {
        if let Some(t) = warm_window_total(file_name, widx).await {
            if t > 0 {
                return reply("warmed", t);
            }
        }
        Delay::from(core::time::Duration::from_millis(WARM_WAIT_STEP_MS)).await;
    }
    reply("error kesh tasdiqlanmadi", total)
}

/// ═══════════════════════════════════════════════════════════════
///  GET /api/play/:filename  — PLEYER SHU YERDAN OQIM OLADI
/// ═══════════════════════════════════════════════════════════════
///
/// ── QAT'IY QOIDA: BU YERDAN B2'GA UMUMAN CHIQILMAYDI ───────────
///
/// Javob FAQAT Cloudflare keshidagi "isitilgan oyna"dan beriladi
/// (`X-Cache: HIT-WINDOW`). Kesh tekin, B2'ning har bir so'rovi esa
/// pul — shu sabab ijro oqimi B2'ga HECH QACHON tegmaydi.
///
/// B2'ga murojaat butun ijro yo'lida ATIGI BITTA joyda bo'ladi:
/// `/api/warm/...` oynani (480 MiB) B2'dan keshga ko'chirganda.
/// Ilova pleyerni ochishdan OLDIN aynan o'sha isitishni chaqiradi
/// va HAQIQATAN tugashini kutadi.
///
/// Kesh tayyor bo'lmasa bu yerda 503 qaytadi va javobda
/// `X-Warm-Window` sarlavhasi bo'ladi — ilova AYNAN o'sha oynani
/// isitib, qaytadan uriniladi.
///
/// ── NEGA ALOHIDA MANZIL KERAK BO'LDI ────────────────────────────
///
/// Ilgari pleyer videoni TELEFONDAGI mahalliy (127.0.0.1) kesh
/// serveri orqali ko'rsatardi. U ikkita muammo tug'dirardi:
///
///   1) ORTIQCHA YUKLASH — mahalliy server pleyer so'ramagan
///      baytlarni ham oldindan (8 MiB'lik guruhlar bilan) tortib
///      olardi. Foydalanuvchi videoning 2 daqiqasini ko'rsa ham,
///      trafik ancha ko'p sarflanardi.
///
///   2) "VIDEO TUGADI" DEB QAYTA BOSHLANISH — mahalliy server
///      bo'lakni ololmasa javobni yarmida to'xtatib, ulanishni
///      yopardi. ExoPlayer uchun javobning erta tugashi "FAYL
///      TUGADI" degani: u videoni tugagan deb bilib, yig'ilgan
///      buferni boshidan qayta ko'rsatardi.
///
/// Shu sabab bu yerda javob HECH QACHON sun'iy ravishda kesilmaydi:
/// so'ralgan oraliq keshdan TO'LIQ berilsagina javob qaytadi, aks
/// holda 503. `/api/image/...` (bo'laklab keshlaydigan yo'l)
/// o'zgarishsiz qoladi — undan endi FAQAT "yuklab olish" tugmasi
/// foydalanadi.
async fn b2_play(
    _env: &Env,
    ctx: &Context,
    file_name: &str,
    range: Option<String>,
) -> Result<Response> {
    // Nima uchun keshdan berib bo'lmaganini aytadi (diagnostika —
    // `X-Warm-Reason` sarlavhasida ko'rinadi).
    let mut reason = String::new();
    if let Some(resp) =
        play_from_warm_cache(ctx, file_name, range.as_deref(), &mut reason).await?
    {
        return Ok(resp);
    }

    // ── KESH TAYYOR EMAS: 503, B2'GA CHIQILMAYDI ─────────────
    //
    // Ilova buni xato deb emas, "oynani isitish kerak" deb
    // tushunadi: `X-Warm-Window` qaysi oynani isitish kerakligini
    // aytadi (480 MiB'dan katta fayllarda bu 0 dan katta bo'ladi).
    //
    // MUHIM: bu yerda B2'ga chiqib "shunchaki ishlab ketsin" deyish
    // MUMKIN EMAS. Har bir bayt B2'dan qayta-qayta olinsa, bu
    // to'g'ridan-to'g'ri pul; kesh esa tekin. Shu sabab yechim
    // "B2'ga chiqish" emas, ISITISHNI ISHONCHLI QILISH — buning
    // uchun `b2_warm` endi haqiqatan kutadi va natijani tekshiradi.
    let widx = range
        .as_deref()
        .and_then(parse_range)
        .map(|(start, _)| start / WARM_WINDOW)
        .unwrap_or(0);
    let mut resp = Response::error("Oyna hali keshga isitilmagan", 503)?;
    set_cors(&mut resp);
    {
        let h = resp.headers_mut();
        h.set("Cache-Control", "no-store")?;
        h.set("X-Cache", "NOT-WARMED")?;
        h.set("X-Warm-Reason", &reason)?;
        h.set("X-Warm-Window", &widx.to_string())?;
        // Ilova AYNAN shu oynani keshga oladi va qayta uriniladi.
        // `Retry-After` bo'lmasa ba'zi mijozlar darhol, to'xtovsiz
        // qayta so'rab, bekorga yuk yaratardi.
        h.set("Retry-After", "1")?;
    }
    Ok(resp)
}

// ═══════════════════════════════════════════════════════════════
//  BIR NECHA OYNANI BITTA JAVOBGA ULASH ("stitching")
// ═══════════════════════════════════════════════════════════════
//
// ── MUAMMO ───────────────────────────────────────────────────
//
// Kesh yozuvi eng ko'pi 480 MiB (Cloudflare chegarasi ~512 MB).
// Ya'ni 1.5 GB'lik fayl 4 ta "oyna"ga bo'linadi.
//
// ExoPlayer esa videoni ochganda `Range: bytes=0-` deb so'raydi va
// javobda E'LON QILINGAN uzunlikni FAYLNING QOLGAN QISMI deb
// biladi. Agar biz atigi bitta oynani (480 MiB) berib, javobni
// shu yerda tugatsak — pleyer buni "FAYL TUGADI" deb tushunadi va
// video 480 MiB'da to'xtab qoladi.
//
// Ilgari bu holat umuman ishlamasdi: `play_from_warm_cache`
// so'ralgan oraliq oynadan chiqib ketsa "outside-window" deb
// javob bermasdi va pleyer 503 olardi. Ya'ni 480 MiB'dan KATTA
// videolar UMUMAN OCHILMASDI.
//
// ── YECHIM ───────────────────────────────────────────────────
//
// Javob tanasi bir nechta oynadan KETMA-KET yig'iladi va
// uzunligi oldindan (to'g'ri qiymat bilan) e'lon qilinadi.
// Baytlar oqim bilan o'tadi — worker xotirasiga hech narsa
// yig'ilmaydi.
//
// MUHIM: bu yerda B2'ga BITTA HAM so'rov ketmaydi. Keyingi oyna
// hali keshda bo'lmasa, u KUTILADI (ilova o'sha paytda uni
// keshga oldirayotgan bo'ladi) — foydalanuvchi uchun bu oddiy
// buferlash bo'lib ko'rinadi. Ya'ni "faqat kerak bo'lgan bo'lak
// keshlanadi" qoidasi buzilmaydi.

/// Keyingi oyna keshda paydo bo'lishini eng ko'pi shuncha kutamiz.
const STITCH_WAIT_TICKS: u32 = 60;

/// Oynadan (kesh yozuvidan) nisbiy oraliqni so'raydi.
async fn window_slice(
    file_name: &str,
    widx: u64,
    rel_start: u64,
    rel_end: u64,
) -> Result<Option<Response>> {
    let h = Headers::new();
    h.set("Range", &format!("bytes={rel_start}-{rel_end}"))?;
    let req = Request::new_with_init(
        &warm_window_url(file_name, widx),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    Cache::default().get(&req, false).await
}

/// Javob AYNAN so'ralgan baytlarni o'z ichiga oladimi.
fn slice_matches(hit: &Response, rel_start: u64, want_len: u64) -> bool {
    match hit.status_code() {
        200 => {
            let len = hit
                .headers()
                .get("Content-Length")
                .ok()
                .flatten()
                .and_then(|v| v.parse::<u64>().ok());
            rel_start == 0 && len == Some(want_len)
        }
        206 => hit
            .headers()
            .get("Content-Range")
            .ok()
            .flatten()
            .and_then(|c| parse_content_range(&c))
            .map(|(s, e, _)| s == rel_start && e == rel_start + want_len - 1)
            .unwrap_or(false),
        _ => false,
    }
}

/// `src` oqimini `dst`ga quyadi, LEKIN `dst`ni yopmaydi (keyingi
/// oyna ham shu quvurga yozilishi kerak).
fn pipe_keep_open(
    src: &web_sys::ReadableStream,
    dst: &web_sys::WritableStream,
) -> Result<js_sys::Promise> {
    use worker::wasm_bindgen::{JsCast, JsValue};
    let f = js_sys::Reflect::get(src, &JsValue::from_str("pipeTo"))
        .map_err(|_| Error::RustError("pipeTo topilmadi".into()))?;
    let f: js_sys::Function = f
        .dyn_into()
        .map_err(|_| Error::RustError("pipeTo funksiya emas".into()))?;
    let opts = js_sys::Object::new();
    let _ = js_sys::Reflect::set(
        &opts,
        &JsValue::from_str("preventClose"),
        &JsValue::TRUE,
    );
    let p = f
        .call2(src, dst, &opts)
        .map_err(|_| Error::RustError("pipeTo bajarilmadi".into()))?;
    p.dyn_into::<js_sys::Promise>()
        .map_err(|_| Error::RustError("pipeTo Promise qaytarmadi".into()))
}

/// Obyektning metodini nomi bo'yicha chaqiradi (web_sys'da
/// mavjudligiga tayanmaslik uchun).
fn call_method(obj: &worker::wasm_bindgen::JsValue, name: &str) -> Option<worker::wasm_bindgen::JsValue> {
    use worker::wasm_bindgen::{JsCast, JsValue};
    let f = js_sys::Reflect::get(obj, &JsValue::from_str(name)).ok()?;
    let f: js_sys::Function = f.dyn_into().ok()?;
    f.call0(obj).ok()
}

/// Quvurni yopadi (hamma oynalar yozilib bo'lgach).
fn close_pipe(dst: &web_sys::WritableStream) {
    use worker::wasm_bindgen::JsCast;
    let v: &worker::wasm_bindgen::JsValue = dst.unchecked_ref();
    if let Some(writer) = call_method(v, "getWriter") {
        let _ = call_method(&writer, "close");
    }
}

/// Quvurni uzadi (xato bo'lganda) — mijoz javobning tugamaganini
/// ko'radi va qayta uriniladi.
fn abort_pipe(dst: &web_sys::WritableStream) {
    use worker::wasm_bindgen::JsCast;
    let v: &worker::wasm_bindgen::JsValue = dst.unchecked_ref();
    let _ = call_method(v, "abort");
}

/// Isitilgan oyna keshi so'ralgan oraliqni TO'LIQ qoplasa — javobni
/// o'sha yerdan (Cloudflare chekkasidan) beradi.
///
/// "To'liq qoplash" shart: kesh AYNAN so'ralgan boshlanish va
/// tugash nuqtasini qaytarishi kerak. Aks holda javob qisqa
/// bo'lib qolardi — ExoPlayer esa buni "fayl tugadi" deb tushunadi.
/// Shu sabab shubha bo'lsa `None` qaytariladi va baytlar B2'dan
/// oqim bilan olinadi.
async fn play_from_warm_cache(
    ctx: &Context,
    file_name: &str,
    range: Option<&str>,
    reason: &mut String,
) -> Result<Option<Response>> {
    let (req_start, req_end_opt) = match range {
        Some(r) => match parse_range(r) {
            Some(v) => v,
            // "bytes=-N" (oxiridan N bayt) — pleyer bunday
            // so'ramaydi, shu sabab bu yerda ishlamaymiz.
            None => {
                *reason = "bad-range".into();
                return Ok(None);
            }
        },
        None => (0, None),
    };

    let widx = req_start / WARM_WINDOW;
    let win_start = widx * WARM_WINDOW;
    let total = match warm_window_total(file_name, widx).await {
        Some(t) if t > 0 => t,
        _ => {
            *reason = "no-window".into();
            return Ok(None);
        }
    };
    if req_start >= total {
        *reason = "start-past-end".into();
        return Ok(None);
    }
    let req_end = req_end_opt.unwrap_or(total - 1).min(total - 1);
    if req_end < req_start {
        *reason = "bad-end".into();
        return Ok(None);
    }
    // ── SO'ROV BIR NECHA OYNANI QAMRAB OLDIMI ────────────────
    //
    // Pleyer videoni ochganda `bytes=0-` deb so'raydi — 480 MiB'dan
    // katta faylda bu bir necha oynaga tegishli bo'ladi. Ilgari
    // shunday so'rov "outside-window" deb rad etilardi va katta
    // videolar UMUMAN ochilmasdi. Endi javob oynalardan ketma-ket
    // yig'iladi (yuqoridagi "stitching" izohiga qarang).
    if req_end >= win_start + WARM_WINDOW {
        return stitched_response(ctx, file_name, req_start, req_end, total, reason).await;
    }

    let rel_start = req_start - win_start;
    let rel_end = req_end - win_start;
    let lookup_h = Headers::new();
    lookup_h.set("Range", &format!("bytes={rel_start}-{rel_end}"))?;
    let lookup = Request::new_with_init(
        &warm_window_url(file_name, widx),
        RequestInit::new().with_method(Method::Get).with_headers(lookup_h),
    )?;
    let Some(mut hit) = Cache::default().get(&lookup, false).await? else {
        *reason = "slice-miss".into();
        return Ok(None);
    };
    let st = hit.status_code();
    let want_len = rel_end - rel_start + 1;
    if st == 200 {
        // ── BUTUN YOZUV SO'RALGANDA KESH 200 QAYTARADI ───────
        //
        // Bu HTTP bo'yicha to'g'ri: so'ralgan oraliq yozuvning
        // o'zi bilan bir xil bo'lsa, server 206 o'rniga 200
        // berishi mumkin. Pleyer videoni ochganda AYNAN shunday
        // so'raydi ("bytes=0-"), shu sabab bu holat oddiy.
        //
        // Lekin uni faqat javob HAQIQATAN so'ralgan baytlar
        // bo'lgandagina qabul qilamiz: boshlanish nuqtasi 0 va
        // uzunlik so'ralganiga teng. Aks holda pleyer noto'g'ri
        // joydan baytlarni olib qolardi.
        let obj_len = hit
            .headers()
            .get("Content-Length")?
            .and_then(|v| v.parse::<u64>().ok());
        if rel_start != 0 || obj_len != Some(want_len) {
            *reason = format!("full-body-{}-vs-{want_len}", obj_len.unwrap_or(0));
            return Ok(None);
        }
    } else if st == 206 {
        // Kesh AYNAN so'ralgan oraliqni berdimi?
        let Some((c_start, c_end, _)) = hit
            .headers()
            .get("Content-Range")?
            .and_then(|c| parse_content_range(&c))
        else {
            *reason = "slice-no-range".into();
            return Ok(None);
        };
        if c_start != rel_start || c_end != rel_end {
            *reason = format!("slice-mismatch-{c_start}-{c_end}");
            return Ok(None);
        }
    } else {
        *reason = format!("slice-status-{st}");
        return Ok(None);
    }

    let ct = hit
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());
    let len = req_end - req_start + 1;
    let is_range = range.is_some();
    let stream = hit.stream()?;
    let mut resp =
        Response::from_stream(stream)?.with_status(if is_range { 206 } else { 200 });
    set_cors(&mut resp);
    {
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "no-store")?;
        h.set("Content-Length", &len.to_string())?;
        if is_range {
            h.set("Content-Range", &format!("bytes {req_start}-{req_end}/{total}"))?;
        }
        h.set("X-Cache", "HIT-WINDOW")?;
    }
    Ok(Some(resp))
}

/// Bir nechta oynadan yig'ilgan BITTA uzluksiz javob.
///
/// Uzunlik oldindan to'g'ri e'lon qilinadi, shu sabab pleyer
/// javobni "fayl tugadi" deb tushunmaydi. Baytlar oqim bilan
/// o'tadi — worker xotirasiga hech narsa yig'ilmaydi va B2'ga
/// BITTA HAM so'rov ketmaydi.
async fn stitched_response(
    ctx: &Context,
    file_name: &str,
    req_start: u64,
    req_end: u64,
    total: u64,
    reason: &mut String,
) -> Result<Option<Response>> {
    let first = req_start / WARM_WINDOW;
    let last = req_end / WARM_WINDOW;

    // ── BIRINCHI OYNA KESHDA BO'LISHI SHART ──────────────────
    // Aks holda javobni umuman boshlab bo'lmaydi: 503 qaytadi va
    // ilova aynan shu oynani keshga oldiradi.
    let fw = first * WARM_WINDOW;
    let f_start = req_start - fw;
    let f_end = (fw + WARM_WINDOW - 1).min(req_end) - fw;
    match window_slice(file_name, first, f_start, f_end).await? {
        Some(probe) if slice_matches(&probe, f_start, f_end - f_start + 1) => {}
        Some(_) => {
            *reason = "stitch-first-mismatch".into();
            return Ok(None);
        }
        None => {
            *reason = "stitch-first-miss".into();
            return Ok(None);
        }
    }

    let len = req_end - req_start + 1;
    let (readable, writable) = fixed_length_pipe(len)?;
    let name = file_name.to_string();

    ctx.wait_until(async move {
        for w in first..=last {
            let ws = w * WARM_WINDOW;
            let s = if w == first { req_start - ws } else { 0 };
            let e = if w == last { req_end - ws } else { WARM_WINDOW - 1 };
            let want = e - s + 1;

            // Oyna hali keshda bo'lmasa — KUTAMIZ. Ayni paytda
            // ilova uni keshga oldirayotgan bo'ladi; foydalanuvchi
            // uchun bu oddiy buferlash bo'lib ko'rinadi. B2'ga bu
            // yerdan hech qachon chiqilmaydi.
            let mut got: Option<Response> = None;
            for _ in 0..STITCH_WAIT_TICKS {
                if let Ok(Some(r)) = window_slice(&name, w, s, e).await {
                    if slice_matches(&r, s, want) {
                        got = Some(r);
                        break;
                    }
                }
                Delay::from(core::time::Duration::from_millis(1000)).await;
            }
            let Some(r) = got else {
                abort_pipe(&writable);
                return;
            };
            let src = match r.body() {
                ResponseBody::Stream(rs) => rs.clone(),
                _ => {
                    abort_pipe(&writable);
                    return;
                }
            };
            match pipe_keep_open(&src, &writable) {
                Ok(pr) => {
                    if worker::wasm_bindgen_futures::JsFuture::from(pr).await.is_err() {
                        abort_pipe(&writable);
                        return;
                    }
                }
                Err(_) => {
                    abort_pipe(&writable);
                    return;
                }
            }
        }
        close_pipe(&writable);
    });

    let mut resp = Response::from_body(ResponseBody::Stream(readable))?.with_status(206);
    set_cors(&mut resp);
    {
        let h = resp.headers_mut();
        h.set("Content-Type", "video/mp4")?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "no-store")?;
        h.set("Content-Length", &len.to_string())?;
        h.set("Content-Range", &format!("bytes {req_start}-{req_end}/{total}"))?;
        h.set("X-Cache", "HIT-STITCH")?;
    }
    Ok(Some(resp))
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
    // ── BIR SO'ROVDA BERILADIGAN ENG KATTA ORALIQ ─────────────
    //
    // Ilova yuklab olishda 16 MiB'lik GURUH so'raydi (worker'ga va
    // B2'ga ketadigan so'rovlar sonini kamaytirish uchun —
    // `GROUP_CHUNKS` izohiga qarang). Kesh oynasi 480 MiB va
    // `480 / 16 = 30`, ya'ni guruh hech qachon oyna chegarasini
    // kesib o'tmaydi.
    //
    // Bu chegara ISITILGAN OYNADAN kesib berish uchun: u yerda
    // baytlar OQIM bilan o'tadi va worker xotirasiga hech narsa
    // yig'ilmaydi, shu sabab 16 MiB xavfsiz.
    const RANGE_MAX: u64 = 16 * 1024 * 1024;

    // ── B2'DAN OLINGANDA CHEGARA KICHIKROQ ────────────────────
    //
    // Kesh bo'sh bo'lgan (nodir) holatda baytlar B2'dan olinadi va
    // XOTIRAGA yig'iladi. Worker'ning 128 MB xotirasi barcha bir
    // vaqtdagi so'rovlar orasida bo'linadi, shu sabab bu yo'lda
    // chegara ataylab kichik.
    //
    // Javob qisqaroq kelishi mijoz uchun muammo emas: u
    // `X-Cache: MISS` sarlavhasini ko'rib, buni serverning DOIMIY
    // chegarasi deb HISOBLAMAYDI va keyingi so'rovlarni baribir
    // 16 MiB bilan yuboradi.
    const B2_RANGE_MAX: u64 = 8 * 1024 * 1024;

    let req_end = req_end_opt
        .unwrap_or(req_start + RANGE_MAX - 1)
        .min(req_start + RANGE_MAX - 1);

    let cache = Cache::default();

    // ── 1) ISITILGAN OYNA KESHIDA BORMI ──────────────────────
    //
    // Ilova video ochilganda (va yuklab olish boshlanganda)
    // `/api/warm/...` ni chaqiradi va butun fayl BITTA kesh
    // yozuviga tushadi. Shundan keyin har qanday oraliq AYNAN
    // shu yozuvdan kesib beriladi — B2'ga umuman chiqilmaydi.
    //
    // Kesishni Cloudflare'ning O'ZI bajaradi: kesh so'roviga
    // `Range` qo'yamiz va u faqat kerakli baytlarni 206 bilan
    // qaytaradi. Ya'ni worker 448 MB'ni hech qachon xotiraga
    // olmaydi.
    let widx = req_start / WARM_WINDOW;
    let win_start = widx * WARM_WINDOW;
    if req_end < win_start + WARM_WINDOW {
        let rel_start = req_start - win_start;
        let rel_end = req_end - win_start;
        let mut lookup_h = Headers::new();
        lookup_h.set("Range", &format!("bytes={rel_start}-{rel_end}"))?;
        let lookup = Request::new_with_init(
            &warm_window_url(file_name, widx),
            RequestInit::new().with_method(Method::Get).with_headers(lookup_h),
        )?;
        if let Some(mut hit) = cache.get(&lookup, false).await? {
            // FAQAT 206 qabul qilinadi: 200 kelsa oraliq kesilmagan
            // va butun oynani mijozga yuborish xato bo'lardi.
            if hit.status_code() == 206 {
                let ct = hit
                    .headers()
                    .get("Content-Type")?
                    .unwrap_or_else(|| "application/octet-stream".to_string());
                let cl = hit.headers().get("Content-Length")?;
                let total = hit
                    .headers()
                    .get("X-Total-Size")?
                    .and_then(|t| t.parse::<u64>().ok())
                    .unwrap_or(0);
                // Keshdagi Content-Range OYNA ichidagi nisbiy
                // oraliqni ko'rsatadi — uni mutlaq oraliqqa
                // o'giramiz.
                let (abs_s, abs_e) = match hit
                    .headers()
                    .get("Content-Range")?
                    .and_then(|c| parse_content_range(&c))
                {
                    Some((s, e, _)) => (win_start + s, win_start + e),
                    None => (req_start, req_end),
                };
                let total_str = if total > 0 {
                    total.to_string()
                } else {
                    (abs_e + 1).to_string()
                };
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
                h.set("Content-Range", &format!("bytes {abs_s}-{abs_e}/{total_str}"))?;
                h.set("X-Cache", "HIT-WINDOW")?;
                return Ok(resp);
            }
        }
    }

    // ── 2) SHU ANIQ ORALIQ KESHIDA BORMI ─────────────────────
    // Oyna hali isitilmagan bo'lsa, oldingi so'rovlardan qolgan
    // aniq oraliqlar shu yerda topiladi.
    //
    // MUHIM: bunday yozuvlar HAR DOIM `B2_RANGE_MAX` o'lchamida
    // saqlanadi (3-bosqichga qarang), shu sabab qidiruv kaliti ham
    // aynan shu o'lchamda hisoblanadi — aks holda yozuv yozilgani
    // bilan hech qachon topilmasdi.
    let miss_end = req_end.min(req_start + B2_RANGE_MAX - 1);
    let cache_url = cache_key_url(file_name, &format!("r{req_start}-{miss_end}"));
    let key = Request::new(&cache_url, Method::Get)?;
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
        h.set("X-Cache", "HIT-RANGE")?;
        return Ok(resp);
    }

    // ── 3) KESH MISS: B2'dan BIR MARTA olamiz ────────────────
    // Bu yo'lda javob xotiraga yig'ilgani uchun oraliq qo'shimcha
    // qisqartiriladi (yuqoridagi `B2_RANGE_MAX` izohiga qarang).
    let req_end = miss_end;
    let (mut b2, total) = b2_fetch_range(env, file_name, req_start, req_end).await?;
    let ct = b2
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());
    // Eng ko'pi B2_RANGE_MAX (8 MiB) — worker xotirasi uchun
    // xavfsiz. Katta oyna HECH QACHON xotiraga olinmaydi.
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

// ═══════════════════════════════════════════════════════════════
//  RO'YXAT SO'ROVLARI UCHUN CHEKKA (EDGE) KESHI
// ═══════════════════════════════════════════════════════════════
//
// MUAMMO (miqyos): anime/bo'lim/qism ro'yxatlari HAR BIR ilova
// ochilishida so'raladi va har bir so'rov Turso'ga boradi. Bir
// vaqtda 100 ming (yoki 1 million) foydalanuvchi bo'lganda baza
// birinchi bo'lib "yiqiladigan" joy aynan shu — chunki bazaning
// bir soniyadagi so'rov chegarasi bor, Cloudflare chekkasiniki
// esa amalda yo'q.
//
// YECHIM: ro'yxat javoblari Cloudflare chekkasida qisqa muddat
// saqlanadi. Bir data-markazdagi MINGLAB foydalanuvchi bitta
// baza so'rovi bilan xizmat qilinadi.
//
// ── NEGA 30 SONIYA ────────────────────────────────────────────
// Kontent kuniga bir necha marta o'zgaradi, ya'ni 30 soniyalik
// "eskirish" foydalanuvchi uchun umuman sezilmaydi. Boshqa
// tomondan, 30 soniya bir data-markazdagi barcha so'rovlarni
// BITTAGA jamlash uchun yetarlicha uzun.
//
// ── ADMIN DARHOL KO'RADI ──────────────────────────────────────
// Har qanday yozish (POST/PUT/DELETE) so'rovidan keyin tegishli
// kesh yozuvlari O'CHIRILADI. Admin ekranidagi keyingi so'rov
// (odatda AYNAN O'SHA data-markazga tushadi) yangi ma'lumotni
// oladi — ya'ni "saqladim, lekin ko'rinmayapti" holati yo'q.
const LIST_CACHE_SECONDS: u64 = 30;

/// Ro'yxat keshining kaliti. So'rov satri (query) ham kalitga
/// kiradi — ya'ni turli filtrlar aralashib ketmaydi.
fn list_cache_url(path: &str, query: Option<&str>) -> String {
    match query {
        Some(q) if !q.is_empty() => {
            format!("https://fulutter-list-cache.internal{path}?{q}")
        }
        _ => format!("https://fulutter-list-cache.internal{path}"),
    }
}

/// Shu manzil keshlanadigan (faqat o'qiydigan) ro'yxatmi.
fn is_list_path(path: &str) -> bool {
    path == "/api/anime"
        || path == "/api/seasons"
        || path.starts_with("/api/anime/janr/")
        || path.starts_with("/api/seasons/anime/")
        || path.starts_with("/api/epizods/")
}

/// Yozishdan keyin qaysi kesh yozuvlari eskiradi.
fn invalidated_list_paths(path: &str) -> Vec<String> {
    let mut out = vec!["/api/anime".to_string(), "/api/seasons".to_string()];
    // /api/epizods/<anime>/<season>[/<epizod>] -> ro'yxat kaliti
    if let Some(rest) = path.strip_prefix("/api/epizods/") {
        let parts: Vec<&str> = rest.split('/').collect();
        if parts.len() >= 2 {
            out.push(format!("/api/epizods/{}/{}", parts[0], parts[1]));
        }
    }
    // /api/seasons/<anime>/<season> -> o'sha anime bo'limlari
    if let Some(rest) = path.strip_prefix("/api/seasons/") {
        let first = rest.split('/').next().unwrap_or("");
        if !first.is_empty() && first != "anime" {
            out.push(format!("/api/seasons/anime/{first}"));
        }
    }
    out
}

/// Kesh yozuvlarini o'chiradi (xatolar e'tiborsiz qoldiriladi —
/// kesh eskirsa ham eng ko'pi 30 soniyadan keyin o'zi yangilanadi).
async fn purge_list_cache(path: &str) {
    let cache = Cache::default();
    for p in invalidated_list_paths(path) {
        if let Ok(k) = Request::new(&list_cache_url(&p, None), Method::Get) {
            let _ = cache.delete(&k, false).await;
        }
    }
}

// ── Router ─────────────────────────────────────────────────────

#[event(fetch)]
async fn main(req: Request, env: Env, ctx: Context) -> Result<Response> {
    let url = req.url()?;
    let path = url.path().to_string();
    let query = url.query().map(|q| q.to_string());
    let method = req.method();

    let cacheable = method == Method::Get && is_list_path(&path);
    let key_url = list_cache_url(&path, query.as_deref());

    // 1) Chekkadagi kesh — bazaga umuman borilmaydi.
    if cacheable {
        if let Ok(k) = Request::new(&key_url, Method::Get) {
            if let Ok(Some(hit)) = Cache::default().get(&k, false).await {
                return Ok(hit);
            }
        }
    }

    let write = matches!(method, Method::Post | Method::Put | Method::Delete);
    let mut resp = route(req, env, ctx).await?;

    // 2) Yozishdan keyin eskirgan yozuvlar o'chiriladi.
    if write && resp.status_code() < 400 {
        purge_list_cache(&path).await;
    }

    // 3) Yangi ro'yxat javobi keshga yoziladi.
    if cacheable && resp.status_code() == 200 {
        let bytes = resp.bytes().await?;
        if let Ok(k) = Request::new(&key_url, Method::Get) {
            if let Ok(mut to_cache) = Response::from_bytes(bytes.clone()) {
                set_cors(&mut to_cache);
                let h = to_cache.headers_mut();
                let _ = h.set("Content-Type", "application/json");
                let _ = h.set(
                    "Cache-Control",
                    &format!("public, max-age={LIST_CACHE_SECONDS}"),
                );
                let _ = Cache::default().put(&k, to_cache).await;
            }
        }
        let mut out = Response::from_bytes(bytes)?;
        set_cors(&mut out);
        {
            let h = out.headers_mut();
            h.set("Content-Type", "application/json")?;
            h.set(
                "Cache-Control",
                &format!("public, max-age={LIST_CACHE_SECONDS}"),
            )?;
        }
        return Ok(out);
    }

    Ok(resp)
}

async fn route(req: Request, env: Env, ctx: Context) -> Result<Response> {
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
        // Pleyer SHU manzildan oqim oladi (b2_play izohiga qarang).
        // Farqi: javob hech qachon sun'iy kesilmaydi va bo'laklab
        // keshlash mantiqi umuman ishlatilmaydi — ya'ni pleyer
        // faqat o'zi so'ragan baytni oladi.
        if let Some(fname) = path.strip_prefix("/api/play/") {
            return b2_play(&env, &ctx, fname, range_header).await;
        }
        // Oynani keshga isitish — ilova video ochilganda BIR MARTA
        // chaqiradi va so'rov tugaguncha ulanib turadi (b2_warm
        // izohiga qarang).
        if let Some(fname) = path.strip_prefix("/api/warm/") {
            let widx = url
                .query_pairs()
                .find(|(k, _)| k == "w")
                .and_then(|(_, v)| v.parse::<u64>().ok())
                .unwrap_or(0);
            let force = url
                .query_pairs()
                .any(|(k, v)| k == "force" && (v == "1" || v == "true"));
            return b2_warm(&env, fname, widx, force).await;
        }
    }

    ensure_db(&env).await;

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

