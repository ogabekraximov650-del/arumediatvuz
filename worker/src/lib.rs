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
    let mut r = Fetch::Request(req).send().await?;

    // ── HAR BIR BUYRUQ NATIJASI TEKSHIRILADI ──────────────────
    //
    // Turso "pipeline" HTTP darajasida 200 qaytaradi, lekin
    // ichidagi buyruqlardan biri yiqilgan bo'lishi mumkin. Ilgari
    // javob umuman o'qilmasdi — ya'ni INSERT yiqilsa ham chaqiruvchi
    // "hammasi joyida" deb o'ylardi. Kirish jarayonida bu eng
    // yomon xatoni berardi: sessiya YOZILMAGAN bo'lsa ham kirish
    // tokeni "tasdiqlangan" deb belgilanardi va foydalanuvchi
    // ilovaga kira olmay qolardi.
    let d: Value = r.json().await.unwrap_or(json!({}));
    if let Some(list) = d["results"].as_array() {
        for item in list {
            if item["type"] == json!("error") {
                let why = item["error"]["message"].as_str().unwrap_or("noma'lum");
                return Err(Error::RustError(format!("baza xatosi: {why}")));
            }
        }
    }
    Ok(())
}

/// Bir nechta buyruqni BITTA so'rovda yuboradi va HAR BIRINING
/// natijasini qaytaradi.
///
/// NEGA KERAK: Turso'ga har bir murojaat — alohida HTTP so'rov,
/// ya'ni yo'l kechikishi (100-200 ms). Bir-biriga bog'liq bo'lmagan
/// buyruqlarni bitta "quvur"ga yig'ish javob vaqtini bir necha
/// barobar qisqartiradi. Statistika va tarix yozuvi aynan shunday
/// ishlaydi: 7 ta buyruq — 1 ta so'rov.
async fn turso_many(env: &Env, stmts: &[(&str, Vec<TursoArg>)]) -> Result<Vec<Value>> {
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
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await.unwrap_or(json!({}));
    let mut out = Vec::with_capacity(stmts.len());
    if let Some(list) = d["results"].as_array() {
        for item in list.iter().take(stmts.len()) {
            if item["type"] == json!("error") {
                let why = item["error"]["message"].as_str().unwrap_or("noma'lum");
                return Err(Error::RustError(format!("baza xatosi: {why}")));
            }
            out.push(item["response"]["result"].clone());
        }
    }
    Ok(out)
}

/// Natijadagi birinchi qatorning birinchi ustuni — son sifatida.
fn scalar(res: &Value) -> i64 {
    let cell = &res["rows"][0][0];
    match cell["value"].as_str() {
        Some(v) => v.parse::<i64>().unwrap_or(0),
        None => cell.as_i64().unwrap_or(0),
    }
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
    migrate_db(env).await;
    DB_READY.store(true, Ordering::Relaxed);
}

/// Eski sxema qolib ketgan bo'lsa — jimgina to'g'rilaydi.
///
/// ═══════════════════════════════════════════════════════════════
///  NEGA KERAK (TOPILGAN XATO)
/// ═══════════════════════════════════════════════════════════════
///
/// Baza tozalangandan keyin, YANGI worker deploy bo'lguncha
/// oraliqda ESKI worker bitta so'rov oldi va o'zining `init_db` si
/// bilan ESKI jadvallarni qaytadan yaratib qo'ydi. Yangi
/// `CREATE TABLE IF NOT EXISTS` esa endi hech narsa qilmaydi —
/// natijada `season_db` da `views_total` kabi ustunlar bo'lmay
/// qoldi va Ma'lumot oynasi 500 xato berardi.
///
/// Shu sabab endi ilova QO'LDA tozalashga TAYANMAYDI: yetishmayotgan
/// ustunlar o'zi qo'shiladi. Tekshiruv arzon — bitta so'rov, va u
/// izolyat umri davomida BIR MARTA bajariladi.
///
/// `ALTER TABLE ... ADD COLUMN` ustun mavjud bo'lganda xato beradi
/// va Turso to'plamdagi birinchi xatodan keyin qolganini
/// BAJARMAYDI — shu sabab har biri ALOHIDA yuboriladi va xatosi
/// e'tiborsiz qoldiriladi.
async fn migrate_db(env: &Env) {
    // Yangi ustunlardan bittasi bormi? Bo'lsa — hammasi joyida.
    let probe = turso_exec(env,
        "SELECT COUNT(*) FROM pragma_table_info('season_db') WHERE name='views_total'",
        vec![]).await;
    if let Ok(res) = &probe {
        if scalar(res) > 0 {
            return;
        }
    }

    for sql in [
        "ALTER TABLE season_db ADD COLUMN epizod_count INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN views_total INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN watch_ms_total INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN fav_count INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN rating_sum INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN rating_count INTEGER DEFAULT 0",
        "ALTER TABLE epizod_db ADD COLUMN views_total INTEGER DEFAULT 0",
        "ALTER TABLE epizod_db ADD COLUMN watch_ms_total INTEGER DEFAULT 0",
        "ALTER TABLE watch_history_db ADD COLUMN watched_ms INTEGER DEFAULT 0",
        "ALTER TABLE watch_history_db ADD COLUMN view_count INTEGER DEFAULT 0",
        "ALTER TABLE watch_history_db ADD COLUMN deleted_at INTEGER DEFAULT 0",
        "ALTER TABLE watch_history_db ADD COLUMN created_at INTEGER",
        // Eski, endi keraksiz indekslar (birlamchi kalit o'zi
        // qoplaydigan yoki umuman ishlatilmaydigan).
        "DROP INDEX IF EXISTS idx_name",
        "DROP INDEX IF EXISTS idx_janri",
        "DROP INDEX IF EXISTS idx_season_anime",
        "DROP INDEX IF EXISTS idx_season_janri",
        "DROP INDEX IF EXISTS idx_epizod_season",
        "DROP INDEX IF EXISTS idx_users_tg",
        "DROP INDEX IF EXISTS idx_sessions_token",
        // Tarix indeksi endi `deleted_at` ni ham o'z ichiga oladi.
        "DROP INDEX IF EXISTS idx_history_user",
        "CREATE INDEX IF NOT EXISTS idx_history_user
           ON watch_history_db(user_id, deleted_at, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_seen
           ON sessions_db(last_seen_at)",
        "CREATE INDEX IF NOT EXISTS idx_users_created
           ON users_db(created_at)",
    ] {
        let _ = turso_exec(env, sql, vec![]).await;
    }
}

async fn init_db(env: &Env) {
    // ═══════════════════════════════════════════════════════════
    //  SXEMA — BITTA JOYDA, TOZA HOLDA
    // ═══════════════════════════════════════════════════════════
    //
    // Baza bir marta butunlay tozalangan (2026-09), shu sabab bu
    // yerda `ALTER TABLE ... ADD COLUMN` yamoqlari YO'Q: har bir
    // jadval o'zining yakuniy ko'rinishida yaratiladi. Yangi ustun
    // kerak bo'lsa — jadvalga qo'shing va ALOHIDA `ALTER` yozing
    // (eski bazalarda ustun bo'lmasligi mumkin).
    //
    // ── VAQT: UTC+5 ────────────────────────────────────────────
    //
    // Hamma vaqt Unix millisekundda (UTC) saqlanadi. Kunlik
    // hisoblar uchun esa `day` / `hour` ustuni yoziladi va u
    // TOSHKENT vaqti bo'yicha hisoblanadi (`day_key` / `hour_key`)
    // — ya'ni "kun" mahalliy yarim tunda almashadi.
    //
    // ── INDEKSLAR: KAM, LEKIN ANIQ ─────────────────────────────
    //
    // Har bir indeks YOZISHNI sekinlashtiradi, shu sabab bu yerda
    // faqat HAQIQATDA ishlatiladigan so'rovlar uchun indeks bor.
    // Birlamchi kalit (PRIMARY KEY) o'zi indeks bo'lgani uchun
    // uning BOSHIDAGI ustunlar bo'yicha qidiruvga qo'shimcha
    // indeks KERAK EMAS — masalan `epizod_db` dan bo'lim
    // qismlarini olish `PK(anime_id, season_id, ...)` bilan
    // ishlaydi.

    // ── 1. KONTENT ─────────────────────────────────────────────
    let _ = turso_batch(env, &[
        ("CREATE TABLE IF NOT EXISTS anime_db (
            id INTEGER PRIMARY KEY,
            photo_url TEXT, name TEXT, davlat TEXT, studiya TEXT,
            janri TEXT, tavsif TEXT,
            created_at INTEGER
        )", vec![]),
        // Indeks yo'q: ro'yxat `ORDER BY id DESC LIMIT 100` (PK),
        // qidiruv esa ILOVANING O'ZIDA (Rust yadrosi) bajariladi.

        ("CREATE TABLE IF NOT EXISTS season_db (
            anime_id INTEGER, season_id INTEGER, bolim_id INTEGER,
            photo_url TEXT, nomi TEXT, studio TEXT, tarjimon TEXT,
            yili TEXT, janri TEXT, turi TEXT, holati TEXT, tavsif TEXT,
            epizod_count INTEGER DEFAULT 0,
            views_total INTEGER DEFAULT 0,
            watch_ms_total INTEGER DEFAULT 0,
            fav_count INTEGER DEFAULT 0,
            rating_sum INTEGER DEFAULT 0,
            rating_count INTEGER DEFAULT 0,
            created_at INTEGER,
            PRIMARY KEY (anime_id, season_id)
        )", vec![]),
        // Indeks yo'q: "anime bo'limlari" so'rovi PK boshidagi
        // `anime_id` bilan ishlaydi, umumiy ro'yxat esa kichik.

        ("CREATE TABLE IF NOT EXISTS epizod_db (
            anime_id INTEGER, season_id INTEGER, epizod_id INTEGER,
            epizod_number INTEGER, epizod_name TEXT,
            url_360p TEXT, size_360p TEXT,
            url_480p TEXT, size_480p TEXT,
            url_720p TEXT, size_720p TEXT,
            url_1080p TEXT, size_1080p TEXT,
            views_total INTEGER DEFAULT 0,
            watch_ms_total INTEGER DEFAULT 0,
            created_at INTEGER,
            PRIMARY KEY (anime_id, season_id, epizod_id)
        )", vec![]),

        // Janrlar — BOG'LOVCHI jadval. Bitta bo'limda bir nechta
        // janr bo'ladi; `season_db.janri` esa faqat KO'RSATISH
        // uchun saqlanadigan matn nusxasi.
        ("CREATE TABLE IF NOT EXISTS season_janr (
            anime_id INTEGER, season_id INTEGER, janr TEXT,
            PRIMARY KEY (anime_id, season_id, janr)
        )", vec![]),
        // Janr bo'yicha filtr uchun (PK bu tartibda yordam bermaydi).
        ("CREATE INDEX IF NOT EXISTS idx_janr ON season_janr(janr)", vec![]),
    ]).await;

    // ── 2. FOYDALANUVCHI ───────────────────────────────────────
    let _ = turso_batch(env, &[
        ("CREATE TABLE IF NOT EXISTS users_db (
            id INTEGER PRIMARY KEY,
            telegram_id INTEGER UNIQUE,
            username TEXT, first_name TEXT, last_name TEXT,
            language_code TEXT,
            is_premium INTEGER DEFAULT 0,
            is_banned INTEGER DEFAULT 0,
            balance INTEGER DEFAULT 0,
            avatar_file TEXT,
            profile_done INTEGER DEFAULT 1,
            created_at INTEGER,
            last_login_at INTEGER
        )", vec![]),
        // `telegram_id UNIQUE` o'zi indeks — alohida indeks KERAK EMAS.
        // Username takrorlanmasin (bo'shlar indeksga kirmaydi).
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_users_uname
            ON users_db(LOWER(username)) WHERE username <> ''", vec![]),
        // Statistika: "shu davrda nechta hisob ochilgan".
        ("CREATE INDEX IF NOT EXISTS idx_users_created ON users_db(created_at)", vec![]),

        ("CREATE TABLE IF NOT EXISTS login_tokens (
            token TEXT PRIMARY KEY,
            status TEXT,
            user_id INTEGER,
            session_token TEXT,
            device TEXT, platform TEXT, app_version TEXT, api_base TEXT,
            created_at INTEGER,
            expires_at INTEGER
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_login_exp ON login_tokens(expires_at)", vec![]),

        ("CREATE TABLE IF NOT EXISTS sessions_db (
            id INTEGER PRIMARY KEY,
            user_id INTEGER,
            telegram_id INTEGER,
            username TEXT,
            first_name TEXT,
            session_token TEXT UNIQUE,
            api_base TEXT,
            device TEXT,
            platform TEXT,
            app_version TEXT,
            created_at INTEGER,
            last_seen_at INTEGER
        )", vec![]),
        // `session_token UNIQUE` o'zi indeks — qo'shimchasi kerak emas.
        // Qurilmalar ro'yxati va 4 ta chegara uchun:
        ("CREATE INDEX IF NOT EXISTS idx_sessions_user
            ON sessions_db(user_id, last_seen_at)", vec![]),
        // KUNLIK FAOL FOYDALANUVCHI: oxirgi 24 soatda kim onlayn
        // bo'lgani AYNAN shu indeks bilan sanaladi.
        ("CREATE INDEX IF NOT EXISTS idx_sessions_seen
            ON sessions_db(last_seen_at)", vec![]),
    ]).await;

    // ── 3. TOMOSHA, BAHO, SEVIMLILAR, STATISTIKA ───────────────
    let _ = turso_batch(env, &[
        // Bitta qism uchun HAR DOIM bitta qator.
        //
        //   watched_ms — shu odam shu qismni JAMI qancha ko'rgani
        //                (1x tezlikda, qism uzunligidan oshmaydi);
        //   view_count — necha marta ochib ko'rgani;
        //   deleted_at — 0 bo'lmasa, tarixda KO'RINMAYDI. Yozuv
        //                o'chirilmaydi: qism qayta ko'rilsa yana
        //                paydo bo'ladi va statistika buzilmaydi.
        ("CREATE TABLE IF NOT EXISTS watch_history_db (
            user_id INTEGER,
            anime_id INTEGER,
            season_id INTEGER,
            epizod_number INTEGER,
            video_url TEXT,
            position_ms INTEGER,
            duration_ms INTEGER,
            watched_ms INTEGER DEFAULT 0,
            view_count INTEGER DEFAULT 0,
            deleted_at INTEGER DEFAULT 0,
            created_at INTEGER,
            updated_at INTEGER,
            PRIMARY KEY (user_id, anime_id, season_id, epizod_number)
        )", vec![]),
        // Tarix ro'yxati AYNAN shu tartibda so'raladi:
        // WHERE user_id=? AND deleted_at=0 ORDER BY updated_at DESC
        ("CREATE INDEX IF NOT EXISTS idx_history_user
            ON watch_history_db(user_id, deleted_at, updated_at DESC)", vec![]),

        // Baho — bitta odam, bitta BO'LIM uchun bitta baho (1..10).
        // O'rtacha qiymat `season_db` da yig'ilib boradi, shu sabab
        // bu jadvalga qo'shimcha indeks kerak emas.
        ("CREATE TABLE IF NOT EXISTS ratings_db (
            user_id INTEGER, anime_id INTEGER, season_id INTEGER,
            stars INTEGER,
            created_at INTEGER, updated_at INTEGER,
            PRIMARY KEY (user_id, anime_id, season_id)
        )", vec![]),

        // Sevimlilar — bo'lim darajasida.
        ("CREATE TABLE IF NOT EXISTS favorites_db (
            user_id INTEGER, anime_id INTEGER, season_id INTEGER,
            created_at INTEGER,
            PRIMARY KEY (user_id, anime_id, season_id)
        )", vec![]),

        // ── STATISTIKA CHELAKLARI ─────────────────────────────
        //
        // Hodisalar RO'YXATI saqlanmaydi (u millionlab qator
        // bo'lardi) — faqat yig'indilar:
        //
        //   stats_hourly — "oxirgi 24 soat" uchun (24 ta qator);
        //   stats_daily  — hafta/oy/yil/jami uchun (yiliga ~365).
        //
        // `metric`: 'views' | 'traffic' | 'watch_ms'.
        ("CREATE TABLE IF NOT EXISTS stats_hourly (
            hour TEXT, metric TEXT, value INTEGER,
            PRIMARY KEY (hour, metric)
        )", vec![]),
        ("CREATE TABLE IF NOT EXISTS stats_daily (
            day TEXT, metric TEXT, value INTEGER,
            PRIMARY KEY (day, metric)
        )", vec![]),

        // Worker ichki sozlamalari (webhook siri va manzili).
        ("CREATE TABLE IF NOT EXISTS app_config (
            cfg_key TEXT PRIMARY KEY,
            cfg_value TEXT
        )", vec![]),
    ]).await;
}

// ═══════════════════════════════════════════════════════════════
//  VAQT — TOSHKENT (UTC+5)
// ═══════════════════════════════════════════════════════════════
//
// Statistika chelaklari AYNAN shu funksiyalar bilan belgilanadi.
// Ularni o'zgartirmang: eski qatorlar boshqa mintaqada yozilgan
// bo'lsa, hisob siljib ketadi.

const UTC5_OFFSET_MS: i64 = 5 * 3600 * 1000;

/// Unix ms -> "YYYY-MM-DD" (Toshkent vaqti bo'yicha).
fn day_key(ms: i64) -> String {
    let (y, m, d, _, _) = ymdhm(ms + UTC5_OFFSET_MS);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Unix ms -> "YYYY-MM-DDTHH" (Toshkent vaqti bo'yicha).
fn hour_key(ms: i64) -> String {
    let (y, m, d, h, _) = ymdhm(ms + UTC5_OFFSET_MS);
    format!("{y:04}-{m:02}-{d:02}T{h:02}")
}

/// Unix ms (allaqachon siljitilgan) -> (yil, oy, kun, soat, daqiqa).
///
/// Tashqi kutubxonasiz: WASM hajmi ortmasin. Sanani hisoblash
/// "fuqarolik kalendaridan kunlar" algoritmi (Howard Hinnant).
fn ymdhm(ms: i64) -> (i64, i64, i64, i64, i64) {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (h, mi) = (rem / 3600, (rem % 3600) / 60);

    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, h, mi)
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
    // ── JAVOB UZUNLIGI E'LON QILINISHI SHART ──────────────────
    //
    // TUZATILGAN XATO (o'lchab topildi: bitta 16 MiB so'rovning
    // javobi ~10 holatdan 5 tasida 0.6-1.5 MB da JIM UZILIB
    // qolardi — na xato, na belgi).
    //
    // SABABI: `Response::from_stream` javobni `Transfer-Encoding:
    // chunked` bilan yuboradi, ya'ni uzunlik OLDINDAN e'lon
    // QILINMAYDI (qo'lda yozilgan `Content-Length`ni runtime
    // tashlab yuboradi — yuqoridagi `fixed_length_stream` izohiga
    // qarang). Uzunlik ma'lum bo'lmasa, oqim erta tugasa mijoz
    // buni "fayl tugadi" deb qabul qiladi: yuklovchi 16 MiB
    // o'rniga 1 MB olib, qolganini qayta-qayta so'rardi — yuklash
    // aynan shu sabab sudralib ketardi.
    //
    // YECHIM: oqim `FixedLengthStream` orqali o'tkaziladi. Shunda
    // runtime `Content-Length`ni O'ZI qo'yadi; javob erta uzilsa
    // mijoz buni DARHOL xato deb ko'radi va o'sha joydan davom
    // etadi. Xotiraga hech narsa yig'ilmaydi — bu faqat quvur.
    let src = match hit.body() {
        ResponseBody::Stream(rs) => rs.clone(),
        _ => {
            *reason = "slice-not-stream".into();
            return Ok(None);
        }
    };
    let readable = fixed_length_stream(&src, len)?;
    let mut resp = Response::from_body(ResponseBody::Stream(readable))?
        .with_status(if is_range { 206 } else { 200 });
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
    // Ilova yuklab olishda 64 MiB'lik oraliq so'raydi (Rust
    // tomondagi `DL_REQUEST_CHUNKS` bilan aynan bir xil). Kesh
    // oynasi 480 MiB va `480 / 64 = 7.5` — ya'ni oraliq oyna
    // chegarasini kesib o'tishi mumkin bo'lardi, lekin ilova uni
    // O'ZI oyna ichida ushlab turadi (yo'laklar oyna-oyna
    // taqsimlanadi), shu sabab bu yerda qo'shimcha kesish shart
    // emas.
    //
    // NEGA 16 -> 64 MiB: bu chegara ISITILGAN OYNADAN kesib berish
    // uchun, u yerda baytlar OQIM bilan o'tadi (`Response::
    // from_stream`) va worker xotirasiga hech narsa yig'ilmaydi —
    // fayl 166 MB bo'ladimi, 5 GB bo'ladimi, xotira sarfi bir xil.
    // Ya'ni chegarani ko'tarish xotiraga UMUMAN ta'sir qilmaydi,
    // lekin so'rovlar sonini keskin kamaytiradi:
    //
    //     166 MB'lik qism:  11 ta so'rov  ->  6 ta
    //     1 GB'lik fayl:    64 ta so'rov  -> 12 ta
    //
    // Har bir so'rov B2/Cloudflare hisobida pul bo'lgani uchun bu
    // to'g'ridan-to'g'ri tejash.
    const RANGE_MAX: u64 = 64 * 1024 * 1024;

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
        let lookup_h = Headers::new();
        lookup_h.set("Range", &format!("bytes={rel_start}-{rel_end}"))?;
        let lookup = Request::new_with_init(
            &warm_window_url(file_name, widx),
            RequestInit::new().with_method(Method::Get).with_headers(lookup_h),
        )?;
        if let Some(hit) = cache.get(&lookup, false).await? {
            // FAQAT 206 qabul qilinadi: 200 kelsa oraliq kesilmagan
            // va butun oynani mijozga yuborish xato bo'lardi.
            if hit.status_code() == 206 {
                let ct = hit
                    .headers()
                    .get("Content-Type")?
                    .unwrap_or_else(|| "application/octet-stream".to_string());
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
                // Uzunlik OLDINDAN e'lon qilinadi — yuqoridagi
                // `play_from_warm_cache` izohiga qarang. Aks holda
                // javob jimgina uzilib, yuklovchi 16 MiB o'rniga
                // 1 MB olib qolardi.
                let slice_len = abs_e - abs_s + 1;
                let src = match hit.body() {
                    ResponseBody::Stream(rs) => rs.clone(),
                    _ => return Err(Error::RustError("kesh oqim bermadi".into())),
                };
                let readable = fixed_length_stream(&src, slice_len)?;
                let mut resp = Response::from_body(ResponseBody::Stream(readable))?
                    .with_status(206);
                set_cors(&mut resp);
                let h = resp.headers_mut();
                h.set("Content-Type", &ct)?;
                h.set("Accept-Ranges", "bytes")?;
                h.set("Cache-Control", "no-store")?;
                h.set("Content-Length", &slice_len.to_string())?;
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
    if let Some(hit) = cache.get(&key, false).await? {
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
        // Bu yozuv HAR DOIM to'liq saqlanadi (3-bosqichga qarang),
        // ya'ni uzunligi aynan `miss_end - req_start + 1`.
        let entry_len = cl
            .as_deref()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(miss_end - req_start + 1);
        let src = match hit.body() {
            ResponseBody::Stream(rs) => rs.clone(),
            _ => return Err(Error::RustError("kesh oqim bermadi".into())),
        };
        let readable = fixed_length_stream(&src, entry_len)?;
        let mut resp = Response::from_body(ResponseBody::Stream(readable))?.with_status(206);
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "no-store")?;
        h.set("Content-Length", &entry_len.to_string())?;
        let total_str = if total > 0 {
            total.to_string()
        } else {
            (miss_end + 1).to_string()
        };
        // MUHIM: bu yozuv HAR DOIM `B2_RANGE_MAX` o'lchamida
        // saqlanadi, ya'ni tana so'ralganidan QISQA bo'lishi
        // mumkin. Sarlavhada so'ralgan (kattaroq) oraliqni e'lon
        // qilish mijozni chalg'itardi: u javobni "server shuncha
        // beradi" deb o'rganib, keyingi so'rovlarni ham
        // kichraytirib yuborardi. Shu sabab HAQIQIY oraliq
        // e'lon qilinadi.
        h.set("Content-Range", &format!("bytes {req_start}-{miss_end}/{total_str}"))?;
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
        let cl = cached
            .headers()
            .get("Content-Length")?
            .and_then(|v| v.parse::<u64>().ok());
        // Uzunlik ma'lum bo'lsa — quvur orqali e'lon qilamiz
        // (`fixed_length_stream` izohiga qarang), aks holda
        // odatdagidek oqim bilan.
        let mut resp = match (cl, cached.body()) {
            (Some(len), ResponseBody::Stream(rs)) => {
                let readable = fixed_length_stream(&rs.clone(), len)?;
                Response::from_body(ResponseBody::Stream(readable))?.with_status(200)
            }
            _ => Response::from_stream(cached.stream()?)?.with_status(200),
        };
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", "public, max-age=86400")?;
        if let Some(len) = cl {
            h.set("Content-Length", &len.to_string())?;
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
    let mut resp = match (total, b2.body()) {
        (t, ResponseBody::Stream(rs)) if t > 0 => {
            let readable = fixed_length_stream(&rs.clone(), t)?;
            Response::from_body(ResponseBody::Stream(readable))?.with_status(200)
        }
        _ => Response::from_stream(b2.stream()?)?.with_status(200),
    };
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
///
/// Natijaga qaralmaydigan joylar uchun (anime/epizod o'chirilganda).
async fn b2_delete(env: &Env, value: &str) {
    let _ = b2_delete_checked(env, value).await;
}

/// O'shaning O'ZI, lekin NATIJANI QAYTARADI.
///
/// `true` — fayl o'chirildi YOKI omborda umuman yo'q edi (ikkalasi
/// ham "endi yo'q" degani). `false` — B2'ga yetib bo'lmadi yoki u
/// o'chirishni rad etdi.
///
/// NEGA KERAK: hisob o'chirilayotganda profil rasmi B2'da qolib
/// ketsa, uni endi HECH KIM o'chira olmaydi — bazadagi yagona
/// havola ham o'chib ketgan bo'ladi. Ya'ni fayl abadiy yotib,
/// ombor uchun pul yeb turadi. Shu sabab u yerda natija
/// TEKSHIRILADI.
async fn b2_delete_checked(env: &Env, value: &str) -> bool {
    if value.is_empty() { return true; }
    let file_name = match value.find("/api/image/") {
        Some(p) => &value[p + 11..],
        None => value,
    };
    let auth = match b2_auth(env).await { Ok(a) => a, Err(_) => return false };
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let acct = auth["accountId"].as_str().unwrap_or("").to_string();
    let bid = match b2_bucket_id(&api_url, &token, &acct).await {
        Ok(id) => id,
        Err(_) => return false,
    };

    let mut h = Headers::new();
    let _ = h.set("Authorization", &token);
    let req = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_file_names?bucketId={bid}&prefix={file_name}&maxFileCount=1"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    ) { Ok(r) => r, Err(_) => return false };
    let mut r = match Fetch::Request(req).send().await { Ok(r) => r, Err(_) => return false };
    let d: Value = match r.json().await { Ok(d) => d, Err(_) => return false };
    // Fayl topilmadi — demak allaqachon yo'q. Bu XATO EMAS.
    let fid = match d["files"][0]["fileId"].as_str() {
        Some(id) => id.to_string(),
        None => return true,
    };

    let mut h2 = Headers::new();
    let _ = h2.set("Authorization", &token);
    let _ = h2.set("Content-Type", "application/json");
    let req2 = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_delete_file_version"),
        RequestInit::new().with_method(Method::Post).with_headers(h2)
            .with_body(Some(json!({"fileName": file_name, "fileId": fid}).to_string().into())),
    ) { Ok(r) => r, Err(_) => return false };
    match Fetch::Request(req2).send().await {
        Ok(resp) => resp.status_code() == 200,
        Err(_) => false,
    }
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

/// Janrlar ro'yxati: ilova `janrlar: ["Drama", ...]` yuboradi,
/// eski versiyalar esa vergul bilan ajratilgan matn (`janri`).
/// Ikkalasi ham qabul qilinadi.
fn janr_list(b: &Value, janri_text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Some(arr) = b["janrlar"].as_array() {
        for v in arr {
            if let Some(t) = v.as_str() {
                let t = t.trim();
                if !t.is_empty() && !out.iter().any(|x| x == t) {
                    out.push(t.to_string());
                }
            }
        }
    }
    if out.is_empty() {
        for part in janri_text.split(',') {
            let t = part.trim();
            if !t.is_empty() && !out.iter().any(|x| x == t) {
                out.push(t.to_string());
            }
        }
    }
    // Alifbo tartibida — ilovadagi tugmalar bilan bir xil ko'rinsin.
    out.sort();
    out.truncate(12);
    out
}

/// Bo'limning janrlarini bog'lovchi jadvalga yozadi (eskisi
/// o'chiriladi). Bitta so'rovda ketadi.
async fn save_janrs(env: &Env, anime_id: i64, season_id: i64, janrs: &[String]) {
    let mut stmts: Vec<(&str, Vec<TursoArg>)> = vec![(
        "DELETE FROM season_janr WHERE anime_id=? AND season_id=?",
        vec![TursoArg::int(anime_id), TursoArg::int(season_id)],
    )];
    for j in janrs {
        stmts.push((
            "INSERT OR IGNORE INTO season_janr (anime_id,season_id,janr) VALUES (?,?,?)",
            vec![TursoArg::int(anime_id), TursoArg::int(season_id), TursoArg::text(j)],
        ));
    }
    let _ = turso_batch(env, &stmts).await;
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
/// Shu yo'l javobi chekkada necha soniya turadi.
///
/// Statistika og'ir so'rov (bir necha yuz qator o'qiydi) va uning
/// raqamlari bir necha daqiqada o'zgarmaydi — shu sabab u
/// ro'yxatlardan uzoqroq keshlanadi.
fn cache_seconds(path: &str) -> u64 {
    if path == "/api/stats" { 300 } else { LIST_CACHE_SECONDS }
}

fn is_list_path(path: &str) -> bool {
    path == "/api/stats"
        || path == "/api/anime"
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

// ══════════════════════════════════════════════════════════════
//  TELEGRAM ORQALI KIRISH
// ══════════════════════════════════════════════════════════════
//
// OQIM (foydalanuvchi nuqtai nazaridan):
//
//   1. Profil sahifasida "Telegram orqali kirish" bosiladi.
//   2. Ilova POST /api/auth/telegram/start yuboradi va 16 xonali
//      bir martalik token oladi.
//   3. Ilova https://t.me/<bot>?start=<token> manzilini ochadi —
//      Telegram ilovasi ochiladi va START tugmasi ko'rinadi.
//   4. START bosilganda Telegram BIZNING webhook'imizga xabar
//      yuboradi. Worker tokenni topadi, foydalanuvchini bazada
//      yaratadi (yoki topadi) va unga sessiya ochadi.
//   5. Ilova (fon'da 2 soniyada bir marta, hamda Telegram'dan
//      qaytgan zahoti) GET /api/auth/telegram/status?token=... ni
//      so'raydi va sessiya tokenini oladi. Kirish tugadi.
//
// XAVFSIZLIK:
//   • Bot tokeni FAQAT worker ichida (Cloudflare secret). Ilovaga
//     hech qachon yuborilmaydi — APK'ni ochib olib bo'lmaydi.
//   • Webhook'ga kelgan har bir so'rov `X-Telegram-Bot-Api-Secret-
//     Token` sarlavhasi bo'yicha tekshiriladi. Sirni worker o'zi
//     BIR MARTA yaratadi va app_config jadvalida saqlaydi, ya'ni
//     qo'lda qo'shiladigan qo'shimcha secret kerak emas.
//   • Login token bir martalik va 5 daqiqa yashaydi.
//   • Avatar Telegram'dan WORKER orqali uzatiladi (/api/avatar/:id)
//     — Telegram'ning fayl manzilida bot tokeni bo'lgani uchun u
//     manzil hech qachon ilovaga chiqarilmaydi.

const BOT_USERNAME: &str = "aniraxuzloginbot";

/// Login tokeni necha millisekund yashaydi (5 daqiqa).
const LOGIN_TOKEN_TTL_MS: i64 = 5 * 60 * 1000;

/// Kirish tasdiqlangandan keyin ilova sessiyani olib ketishi uchun
/// qo'shimcha muhlat (tarmoq uzilib qolsa qayta so'ray oladi).
const LOGIN_CLAIM_TTL_MS: i64 = 5 * 60 * 1000;

/// BITTA HISOB UCHUN ENG KO'PI 4 TA QURILMA.
/// 5-chisi qo'shilganda ENG OLDIN onlayn bo'lgan (ya'ni eng uzoq
/// vaqt oldin ko'rilgan) sessiya hisobdan chiqarib tashlanadi.
const MAX_SESSIONS_PER_USER: i64 = 4;

/// Avatar chekka keshda necha soniya turadi (1 kun).
const AVATAR_CACHE_SECONDS: u64 = 24 * 60 * 60;

fn now_ms() -> i64 {
    Date::now().as_millis() as i64
}

/// Kriptografik tasodifiy hex satr (`crypto.randomUUID` asosida —
/// Workers muhitida har doim mavjud).
fn random_hex(len: usize) -> String {
    use worker::wasm_bindgen::{JsCast, JsValue};

    let mut out = String::new();
    let global = js_sys::global();
    if let Ok(crypto) = js_sys::Reflect::get(&global, &JsValue::from_str("crypto")) {
        if let Ok(f) = js_sys::Reflect::get(&crypto, &JsValue::from_str("randomUUID")) {
            if let Ok(f) = f.dyn_into::<js_sys::Function>() {
                while out.len() < len {
                    match f.call0(&crypto).ok().and_then(|v| v.as_string()) {
                        Some(s) => out.push_str(&s.replace('-', "")),
                        None => break,
                    }
                }
            }
        }
    }
    // Zaxira yo'l — `crypto` topilmasa (amalda bo'lmaydi).
    while out.len() < len {
        let r = js_sys::Math::random();
        out.push_str(&format!("{:08x}", (r * 4_294_967_295.0) as u32));
    }
    out.truncate(len);
    out
}

// ── app_config: kichik kalit/qiymat ombori ─────────────────────

async fn config_get(env: &Env, key: &str) -> Option<String> {
    let res = turso_exec(env, "SELECT cfg_value FROM app_config WHERE cfg_key=?",
        vec![TursoArg::text(key)]).await.ok()?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() { return None; }
    let v = row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![]))["cfg_value"]
        .as_str().unwrap_or("").to_string();
    if v.is_empty() { None } else { Some(v) }
}

async fn config_put(env: &Env, key: &str, value: &str) {
    let _ = turso_exec(env,
        "INSERT INTO app_config (cfg_key,cfg_value) VALUES (?,?)
         ON CONFLICT(cfg_key) DO UPDATE SET cfg_value=excluded.cfg_value",
        vec![TursoArg::text(key), TursoArg::text(value)]).await;
}

// ── Telegram Bot API ───────────────────────────────────────────

async fn tg_api(env: &Env, method: &str, body: Value) -> Result<Value> {
    let token = env.secret("TELEGRAM_BOT_TOKEN")?.to_string();
    let h = Headers::new();
    h.set("Content-Type", "application/json")?;
    let req = Request::new_with_init(
        &format!("https://api.telegram.org/bot{token}/{method}"),
        RequestInit::new().with_method(Method::Post).with_headers(h)
            .with_body(Some(body.to_string().into())),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    if d["ok"] != json!(true) {
        return Err(Error::RustError(format!(
            "Telegram xatosi ({method}): {}",
            d["description"].as_str().unwrap_or("noma'lum")
        )));
    }
    Ok(d["result"].clone())
}

/// Telegram HTML rejimida `< > &` belgilari maxsus. Foydalanuvchi
/// ismi ularni o'z ichiga olishi mumkin — qalqib chiqmasa, xabar
/// umuman yuborilmay qolardi.
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Botga xabar yuboradi. Xatolar e'tiborsiz — kirishning o'zi
/// xabar yuborilmagani uchun buzilmasligi kerak.
async fn tg_send(env: &Env, chat_id: i64, text: &str) {
    let _ = tg_api(env, "sendMessage", json!({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": true,
    })).await;
}

/// Webhook SHU IZOLYATDA allaqachon ro'yxatdan o'tkazilganmi.
static WEBHOOK_READY: core::sync::atomic::AtomicBool =
    core::sync::atomic::AtomicBool::new(false);

/// Webhook'ni Telegram'da BIR MARTA ro'yxatdan o'tkazadi.
///
/// Qo'lda hech narsa qilish shart emas: worker o'z domenini kelgan
/// so'rovdan biladi, shu sabab domen o'zgarsa ham o'zi moslashadi.
/// Sir (`secret_token`) ham shu yerda bir marta yaratilib bazaga
/// yoziladi.
async fn ensure_webhook(env: &Env, origin: &str) {
    use core::sync::atomic::Ordering;
    if WEBHOOK_READY.load(Ordering::Relaxed) { return; }

    let secret = match config_get(env, "tg_webhook_secret").await {
        Some(s) => s,
        None => {
            let fresh = random_hex(48);
            // INSERT OR IGNORE — ikki so'rov bir vaqtda kelsa ham
            // bazada BITTA sir qoladi, keyin uni qayta o'qiymiz.
            let _ = turso_exec(env,
                "INSERT OR IGNORE INTO app_config (cfg_key,cfg_value) VALUES (?,?)",
                vec![TursoArg::text("tg_webhook_secret"), TursoArg::text(&fresh)]).await;
            config_get(env, "tg_webhook_secret").await.unwrap_or(fresh)
        }
    };

    let want = format!("{origin}/api/telegram/webhook");
    if config_get(env, "tg_webhook_url").await.as_deref() == Some(want.as_str()) {
        WEBHOOK_READY.store(true, Ordering::Relaxed);
        return;
    }

    let res = tg_api(env, "setWebhook", json!({
        "url": want,
        "secret_token": secret,
        "allowed_updates": ["message"],
        "drop_pending_updates": true,
    })).await;

    if res.is_ok() {
        config_put(env, "tg_webhook_url", &want).await;
        WEBHOOK_READY.store(true, Ordering::Relaxed);
    }
}

// ── users_db ───────────────────────────────────────────────────

/// Yangi hisob uchun ID va BO'SH TURGAN ENG KICHIK raqam.
///
/// Qaytaradi: `(id, n)`. `id` — hisob raqami (oxirgi ID + 1,
/// anime/epizodlardagi bilan bir xil tartib). `n` — bazada hali
/// egallanmagan eng kichik son: undan `User n` (ism) va `user_n`
/// (username) yasaladi.
///
/// NEGA `n` alohida hisoblanadi (ID ning o'zi yetmaydimi?):
/// hisob o'chirilganda uning ID'si bo'shab qoladi va keyingi
/// odamga o'sha ID tegishi mumkin. Agar nom ID'dan yasalsa,
/// o'chirilgan odamning nomi yangi odamga tushib qolardi. Bu yerda
/// esa NOMLAR ro'yxati bo'yicha qidiriladi: `user_1` band bo'lsa
/// `user_2`, u ham band bo'lsa `user_3` va hokazo.
///
/// HAMMASI BITTA SO'ROVDA: bazaga ikki marta borish shart emas.
async fn next_user_slot(env: &Env) -> Result<(i64, i64)> {
    // `used` — allaqachon olingan `user_<raqam>` nomlaridagi raqamlar.
    // Faqat TO'LIQ raqamli quyruq hisobga olinadi (`user_7` — ha,
    // `user_7a` — yo'q), registr esa ahamiyatsiz: unikal indeks
    // `LOWER(username)` bo'yicha qurilgan, ya'ni `User_7` ham
    // `user_7` ni band qiladi.
    let res = turso_exec(env,
        "WITH used(n) AS (
             SELECT CAST(SUBSTR(username,6) AS INTEGER) FROM users_db
              WHERE LOWER(SUBSTR(username,1,5))='user_'
                AND LENGTH(username) > 5
                AND SUBSTR(username,6) NOT GLOB '*[^0-9]*'
         )
         SELECT
           (SELECT COALESCE(MAX(id),0)+1 FROM users_db) AS new_id,
           (SELECT COALESCE(MIN(c.n),1) FROM
                (SELECT 1 AS n UNION ALL SELECT n+1 FROM used) c
             WHERE c.n NOT IN (SELECT n FROM used)) AS free_n",
        vec![]).await?;
    let Some(row) = first_row(&res) else { return Ok((1, 1)) };
    Ok((
        row["new_id"].as_i64().unwrap_or(1).max(1),
        row["free_n"].as_i64().unwrap_or(1).max(1),
    ))
}

fn first_row(res: &Value) -> Option<Value> {
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() { return None; }
    Some(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])))
}

/// Telegram'dan kelgan `from` obyekti bo'yicha foydalanuvchini
/// topadi yoki yaratadi.
///
/// MAX(id)+1 usuli ikki odam AYNAN bir vaqtda ro'yxatdan o'tsa
/// to'qnashishi mumkin — shu sabab `telegram_id` va `id` UNIQUE
/// qilingan va bu yerda qayta urinish (retry) bor. Ya'ni bir xil
/// ID hech qachon ikki kishiga tegmaydi.
async fn upsert_user(env: &Env, from: &Value) -> Result<Value> {
    let tg_id = from["id"].as_i64().unwrap_or(0);
    if tg_id == 0 { return Err(Error::RustError("telegram_id yo'q".into())); }

    // ── ISM VA USERNAME TELEGRAMDAN OLINMAYDI ─────────────────
    //
    // Foydalanuvchi talabi. Telegramdan faqat `telegram_id` (hisobni
    // tanish uchun), til va premium belgisi olinadi. Ism va username
    // esa ILOVANING O'ZIDA hosil qilinadi va keyingi kirishlarda
    // USTIGA YOZILMAYDI — aks holda foydalanuvchi tanlagan nom har
    // safar Telegramdagisiga qaytib qolardi.
    let lang = from["language_code"].as_str().unwrap_or("").to_string();
    let is_premium = if from["is_premium"] == json!(true) { 1 } else { 0 };
    let now = now_ms();

    // ── MAVJUD HISOB: BITTA SO'ROV ────────────────────────────
    //
    // Ilgari avval `find_user_by_tg` (SELECT), keyin UPDATE
    // qilinardi — ya'ni bazaga IKKI marta borilardi. Bazaga har
    // borish chekkadan ~100 ms olib ketadi va kirish jarayonida
    // bunday ortiqcha borishlar yig'ilib, bot "sekin" bo'lib
    // ko'rinardi. `RETURNING *` ikkovini bitta so'rovga jamlaydi:
    // qator o'zgargan bo'lsa o'zi qaytadi, bo'lmasa bo'sh keladi.
    let res = turso_exec(env,
        "UPDATE users_db SET language_code=?,is_premium=?,last_login_at=?
         WHERE telegram_id=? RETURNING *",
        vec![
            TursoArg::text(&lang), TursoArg::int(is_premium),
            TursoArg::int(now), TursoArg::int(tg_id),
        ]).await?;
    if let Some(u) = first_row(&res) { return Ok(u); }

    // ── YANGI HISOB: ISM VA USERNAME AVTOMATIK ────────────────
    //
    // TALAB: foydalanuvchidan hech narsa so'ralmasin — ilova o'zi
    // bazada BAND BO'LMAGAN ENG KICHIK raqamni topib, undan
    // `User 1` (ism) va `user_1` (username) yasasin. Keyin
    // foydalanuvchi profil sahifasidagi tahrirlash tugmasi orqali
    // ikkovini ham o'zgartira oladi.
    //
    // `profile_done=1` — ya'ni majburiy "ism/username kiriting"
    // oynasi endi UMUMAN ochilmaydi.
    //
    // Qayta urinish: ayni damda boshqa odam ham ro'yxatdan o'tib,
    // o'sha raqamni olib ulgurishi mumkin. Bunday holda unikal
    // indeks INSERT'ni yiqitadi va biz KEYINGI bo'sh raqamni
    // qidiramiz.
    for _ in 0..5 {
        let (new_id, n) = next_user_slot(env).await?;
        let username = format!("user_{n}");
        let first_name = format!("User {n}");
        let res = turso_exec(env,
            "INSERT INTO users_db (id,telegram_id,username,first_name,last_name,
             language_code,is_premium,is_banned,created_at,last_login_at,profile_done)
             VALUES (?,?,?,?,'',?,?,0,?,?,1) RETURNING *",
            vec![
                TursoArg::int(new_id), TursoArg::int(tg_id),
                TursoArg::text(&username), TursoArg::text(&first_name),
                TursoArg::text(&lang),
                TursoArg::int(is_premium), TursoArg::int(now), TursoArg::int(now),
            ]).await;

        match res {
            Ok(r) => { if let Some(u) = first_row(&r) { return Ok(u); } }
            // ID, telegram_id yoki username band bo'lib qoldi —
            // qaytadan urinamiz (bo'sh raqam qaytadan qidiriladi).
            Err(_) => continue,
        }
    }
    Err(Error::RustError("Foydalanuvchi yaratib bo'lmadi".into()))
}

/// Ilovaga BERILADIGAN foydalanuvchi ko'rinishi.
///
/// AVATAR IKKI MANBADAN KELADI:
///
///   * foydalanuvchi profilda O'ZI rasm tanlagan bo'lsa —
///     `avatar_file` (B2'dagi fayl nomi) va rasm odatdagi
///     `/api/image/...` yo'li bilan beriladi. Fayl nomi har
///     yuklashda yangi (ichida vaqt belgisi bor), shu sabab
///     eski rasm keshda qolib ketmaydi;
///   * aks holda Telegram avatari — `/api/avatar/:id`. Telegram
///     fayl manzilida bot tokeni bo'lgani uchun u tashqariga
///     hech qachon chiqarilmaydi, worker o'zi uzatib beradi.
fn user_public(origin: &str, u: &Value) -> Value {
    let id = u["id"].as_i64().unwrap_or(0);
    let avatar = u["avatar_file"].as_str().unwrap_or("");
    let photo_url = if avatar.is_empty() {
        format!("{origin}/api/avatar/{id}")
    } else {
        format!("{origin}/api/image/{avatar}")
    };
    json!({
        "id": id,
        "telegram_id": u["telegram_id"].as_i64().unwrap_or(0),
        "username": u["username"].as_str().unwrap_or(""),
        "first_name": u["first_name"].as_str().unwrap_or(""),
        "last_name": u["last_name"].as_str().unwrap_or(""),
        "photo_url": photo_url,
        "balance": u["balance"].as_i64().unwrap_or(0),
        // Ism/username to'ldirilganmi. Yangi hisobga nom
        // AVTOMATIK berilgani uchun bu endi doim 1 — maydon
        // eski ilova versiyalari bilan moslik uchun qoldirilgan.
        "profile_done": u["profile_done"].as_i64().unwrap_or(0) == 1,
        "created_at": u["created_at"].clone(),
        "last_login_at": u["last_login_at"].clone(),
    })
}

/// Profil rasmi uchun fayl nomi QABUL QILINADIMI.
///
/// NEGA SHART. Ilova rasmni to'g'ridan-to'g'ri B2'ga yuklaydi va
/// keyin workerga faqat FAYL NOMINI aytadi. Agar nom tekshirilmasa,
/// foydalanuvchi o'z profiliga masalan `anime_17.jpg` ni yozib
/// qo'ya olardi — va keyingi safar rasm almashtirganda worker
/// eskisini "o'ziniki" deb bilib, o'sha anime rasmini B2'dan
/// O'CHIRIB yuborardi.
///
/// Shu sabab nom qat'iy qolipda bo'lishi shart:
///   `avatar_<foydalanuvchi id>_<raqam>.jpg`
/// Ya'ni har kim faqat o'z fayllariga tega oladi.
/// USERNAME QOIDALARI (ilova bilan AYNAN bir xil).
///
///   * 3 dan 15 tagacha belgi. Yuqori chegara foydalanuvchi
///     talabi; quyi chegara — bir-ikki harfli nomlar amalda
///     o'qilmaydi va tezda tugab qoladi;
///   * FAQAT harf (a-z, A-Z), raqam va pastki chiziq `_`.
///     Belgi, bo'shliq, emoji — taqiqlanadi.
///
/// Qaytaradi: xato sababi (ilovaga ko'rsatiladi) yoki `None`.
fn username_problem(u: &str) -> Option<&'static str> {
    let n = u.chars().count();
    if n < 3 {
        return Some("Username kamida 3 ta belgidan iborat bo'lsin");
    }
    if n > 15 {
        return Some("Username eng ko'pi 15 ta belgi bo'lishi mumkin");
    }
    if !u.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Some("Faqat harf, raqam va pastki chiziq (_) ishlatiladi");
    }
    None
}

/// Username band emasmi. `me` — o'zining id'si (o'z nomini
/// "band" deb hisoblamaslik uchun).
async fn username_taken(env: &Env, u: &str, me: i64) -> Result<bool> {
    let res = turso_exec(env,
        "SELECT id FROM users_db WHERE LOWER(username)=LOWER(?) AND id<>? LIMIT 1",
        vec![TursoArg::text(u), TursoArg::int(me)]).await?;
    Ok(res["rows"].as_array().map(|r| !r.is_empty()).unwrap_or(false))
}

fn valid_avatar_file(file: &str, user_id: i64) -> bool {
    let prefix = format!("avatar_{user_id}_");
    let Some(rest) = file.strip_prefix(&prefix) else { return false };
    let Some(digits) = rest.strip_suffix(".jpg") else { return false };
    !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
}

// ── sessions_db ────────────────────────────────────────────────

/// Yangi sessiya ochadi, 4 ta qurilma chegarasini qo'llaydi VA
/// kirish tokenini "tasdiqlangan" holatiga o'tkazadi.
///
/// Jurnalda saqlanadigan ma'lumot (talab bo'yicha):
///   • hisob ma'lumoti — user_id, telegram_id, username, first_name
///   • qaysi API orqali kirgan — api_base
///   • qaysi qurilma bilan kirgan — device, platform, app_version
///
/// ═══════════════════════════════════════════════════════════════
///  NEGA HAMMASI BITTA SO'ROVDA
/// ═══════════════════════════════════════════════════════════════
///
/// Ilgari bu ish bazaga BESH marta alohida borardi: eski sessiyani
/// o'chirish, keyingi ID'ni so'rash, sessiyani yozish, chegarani
/// qo'llash va kirish tokenini tasdiqlash. Cloudflare chekkasidan
/// Turso'ga har borish ~100 ms, ya'ni faqat shu yerda yarim
/// soniyagacha behuda ketardi va foydalanuvchi "bot sekin" deb
/// sezardi.
///
/// Endi hammasi bitta "pipeline" so'rovi. Turso to'plamdagi
/// BIRINCHI XATODAN keyin qolganini bajarmaydi — bu bizning
/// foydamizga: sessiya yozilmasa, kirish tokeni ham tasdiqlanmaydi,
/// ya'ni "kirdingiz" deb yolg'on aytilmaydi.
///
/// Sessiya ID'si ham SQL ichida hisoblanadi
/// (`SELECT MAX(id)+1`) — shu sabab uni alohida so'rashga hojat
/// qolmadi.
async fn create_session(
    env: &Env,
    user: &Value,
    login: &Value,
    login_token: &str,
) -> Result<String> {
    let user_id = user["id"].as_i64().unwrap_or(0);
    let now = now_ms();

    let device = login["device"].as_str().unwrap_or("").to_string();
    let platform = login["platform"].as_str().unwrap_or("").to_string();
    let app_version = login["app_version"].as_str().unwrap_or("").to_string();
    let api_base = login["api_base"].as_str().unwrap_or("").to_string();

    // Qayta urinish: sessiya ID'si yoki tokeni ayni damda boshqa
    // kirish tomonidan band qilingan bo'lishi mumkin. Har urinishda
    // token YANGIDAN yasaladi — yarim yozilib qolgan qator keyingi
    // urinishga xalaqit qilmasin.
    for _ in 0..3 {
        let token = format!("{}{}", random_hex(32), random_hex(32));
        let mut stmts: Vec<(&str, Vec<TursoArg>)> = Vec::new();

        // ── SHU QURILMANING ESKI SESSIYASI O'CHIRILADI ────────
        //
        // TOPILGAN MUAMMO: foydalanuvchi bir necha marta kirishga
        // urinsa (masalan ilova Telegramga o'tganda yopilib ketgani
        // uchun), HAR BIR urinish yangi sessiya ochardi. Natijada
        // bitta telefondan 4 ta "qurilma" paydo bo'lardi, chegara
        // to'lib qolardi va foydalanuvchining BOSHQA haqiqiy
        // qurilmalari o'rinsiz chiqarib yuborilardi.
        //
        // Endi ayni shu qurilma (nomi + tizimi bir xil) uchun eski
        // yozuv oldindan o'chiriladi: bitta telefon ro'yxatda HAR
        // DOIM bitta qator egallaydi.
        //
        // Qurilma nomi bo'sh bo'lsa hech narsa o'chirilmaydi — aks
        // holda nomi aniqlanmagan turli qurilmalar bir-birini
        // chiqarib yuborardi.
        if !device.is_empty() {
            stmts.push((
                "DELETE FROM sessions_db WHERE user_id=? AND device=? AND platform=?",
                vec![
                    TursoArg::int(user_id),
                    TursoArg::text(&device),
                    TursoArg::text(&platform),
                ],
            ));
        }

        stmts.push((
            "INSERT INTO sessions_db (id,user_id,telegram_id,username,first_name,
             session_token,api_base,device,platform,app_version,created_at,last_seen_at)
             VALUES ((SELECT COALESCE(MAX(id),0)+1 FROM sessions_db),
                     ?,?,?,?,?,?,?,?,?,?,?)",
            vec![
                TursoArg::int(user_id),
                TursoArg::int(user["telegram_id"].as_i64().unwrap_or(0)),
                TursoArg::text(user["username"].as_str().unwrap_or("")),
                TursoArg::text(user["first_name"].as_str().unwrap_or("")),
                TursoArg::text(&token), TursoArg::text(&api_base), TursoArg::text(&device),
                TursoArg::text(&platform), TursoArg::text(&app_version),
                TursoArg::int(now), TursoArg::int(now),
            ],
        ));

        // ── 4 TA QURILMA CHEGARASI ────────────────────────────
        // Eng SO'NGGI onlayn bo'lgan 4 tasi qoldiriladi; qolgani —
        // ya'ni eng oldin onlayn bo'lgani — o'chiriladi va o'sha
        // qurilma keyingi so'rovda hisobdan chiqib qoladi.
        stmts.push((
            "DELETE FROM sessions_db WHERE user_id=? AND id NOT IN (
                SELECT id FROM sessions_db WHERE user_id=?
                ORDER BY last_seen_at DESC, id DESC LIMIT ?
             )",
            vec![TursoArg::int(user_id), TursoArg::int(user_id),
                 TursoArg::int(MAX_SESSIONS_PER_USER)],
        ));

        // ── KIRISH TOKENI TASDIQLANADI ────────────────────────
        // Ilova aynan shu belgini kutib turadi: u "approved"
        // bo'lishi bilan hisob ilovada ochiladi.
        stmts.push((
            "UPDATE login_tokens SET status='approved', user_id=?, session_token=?,
             expires_at=? WHERE token=?",
            vec![
                TursoArg::int(user_id),
                TursoArg::text(&token),
                TursoArg::int(now + LOGIN_CLAIM_TTL_MS),
                TursoArg::text(login_token),
            ],
        ));

        if turso_batch(env, &stmts).await.is_ok() {
            return Ok(token);
        }
    }
    Err(Error::RustError("Sessiya ochib bo'lmadi".into()))
}

/// Sessiya tokeni bo'yicha foydalanuvchini topadi va "oxirgi
/// ko'rilgan" vaqtini yangilaydi (4 ta qurilma tartibi shunga
/// qarab hisoblanadi).
async fn session_user(env: &Env, token: &str) -> Result<Option<Value>> {
    if token.is_empty() { return Ok(None); }
    let now = now_ms();

    // ── IKKI BUYRUQ — BITTA SO'ROV ────────────────────────────
    //
    // Ilgari bu yerda ikkita alohida Turso so'rovi bor edi, ya'ni
    // HAR BIR himoyalangan so'rov ikki marta yo'l yurardi.
    //
    // "Oxirgi ko'rinish" vaqti esa endi FAQAT 60 soniyada bir
    // marta yoziladi: u ikkita indeksni qayta yozadi va har bir
    // so'rovda bajarilsa bazadagi eng qimmat amalga aylanardi.
    // Kunlik faol foydalanuvchi 24 SOATLIK oyna bilan sanaladi —
    // ya'ni bu aniqlikka umuman ta'sir qilmaydi.
    let res = turso_many(env, &[
        ("SELECT u.* FROM sessions_db s JOIN users_db u ON u.id = s.user_id
          WHERE s.session_token = ?", vec![TursoArg::text(token)]),
        ("UPDATE sessions_db SET last_seen_at=?
          WHERE session_token=? AND COALESCE(last_seen_at,0) < ?",
         vec![TursoArg::int(now), TursoArg::text(token), TursoArg::int(now - 60_000)]),
    ]).await?;
    let Some(first) = res.first() else { return Ok(None) };
    let Some(u) = first_row(first) else { return Ok(None) };
    if u["is_banned"].as_i64().unwrap_or(0) == 1 { return Ok(None); }
    Ok(Some(u))
}

fn bearer(req: &Request) -> String {
    req.headers().get("Authorization").ok().flatten()
        .and_then(|v| v.strip_prefix("Bearer ").map(|s| s.trim().to_string()))
        .unwrap_or_default()
}

/// Kirish javoblari HECH QACHON keshlanmasligi kerak.
fn ok_nostore(v: Value) -> Result<Response> {
    let mut resp = Response::from_json(&v)?;
    set_cors(&mut resp);
    let _ = resp.headers_mut().set("Cache-Control", "no-store");
    Ok(resp)
}

// ── Avatar (Telegram → worker → ilova) ─────────────────────────

async fn tg_avatar(env: &Env, user_id: i64) -> Result<Response> {
    let cache = Cache::default();
    let key_url = format!("https://fulutter-chunk-cache.internal/_avatar/{user_id}");
    if let Ok(k) = Request::new(&key_url, Method::Get) {
        if let Ok(Some(hit)) = cache.get(&k, false).await { return Ok(hit); }
    }

    let res = turso_exec(env, "SELECT telegram_id FROM users_db WHERE id=?",
        vec![TursoArg::int(user_id)]).await?;
    let Some(u) = first_row(&res) else { return err404("Foydalanuvchi topilmadi") };
    let tg_id = u["telegram_id"].as_i64().unwrap_or(0);
    if tg_id == 0 { return err404("Avatar yo'q"); }

    let photos = tg_api(env, "getUserProfilePhotos",
        json!({"user_id": tg_id, "limit": 1})).await?;
    // `photos[0]` — bir rasmning turli o'lchamlari; oxirgisi eng kattasi.
    let file_id = photos["photos"][0].as_array()
        .and_then(|sizes| sizes.last())
        .and_then(|f| f["file_id"].as_str())
        .unwrap_or("").to_string();
    if file_id.is_empty() { return err404("Avatar yo'q"); }

    let file = tg_api(env, "getFile", json!({"file_id": file_id})).await?;
    let file_path = file["file_path"].as_str().unwrap_or("").to_string();
    if file_path.is_empty() { return err404("Avatar yo'q"); }

    // DIQQAT: bu manzilda bot tokeni bor — u faqat worker ichida
    // qoladi, javobga esa FAQAT rasm baytlari chiqadi.
    let token = env.secret("TELEGRAM_BOT_TOKEN")?.to_string();
    let req = Request::new(
        &format!("https://api.telegram.org/file/bot{token}/{file_path}"), Method::Get)?;
    let mut r = Fetch::Request(req).send().await?;
    if r.status_code() != 200 { return err404("Avatar olinmadi"); }
    let bytes = r.bytes().await?;

    let build = |b: Vec<u8>| -> Result<Response> {
        let mut resp = Response::from_bytes(b)?;
        set_cors(&mut resp);
        let h = resp.headers_mut();
        h.set("Content-Type", "image/jpeg")?;
        h.set("Cache-Control", &format!("public, max-age={AVATAR_CACHE_SECONDS}"))?;
        Ok(resp)
    };

    if let Ok(k) = Request::new(&key_url, Method::Get) {
        if let Ok(to_cache) = build(bytes.clone()) {
            let _ = cache.put(&k, to_cache).await;
        }
    }
    build(bytes)
}

// ── Webhook ────────────────────────────────────────────────────

/// ═══════════════════════════════════════════════════════════════
///  BOTDAGI YOZUVLAR
/// ═══════════════════════════════════════════════════════════════
///
/// QOIDA: foydalanuvchi botdan texnik atama ko'rmasligi kerak.
/// Har bir xabar ikki narsani aytadi — NIMA bo'ldi va ENDI NIMA
/// QILISH kerak. "Xatolik: Telegram xatosi (sendMessage)" kabi
/// ichki matnlar hech qachon tashqariga chiqmaydi: ular
/// foydalanuvchiga hech narsa tushuntirmaydi, faqat qo'rqitadi.
const MSG_HELP: &str = "\u{1F44B} Salom! Men \u{2014} <b>AniRaxUz</b> ilovasining kirish yordamchisiman.\n\n\
     Kirish uchun: ilovani oching \u{2192} pastdagi <b>Profil</b> bo'limi \u{2192} \u{AB}Telegram orqali kirish\u{BB} tugmasi.\n\n\
     O'sha tugma meni o'zi ochadi \u{2014} bu yerda hech narsa yozishingiz shart emas.";

/// Havola yaroqsiz (bazada topilmadi yoki allaqachon ishlatilgan).
const MSG_BAD_LINK: &str = "\u{231B} Bu havola ishlamaydi \u{2014} u eskirgan yoki allaqachon ishlatilgan.\n\n\
     Ilovaga qayting va \u{AB}Telegram orqali kirish\u{BB} tugmasini yana bosing \u{2014} yangi havola hosil bo'ladi.";

/// Havolaning 5 daqiqalik muddati tugagan.
const MSG_EXPIRED: &str = "\u{231B} Havolaning muddati tugadi.\n\n\
     Havola atigi 5 daqiqa amal qiladi. Ilovaga qayting va \u{AB}Telegram orqali kirish\u{BB} tugmasini yana bosing.";

/// Shu havola bilan allaqachon kirilgan.
const MSG_ALREADY: &str = "\u{2705} Siz allaqachon kirgansiz.\n\n\
     Ilovaga qayting \u{2014} hisobingiz o'zi ochiladi.";

/// Serverda vaqtinchalik muammo. Sabab AYTILMAYDI: foydalanuvchi
/// uni baribir tuzata olmaydi, unga faqat "nima qilay" kerak.
const MSG_TRY_LATER: &str = "\u{1F614} Hozir kirishning iloji bo'lmadi.\n\n\
     Bir daqiqadan keyin ilovadagi \u{AB}Telegram orqali kirish\u{BB} tugmasini yana bosing.";

async fn handle_tg_webhook(env: &Env, mut req: Request) -> Result<Response> {
    // Sir mos kelmasa — bu Telegram emas.
    let got = req.headers().get("X-Telegram-Bot-Api-Secret-Token").ok().flatten()
        .unwrap_or_default();
    let want = config_get(env, "tg_webhook_secret").await.unwrap_or_default();
    if want.is_empty() || got != want {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }

    let update: Value = req.json().await.unwrap_or(json!({}));
    let msg = update["message"].clone();
    let chat_id = msg["chat"]["id"].as_i64().unwrap_or(0);
    let text = msg["text"].as_str().unwrap_or("").trim().to_string();
    if chat_id == 0 {
        return ok(json!({"ok": true}));
    }

    // Telegram takroriy urinmasligi uchun bu yerdan keyin HAR DOIM
    // 200 qaytadi — xatolar foydalanuvchiga xabar sifatida boradi.
    if !text.starts_with("/start") {
        tg_send(env, chat_id, MSG_HELP).await;
        return ok(json!({"ok": true}));
    }

    // Ba'zi mijozlar buyruqni "/start@botnomi token" ko'rinishida
    // yuboradi — bot nomini olib tashlaymiz.
    let mut arg = text.strip_prefix("/start").unwrap_or("").trim().to_string();
    if arg.starts_with('@') {
        arg = arg.split_whitespace().skip(1).collect::<Vec<_>>().join(" ");
    }
    if arg.is_empty() {
        tg_send(env, chat_id, MSG_HELP).await;
        return ok(json!({"ok": true}));
    }

    let now = now_ms();
    let res = turso_exec(env, "SELECT * FROM login_tokens WHERE token=?",
        vec![TursoArg::text(&arg)]).await?;
    let Some(login) = first_row(&res) else {
        tg_send(env, chat_id, MSG_BAD_LINK).await;
        return ok(json!({"ok": true}));
    };

    if login["expires_at"].as_i64().unwrap_or(0) < now {
        let _ = turso_exec(env, "DELETE FROM login_tokens WHERE token=?",
            vec![TursoArg::text(&arg)]).await;
        tg_send(env, chat_id, MSG_EXPIRED).await;
        return ok(json!({"ok": true}));
    }

    // Allaqachon tasdiqlangan bo'lsa — takroriy START. Yangi sessiya
    // ochilmaydi, shunchaki eslatib qo'yamiz.
    if login["status"].as_str().unwrap_or("") == "approved" {
        tg_send(env, chat_id, MSG_ALREADY).await;
        return ok(json!({"ok": true}));
    }

    let from = msg["from"].clone();
    let Ok(user) = upsert_user(env, &from).await else {
        tg_send(env, chat_id, MSG_TRY_LATER).await;
        return ok(json!({"ok": true}));
    };

    // Sessiya ochish VA kirish tokenini tasdiqlash bitta so'rovda
    // ketadi (`create_session` izohiga qarang) — ilova shu daqiqada
    // hisobni ochadi.
    if create_session(env, &user, &login, &arg).await.is_err() {
        tg_send(env, chat_id, MSG_TRY_LATER).await;
        return ok(json!({"ok": true}));
    }

    // ── XUSH KELIBSIZ XABARI ──────────────────────────────────
    //
    // Ism va username endi ilova tomonidan AVTOMATIK beriladi
    // (`upsert_user` izohiga qarang), shu sabab ikkovi ham shu
    // yerda ko'rsatiladi: foydalanuvchi o'zining nomini darhol
    // biladi va uni qayerdan o'zgartirishni ham biladi.
    let raw_name = user["first_name"].as_str().unwrap_or("").trim().to_string();
    let name = html_escape(if raw_name.is_empty() { "do'stim" } else { &raw_name });
    let uname = html_escape(user["username"].as_str().unwrap_or(""));
    tg_send(env, chat_id, &format!(
        "\u{2705} Tayyor, <b>{name}</b>!\n\n\
         Endi <b>ilovaga qayting</b> \u{2014} hisobingiz o'zi ochiladi.\n\n\
         \u{1F194} ID raqamingiz: <b>{}</b>\n\
         \u{1F464} Username: <b>@{uname}</b>\n\n\
         Ism va username'ni ilovaning <b>Profil</b> bo'limidagi tahrirlash \
         tugmasi orqali istagan vaqtda o'zgartira olasiz.",
        user["id"].as_i64().unwrap_or(0)
    )).await;

    ok(json!({"ok": true}))
}

// ═══════════════════════════════════════════════════════════════
//  TOMOSHA TARIXI
// ═══════════════════════════════════════════════════════════════
//
// ── NEGA SO'ROVLAR SHUNCHALIK KAM ─────────────────────────────
//
// Pleyer to'xtagan joyni HAR SONIYA eslab qoladi, lekin bu faqat
// telefon xotirasiga yoziladi. Serverga esa atigi IKKI holatda
// murojaat qilinadi:
//
//   * qism ko'rib bo'lingach yoki pleyerdan chiqilganda —
//     BITTA `POST` (bir marta ko'rish = bitta yozuv);
//   * tarix sahifasi ochilganda — BITTA `GET`.
//
// Ya'ni bir soatlik tomosha ham bazaga bir necha yozuvdan ortiq
// yuk bermaydi.
//
// `GET` javobi ro'yxat uchun kerak bo'lgan HAMMA narsani bir
// yo'la qaytaradi (anime nomi, posteri, bo'lim raqami) — ilova
// qo'shimcha so'rov qilmaydi.
async fn history_route(
    req: Request,
    env: &Env,
    path: &str,
    method: Method,
) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);

    match (method, path) {
        // ── RO'YXAT ────────────────────────────────────────────
        //
        // O'chirilgan yozuvlar (deleted_at <> 0) CHIQMAYDI, lekin
        // bazada qoladi: qism qayta ko'rilsa o'sha qator tiriladi
        // va statistika ham buzilmaydi.
        (Method::Get, "/api/history") => {
            let res = turso_exec(env,
                "SELECT h.anime_id, h.season_id, h.epizod_number, h.video_url,
                        h.position_ms, h.duration_ms, h.watched_ms, h.view_count,
                        h.updated_at,
                        a.name AS anime_name, a.photo_url AS anime_photo,
                        s.bolim_id AS bolim_id, s.nomi AS season_name,
                        s.photo_url AS season_photo
                   FROM watch_history_db h
                   LEFT JOIN anime_db a ON a.id = h.anime_id
                   LEFT JOIN season_db s
                          ON s.anime_id = h.anime_id AND s.season_id = h.season_id
                  WHERE h.user_id = ? AND h.deleted_at = 0
                  ORDER BY h.updated_at DESC
                  LIMIT 300",
                vec![TursoArg::int(me)]).await?;

            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            let items: Vec<Value> = rows
                .iter()
                .map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![])))
                .collect();
            // Rasm manzillari ilovaga to'liq ko'rinishda beriladi.
            let items = resolve_list(&origin_of(&req), items, &["anime_photo", "season_photo"]);
            ok_nostore(json!({"items": items}))
        }

        // ── BITTA QISM YOZILADI (yoki yangilanadi) ─────────────
        //
        // Bu yo'l bir vaqtning o'zida TO'RTTA ishni bajaradi:
        //
        //   1. tomosha tarixini yangilaydi (va o'chirilgan bo'lsa
        //      qaytadan ko'rinadigan qiladi);
        //   2. qism va bo'limning KO'RISHLAR sonini oshiradi;
        //   3. TOMOSHA VAQTINI qo'shadi — faqat haqiqiy, 1x
        //      tezlikdagi vaqt va qism uzunligidan oshmagan holda;
        //   4. kunlik/soatlik statistika chelaklarini to'ldiradi.
        //
        // Hammasi ATIGI IKKI so'rovda: bitta o'qish (eski holat) va
        // bitta "quvur" (hamma yozuv).
        (Method::Post, "/api/history") => {
            let mut req = req;
            let b: Value = req.json().await.unwrap_or(json!({}));

            let anime_id = b["anime_id"].as_i64().unwrap_or(0);
            let season_id = b["season_id"].as_i64().unwrap_or(0);
            let epizod = b["epizod_number"].as_i64().unwrap_or(0);
            let video_url = b["video_url"].as_str().unwrap_or("").trim().to_string();
            let position = b["position_ms"].as_i64().unwrap_or(0).max(0);
            let duration = b["duration_ms"].as_i64().unwrap_or(0).max(0);
            // Ilova yuborgan JAMI tomosha vaqti (shu odam, shu qism).
            let watched = b["watched_ms"].as_i64().unwrap_or(0).max(0);
            // Shu ochilishda yangi ko'rish bo'ldimi (ilova belgilaydi).
            let new_view = b["new_view"].as_bool().unwrap_or(false);

            if anime_id <= 0 || epizod <= 0 || duration <= 0 {
                return json_resp(&json!({"error": "to'liq bo'lmagan yozuv"}), 400);
            }

            let now = now_ms();
            let key = vec![
                TursoArg::int(me), TursoArg::int(anime_id),
                TursoArg::int(season_id), TursoArg::int(epizod),
            ];

            // 1) Eski holat — bitta qator (birlamchi kalit bo'yicha).
            let old = turso_exec(env,
                "SELECT watched_ms, view_count, updated_at, created_at
                   FROM watch_history_db
                  WHERE user_id=? AND anime_id=? AND season_id=? AND epizod_number=?",
                key.clone()).await?;
            let old_row = first_row(&old);
            let old_watched = old_row.as_ref()
                .and_then(|r| r["watched_ms"].as_i64()).unwrap_or(0).max(0);
            let old_views = old_row.as_ref()
                .and_then(|r| r["view_count"].as_i64()).unwrap_or(0).max(0);
            let old_updated = old_row.as_ref()
                .and_then(|r| r["updated_at"].as_i64()).unwrap_or(0);
            let created_at = old_row.as_ref()
                .and_then(|r| r["created_at"].as_i64()).filter(|v| *v > 0).unwrap_or(now);

            // ── TOMOSHA VAQTI QOIDASI ────────────────────────
            //
            // Foydalanuvchi qismni necha marta ko'rsa ham, uning
            // hissasi QISM UZUNLIGIDAN OSHMAYDI va hech qachon
            // kamaymaydi (eski ilova eskirgan son yuborsa ham).
            let capped = watched.min(duration).max(old_watched);
            let delta = (capped - old_watched).max(0);

            // Yangi ko'rish: ilova shunday deb belgilagan bo'lsa va
            // oxirgi yozuvdan kamida 30 soniya o'tgan bo'lsa. Bu
            // takroriy yuborishdan (masalan ilova fonga chiqib
            // qaytganda) himoya qiladi.
            let counts_view = new_view && (old_row.is_none() || now - old_updated > 30_000);
            let view_inc = if counts_view { 1 } else { 0 };

            let day = day_key(now);
            let hour = hour_key(now);

            let mut stmts: Vec<(&str, Vec<TursoArg>)> = Vec::with_capacity(8);
            stmts.push((
                "INSERT INTO watch_history_db
                    (user_id,anime_id,season_id,epizod_number,video_url,
                     position_ms,duration_ms,watched_ms,view_count,deleted_at,
                     created_at,updated_at)
                 VALUES (?,?,?,?,?,?,?,?,?,0,?,?)
                 ON CONFLICT(user_id,anime_id,season_id,epizod_number) DO UPDATE SET
                    video_url=excluded.video_url,
                    position_ms=excluded.position_ms,
                    duration_ms=excluded.duration_ms,
                    watched_ms=excluded.watched_ms,
                    view_count=excluded.view_count,
                    deleted_at=0,
                    updated_at=excluded.updated_at",
                vec![
                    TursoArg::int(me), TursoArg::int(anime_id), TursoArg::int(season_id),
                    TursoArg::int(epizod), TursoArg::text(&video_url),
                    TursoArg::int(position), TursoArg::int(duration),
                    TursoArg::int(capped), TursoArg::int(old_views + view_inc),
                    TursoArg::int(created_at), TursoArg::int(now),
                ],
            ));

            if view_inc > 0 || delta > 0 {
                stmts.push((
                    "UPDATE epizod_db SET views_total=views_total+?, watch_ms_total=watch_ms_total+?
                      WHERE anime_id=? AND season_id=? AND epizod_number=?",
                    vec![
                        TursoArg::int(view_inc), TursoArg::int(delta),
                        TursoArg::int(anime_id), TursoArg::int(season_id), TursoArg::int(epizod),
                    ],
                ));
                stmts.push((
                    "UPDATE season_db SET views_total=views_total+?, watch_ms_total=watch_ms_total+?
                      WHERE anime_id=? AND season_id=?",
                    vec![
                        TursoArg::int(view_inc), TursoArg::int(delta),
                        TursoArg::int(anime_id), TursoArg::int(season_id),
                    ],
                ));
            }
            if view_inc > 0 {
                stmts.push((STAT_HOUR_SQL, stat_args(&hour, "views", view_inc)));
                stmts.push((STAT_DAY_SQL, stat_args(&day, "views", view_inc)));
            }
            if delta > 0 {
                stmts.push((STAT_HOUR_SQL, stat_args(&hour, "watch_ms", delta)));
                stmts.push((STAT_DAY_SQL, stat_args(&day, "watch_ms", delta)));
            }

            turso_batch(env, &stmts).await?;
            ok_nostore(json!({"ok": true, "watched_ms": capped}))
        }

        // ── TARIXDAN YASHIRISH ─────────────────────────────────
        //
        // Yozuv O'CHIRILMAYDI (foydalanuvchi talabi): faqat
        // `deleted_at` belgilanadi. Qism keyin qayta ko'rilsa,
        // yuqoridagi yozuv uni yana ko'rinadigan qiladi.
        (Method::Delete, "/api/history") => {
            let mut req = req;
            let b: Value = req.json().await.unwrap_or(json!({}));
            turso_exec(env,
                "UPDATE watch_history_db SET deleted_at=?
                  WHERE user_id=? AND anime_id=? AND season_id=? AND epizod_number=?",
                vec![
                    TursoArg::int(now_ms()),
                    TursoArg::int(me),
                    TursoArg::int(b["anime_id"].as_i64().unwrap_or(0)),
                    TursoArg::int(b["season_id"].as_i64().unwrap_or(0)),
                    TursoArg::int(b["epizod_number"].as_i64().unwrap_or(0)),
                ]).await?;
            ok_nostore(json!({"ok": true}))
        }

        _ => err404("yo'l topilmadi"),
    }
}

// ═══════════════════════════════════════════════════════════════
//  STATISTIKA CHELAKLARI
// ═══════════════════════════════════════════════════════════════

const STAT_HOUR_SQL: &str =
    "INSERT INTO stats_hourly (hour,metric,value) VALUES (?,?,?)
     ON CONFLICT(hour,metric) DO UPDATE SET value=value+excluded.value";
const STAT_DAY_SQL: &str =
    "INSERT INTO stats_daily (day,metric,value) VALUES (?,?,?)
     ON CONFLICT(day,metric) DO UPDATE SET value=value+excluded.value";

fn stat_args(bucket: &str, metric: &str, value: i64) -> Vec<TursoArg> {
    vec![TursoArg::text(bucket), TursoArg::text(metric), TursoArg::int(value)]
}

/// Javobdagi baytlarni trafik hisobiga qo'shadi.
///
/// Javob YUBORILGANDAN KEYIN, fon'da (`wait_until`) bajariladi —
/// foydalanuvchi buni kutmaydi.
fn note_response_traffic(env: &Env, ctx: &Context, resp: &Response) {
    let bytes = resp
        .headers()
        .get("Content-Length")
        .ok()
        .flatten()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(0);
    if bytes <= 0 { return; }
    let env = env.clone();
    ctx.wait_until(async move { note_traffic(&env, bytes).await });
}

/// Trafikni hisobga qo'shadi (javob yuborilgandan keyin, fon'da).
///
/// O'lchov — javobda E'LON QILINGAN uzunlik. Mijoz oqimni yarmida
/// uzsa haqiqiy raqam biroz kichikroq bo'ladi; buning evaziga ijro
/// yo'liga (loyihaning eng nozik qismiga) umuman tegilmaydi.
async fn note_traffic(env: &Env, bytes: i64) {
    if bytes <= 0 { return; }
    // Ijro yo'li bazaga umuman tegmaydi, ya'ni jadvallar hali
    // tekshirilmagan bo'lishi mumkin.
    ensure_db(env).await;
    let now = now_ms();
    let _ = turso_batch(env, &[
        (STAT_HOUR_SQL, stat_args(&hour_key(now), "traffic", bytes)),
        (STAT_DAY_SQL, stat_args(&day_key(now), "traffic", bytes)),
    ]).await;
}

// ═══════════════════════════════════════════════════════════════
//  GET /api/stats — SHAFFOF STATISTIKA
// ═══════════════════════════════════════════════════════════════
//
// Hammasi BITTA so'rovda (6 ta buyruq bitta quvurda) va chekkada
// 5 daqiqa keshlanadi — minglab foydalanuvchi bazani urmaydi.
//
// Kunlik ko'rsatkich — "oxirgi 24 soat" (soatlik chelaklardan),
// qolganlari esa kunlik chelaklardan yig'iladi.
async fn stats_route(env: &Env) -> Result<Response> {
    let now = now_ms();
    let day_ms = 86_400_000i64;
    let h24 = hour_key(now - 23 * 3_600_000);
    let d7 = day_key(now - 6 * day_ms);
    let d30 = day_key(now - 29 * day_ms);
    let d365 = day_key(now - 364 * day_ms);

    let res = turso_many(env, &[
        // Foydalanuvchilar: jami + davr bo'yicha yangi hisoblar.
        ("SELECT COUNT(*),
                 SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END),
                 SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END),
                 SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END)
            FROM users_db",
         vec![
            TursoArg::int(now - 7 * day_ms),
            TursoArg::int(now - 30 * day_ms),
            TursoArg::int(now - 365 * day_ms),
         ]),
        // Kunlik: oxirgi 24 soatda onlayn bo'lganlar.
        ("SELECT COUNT(DISTINCT user_id) FROM sessions_db WHERE last_seen_at >= ?",
         vec![TursoArg::int(now - day_ms)]),
        // Oxirgi 24 soat — soatlik chelaklar.
        ("SELECT metric, SUM(value) FROM stats_hourly WHERE hour >= ? GROUP BY metric",
         vec![TursoArg::text(&h24)]),
        // Hafta / oy / yil / jami — kunlik chelaklar.
        ("SELECT metric,
                 SUM(CASE WHEN day >= ? THEN value ELSE 0 END),
                 SUM(CASE WHEN day >= ? THEN value ELSE 0 END),
                 SUM(CASE WHEN day >= ? THEN value ELSE 0 END),
                 SUM(value)
            FROM stats_daily GROUP BY metric",
         vec![TursoArg::text(&d7), TursoArg::text(&d30), TursoArg::text(&d365)]),
        // Eski soatlik chelaklar kerak emas (3 kundan oshgani).
        ("DELETE FROM stats_hourly WHERE hour < ?",
         vec![TursoArg::text(&day_key(now - 3 * day_ms))]),
    ]).await?;

    let urow = &res[0]["rows"][0];
    let cell = |row: &Value, i: usize| -> i64 {
        row[i]["value"].as_str().and_then(|v| v.parse::<i64>().ok()).unwrap_or(0)
    };

    let mut out = serde_json::Map::new();
    out.insert("users".into(), json!({
        "daily": scalar(&res[1]),
        "weekly": cell(urow, 1),
        "monthly": cell(urow, 2),
        "yearly": cell(urow, 3),
        "total": cell(urow, 0),
    }));

    // Soatlik chelaklardan kunlik qiymat.
    let mut daily: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    if let Some(rows) = res[2]["rows"].as_array() {
        for r in rows {
            let m = r[0]["value"].as_str().unwrap_or("").to_string();
            daily.insert(m, cell(r, 1));
        }
    }
    let mut periods: std::collections::HashMap<String, (i64, i64, i64, i64)> =
        std::collections::HashMap::new();
    if let Some(rows) = res[3]["rows"].as_array() {
        for r in rows {
            let m = r[0]["value"].as_str().unwrap_or("").to_string();
            periods.insert(m, (cell(r, 1), cell(r, 2), cell(r, 3), cell(r, 4)));
        }
    }
    for (metric, key) in [("views", "views"), ("traffic", "traffic"), ("watch_ms", "watch")] {
        let (w, m, y, t) = periods.get(metric).copied().unwrap_or((0, 0, 0, 0));
        out.insert(key.into(), json!({
            "daily": daily.get(metric).copied().unwrap_or(0),
            "weekly": w, "monthly": m, "yearly": y, "total": t,
        }));
    }
    out.insert("tz".into(), json!("UTC+5"));
    ok(Value::Object(out))
}

// ═══════════════════════════════════════════════════════════════
//  BO'LIM SAHIFASI: MA'LUMOT, BAHO, SEVIMLILAR
// ═══════════════════════════════════════════════════════════════

/// Eng kam baho soni — IMDb uslubidagi VAZNLI o'rtacha uchun.
///
/// Busiz bitta odam 10 qo'yishi bilan reyting 10.00 bo'lib qolardi.
const RATING_MIN_VOTES: f64 = 5.0;

/// Vaznli o'rtacha: (n/(n+m))*R + (m/(n+m))*C.
fn weighted_rating(sum: i64, count: i64, global_sum: i64, global_count: i64) -> f64 {
    if count <= 0 { return 0.0; }
    let n = count as f64;
    let r = sum as f64 / n;
    let c = if global_count > 0 {
        global_sum as f64 / global_count as f64
    } else {
        r
    };
    let m = RATING_MIN_VOTES;
    ((n / (n + m)) * r + (m / (n + m)) * c * 100.0).round() / 100.0
}

async fn season_detail(env: &Env, origin: &str, req: &Request, aid: i64, sid: i64) -> Result<Response> {
    let me = match session_user(env, &bearer(req)).await? {
        Some(u) => u["id"].as_i64().unwrap_or(0),
        None => 0,
    };
    let res = turso_many(env, &[
        ("SELECT * FROM season_db WHERE anime_id=? AND season_id=?",
         vec![TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT COALESCE(SUM(rating_sum),0), COALESCE(SUM(rating_count),0) FROM season_db", vec![]),
        ("SELECT stars FROM ratings_db WHERE user_id=? AND anime_id=? AND season_id=?",
         vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT 1 FROM favorites_db WHERE user_id=? AND anime_id=? AND season_id=?",
         vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)]),
    ]).await?;

    let Some(row) = first_row(&res[0]) else { return err404("Bo'lim topilmadi") };
    let grow = &res[1]["rows"][0];
    let gnum = |i: usize| -> i64 {
        grow[i]["value"].as_str().and_then(|v| v.parse::<i64>().ok()).unwrap_or(0)
    };
    let my_stars = first_row(&res[2]).and_then(|r| r["stars"].as_i64()).unwrap_or(0);
    let is_fav = res[3]["rows"].as_array().map(|r| !r.is_empty()).unwrap_or(false);

    let rating = weighted_rating(
        row["rating_sum"].as_i64().unwrap_or(0),
        row["rating_count"].as_i64().unwrap_or(0),
        gnum(0), gnum(1),
    );

    ok_nostore(json!({
        "season": resolve_fields(origin, row, SEASON_URL_KEYS),
        "rating": rating,
        "my_stars": my_stars,
        "is_fav": is_fav,
    }))
}

/// POST /api/rating — bitta bo'limga bitta baho (1..10).
async fn rating_route(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let aid = b["anime_id"].as_i64().unwrap_or(0);
    let sid = b["season_id"].as_i64().unwrap_or(0);
    let stars = b["stars"].as_i64().unwrap_or(0);
    if aid <= 0 || !(1..=10).contains(&stars) {
        return json_resp(&json!({"error": "noto'g'ri baho"}), 400);
    }

    let now = now_ms();
    let pre = turso_many(env, &[
        ("SELECT stars FROM ratings_db WHERE user_id=? AND anime_id=? AND season_id=?",
         vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT rating_sum, rating_count FROM season_db WHERE anime_id=? AND season_id=?",
         vec![TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT COALESCE(SUM(rating_sum),0), COALESCE(SUM(rating_count),0) FROM season_db", vec![]),
    ]).await?;
    let old = first_row(&pre[0]).and_then(|r| r["stars"].as_i64());
    let Some(srow) = first_row(&pre[1]) else { return err404("Bo'lim topilmadi") };
    let sum = srow["rating_sum"].as_i64().unwrap_or(0) + stars - old.unwrap_or(0);
    let count = srow["rating_count"].as_i64().unwrap_or(0) + if old.is_some() { 0 } else { 1 };

    turso_batch(env, &[
        ("INSERT INTO ratings_db (user_id,anime_id,season_id,stars,created_at,updated_at)
          VALUES (?,?,?,?,?,?)
          ON CONFLICT(user_id,anime_id,season_id) DO UPDATE SET
             stars=excluded.stars, updated_at=excluded.updated_at",
         vec![
            TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid),
            TursoArg::int(stars), TursoArg::int(now), TursoArg::int(now),
         ]),
        ("UPDATE season_db SET rating_sum=?, rating_count=? WHERE anime_id=? AND season_id=?",
         vec![
            TursoArg::int(sum), TursoArg::int(count),
            TursoArg::int(aid), TursoArg::int(sid),
         ]),
    ]).await?;

    let grow = &pre[2]["rows"][0];
    let gnum = |i: usize| -> i64 {
        grow[i]["value"].as_str().and_then(|v| v.parse::<i64>().ok()).unwrap_or(0)
    };
    ok_nostore(json!({
        "ok": true,
        "my_stars": stars,
        "rating": weighted_rating(sum, count, gnum(0), gnum(1)),
        "rating_count": count,
    }))
}

/// POST /api/favorite — bo'limni sevimlilarga qo'shish/olib tashlash.
async fn favorite_route(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let aid = b["anime_id"].as_i64().unwrap_or(0);
    let sid = b["season_id"].as_i64().unwrap_or(0);
    let on = b["on"].as_bool().unwrap_or(true);
    if aid <= 0 { return json_resp(&json!({"error": "noto'g'ri so'rov"}), 400); }

    let key = vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)];
    let pre = turso_many(env, &[
        ("SELECT 1 FROM favorites_db WHERE user_id=? AND anime_id=? AND season_id=?", key.clone()),
        ("SELECT fav_count FROM season_db WHERE anime_id=? AND season_id=?",
         vec![TursoArg::int(aid), TursoArg::int(sid)]),
    ]).await?;
    let existed = pre[0]["rows"].as_array().map(|r| !r.is_empty()).unwrap_or(false);
    let mut count = first_row(&pre[1]).and_then(|r| r["fav_count"].as_i64()).unwrap_or(0);

    if on && !existed {
        count += 1;
        turso_batch(env, &[
            ("INSERT OR IGNORE INTO favorites_db (user_id,anime_id,season_id,created_at) VALUES (?,?,?,?)",
             vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(now_ms())]),
            ("UPDATE season_db SET fav_count=? WHERE anime_id=? AND season_id=?",
             vec![TursoArg::int(count), TursoArg::int(aid), TursoArg::int(sid)]),
        ]).await?;
    } else if !on && existed {
        count = (count - 1).max(0);
        turso_batch(env, &[
            ("DELETE FROM favorites_db WHERE user_id=? AND anime_id=? AND season_id=?", key),
            ("UPDATE season_db SET fav_count=? WHERE anime_id=? AND season_id=?",
             vec![TursoArg::int(count), TursoArg::int(aid), TursoArg::int(sid)]),
        ]).await?;
    }
    ok_nostore(json!({"ok": true, "is_fav": on, "fav_count": count}))
}

/// So'rov kelgan domen — rasm manzillarini to'liq qilish uchun.
fn origin_of(req: &Request) -> String {
    match req.url() {
        Ok(u) => format!("{}://{}", u.scheme(), u.host_str().unwrap_or("")),
        Err(_) => String::new(),
    }
}

/// `/api/auth/...` va `/api/telegram/...` yo'llari.
///
/// MUHIM: bu javoblar HECH QACHON keshlanmaydi va yozish
/// amallaridan keyin ro'yxat keshi ham tozalanmaydi (main() ichida
/// alohida ajratilgan) — aks holda har bir kirish anime/bo'limlar
/// keshini behuda kuydirib yuborardi.
async fn auth_route(req: Request, env: &Env, origin: &str, path: &str, method: Method)
    -> Result<Response>
{
    match (method.clone(), path) {

        // ── 1-QADAM: ilova bir martalik token so'raydi ──────────
        (Method::Post, "/api/auth/telegram/start") => {
            // Webhook birinchi so'rovda o'zi ro'yxatdan o'tadi —
            // qo'lda hech narsa qilish shart emas.
            ensure_webhook(env, origin).await;

            let mut req = req;
            let b: Value = req.json().await.unwrap_or(json!({}));
            let now = now_ms();

            // Eskirgan tokenlarni yo'l-yo'lakay tozalaymiz.
            let _ = turso_exec(env, "DELETE FROM login_tokens WHERE expires_at < ?",
                vec![TursoArg::int(now)]).await;

            let token = random_hex(16);
            turso_exec(env,
                "INSERT INTO login_tokens (token,status,user_id,session_token,
                 device,platform,app_version,api_base,created_at,expires_at)
                 VALUES (?,'pending',0,'',?,?,?,?,?,?)",
                vec![
                    TursoArg::text(&token),
                    TursoArg::text(b["device"].as_str().unwrap_or("")),
                    TursoArg::text(b["platform"].as_str().unwrap_or("")),
                    TursoArg::text(b["app_version"].as_str().unwrap_or("")),
                    TursoArg::text(origin),
                    TursoArg::int(now),
                    TursoArg::int(now + LOGIN_TOKEN_TTL_MS),
                ]).await?;

            ok_nostore(json!({
                "token": token,
                "bot": BOT_USERNAME,
                "deep_link": format!("https://t.me/{BOT_USERNAME}?start={token}"),
                "expires_in": LOGIN_TOKEN_TTL_MS / 1000,
            }))
        }

        // ── 3-QADAM: ilova natijani so'rab turadi ───────────────
        (Method::Get, "/api/auth/telegram/status") => {
            let url = req.url()?;
            let token = url.query_pairs().find(|(k, _)| k == "token")
                .map(|(_, v)| v.to_string()).unwrap_or_default();
            if token.is_empty() {
                return json_resp(&json!({"error": "token ko'rsatilmagan"}), 400);
            }

            let res = turso_exec(env, "SELECT * FROM login_tokens WHERE token=?",
                vec![TursoArg::text(&token)]).await?;
            let Some(row) = first_row(&res) else {
                return ok_nostore(json!({"status": "expired"}));
            };
            if row["expires_at"].as_i64().unwrap_or(0) < now_ms() {
                let _ = turso_exec(env, "DELETE FROM login_tokens WHERE token=?",
                    vec![TursoArg::text(&token)]).await;
                return ok_nostore(json!({"status": "expired"}));
            }
            if row["status"].as_str().unwrap_or("") != "approved" {
                return ok_nostore(json!({"status": "pending"}));
            }

            let ures = turso_exec(env, "SELECT * FROM users_db WHERE id=?",
                vec![TursoArg::int(row["user_id"].as_i64().unwrap_or(0))]).await?;
            let Some(u) = first_row(&ures) else {
                return ok_nostore(json!({"status": "expired"}));
            };
            ok_nostore(json!({
                "status": "ok",
                "session": row["session_token"].as_str().unwrap_or(""),
                "user": user_public(origin, &u),
            }))
        }

        // ── 2-QADAM: Telegram START tugmasi bosildi ─────────────
        (Method::Post, "/api/telegram/webhook") => handle_tg_webhook(env, req).await,

        // ── Sozlash TO'G'RI ekanini tekshirish ──────────────────
        //
        // Kirish ishlamay qolsa BIRINCHI shu manzil ochiladi. U
        // ikkita savolga javob beradi:
        //   1. Bot tokeni Cloudflare'ga yuklanganmi va ISHLAYDIMI
        //      (Telegram'ning `getMe` javobi bilan tasdiqlanadi);
        //   2. Webhook ro'yxatdan o'tganmi.
        //
        // Sir ma'lumot chiqmaydi: bot tokeni ham, webhook siri ham
        // javobda YO'Q — faqat "bor/yo'q" belgisi va botning ochiq
        // nomi.
        (Method::Get, "/api/auth/telegram/health") => {
            ensure_webhook(env, origin).await;

            let token_ok = env.secret("TELEGRAM_BOT_TOKEN")
                .map(|t| !t.to_string().is_empty()).unwrap_or(false);

            let (bot_ok, bot_username) = match tg_api(env, "getMe", json!({})).await {
                Ok(me) => (true, me["username"].as_str().unwrap_or("").to_string()),
                Err(_) => (false, String::new()),
            };

            let webhook_url = config_get(env, "tg_webhook_url").await.unwrap_or_default();

            ok_nostore(json!({
                "bot_token_configured": token_ok,
                "bot_reachable": bot_ok,
                "bot_username": bot_username,
                "expected_bot": BOT_USERNAME,
                "webhook_registered": !webhook_url.is_empty(),
                "webhook_url": webhook_url,
                "max_devices": MAX_SESSIONS_PER_USER,
                "ok": token_ok && bot_ok && bot_username == BOT_USERNAME,
            }))
        }

        // ── Ilova ochilganda: sessiya hali kuchdami? ────────────
        (Method::Get, "/api/auth/me") => {
            match session_user(env, &bearer(&req)).await? {
                Some(u) => ok_nostore(json!({"user": user_public(origin, &u)})),
                // Sessiya o'chirilgan (masalan 5-qurilma kirgani uchun)
                // — ilova buni ko'rib foydalanuvchini chiqaradi.
                None => json_resp(&json!({"error": "unauthorized"}), 401),
            }
        }

        // ── USERNAME BAND EMASMI (yozayotganda tekshiriladi) ───
        //
        // Ilova har bir belgi qo'shilganda/olinganda shu manzilga
        // murojaat qiladi, shu sabab javob YENGIL: bitta indeksli
        // SELECT. Keshlanmaydi (`ok_nostore`) — aks holda band
        // bo'lib qolgan nom "bo'sh" bo'lib ko'rinib turardi.
        (Method::Get, "/api/auth/username-check") => {
            let Some(u) = session_user(env, &bearer(&req)).await? else {
                return json_resp(&json!({"error": "unauthorized"}), 401);
            };
            let url = req.url()?;
            let name = url.query_pairs().find(|(k, _)| k == "u")
                .map(|(_, v)| v.to_string()).unwrap_or_default();

            if let Some(why) = username_problem(&name) {
                return ok_nostore(json!({"valid": false, "available": false, "reason": why}));
            }
            let me = u["id"].as_i64().unwrap_or(0);
            let taken = username_taken(env, &name, me).await?;
            ok_nostore(json!({
                "valid": true,
                "available": !taken,
                "reason": if taken { "Bu username band" } else { "" },
            }))
        }

        // ── ISM VA USERNAME'NI SAQLASH ─────────────────────────
        //
        // Yangi hisob birinchi marta shu yerda to'ldiriladi.
        // Tekshiruv SERVERDA ham qaytariladi: ilovadagi tekshiruv
        // faqat qulaylik uchun, ishonch esa shu yerda.
        (Method::Post, "/api/auth/profile") => {
            let Some(u) = session_user(env, &bearer(&req)).await? else {
                return json_resp(&json!({"error": "unauthorized"}), 401);
            };
            let me = u["id"].as_i64().unwrap_or(0);
            let mut req = req;
            let b: Value = req.json().await.unwrap_or(json!({}));

            let first_name = b["first_name"].as_str().unwrap_or("").trim().to_string();
            let username = b["username"].as_str().unwrap_or("").trim().to_string();

            if first_name.is_empty() {
                return json_resp(&json!({"error": "Ism kiritilmadi"}), 400);
            }
            // ── ISM: 20 TA BELGI, ICHIDA ISTALGAN NARSA ───────
            //
            // TALAB: ismga emoji ham, istalgan belgi ham qo'yish
            // mumkin; uzunligi esa eng ko'pi 20 ta belgi.
            //
            // 20 TA BELGINI ILOVA SANAYDI, server emas. Sabab:
            // "belgi" degani ko'zga BITTA ko'ringan narsa, lekin
            // bitta emoji ichida bir nechta Unicode kodi bo'lishi
            // mumkin (masalan oila emojisi \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} — beshta).
            // Rustning `chars()` aynan Unicode kodlarini sanaydi,
            // ya'ni u yerda 20 deb chegaralasak, foydalanuvchi
            // ilovada 4 ta emoji yozganda ham "uzun" degan xato
            // chiqib qolardi.
            //
            // Shu sabab bu yerdagi chegara — faqat SUIISTE'MOLGA
            // qarshi keng chegara (bir necha kilobaytlik ism
            // bazaga tushmasin), haqiqiy 20 ta belgi qoidasi esa
            // ilovada (`AuthService.nameProblem`) qo'llanadi.
            if first_name.chars().count() > 160 {
                return json_resp(&json!({"error": "Ism juda uzun"}), 400);
            }
            if let Some(why) = username_problem(&username) {
                return json_resp(&json!({"error": why}), 400);
            }
            if username_taken(env, &username, me).await? {
                return json_resp(&json!({"error": "Bu username band"}), 409);
            }

            let res = turso_exec(env,
                "UPDATE users_db SET first_name=?,username=?,profile_done=1
                 WHERE id=? RETURNING *",
                vec![TursoArg::text(&first_name), TursoArg::text(&username),
                     TursoArg::int(me)]).await;

            let Ok(res) = res else {
                // Yagona indeks to'qnashuvi — ayni damda boshqa
                // kishi shu nomni olib ulgurgan.
                return json_resp(&json!({"error": "Bu username band"}), 409);
            };
            let Some(nu) = first_row(&res) else {
                return err500("Saqlab bo'lmadi");
            };

            // Sessiyalar jurnalidagi nusxa ham yangilansin.
            let _ = turso_exec(env,
                "UPDATE sessions_db SET username=?,first_name=? WHERE user_id=?",
                vec![TursoArg::text(&username), TursoArg::text(&first_name),
                     TursoArg::int(me)]).await;

            ok_nostore(json!({"user": user_public(origin, &nu)}))
        }

        // ── HISOBNI BUTUNLAY O'CHIRISH ─────────────────────────
        //
        // Ilovada IKKI MARTA so'ralgandan keyin chaqiriladi.
        //
        // TARTIB: 1) B2'dagi profil rasmi, 2) sessiyalar,
        // 3) bir martalik tokenlar, 4) hisobning o'zi.
        //
        // NEGA AYNAN SHU TARTIBDA: bazadagi yozuv B2'dagi faylga
        // yagona havoladir. Avval hisobni o'chirsak va keyin fayl
        // o'chmay qolsa, uni endi HECH KIM topa olmaydi — fayl
        // omborda abadiy yotib, pul yeb turadi.
        //
        // Shu sabab rasm o'chishi TEKSHIRILADI: o'chmasa hisobga
        // umuman tegilmaydi va foydalanuvchi qaytadan urinishi
        // mumkin. (Fayl allaqachon yo'q bo'lsa — bu xato emas.)
        (Method::Post, "/api/auth/delete-account") => {
            let Some(u) = session_user(env, &bearer(&req)).await? else {
                return json_resp(&json!({"error": "unauthorized"}), 401);
            };
            let me = u["id"].as_i64().unwrap_or(0);
            if me == 0 {
                return err500("Hisob aniqlanmadi");
            }

            let avatar = u["avatar_file"].as_str().unwrap_or("").to_string();
            if !avatar.is_empty() && !b2_delete_checked(env, &avatar).await {
                return json_resp(&json!({
                    "error": "Profil rasmini o'chirib bo'lmadi — qaytadan urinib ko'ring"
                }), 502);
            }

            let _ = turso_exec(env, "DELETE FROM sessions_db WHERE user_id=?",
                vec![TursoArg::int(me)]).await;
            let _ = turso_exec(env, "DELETE FROM login_tokens WHERE user_id=?",
                vec![TursoArg::int(me)]).await;
            let _ = turso_exec(env, "DELETE FROM users_db WHERE id=?",
                vec![TursoArg::int(me)]).await;

            ok_nostore(json!({"success": true}))
        }

        // ── PROFIL RASMINI ALMASHTIRISH ────────────────────────
        //
        // Ilova rasmni B2'ga O'ZI yuklaydi (`/api/upload-token`
        // bilan, anime rasmlari qanday yuklansa shunday), keyin
        // shu yerga faqat FAYL NOMINI yuboradi.
        //
        // Bu yerda ikki ish bo'ladi:
        //   1. eski rasm B2'dan BUTUNLAY o'chiriladi — foydalanuvchi
        //      rasmni necha marta almashtirsa ham ombor to'lib
        //      ketmaydi;
        //   2. yangi nom `users_db.avatar_file` ga yoziladi.
        //
        // Nom qolipi `valid_avatar_file` bilan tekshiriladi, ya'ni
        // hech kim boshqa birovning (yoki anime) faylini o'z
        // profiliga bog'lab, keyin uni o'chirtira olmaydi.
        (Method::Post, "/api/auth/avatar") => {
            let Some(u) = session_user(env, &bearer(&req)).await? else {
                return json_resp(&json!({"error": "unauthorized"}), 401);
            };
            let uid = u["id"].as_i64().unwrap_or(0);
            let mut req = req;
            let b: Value = req.json().await.unwrap_or(json!({}));
            let file = b["file"].as_str().unwrap_or("").to_string();
            if !valid_avatar_file(&file, uid) {
                return json_resp(&json!({"error": "fayl nomi noto'g'ri"}), 400);
            }

            // Eskisi — YANGISINI yozishdan oldin olinadi.
            let old_file = u["avatar_file"].as_str().unwrap_or("").to_string();

            let res = turso_exec(env,
                "UPDATE users_db SET avatar_file=? WHERE id=? RETURNING *",
                vec![TursoArg::text(&file), TursoArg::int(uid)]).await?;
            let Some(nu) = first_row(&res) else {
                return err500("Rasmni saqlab bo'lmadi");
            };

            // Eski fayl faqat YANGISI saqlangandan keyin o'chiriladi:
            // saqlash yiqilsa foydalanuvchi rasmsiz qolib ketmaydi.
            if !old_file.is_empty() && old_file != file {
                b2_delete(env, &old_file).await;
            }

            ok_nostore(json!({"user": user_public(origin, &nu)}))
        }

        (Method::Post, "/api/auth/logout") => {
            let t = bearer(&req);
            if !t.is_empty() {
                let _ = turso_exec(env, "DELETE FROM sessions_db WHERE session_token=?",
                    vec![TursoArg::text(&t)]).await;
            }
            ok_nostore(json!({"success": true}))
        }

        // ── Sessiyalar jurnali: qaysi qurilma, qaysi API ────────
        (Method::Get, "/api/auth/sessions") => {
            let t = bearer(&req);
            let Some(u) = session_user(env, &t).await? else {
                return json_resp(&json!({"error": "unauthorized"}), 401);
            };
            let res = turso_exec(env,
                "SELECT * FROM sessions_db WHERE user_id=? ORDER BY last_seen_at DESC",
                vec![TursoArg::int(u["id"].as_i64().unwrap_or(0))]).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            let items: Vec<Value> = rows.iter().map(|r| {
                let mut o = row_to_obj(&cols, r.as_array().unwrap_or(&vec![]));
                if let Some(m) = o.as_object_mut() {
                    // Sessiya tokeni javobga CHIQMAYDI — faqat "shu
                    // qurilmami?" belgisiga aylantiriladi.
                    let is_current = m.get("session_token")
                        .and_then(|v| v.as_str()).map(|s| s == t).unwrap_or(false);
                    m.remove("session_token");
                    m.insert("current".into(), json!(is_current));
                }
                o
            }).collect();
            ok_nostore(json!({"sessions": items, "max_devices": MAX_SESSIONS_PER_USER}))
        }

        _ => {
            // DELETE /api/auth/sessions/:id — o'z qurilmasini chiqarish
            if method == Method::Delete {
                if let Some(ids) = path.strip_prefix("/api/auth/sessions/") {
                    if let Ok(sid) = ids.parse::<i64>() {
                        let Some(u) = session_user(env, &bearer(&req)).await? else {
                            return json_resp(&json!({"error": "unauthorized"}), 401);
                        };
                        let _ = turso_exec(env,
                            "DELETE FROM sessions_db WHERE id=? AND user_id=?",
                            vec![TursoArg::int(sid),
                                 TursoArg::int(u["id"].as_i64().unwrap_or(0))]).await;
                        return ok_nostore(json!({"success": true}));
                    }
                }
            }
            err404("Not found")
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

    // Kirish (auth) so'rovlari ro'yxat keshiga umuman aloqador
    // emas — ular ham keshni tozalayversa, HAR BIR kirish
    // anime/bo'limlar keshini behuda kuydirib yuborardi.
    // `/api/history` ham shu ro'yxatga kiradi: u foydalanuvchining
    // SHAXSIY yozuvi, anime/bo'limlar ro'yxatiga umuman aloqasi
    // yo'q. Aks holda har bir ko'rilgan qism butun katalog keshini
    // behuda kuydirib yuborardi.
    // `/api/rating` va `/api/favorite` ham shu ro'yxatda: ular
    // foydalanuvchining SHAXSIY yozuvi va katalog ro'yxatiga
    // aloqasi yo'q. Aks holda har bir baho/sevimli butun katalog
    // keshini behuda kuydirib yuborardi.
    let auth_path = path.starts_with("/api/auth/")
        || path.starts_with("/api/telegram/")
        || path.starts_with("/api/history")
        || path == "/api/rating"
        || path == "/api/favorite";
    let write = matches!(method, Method::Post | Method::Put | Method::Delete) && !auth_path;
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
                    &format!("public, max-age={}", cache_seconds(&path)),
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
                &format!("public, max-age={}", cache_seconds(&path)),
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
            let resp = b2_proxy(&env, &ctx, fname, range_header).await?;
            note_response_traffic(&env, &ctx, &resp);
            return Ok(resp);
        }
        // Pleyer SHU manzildan oqim oladi (b2_play izohiga qarang).
        // Farqi: javob hech qachon sun'iy kesilmaydi va bo'laklab
        // keshlash mantiqi umuman ishlatilmaydi — ya'ni pleyer
        // faqat o'zi so'ragan baytni oladi.
        if let Some(fname) = path.strip_prefix("/api/play/") {
            let resp = b2_play(&env, &ctx, fname, range_header).await?;
            note_response_traffic(&env, &ctx, &resp);
            return Ok(resp);
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

    // ── TELEGRAM ORQALI KIRISH ────────────────────────────────
    if path.starts_with("/api/history") {
        return history_route(req, &env, path, method.clone()).await;
    }

    if path.starts_with("/api/auth/") || path.starts_with("/api/telegram/") {
        return auth_route(req, &env, &origin, path, method.clone()).await;
    }

    // ── SHAFFOF STATISTIKA ────────────────────────────────────
    if path == "/api/stats" && method == Method::Get {
        return stats_route(&env).await;
    }

    // ── BAHO VA SEVIMLILAR ────────────────────────────────────
    if path == "/api/rating" && method == Method::Post {
        return rating_route(req, &env).await;
    }
    if path == "/api/favorite" && method == Method::Post {
        return favorite_route(req, &env).await;
    }

    // ── BITTA BO'LIM: MA'LUMOT OYNASI UCHUN ───────────────────
    //
    // Pleyer ochilganda BITTA so'rov: bo'lim ma'lumoti, ko'rishlar,
    // tomosha vaqti, sevimlilar soni, reyting va shu odamning O'Z
    // bahosi/sevimlisi — hammasi bir yo'la.
    if method == Method::Get {
        if let Some(rest) = path.strip_prefix("/api/season/") {
            let parts: Vec<&str> = rest.split('/').collect();
            if parts.len() == 2 {
                if let (Ok(aid), Ok(sid)) = (parts[0].parse::<i64>(), parts[1].parse::<i64>()) {
                    return season_detail(&env, &origin, &req, aid, sid).await;
                }
            }
        }
    }
    // Avatar: Telegram'dan olinadi, WORKER orqali uzatiladi va
    // chekkada 1 kun keshlanadi. Telegram fayl manzilida bot
    // tokeni bo'lgani uchun u manzil ilovaga chiqarilmaydi.
    if method == Method::Get {
        if let Some(ids) = path.strip_prefix("/api/avatar/") {
            if let Ok(uid) = ids.parse::<i64>() {
                return tg_avatar(&env, uid).await;
            }
        }
    }

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
                "INSERT INTO anime_db (id,photo_url,name,davlat,studiya,janri,tavsif,created_at)
                 VALUES (?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::int(new_id),
                    TursoArg::text(b["photo_url"].as_str().unwrap_or("")),
                    TursoArg::text(b["name"].as_str().unwrap_or("")),
                    TursoArg::text(b["davlat"].as_str().unwrap_or("")),
                    TursoArg::text(b["studiya"].as_str().unwrap_or("")),
                    TursoArg::text(b["janri"].as_str().unwrap_or("")),
                    TursoArg::text(b["tavsif"].as_str().unwrap_or("")),
                    TursoArg::int(now_ms()),
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

        // ── BO'LIM QO'SHISH ───────────────────────────────────
        //
        // TOPILGAN XATO (foydalanuvchi ko'rgan "500 INTERNAL SERVER
        // ERROR"): `season_id` birlamchi kalitning bir qismi va u
        // QO'LDA kiritilardi. Band raqam kiritilsa SQLite
        // "UNIQUE constraint failed" beradi va so'rov 500 bo'lib
        // yiqilardi — foydalanuvchiga esa sababi ko'rinmasdi.
        //
        // Endi `season_id` ni SERVER beradi (shu anime uchun
        // MAX+1), foydalanuvchi esa faqat "N-bo'lim" raqamini
        // kiritadi. Band bo'lim raqami ham tushunarli xabar bilan
        // qaytariladi.
        (Method::Post, "/api/seasons") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let (bid, _, pu, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, animeidval) = season_fields(&b);
            let anime_id: i64 = animeidval.trim().parse().unwrap_or(0);
            if anime_id <= 0 { return json_resp(&json!({"error": "anime tanlanmagan"}), 400); }
            if bid <= 0 { return json_resp(&json!({"error": "Bo'lim raqamini kiriting"}), 400); }

            let pre = turso_many(&env, &[
                ("SELECT COALESCE(MAX(season_id),0)+1 FROM season_db WHERE anime_id=?",
                 vec![TursoArg::int(anime_id)]),
                ("SELECT COUNT(*) FROM season_db WHERE anime_id=? AND bolim_id=?",
                 vec![TursoArg::int(anime_id), TursoArg::int(bid)]),
            ]).await?;
            if scalar(&pre[1]) > 0 {
                return json_resp(&json!({"error": format!("{bid}-bo'lim allaqachon mavjud")}), 409);
            }
            let sid = scalar(&pre[0]).max(1);
            let janrs = janr_list(&b, &janri);
            let janri_text = janrs.join(", ");

            let res = turso_exec(&env,
                "INSERT INTO season_db (anime_id,season_id,bolim_id,photo_url,nomi,studio,tarjimon,yili,janri,turi,holati,tavsif,created_at)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::int(anime_id), TursoArg::int(sid), TursoArg::int(bid),
                    TursoArg::text(&pu), TursoArg::text(&nomi), TursoArg::text(&studio),
                    TursoArg::text(&tarjimon), TursoArg::text(&yili), TursoArg::text(&janri_text),
                    TursoArg::text(&turi), TursoArg::text(&holati), TursoArg::text(&tavsif),
                    TursoArg::int(now_ms()),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Bo'lim qo'shib bo'lmadi"); }
            save_janrs(&env, anime_id, sid, &janrs).await;
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
                "INSERT INTO epizod_db (anime_id,season_id,epizod_id,epizod_number,epizod_name,url_360p,size_360p,url_480p,size_480p,url_720p,size_720p,url_1080p,size_1080p,created_at)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::text(&anime_id), TursoArg::text(&season_id), TursoArg::int(new_id),
                    TursoArg::int(ep_num), TursoArg::text(&ep_name),
                    TursoArg::text(&u360), TursoArg::text(&s360), TursoArg::text(&u480), TursoArg::text(&s480),
                    TursoArg::text(&u720), TursoArg::text(&s720), TursoArg::text(&u1080), TursoArg::text(&s1080),
                    TursoArg::int(now_ms()),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Epizod qo'shib bo'lmadi"); }
            // Bo'limdagi qismlar soni — Ma'lumot oynasidagi
            // "N-bo'lim M-qism" shundan olinadi.
            let _ = turso_exec(&env,
                "UPDATE season_db SET epizod_count=(SELECT COUNT(*) FROM epizod_db WHERE anime_id=? AND season_id=?)
                 WHERE anime_id=? AND season_id=?",
                vec![
                    TursoArg::text(&anime_id), TursoArg::text(&season_id),
                    TursoArg::text(&anime_id), TursoArg::text(&season_id),
                ]).await;
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
                            let _ = turso_batch(&env, &[
                                ("DELETE FROM epizod_db WHERE anime_id=? AND season_id=? AND epizod_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid)]),
                                ("UPDATE season_db SET epizod_count=(SELECT COUNT(*) FROM epizod_db WHERE anime_id=? AND season_id=?)
                                  WHERE anime_id=? AND season_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(aid), TursoArg::int(sid)]),
                            ]).await;
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
                            let janrs = janr_list(&b, &janri);
                            let janri = janrs.join(", ");
                            save_janrs(&env, aid, sid, &janrs).await;
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

