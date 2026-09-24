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
// Cloudflare Cache API orqali keshlaydi (1000 kunga). Bo'lak birinchi
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

/// To'liq manzildan YALANG fayl nomini ajratadi (`resolve_url` ning
/// teskarisi).
///
/// NEGA KERAK: bazada manzil emas, faqat fayl nomi saqlanadi.
/// Ayniqsa `watch_history_db` uchun muhim — u eng tez o'sadigan
/// jadval va har qatorda to'liq manzil ~90 belgi, yalang nom esa
/// ~35 belgi joy egallaydi. Domen o'zgarsa ham eski yozuvlar
/// ishlayveradi, chunki manzil har safar qaytadan yig'iladi.
fn bare_name(value: &str) -> String {
    let v = value.trim();
    if v.is_empty() { return String::new(); }
    // So'rov qismi (`?...`) va yo'lning oxirgi bo'lagi.
    let no_query = v.split('?').next().unwrap_or(v);
    match no_query.rsplit('/').next() {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => no_query.to_string(),
    }
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
    // ── BELGI FAQAT MUVAFFAQIYATDA QO'YILADI ──────────────────
    //
    // Ilgari `init_db` yiqilsa ham belgi qo'yilardi va izolyat
    // umrining OXIRIGACHA jadvallar yaratilmagan holda ishlayverardi
    // — keyingi har bir so'rov "no such table" bilan yiqilardi va
    // sababi hech qayerda ko'rinmasdi.
    if init_db(env).await {
        DB_READY.store(true, Ordering::Relaxed);
    }
}

async fn init_db(env: &Env) -> bool {
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
    let mut ok = turso_batch(env, &[
        // `created_at` YO'Q: anime qachon qo'shilgani hech qayerda
        // ko'rsatilmaydi (pleyerdagi "qo'shilgan sana" BO'LIMniki).
        ("CREATE TABLE IF NOT EXISTS anime_db (
            id INTEGER PRIMARY KEY,
            photo_url TEXT, name TEXT, davlat TEXT, studiya TEXT,
            janri TEXT, tavsif TEXT
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
            -- Yosh chegarasi: 0 — belgilanmagan, aks holda 6/12/16/18...
            -- Admin uni BO'LIM qo'shish oynasida yozadi va u butun
            -- bo'limga amal qiladi (foydalanuvchi talabi: yosh
            -- chegarasi bitta bo'lim uchun amal qiladi).
            -- Kartochkada 18+ ko'rinishida chiqadi.
            yosh INTEGER DEFAULT 0,
            created_at INTEGER,
            PRIMARY KEY (anime_id, season_id)
        )", vec![]),
        // Indeks yo'q: "anime bo'limlari" so'rovi PK boshidagi
        // `anime_id` bilan ishlaydi, umumiy ro'yxat esa kichik.

        // ── INTRO (OPENING) VAQTLARI ──────────────────────────
        //
        // TALAB (foydalanuvchi): pleyer openingni o'tkazib
        // yuboradigan tugma ko'rsatsin, bitta qismda bunday joy
        // bir nechta bo'lishi mumkin.
        //
        // Shu sabab 5 ta JUFTLIK ustun bor:
        //
        //   intro_1 / intro_2   — 1-oraliqning boshi va oxiri,
        //   intro_3 / intro_4   — 2-oraliq,
        //   ... intro_9 / intro_10 — 5-oraliq.
        //
        // Qiymat — AYNAN admin yozgan MATN: `5:14`, `6:44`
        // (foydalanuvchi talabi: "intro vaqtini 5:14 va 6:44 qilib
        // yoziladigan qil, soniya bilan emas").
        //
        // Ilgari bu yerda soniya saqlanardi va admin oynasi uni
        // ikki marta o'girardi (yozishda -> soniya, ochishda ->
        // matn). Bitta ortiqcha qatlam, bitta ortiqcha xato
        // manbai: endi bazada ham, ekranda ham bir xil matn
        // turadi.
        //
        // Pleyer matnni qism ochilganda BIR MARTA millisekundga
        // o'giradi (`_introsOf`) va keyin tayyor songa qaraydi —
        // ya'ni bu tezlikka ta'sir qilmaydi.
        //
        // Bo'sh satr — "bu oraliq belgilanmagan".
        ("CREATE TABLE IF NOT EXISTS epizod_db (
            anime_id INTEGER, season_id INTEGER, epizod_id INTEGER,
            epizod_number INTEGER, epizod_name TEXT,
            url_360p TEXT, size_360p TEXT,
            url_480p TEXT, size_480p TEXT,
            url_720p TEXT, size_720p TEXT,
            url_1080p TEXT, size_1080p TEXT,
            intro_1 TEXT, intro_2 TEXT, intro_3 TEXT, intro_4 TEXT,
            intro_5 TEXT, intro_6 TEXT, intro_7 TEXT, intro_8 TEXT,
            intro_9 TEXT, intro_10 TEXT,
            views_total INTEGER DEFAULT 0,
            watch_ms_total INTEGER DEFAULT 0,
            -- ESKI ustun: yosh chegarasi endi QISMGA emas, butun
            -- BO'LIMga yoziladi (`season_db.yosh`). Ustun eski
            -- bazalarda qolgani uchun turibdi — hech qayerda
            -- o'qilmaydi va yozilmaydi.
            yosh INTEGER DEFAULT 0,
            created_at INTEGER,
            PRIMARY KEY (anime_id, season_id, epizod_id)
        )", vec![]),

        // ── JANRLAR: BITTA BO'LIM — BITTA QATOR ───────────────
        //
        // TALAB (foydalanuvchi): "hozir tursoda bitta bo'lim uchun
        // 4 yoki 5 ta qator yozilyabdi, bu esa harajatni oshiradi".
        //
        // To'g'ri: ilgari bu BOG'LOVCHI jadval edi va har bir janr
        // uchun alohida qator yozilardi. Endi bo'limning hamma
        // janri BITTA qatorga sig'adi — `janr_1 ... janr_10`.
        // Bo'sh ustun = janr yo'q.
        //
        // NEGA 10 TA: ro'yxatda jami 37 janr bor va bitta bo'limga
        // odatda 3-6 tasi qo'yiladi. Bo'sh TEXT ustun SQLite'da
        // bir baytdan oshmaydi, ya'ni zaxira ustunlar deyarli
        // bepul.
        //
        // ── INDEKS OLIB TASHLANDI ─────────────────────────────
        //
        // `idx_janr(janr)` endi ma'nosiz: janr 10 ta ustunning
        // istalganida bo'lishi mumkin va bitta indeks ularni
        // qamrab ololmaydi. Janr bo'yicha filtr — bo'limlar
        // ro'yxati bo'yicha to'liq ko'rib chiqish, lekin bo'limlar
        // soni KICHIK (foydalanuvchilar emas, kontent), shu sabab
        // bu arzon. Yutuq esa katta: har bo'limga bitta qator va
        // bitta yozuv so'rovi.
        ("CREATE TABLE IF NOT EXISTS season_janr (
            anime_id INTEGER, season_id INTEGER,
            janr_1 TEXT, janr_2 TEXT, janr_3 TEXT, janr_4 TEXT, janr_5 TEXT,
            janr_6 TEXT, janr_7 TEXT, janr_8 TEXT, janr_9 TEXT, janr_10 TEXT,
            PRIMARY KEY (anime_id, season_id)
        )", vec![]),
    ]).await.is_ok();

    // ── YOSH CHEGARASI USTUNI (eski bazalar uchun) ─────────────
    //
    // `CREATE TABLE IF NOT EXISTS` mavjud jadvalga TEGMAYDI, ya'ni
    // baza allaqachon yaratilgan bo'lsa yuqoridagi `yosh` ustuni
    // o'z-o'zidan paydo bo'lmaydi. Shu sabab qo'shimcha `ALTER`.
    //
    // HAR BIRI ALOHIDA yuboriladi va natijasi E'TIBORSIZ
    // qoldiriladi: ustun allaqachon bo'lsa Turso xato qaytaradi,
    // to'plamda esa birinchi xatodan keyin qolgani umuman
    // bajarilmasdi. `ok` ga ham qo'shilmaydi — bu xato emas,
    // kutilgan holat.
    // ── OLIB TASHLANGAN IMKONIYATLARNI TOZALASH ──────────────
    //
    // TALAB (foydalanuvchi): "shaxsiy chat va GIF tizimini
    // butunlay tozalab tashla, ilovadan ham bazadan ham — umuman
    // keragi yo'q".
    //
    // Bu buyruqlar bir marta ishlaydi va keyin xato qaytaradi
    // (jadval yoki ustun allaqachon yo'q) — bu KUTILGAN holat,
    // pastdagi halqa natijani e'tiborsiz qoldiradi.
    //
    // Shaxsiy yozishmalarga kelgan shikoyatlar ham ketadi: ular
    // endi hech qayerga olib bormaydi.
    for sql in [
        // ── BLOKLASH: MUDDAT VA SABAB ────────────────────
        //
        // TALAB (foydalanuvchi): "foydalanuvchini bloklaganda
        // muddatsiz va muddatli bloklash tizimini qo'sh va
        // bloklanish sababini ham yozsa bo'ladigan qil".
        //
        // `is_banned` eski ustun, o'z joyida qoladi — "bloklanganmi"
        // degan savolga javob beradi.
        //   * `ban_until` = 0  -> MUDDATSIZ;
        //   * `ban_until` > 0  -> o'sha vaqtgacha.
        // `ban_reason` bo'sh bo'lishi mumkin (sabab yozilmagan).
        // ── PROFIL MAXFIYLIGI ────────────────────────────
        //
        // TALAB (foydalanuvchi): "foydalanuvchi boshqa profilni
        // ko'rishi mumkin bo'lsin, faqat to'liq emas — faqatgina
        // profil surati, nomi va usernameni ko'rishga ruxsat
        // berilsin. ID, balans va qolgan statistikalar
        // ko'rinmasin. Bu narsalarni boshqalar ko'rishi uchun
        // foydalanuvchi sozlamalar panelidan ruxsat berib
        // chiqishi kerak".
        //
        // Ya'ni ODATIY holat — YOPIQ. Ustun `0` bo'lsa statistika
        // ko'rinmaydi; odam sozlamalardan yoqsa `1` bo'ladi.
        // Odatiy qiymatni ataylab `0` qildik: maxfiylik
        // "o'chirib qo'yiladigan" emas, "yoqiladigan" narsa
        // bo'lishi kerak.
        "DROP TABLE IF EXISTS dm_messages",
        "DROP TABLE IF EXISTS dm_threads",
        "DROP TABLE IF EXISTS dm_reactions",
        "DELETE FROM reports_db WHERE kind='dm'",
        "ALTER TABLE comments_db DROP COLUMN gif_url",
        "ALTER TABLE users_db ADD COLUMN show_stats INTEGER DEFAULT 0",
        // ── QAYSI STATISTIKA YASHIRILGAN ──────────────────────
        //
        // TALAB (foydalanuvchi): "sozlamalardan avvalgi yashirish
        // tugmasini olib tashla va o'rniga HAR BITTA statistika
        // uchun alohida yashirish tugmasi qo'yib chiq. Barcha
        // hisobda statistika OCHIQ turadi va foydalanuvchi qo'lda
        // yashirib chiqishi kerak; qaysi statistika yashirilgani
        // bazada ham saqlanishi kerak".
        //
        // Bitta `INTEGER` bilan bo'lmaydi — endi bittasi emas,
        // yettitasi bor. Alohida jadval ham ortiqcha: qiymat
        // kichkina va har doim foydalanuvchi qatori bilan birga
        // o'qiladi. Shu sabab ODDIY RO'YXAT: "episodes,comments".
        // Bo'sh satr — hech nima yashirilmagan (odatiy holat).
        "ALTER TABLE users_db ADD COLUMN hidden_stats TEXT DEFAULT ''",
        "ALTER TABLE users_db ADD COLUMN ban_until INTEGER DEFAULT 0",
        "ALTER TABLE users_db ADD COLUMN ban_reason TEXT DEFAULT ''",
        "ALTER TABLE users_db ADD COLUMN banned_at INTEGER DEFAULT 0",
        "ALTER TABLE season_db ADD COLUMN yosh INTEGER DEFAULT 0",
        "ALTER TABLE epizod_db ADD COLUMN yosh INTEGER DEFAULT 0",
        "ALTER TABLE chat_messages ADD COLUMN media_file TEXT DEFAULT ''",
        "ALTER TABLE chat_messages ADD COLUMN media_type TEXT DEFAULT ''",
        // Ovozli xabarning uzunligi (millisekund). Bo'lmasa ham
        // ishlaydi, lekin u holda uzunlik faqat ijro boshlangach
        // ma'lum bo'lardi.
        "ALTER TABLE chat_messages ADD COLUMN media_ms INTEGER DEFAULT 0",
        // Suhbatdosh xabarni O'QIGANMI (bitta / ikkita belgi).
        "ALTER TABLE chat_messages ADD COLUMN seen INTEGER DEFAULT 0",
    ] {
        let _ = turso_exec(env, sql, vec![]).await;
    }

    // ── 2. FOYDALANUVCHI ───────────────────────────────────────
    ok &= turso_batch(env, &[
        ("CREATE TABLE IF NOT EXISTS users_db (
            id INTEGER PRIMARY KEY,
            telegram_id INTEGER UNIQUE,
            username TEXT, first_name TEXT, last_name TEXT,
            is_banned INTEGER DEFAULT 0,
            balance INTEGER DEFAULT 0,
            avatar_file TEXT,
            profile_done INTEGER DEFAULT 1,
            traffic_bytes INTEGER DEFAULT 0,
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
            device TEXT, platform TEXT, app_version TEXT,
            created_at INTEGER,
            expires_at INTEGER
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_login_exp ON login_tokens(expires_at)", vec![]),

        // Qurilmalar ro'yxati. Foydalanuvchining ismi/username'i
        // BU YERDA SAQLANMAYDI — u `users_db` da turadi va kerak
        // bo'lsa `user_id` bo'yicha olinadi. Nusxa saqlash qatorni
        // bekorga kattalashtirardi va nom o'zgarganda eskirib
        // qolardi.
        ("CREATE TABLE IF NOT EXISTS sessions_db (
            id INTEGER PRIMARY KEY,
            user_id INTEGER,
            session_token TEXT UNIQUE,
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
    ]).await.is_ok();

    // ── 3. TOMOSHA, BAHO, SEVIMLILAR, STATISTIKA ───────────────
    ok &= turso_batch(env, &[
        // Bitta qism uchun HAR DOIM bitta qator.
        //
        //   watched_ms — shu odam shu qismni JAMI qancha ko'rgani
        //                (1x tezlikda, qism uzunligidan oshmaydi);
        //   view_count — necha marta ochib ko'rgani;
        //   deleted_at — 0 bo'lmasa, tarixda KO'RINMAYDI. Yozuv
        //                o'chirilmaydi: qism qayta ko'rilsa yana
        //                paydo bo'ladi va statistika buzilmaydi.
        // ── BU JADVAL ENG TEZ O'SADI ──────────────────────────
        //
        // Qatorlar soni = foydalanuvchilar x ko'rilgan qismlar.
        // Shu sabab bu yerda BITTA HAM ortiqcha ustun yo'q:
        //
        //   * `video_url` — B2'dagi YALANG FAYL NOMI (to'liq
        //     manzil EMAS). To'liq manzil har qatorda ~90 belgi
        //     bo'lardi, yalang nom esa ~35. Ilovaga berishdan
        //     oldin manzil `resolve_list` bilan to'ldiriladi —
        //     `epizod_db.url_*` bilan bir xil qoida.
        //   * `created_at` OLIB TASHLANDI — u yozilar, lekin
        //     hech qayerda o'qilmasdi.
        //
        // ── KALIT `epizod_id`, RAQAM EMAS (TOPILGAN XATO) ─────
        //
        // TALAB (foydalanuvchi): "watch history jurnaliga epizod
        // raqami emas idsi yozilsin — qism raqamini o'zgartirganda
        // tomosha tarixidagi kadrlar qotib qoldi".
        //
        // Sabab aniq: kalit `epizod_number` edi, ya'ni admin
        // "5-qism"ni "6-qism" qilib qo'ysa, tarixdagi yozuv HECH
        // QAYSI qismga tegmay qolardi — kadr ham, davom ettirish
        // ham ishlamasdi.
        //
        // `epizod_id` esa qism qo'shilganda bir marta beriladi va
        // HECH QACHON o'zgarmaydi.
        //
        // ── `epizod_number` USTUNI YO'Q (foydalanuvchi talabi) ─
        //
        // "watch history jurnalidan epizod number'ni olib tashla,
        // epizod id yetadi."
        //
        // To'g'ri: raqam baribir `epizod_db` dan `LEFT JOIN` bilan
        // olinardi (admin raqamni o'zgartirsa tarixda ham darhol
        // yangisi ko'rinsin deb), ya'ni bu ustun faqat o'qilmagan
        // nusxa edi. Bu jadval eng tez o'sadigani — har qatordan
        // bitta ustun tejash arziydi.
        //
        // `last_quality` — foydalanuvchi shu qismni oxirgi marta
        // qaysi sifatda ko'rgani ("720p"). Keyingi safar internet
        // yoqilganda video AYNAN o'sha sifatdan davom etadi.
        ("CREATE TABLE IF NOT EXISTS watch_history_db (
            user_id INTEGER,
            anime_id INTEGER,
            season_id INTEGER,
            epizod_id INTEGER,
            video_url TEXT,
            last_quality TEXT,
            position_ms INTEGER,
            duration_ms INTEGER,
            watched_ms INTEGER DEFAULT 0,
            view_count INTEGER DEFAULT 0,
            deleted_at INTEGER DEFAULT 0,
            updated_at INTEGER,
            PRIMARY KEY (user_id, anime_id, season_id, epizod_id)
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
        //   stats_daily  — hafta/oy/jami uchun (yiliga ~365).
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

        // ── SINXRONLASH PAKETLARI ─────────────────────────────
        //
        // Ilova hamma yozuvni telefonda yig'ib, kuniga bir necha
        // marta BITTA paket qilib yuboradi. Tarmoq uzilib paket
        // ikki marta kelib qolsa, ko'rishlar va tomosha vaqti IKKI
        // MARTA sanalib ketardi — shu sabab har bir odamning
        // oxirgi paket raqami saqlanadi va takrori rad etiladi.
        ("CREATE TABLE IF NOT EXISTS sync_batches (
            user_id INTEGER PRIMARY KEY,
            batch_id TEXT,
            at INTEGER
        )", vec![]),

        // Worker ichki sozlamalari (webhook siri va manzili).
        ("CREATE TABLE IF NOT EXISTS app_config (
            cfg_key TEXT PRIMARY KEY,
            cfg_value TEXT
        )", vec![]),

        // ── BALANS, OBUNA VA TO'LOVLAR ────────────────────────
        //
        // `payments_db` — tezcheck.uz da yaratilgan har bir to'lov
        // havolasi. `status` faqat `pending` -> `paid` yo'nalishida
        // o'zgaradi, shu sabab balans ikki marta oshmaydi.
        ("CREATE TABLE IF NOT EXISTS payments_db (
            order_id TEXT PRIMARY KEY,
            user_id INTEGER,
            amount INTEGER,
            status TEXT,
            pay_url TEXT,
            created_at INTEGER,
            expires_at INTEGER,
            paid_at INTEGER
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_pay_user
            ON payments_db(user_id, created_at)", vec![]),

        // Obuna — odamga BITTA qator, tugash vaqti bilan.
        ("CREATE TABLE IF NOT EXISTS subs_db (
            user_id INTEGER PRIMARY KEY,
            expires_at INTEGER,
            updated_at INTEGER
        )", vec![]),

        // Tarix oynasi: har bir to'ldirish va har bir obuna.
        ("CREATE TABLE IF NOT EXISTS billing_log (
            id TEXT PRIMARY KEY,
            user_id INTEGER,
            kind TEXT,
            amount INTEGER,
            days INTEGER,
            note TEXT,
            created_at INTEGER
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_billing_user
            ON billing_log(user_id, created_at)", vec![]),

        // B2'da yetim qolgan fayllar (pastdagi izohga qarang).
        ("CREATE TABLE IF NOT EXISTS orphan_files (
            file_name TEXT PRIMARY KEY,
            noted_at INTEGER
        )", vec![]),

        // ══════════════════════════════════════════════════════
        //  IZOHLAR
        // ══════════════════════════════════════════════════════
        //
        // TALAB (foydalanuvchi): "bo'limlar oynasidan keyin izohlar
        // oynasi bo'lsin va xuddi YouTube'dek — izoh yozish, izohga
        // javob qaytarish, layk bosish".
        //
        // ── BITTA JADVAL: IZOH HAM, JAVOB HAM ─────────────────
        //
        // Javob — bu `parent_id` to'ldirilgan oddiy izoh. Alohida
        // jadval kerak emas va bu tartibni ham soddalashtiradi:
        // bitta so'rov bilan ham izohlar, ham javoblar olinadi.
        //
        // CHUQURLIK BIR DARAJA (YouTube'dagidek): javobga javob
        // yozilsa ham u O'SHA bosh izohga biriktiriladi. Aks holda
        // "javobning javobining javobi" ekranga sig'masdi.
        //
        // `likes` — AYRIM ustun. Uni har safar `comment_likes` dan
        // sanash mumkin edi, lekin ro'yxatdagi har bir izoh uchun
        // alohida hisob degani — 20 ta izoh = 20 ta og'ir so'rov.
        // Ustun esa layk bosilganda BIR MARTA yangilanadi.
        ("CREATE TABLE IF NOT EXISTS comments_db (
            id TEXT PRIMARY KEY,
            anime_id INTEGER, season_id INTEGER,
            user_id INTEGER,
            -- Bosh izoh uchun bo'sh satr, javob uchun bosh izohning
            -- `id` si.
            parent_id TEXT DEFAULT '',
            body TEXT,
            likes INTEGER DEFAULT 0,
            reply_count INTEGER DEFAULT 0,
            -- O'chirilgan izoh QATOR sifatida qoladi: javoblari
            -- yetim qolmasin va hisoblar buzilmasin.
            deleted INTEGER DEFAULT 0,
            created_at INTEGER,
            edited_at INTEGER DEFAULT 0
        )", vec![]),
        // Ro'yxat AYNAN shu tartibda so'raladi: bitta bo'limning
        // bosh izohlari, yangisidan eskisiga.
        ("CREATE INDEX IF NOT EXISTS idx_comments_season
            ON comments_db(anime_id, season_id, parent_id, created_at DESC)",
         vec![]),

        // ── LAYK: BIR ODAM — BIR MARTA ────────────────────────
        //
        // Birlamchi kalit (izoh + odam) laykni TAKRORLASHNI
        // butunlay imkonsiz qiladi: ikki marta bosilsa ikkinchisi
        // bazaga umuman tushmaydi. Shu sabab hisob hech qachon
        // haqiqatdan chetga chiqmaydi.
        ("CREATE TABLE IF NOT EXISTS comment_likes (
            comment_id TEXT, user_id INTEGER, created_at INTEGER,
            PRIMARY KEY (comment_id, user_id)
        )", vec![]),

        // ══════════════════════════════════════════════════════
        //  SHIKOYATLAR
        // ══════════════════════════════════════════════════════
        //
        // TALAB (foydalanuvchi): "izohning o'ng chetiga 3ta nuqta
        // qo'y, bosganda shikoyat qilish chiqsin; admin panelida
        // esa shikoyatlar bo'limida shikoyat qayerdan kelgani,
        // shikoyat qilingan izoh va shikoyat qiluvchining xabari
        // tursin".
        //
        // ── NEGA IZOH NUSXASI SAQLANADI ───────────────────────
        //
        // `target_body` va `target_user_id` — shikoyat kelgan
        // PAYTDAGI holat. Izohni egasi o'chirib yuborsa ham admin
        // nimadan shikoyat qilinganini ko'radi; aks holda ro'yxatda
        // bo'sh qator turardi va shikoyatni hal qilib bo'lmasdi.
        //
        // `anime_id` / `season_id` — "Tekshirish" tugmasi uchun:
        // izoh QAYSI bo'limda yozilgani.
        ("CREATE TABLE IF NOT EXISTS reports_db (
            id TEXT PRIMARY KEY,
            -- Hozircha faqat 'comment' (izoh).
            kind TEXT DEFAULT 'comment',
            target_id TEXT DEFAULT '',
            target_body TEXT DEFAULT '',
            target_user_id INTEGER DEFAULT 0,
            anime_id INTEGER DEFAULT 0,
            season_id INTEGER DEFAULT 0,
            reporter_id INTEGER DEFAULT 0,
            reason TEXT DEFAULT '',
            created_at INTEGER
        )", vec![]),
        // Yangi shikoyat tepada.
        ("CREATE INDEX IF NOT EXISTS idx_reports_new
            ON reports_db(created_at DESC)", vec![]),
        // BIR ODAM — BIR MARTA. Xuddi laykdagidek: takroriy
        // shikoyat ro'yxatni bir xil qatorlar bilan to'ldirib,
        // adminning ishini qiyinlashtirardi.
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_once
            ON reports_db(kind, target_id, reporter_id)", vec![]),

        // ══════════════════════════════════════════════════════
        //  ADMIN BILAN YOZISHMA
        // ══════════════════════════════════════════════════════
        //
        // TALAB (foydalanuvchi): "profil sahifasiga admin bilan
        // bog'lanadigan chat qo'sh, admin paneliga esa barcha
        // chatlar bo'limi. Telegram chatidek ishlasin: xabar
        // o'qilmagan bo'lsa profil sahifasida nuqta yonib tursin,
        // admin panelida yangi xabar yuqorida tursin va profil
        // rasmi bilan ko'rinsin".
        //
        // ── NEGA IKKI JADVAL ──────────────────────────────────
        //
        // `chat_messages` — xabarlarning o'zi.
        // `chat_threads`  — har bir odam uchun BITTA qator:
        //                   oxirgi xabar, uning vaqti va
        //                   o'qilmaganlar soni.
        //
        // Jadvalsiz ham bo'lardi: admin ro'yxatini har safar
        // `chat_messages` dan guruhlab olish mumkin. Lekin u
        // butun jadvalni ko'rib chiqish degani va xabarlar soni
        // o'sgani sari sekinlashib borardi. `chat_threads` esa
        // odam soniga teng va AYNAN kerakli tartibda
        // (`last_at DESC`) indekslangan — ya'ni "yangi xabar
        // yuqorida" ro'yxati har doim bir xil tez.
        ("CREATE TABLE IF NOT EXISTS chat_threads (
            user_id INTEGER PRIMARY KEY,
            last_body TEXT,
            last_at INTEGER DEFAULT 0,
            -- Oxirgi xabarni kim yozgan: 1 — admin, 0 — foydalanuvchi.
            last_from_admin INTEGER DEFAULT 0,
            -- Foydalanuvchi o'qimagan (admin yozgan) xabarlar soni.
            unread_user INTEGER DEFAULT 0,
            -- Admin o'qimagan (foydalanuvchi yozgan) xabarlar soni.
            unread_admin INTEGER DEFAULT 0,
            -- ── SUHBAT VERSIYASI ────────────────────────────
            --
            -- Suhbatda BIROR NARSA o'zgarganda (xabar qo'shildi,
            -- o'qildi deb belgilandi, o'chirildi) shu son bittaga
            -- oshadi. Ilova uzoq kutishda AYNAN shu bitta sonni
            -- so'raydi (`chat_wait`) — ilgari har tekshiruvda 200
            -- ta xabar qatori o'qilardi.
            chat_ver INTEGER DEFAULT 0
        )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_chat_threads_at
            ON chat_threads(last_at DESC)", vec![]),

        ("CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY,
            user_id INTEGER,
            from_admin INTEGER DEFAULT 0,
            body TEXT,
            -- Rasm yoki video (B2 fayl nomi). Bo'sh — oddiy matn.
            media_file TEXT DEFAULT '',
            -- 'image' yoki 'video'.
            media_type TEXT DEFAULT '',
            media_ms INTEGER DEFAULT 0,
            -- ── VIDEONING KADRI (thumbnail) ─────────────────
            --
            -- Kichik JPEG'ning B2'dagi nomi. Uni YUBORUVCHI
            -- yasaydi: fayl uning telefonida turgani uchun kadr
            -- ajratish mahalliy va tezkor ish.
            --
            -- Qabul qiluvchi hech narsa hisoblamaydi — tayyor
            -- rasmni oladi. Telegram ham aynan shunday qiladi.
            media_thumb TEXT DEFAULT '',
            seen INTEGER DEFAULT 0,
            created_at INTEGER
        )", vec![]),
        // Suhbat AYNAN shu tartibda so'raladi.
        ("CREATE INDEX IF NOT EXISTS idx_chat_msgs
            ON chat_messages(user_id, created_at DESC)", vec![]),

        // ── ESKI TRAFIK RAQAMI BIR MARTA TOZALANADI ───────────
        //
        // TALAB (foydalanuvchi): "bosh sahifadagi eski soxta
        // trafikni tozalab tashla".
        //
        // Bir muddat umumiy trafik Cloudflare Analytics'dan
        // olindi va chelaklarga yozildi. O'sha raqam telefon
        // qabul qilganidan ~10 barobar katta edi (pleyer
        // `Range: bytes=0-` bilan so'rab ulanishni uzadi —
        // Cloudflare esa yo'lga chiqqan baytni sanaydi). Endi
        // manba faqat ILOVA, shu sabab eski qatorlar o'chiriladi
        // — aks holda yangi (to'g'ri) raqam eskisining ustiga
        // qo'shilib, hech qachon haqiqatga kelmasdi.
        //
        // Belgi qo'yilgani uchun bu FAQAT BIR MARTA bajariladi.
        ("DELETE FROM stats_hourly WHERE metric='traffic'
            AND NOT EXISTS (SELECT 1 FROM app_config
                             WHERE cfg_key='traffic_reset_v2')", vec![]),
        ("DELETE FROM stats_daily WHERE metric='traffic'
            AND NOT EXISTS (SELECT 1 FROM app_config
                             WHERE cfg_key='traffic_reset_v2')", vec![]),
        ("INSERT OR IGNORE INTO app_config (cfg_key,cfg_value)
          VALUES ('traffic_reset_v2','1')", vec![]),

        // ── HAMMA STATISTIKA BIR MARTA NOLLANADI ──────────────
        //
        // TALAB (foydalanuvchi): "Barcha statistikalarni tozalab
        // tashla, mening profilimga tegishlilarini ham — umuman
        // statistika qolmasin".
        //
        // Ilova sinovda bo'lgan davrda yig'ilgan raqamlar
        // haqiqatni ko'rsatmaydi: trafik ikki xil manbadan
        // sanalgan, ko'rishlar esa sinov hisoblaridan yig'ilgan.
        // Shu sabab HAMMASI noldan boshlanadi.
        //
        // Nima o'chadi:
        //   * `stats_hourly` / `stats_daily` — umumiy chelaklar;
        //   * `season_db` dagi ko'rish va tomosha vaqti yig'indisi;
        //   * `watch_history_db` dagi shaxsiy hisoblagichlar
        //     (tarixning O'ZI qoladi — faqat raqamlar nollanadi);
        //   * `users_db.traffic_bytes` — profildagi shaxsiy trafik.
        //
        // Baho va sevimlilar TEGILMAYDI: ular statistika emas,
        // foydalanuvchining o'z tanlovi.
        //
        // Belgi qo'yilgani uchun bu FAQAT BIR MARTA bajariladi.
        ("DELETE FROM stats_hourly
            WHERE NOT EXISTS (SELECT 1 FROM app_config
                               WHERE cfg_key='stats_reset_v3')", vec![]),
        ("DELETE FROM stats_daily
            WHERE NOT EXISTS (SELECT 1 FROM app_config
                               WHERE cfg_key='stats_reset_v3')", vec![]),
        ("UPDATE season_db SET views_total=0, watch_ms_total=0
            WHERE NOT EXISTS (SELECT 1 FROM app_config
                               WHERE cfg_key='stats_reset_v3')", vec![]),
        ("UPDATE watch_history_db SET watched_ms=0, view_count=0
            WHERE NOT EXISTS (SELECT 1 FROM app_config
                               WHERE cfg_key='stats_reset_v3')", vec![]),
        ("UPDATE users_db SET traffic_bytes=0
            WHERE NOT EXISTS (SELECT 1 FROM app_config
                               WHERE cfg_key='stats_reset_v3')", vec![]),
        ("INSERT OR IGNORE INTO app_config (cfg_key,cfg_value)
          VALUES ('stats_reset_v3','1')", vec![]),

        // ══════════════════════════════════════════════════════
        //  TO'LIQ TOZALASH — FAQAT ANIME MA'LUMOTI QOLADI
        // ══════════════════════════════════════════════════════
        //
        // TALAB (foydalanuvchi): "anime rasmi va video fayllari va
        // Turso'dagi anime ma'lumotlaridan boshqa hamma narsani
        // tozalab tashla".
        //
        // QOLADI: `anime_db`, `season_db`, `epizod_db`,
        // `season_janr` — ya'ni anime, bo'lim va qismlarning O'ZI,
        // shu jumladan rasm va video fayllarining nomlari. B2'dagi
        // fayllarga UMUMAN tegilmaydi.
        //
        // O'CHADI: hamma foydalanuvchi va ularga tegishli har
        // narsa — hisoblar, sessiyalar, tomosha tarixi, baholar,
        // sevimlilar, statistika, to'lovlar, obunalar va
        // sinxronlash izlari.
        //
        // TEGILMAYDI: `app_config` — u foydalanuvchi ma'lumoti
        // emas, tizim sozlamasi (Telegram webhook siri va shu
        // yerdagi bir martalik belgilarning o'zi). Uni o'chirish
        // webhookni buzardi va bu tozalashni HAR SAFAR qayta
        // ishga tushirardi.
        //
        // ── BO'LIM VA QISM HISOBLARI HAM NOLLANADI ───────────
        //
        // TOPILGAN XATO (foydalanuvchi: "nimaga 3 marta ko'rilgan
        // deyapti, mendan boshqa hech kim ko'rmadiku"): oldingi
        // tozalashda `season_db` nollangan, `epizod_db` esa
        // NOLLANMAGAN edi. Shu sabab bitta ekranda ikki xil raqam
        // turardi — tepada 3, pastda 1. Endi ikkovi ham nollanadi.
        //
        // Belgi qo'yilgani uchun bu FAQAT BIR MARTA bajariladi.
        ("DELETE FROM users_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM sessions_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM login_tokens WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM watch_history_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM ratings_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM favorites_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM stats_hourly WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM stats_daily WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM sync_batches WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM payments_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM subs_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM billing_log WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM orphan_files WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM comments_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM comment_likes WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM chat_messages WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("DELETE FROM chat_threads WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        // Anime ma'lumoti QOLADI, faqat unga yopishgan hisoblar
        // nollanadi.
        ("UPDATE season_db SET views_total=0, watch_ms_total=0,
                fav_count=0, rating_sum=0, rating_count=0
            WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("UPDATE epizod_db SET views_total=0, watch_ms_total=0
            WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_all_v4')", vec![]),
        ("INSERT OR IGNORE INTO app_config (cfg_key,cfg_value)
          VALUES ('wipe_all_v4','1')", vec![]),

        // ══════════════════════════════════════════════════════
        //  STATISTIKANI BUTUNLAY TOZALASH (v5)
        // ══════════════════════════════════════════════════════
        //
        // TALAB (foydalanuvchi): "statistikani butunlay tozalab
        // tashla — kim qaysi animeni yoki epizodni ko'rgani, baho
        // bergani, saqlagani va hokazo barchasini".
        //
        // O'CHADI:
        //   * `watch_history_db` — kim nimani ko'rgani (qatorning
        //     O'ZI ham, nafaqat raqamlari);
        //   * `ratings_db` — kim nimaga baho bergani;
        //   * `favorites_db` — kim nimani saqlagani;
        //   * `stats_hourly` / `stats_daily` — umumiy chelaklar;
        //   * `sync_batches` — sinxronlash izlari (paket
        //     raqamlari; ularsiz telefon o'z paketini qaytadan
        //     yuborishi mumkin, lekin yuboradigan narsasi
        //     qolmaydi).
        //
        // NOLLANADI: bo'lim va qism hisoblagichlari, shu jumladan
        // baho yig'indisi va sevimlilar soni; profildagi shaxsiy
        // trafik.
        //
        // TEGILMAYDI: hisoblarning O'ZI (`users_db`), sessiyalar,
        // anime ma'lumoti, B2'dagi fayllar, to'lovlar va obunalar.
        //
        // Belgi qo'yilgani uchun bu FAQAT BIR MARTA bajariladi.
        ("DELETE FROM watch_history_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("DELETE FROM ratings_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("DELETE FROM favorites_db WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("DELETE FROM stats_hourly WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("DELETE FROM stats_daily WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("DELETE FROM sync_batches WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("UPDATE season_db SET views_total=0, watch_ms_total=0,
                fav_count=0, rating_sum=0, rating_count=0
            WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("UPDATE epizod_db SET views_total=0, watch_ms_total=0
            WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("UPDATE users_db SET traffic_bytes=0
            WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='wipe_stats_v5')", vec![]),
        ("INSERT OR IGNORE INTO app_config (cfg_key,cfg_value)
          VALUES ('wipe_stats_v5','1')", vec![]),

        // ── ESKI FARQ BIR MARTA TO'G'RILANADI (v7) ────────────
        //
        // Yuqoridagi tozalashdan keyin ikkovi ham nolda bo'ladi,
        // lekin tozalash allaqachon o'tib ketgan bazada eski farq
        // qolishi mumkin. Shu sabab bo'lim soni bir marta
        // qismlardan qayta yig'iladi (`sync_route` dagi bilan
        // AYNAN bir xil buyruq).
        ("UPDATE season_db SET views_total = (
            SELECT COALESCE(SUM(e.views_total), 0) FROM epizod_db e
             WHERE e.anime_id = season_db.anime_id
               AND e.season_id = season_db.season_id)
          WHERE NOT EXISTS
            (SELECT 1 FROM app_config WHERE cfg_key='views_sync_v7')", vec![]),
        ("INSERT OR IGNORE INTO app_config (cfg_key,cfg_value)
          VALUES ('views_sync_v7','1')", vec![]),
    ]).await.is_ok();

    // ── YANGI USTUN: `chat_threads.chat_ver` ──────────────────
    //
    // Yuqoridagi `CREATE TABLE` faqat YANGI bazada ishlaydi —
    // jadval allaqachon bor bo'lsa u hech narsa qilmaydi. Shu
    // sabab mavjud baza uchun ALOHIDA `ALTER`.
    //
    // ── NEGA UMUMIY PAKETDA EMAS ──────────────────────────────
    //
    // Ustun ALLAQACHON qo'shilgan bo'lsa `ADD COLUMN` xato
    // qaytaradi. Agar bu buyruq yuqoridagi paket ichida bo'lsa,
    // `turso_batch` butun paketni "yiqildi" deb belgilardi,
    // `ok` esa `false` bo'lib qolardi — va o'shanda `DB_READY`
    // hech qachon qo'yilmay, BUTUN DDL to'plami HAR BIR so'rovda
    // qaytadan yuborilardi (aynan yuqoridagi izoh ogohlantirgan
    // falokat).
    //
    // Shu sabab u alohida yuboriladi va natijasi ATAYLAB
    // e'tiborsiz qoldiriladi: "ustun bor" degan xato — bu normal
    // holat, xato emas.
    let _ = turso_exec(env,
        "ALTER TABLE chat_threads ADD COLUMN chat_ver INTEGER DEFAULT 0",
        vec![]).await;

    // Xuddi shunday: videoning kadri (yuqoridagi izohga qarang).
    let _ = turso_exec(env,
        "ALTER TABLE chat_messages ADD COLUMN media_thumb TEXT DEFAULT ''",
        vec![]).await;

    ok
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

/// ── B2 OMBORI (BUCKET) NOMI ───────────────────────────────────
///
/// DIQQAT: bu ilovaning nomi EMAS — Backblaze B2'dagi HAQIQIY
/// ombor nomi. Foydalanuvchi B2 panelida `arumedia` nomli yangi,
/// BO'SH ombor yaratdi (2026-09-15) va shu yerga o'tildi.
///
/// ⚠️ Eski omboridagi fayllar (agar bo'lsa) bu yangi
/// omborda YO'Q. Baza ilgari tozalangani uchun bu muammo emas:
/// yangi yuklangan har bir fayl to'g'ridan-to'g'ri shu omborga
/// tushadi.
///
/// Omborni kelajakda yana almashtirish tartibi:
///   1. B2 panelida yangi ombor yaratib fayllar ko'chiriladi
///      (B2 mavjud omborni qayta nomlashga ruxsat bermaydi);
///   2. shu yerdagi qiymat almashtiriladi;
///   3. worker qayta deploy qilinadi.
const B2_BUCKET: &str = "arumedia";

async fn b2_bucket_id(api_url: &str, auth_token: &str, account_id: &str) -> Result<String> {
    let mut h = Headers::new();
    h.set("Authorization", auth_token)?;
    let req = Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_buckets\
             ?accountId={account_id}&bucketName={B2_BUCKET}"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    if r.status_code() != 200 {
        return Err(Error::RustError(format!("B2 list_buckets xato: {}",
            d["message"].as_str().unwrap_or("unknown"))));
    }
    let bid = d["buckets"][0]["bucketId"].as_str().unwrap_or("").to_string();
    if bid.is_empty() {
        return Err(Error::RustError(format!("B2 bucket '{B2_BUCKET}' topilmadi")));
    }
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
// yoziladi (1000 kunga). Keyingi barcha so'rovlar — boshqa
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
// o'sha oraliq 1000 kun davomida barcha foydalanuvchilarga
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
const CHUNK_CACHE_SECONDS: u64 = 1000 * 24 * 60 * 60; // 1000 kun

/// ── MIJOZ (TELEFON) KESHI ─────────────────────────────────────
///
/// TOPILGAN XATO (foydalanuvchi: "anime posteri diskda saqlanishi
/// kerak edi, lekin har safar ilovaga kirganda qayta yuklanyapti").
///
/// Sabab: javobda `max-age=86400` turardi — ya'ni BIR KUN. Ertasi
/// kuni `cached_network_image` faylni "eskirgan" deb bilib, uni
/// qaytadan yuklab olardi. Ustiga `ETag` ham yo'q edi, shu sabab
/// "o'zgarmagan" degan arzon javob ham chiqmasdi — har safar
/// to'liq rasm.
///
/// B2'dagi fayl nomi HECH QACHON qayta ishlatilmaydi (poster
/// almashtirilsa YANGI nom yoziladi va eskisi o'chiriladi), ya'ni
/// bitta nom = bitta o'zgarmas mazmun. Shuning uchun `immutable`
/// to'g'ri va xavfsiz: telefon faylni bir marta yuklab oladi va
/// boshqa so'ramaydi.
///
/// Muddat — 1000 kun, Cloudflare keshidagi bilan bir xil
/// (`CHUNK_CACHE_SECONDS`, foydalanuvchi talabi).
const CLIENT_CACHE: &str = "public, max-age=86400000, immutable";

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
        &format!("{}/file/{B2_BUCKET}/{file_name}", acc.dl_url),
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

/// ── YOZISHMADAGI RASM/VIDEO/OVOZ ─────────────────────────────
///
/// TALAB (foydalanuvchi): "chatda yuborilgan video ham surat ham
/// keshga saqlanishi kerak va keshdan olinishi kerak — video
/// CLOUDFLARE keshida saqlanishi kerak, telefon keshida emas".
///
/// ── QANDAY ISHLAYDI ─────────────────────────────────────────
///
/// Fayl BIR MARTA B2'dan olinib, BUTUNLAY Cloudflare keshiga
/// ko'chiriladi (anime qismlari uchun yozilgan `b2_warm` shu
/// ishni qiladi). Shundan keyin har qanday so'rov — to'liq
/// bo'ladimi, oraliq bo'ladimi — AYNAN o'sha kesh yozuvidan
/// kesib beriladi va B2'ga umuman chiqilmaydi.
///
/// Ya'ni:
///   * birinchi ochish  — B2'dan bir marta (pulli);
///   * keyingi hammasi  — Cloudflare keshidan (tekin va tez).
///
/// ── NEGA `/api/image/...` YARAMADI ──────────────────────────
///
/// U yo'l bir so'rovda eng ko'pi 8 MiB beradi, chunki baytlar
/// worker xotirasiga yig'iladi. ExoPlayer esa javobda E'LON
/// QILINGAN uzunlikni faylning qolgan qismi deb biladi — 20 MB
/// lik videoni 8 MB deb o'ylab, MP4'ning oxiridagi
/// ko'rsatkichlarga (`moov`) yetib bormay, xato berardi.
///
/// Bu yerda esa oraliq HECH QACHON qisqartirilmaydi: kesh
/// yozuvidan kesish Cloudflare'ning O'ZIDA bo'ladi va baytlar
/// oqim bilan o'tadi.
///
/// ── NEGA `/api/play/...` EMAS ───────────────────────────────
///
/// U faqat oldindan isitilgan oynadan beradi va isitilmagan
/// bo'lsa 503 qaytaradi — ilova o'zi isitishi kerak. Anime
/// qismlari uchun bu to'g'ri (ular gigabaytlik). Yozishmadagi
/// kichik fayl uchun esa ortiqcha: bu yer keraklisini O'ZI
/// isitadi va darhol beradi.
async fn b2_media(
    env: &Env,
    file_name: &str,
    range: Option<String>,
) -> Result<Response> {
    // 1) Keshda bormi — darhol beramiz.
    if let Some(r) = media_from_cache(file_name, range.as_deref()).await? {
        return Ok(r);
    }

    // ── FAQAT KESHDAN ───────────────────────────────────────────
    //
    // TALAB (foydalanuvchi): "faqatgina keshdan uzatilsin, B2'ga
    // ortiqcha so'rov yuborilmasin".
    //
    // B2'ga murojaat FAQAT bitta joyda — isitishda (`b2_warm`):
    // fayl bir marta keshga ko'chiriladi, keyin hamma narsa
    // keshdan. Boshqa birov allaqachon isitayotgan bo'lsa,
    // `b2_warm` o'sha isitish tugashini KUTADI (B2'ga qayta
    // chiqmaydi).
    //
    // Katta faylda isitish uzoq davom etishi mumkin — shu sabab
    // yadrodagi kadr yasovchi bu so'rovni uzoq kutadi
    // (`THUMB_NET_TIMEOUT`), aks holda ulanish uzilib isitish
    // ham to'xtardi.
    let _ = b2_warm(env, file_name, 0, false).await;
    if let Some(r) = media_from_cache(file_name, range.as_deref()).await? {
        return Ok(r);
    }
    // Keshga tushmadi — B2'dan to'g'ridan-to'g'ri BERILMAYDI.
    // Mijoz keyinroq qayta urinadi.
    let mut r = Response::error("Fayl keshga tayyorlanmoqda", 503)?;
    set_cors(&mut r);
    r.headers_mut().set("Retry-After", "5")?;
    r.headers_mut().set("Cache-Control", "no-store")?;
    Ok(r)
}

/// Kesh yozuvidan (butun fayl) so'ralgan qismni kesib beradi.
///
/// `None` qaytsa — keshda yo'q yoki yaroqsiz.
async fn media_from_cache(
    file_name: &str,
    range: Option<&str>,
) -> Result<Option<Response>> {
    let lookup_h = Headers::new();
    if let Some(r) = range {
        lookup_h.set("Range", r)?;
    }
    let lookup = Request::new_with_init(
        &warm_window_url(file_name, 0),
        RequestInit::new().with_method(Method::Get).with_headers(lookup_h),
    )?;
    let Some(hit) = Cache::default().get(&lookup, false).await? else {
        return Ok(None);
    };
    let status = hit.status_code();
    // Oraliq so'ralgan bo'lsa FAQAT 206 yaraydi: 200 kelsa oraliq
    // kesilmagan va butun faylni oraliq o'rniga yuborish xato
    // bo'lardi.
    if range.is_some() && status != 206 {
        return Ok(None);
    }
    let ct = hit
        .headers()
        .get("Content-Type")?
        .unwrap_or_else(|| "application/octet-stream".to_string());
    let total = hit
        .headers()
        .get("X-Total-Size")?
        .and_then(|t| t.parse::<u64>().ok())
        .unwrap_or(0);
    if total == 0 {
        return Ok(None);
    }

    // Nechta bayt qaytyapti va qaysi oraliq.
    let (start, end) = match hit
        .headers()
        .get("Content-Range")?
        .and_then(|c| parse_content_range(&c))
    {
        Some((s, e, _)) => (s, e),
        None => (0, total - 1),
    };
    let len = end.saturating_sub(start) + 1;
    let src = match hit.body() {
        ResponseBody::Stream(rs) => rs.clone(),
        _ => return Ok(None),
    };
    // Uzunlik OLDINDAN e'lon qilinadi — aks holda javob jimgina
    // uzilib, pleyer faylni kalta deb o'ylardi.
    let readable = fixed_length_stream(&src, len)?;
    let mut resp = Response::from_body(ResponseBody::Stream(readable))?
        .with_status(if range.is_some() { 206 } else { 200 });
    set_cors(&mut resp);
    {
        let h = resp.headers_mut();
        h.set("Content-Type", &ct)?;
        h.set("Accept-Ranges", "bytes")?;
        h.set("Cache-Control", CLIENT_CACHE)?;
        h.set("Content-Length", &len.to_string())?;
        if range.is_some() {
            h.set("Content-Range", &format!("bytes {start}-{end}/{total}"))?;
        }
        h.set("X-Cache", "HIT-MEDIA")?;
    }
    Ok(Some(resp))
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
    h.set("Cache-Control", CLIENT_CACHE)?;
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
        h.set("Cache-Control", CLIENT_CACHE)?;
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
        h.set("Cache-Control", CLIENT_CACHE)?;
        h.set("Content-Length", &len.to_string())?;
        return Ok(resp);
    }

    // Katta fayl Range'siz so'ralgan — oqim orqali o'tkazamiz.
    // ── KATTA FAYL HAM KESH ORQALI ──────────────────────────────
    //
    // TALAB (foydalanuvchi): "B2'dagi barcha fayllar 1000 kunga
    // keshlansin". 12 MiB dan katta faylni OraliQSIZ so'raganda u
    // ilgari B2'dan to'g'ridan-to'g'ri uzatilar va keshlanmasdi.
    // Endi fayl isitish oynasiga (1000 kun) ko'chiriladi va o'sha
    // yerdan beriladi; keyingi so'rovlar B2'ga umuman bormaydi.
    // Oynadan katta (480 MiB+) fayl oraliqsiz so'ralmaydi (pleyer ham,
    // yuklab olish ham oraliq bilan ishlaydi) — u holda eski yo'l.
    if total > 0 && total <= WARM_WINDOW {
        let _ = b2_warm(env, file_name, 0, false).await;
        if let Some(r) = media_from_cache(file_name, None).await? {
            return Ok(r);
        }
    }

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
    h.set("Cache-Control", CLIENT_CACHE)?;
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

// ═══════════════════════════════════════════════════════════════
//  B2'DAGI YETIM FAYLLARNI TOZALASH
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "B2'da qolib ketgan eski fayllarni
// tozalab tashla, ya'ni animega tegishli bo'lmagan fayllarni".
//
// ── YETIM FAYL NIMA ─────────────────────────────────────────
//
// Bazada unga ISHORA QILADIGAN birorta qator qolmagan fayl.
// Bunday fayl hech qachon ochilmaydi, lekin ombor uchun pul yeb
// turadi. Ilgari yozishmadagi rasm/video o'chirilganda faqat
// bazadagi qator o'chirilar, fayl esa qolib ketardi — ular
// aynan shunday to'planib qolgan.
//
// ── QAYSI QATORLAR "ISHORA" HISOBLANADI ─────────────────────
//
//   anime_db.photo_url, season_db.photo_url,
//   epizod_db.url_360p / 480p / 720p / 1080p,
//   users_db.avatar_file, chat_messages.media_file.
//
// ── XAVFSIZLIK ──────────────────────────────────────────────
//
// 1. Faqat admin (`admin_only`).
// 2. YANGI fayllarga TEGILMAYDI: hozirgina yuklangan, lekin
//    hali bazaga yozilmagan fayl (yuklash davom etayotgan
//    bo'lishi mumkin) o'chib ketmasin. Chegara — 2 soat.
// 3. `dry=true` bo'lsa HECH NARSA o'chirilmaydi, faqat sanaladi.
//    Avval shu bilan ko'rib olish mumkin.
// 4. Bir chaqiruvda eng ko'pi `B2_CLEAN_MAX` ta fayl o'chiriladi
//    va davomi uchun kursor qaytadi — worker'ning bitta
//    so'rovdan chiqadigan ichki so'rovlari chegarasidan
//    oshmaslik uchun.

/// Bir chaqiruvda eng ko'pi shuncha fayl o'chiriladi.
const B2_CLEAN_MAX: usize = 40;

/// Shundan yangi fayllarga tegilmaydi (yuklash davom etayotgan
/// bo'lishi mumkin).
const B2_CLEAN_MIN_AGE_MS: i64 = 2 * 60 * 60 * 1000;

/// POST /api/admin/b2-cleanup
async fn b2_cleanup(mut req: Request, env: &Env) -> Result<Response> {
    if let Some(deny) = admin_only(&req, env).await? {
        return Ok(deny);
    }
    let b: Value = req.json().await.unwrap_or(json!({}));
    let dry = b["dry"] == json!(true);
    let start = b["start"].as_str().unwrap_or("").to_string();

    // ── 1) BAZADAGI HAMMA ISHORANI YIG'AMIZ ──────────────────
    let res = turso_many(env, &[
        ("SELECT photo_url FROM anime_db", vec![]),
        ("SELECT photo_url FROM season_db", vec![]),
        ("SELECT url_360p, url_480p, url_720p, url_1080p FROM epizod_db", vec![]),
        ("SELECT avatar_file FROM users_db", vec![]),
        // Kadr (`media_thumb`) ham SHU YERDA bo'lishi SHART: aks
        // holda tozalovchi uni "yetim" deb o'chirib yuborardi va
        // videolar kadrsiz qolardi. Pastdagi halqa qatordagi
        // BARCHA ustunni oladi, shu sabab ikkovi ham yetadi.
        ("SELECT media_file, media_thumb FROM chat_messages", vec![]),
    ]).await?;

    let mut keep: std::collections::HashSet<String> = std::collections::HashSet::new();
    for r in res.iter() {
        if let Some(rows) = r["rows"].as_array() {
            for row in rows {
                if let Some(cells) = row.as_array() {
                    for c in cells {
                        if let Some(v) = c["value"].as_str() {
                            let n = bare_name(v);
                            if !n.is_empty() {
                                keep.insert(n);
                            }
                        }
                    }
                }
            }
        }
    }
    // Bazada birorta ham ishora topilmasa — bu shubhali holat
    // (masalan so'rov yiqilgan). Bunday paytda HECH NARSA
    // o'chirilmaydi: butun omborni o'chirib yuborishdan ko'ra
    // hech narsa qilmagan yaxshi.
    if keep.is_empty() && !dry {
        return json_resp(
            &json!({"error": "Bazadan ro'yxat olinmadi — tozalash bekor qilindi"}),
            500,
        );
    }

    // ── 2) B2'DAGI FAYLLARNI RO'YXATLAB CHIQAMIZ ─────────────
    let auth = b2_auth(env).await?;
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let acct = auth["accountId"].as_str().unwrap_or("").to_string();
    let bid = b2_bucket_id(&api_url, &token, &acct).await?;

    let now = now_ms();
    let mut cursor = start;
    let mut checked: i64 = 0;
    let mut deleted: i64 = 0;
    let mut freed: i64 = 0;
    let mut too_new: i64 = 0;
    let mut next = String::new();
    let mut done = false;

    // Ro'yxat sahifalab keladi. Bir chaqiruvda bir necha sahifa
    // ko'riladi, lekin o'chirish soni chegaralangan.
    'outer: for _ in 0..4 {
        let h = Headers::new();
        h.set("Authorization", &token)?;
        let url = if cursor.is_empty() {
            format!("{api_url}/b2api/v3/b2_list_file_names?bucketId={bid}&maxFileCount=1000")
        } else {
            format!(
                "{api_url}/b2api/v3/b2_list_file_names?bucketId={bid}&maxFileCount=1000&startFileName={}",
                urlencoding(&cursor)
            )
        };
        let list_req = Request::new_with_init(
            &url,
            RequestInit::new().with_method(Method::Get).with_headers(h),
        )?;
        let mut lr = Fetch::Request(list_req).send().await?;
        if lr.status_code() != 200 {
            return json_resp(&json!({"error": "B2 ro'yxati olinmadi"}), 502);
        }
        let d: Value = lr.json().await?;
        let files = d["files"].as_array().cloned().unwrap_or_default();

        for f in &files {
            let name = f["fileName"].as_str().unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            checked += 1;
            if keep.contains(&name) {
                continue;
            }
            // Hozirgina yuklangan faylga tegilmaydi.
            let up = f["uploadTimestamp"].as_i64().unwrap_or(0);
            if up > 0 && now - up < B2_CLEAN_MIN_AGE_MS {
                too_new += 1;
                continue;
            }
            let size = f["contentLength"].as_i64().unwrap_or(0);
            if dry {
                deleted += 1;
                freed += size;
                continue;
            }
            let fid = f["fileId"].as_str().unwrap_or("");
            if fid.is_empty() {
                continue;
            }
            let h2 = Headers::new();
            h2.set("Authorization", &token)?;
            h2.set("Content-Type", "application/json")?;
            let del = Request::new_with_init(
                &format!("{api_url}/b2api/v3/b2_delete_file_version"),
                RequestInit::new().with_method(Method::Post).with_headers(h2).with_body(
                    Some(json!({"fileName": name, "fileId": fid}).to_string().into()),
                ),
            )?;
            if let Ok(r) = Fetch::Request(del).send().await {
                if r.status_code() == 200 {
                    deleted += 1;
                    freed += size;
                }
            }
            if deleted as usize >= B2_CLEAN_MAX {
                // Davomi keyingi chaqiruvda — shu fayldan
                // boshlanadi.
                next = name;
                break 'outer;
            }
        }

        match d["nextFileName"].as_str() {
            Some(n) if !n.is_empty() => cursor = n.to_string(),
            _ => {
                done = true;
                break 'outer;
            }
        }
    }
    if next.is_empty() && !done {
        next = cursor;
    }

    ok_nostore(json!({
        "checked": checked,
        "deleted": deleted,
        "freed": freed,
        "too_new": too_new,
        "kept": keep.len(),
        "next": next,
        "done": done,
        "dry": dry,
    }))
}

/// So'rov manzilida ishlatish uchun eng zarur belgilarni
/// o'zgartiradi (B2 fayl nomlari odatda oddiy, lekin bo'sh joy
/// va `+` uchrashi mumkin).
fn urlencoding(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    for ch in v.chars() {
        match ch {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' | '/' => out.push(ch),
            _ => {
                let mut buf = [0u8; 4];
                for b in ch.encode_utf8(&mut buf).as_bytes() {
                    out.push_str(&format!("%{b:02X}"));
                }
            }
        }
    }
    out
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
    // Jadvalda 10 ta ustun bor, ortig'i sig'maydi.
    out.truncate(JANR_SLOTS);
    out
}

/// `season_janr` dagi janr ustunlari soni.
const JANR_SLOTS: usize = 10;

/// Bo'limning janrlarini BITTA qatorga yozadi.
///
/// Ilgari bu bog'lovchi jadval edi va har janr uchun alohida qator
/// yozilardi (bitta bo'lim = 4-5 qator, 5-6 so'rov). Endi bitta
/// bo'lim = BITTA qator va BITTA so'rov: tanlangan janrlar
/// `janr_1 ... janr_10` ustunlariga ketma-ket joylashadi, qolgani
/// bo'sh qoladi. Janr olib tashlansa qator qaytadan yoziladi —
/// ya'ni "bo'sh ustunga yozish" o'zi-o'zidan hal bo'ladi.
async fn save_janrs(env: &Env, anime_id: i64, season_id: i64, janrs: &[String]) {
    let mut args = vec![TursoArg::int(anime_id), TursoArg::int(season_id)];
    for i in 0..JANR_SLOTS {
        args.push(TursoArg::text(janrs.get(i).map(|s| s.as_str()).unwrap_or("")));
    }
    let _ = turso_exec(env,
        "INSERT INTO season_janr
            (anime_id,season_id,janr_1,janr_2,janr_3,janr_4,janr_5,
             janr_6,janr_7,janr_8,janr_9,janr_10)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(anime_id,season_id) DO UPDATE SET
            janr_1=excluded.janr_1, janr_2=excluded.janr_2,
            janr_3=excluded.janr_3, janr_4=excluded.janr_4,
            janr_5=excluded.janr_5, janr_6=excluded.janr_6,
            janr_7=excluded.janr_7, janr_8=excluded.janr_8,
            janr_9=excluded.janr_9, janr_10=excluded.janr_10",
        args).await;
}

/// Yosh chegarasini har qanday ko'rinishdan songa aylantiradi.
///
/// TALAB (foydalanuvchi): "yosh chegarasi bitta BO'LIM uchun amal
/// qiladi" — ya'ni u `season_db` ga yoziladi, qismlarga emas.
///
/// `18`, `"18"`, `"18+"`, `""` — hammasi to'g'ri o'qiladi. Mantiqsiz
/// qiymat (manfiy yoki 21 dan katta) NOLGA tushadi, ya'ni
/// kartochkada belgi umuman ko'rsatilmaydi.
fn yosh_of(v: &Value) -> i64 {
    let n = match v {
        Value::Number(_) => v.as_i64().unwrap_or(0),
        Value::String(t) => t
            .trim()
            .trim_end_matches('+')
            .trim()
            .parse::<i64>()
            .unwrap_or(0),
        _ => 0,
    };
    // Admin raqamni QO'LDA yozadi, shu sabab oraliq keng: 1 dan
    // 99 gacha. Undan tashqarisi (xato bosilgan raqam) 0 bo'ladi —
    // ya'ni kartochkada belgi umuman ko'rsatilmaydi.
    if (1..=99).contains(&n) { n } else { 0 }
}

/// `epizod_db` ga yoziladigan maydonlar.
///
/// Tuple emas, STRUKTURA: ustunlar soni 20 dan oshdi (4 sifat x 2 +
/// 10 ta intro) va tartibda adashish oson bo'lardi.
struct EpizodFields {
    number: i64,
    name: String,
    /// `url_360p`, `size_360p`, `url_480p`, ... — jadvaldagi tartibda.
    media: [String; 8],
    /// `intro_1 ... intro_10` — admin yozgan MATN (`"5:14"`).
    /// Bo'sh satr = belgilanmagan.
    intros: [String; INTRO_SLOTS],
}

/// `epizod_db` dagi intro ustunlari soni — 5 ta juftlik.
const INTRO_SLOTS: usize = 10;

fn epizod_fields(b: &Value) -> EpizodFields {
    let s = |k: &str| b[k].as_str().unwrap_or("").to_string();
    // Ilova matn yuboradi (`"5:14"`). Eski versiya son yuborgan
    // bo'lsa ham yiqilmaydi — u ham matnga aylantiriladi.
    let mut intros: [String; INTRO_SLOTS] = Default::default();
    for (i, slot) in intros.iter_mut().enumerate() {
        let v = &b[format!("intro_{}", i + 1)];
        *slot = match v.as_str() {
            Some(t) => t.trim().to_string(),
            None => v.as_i64().map(|n| n.to_string()).unwrap_or_default(),
        };
    }
    EpizodFields {
        number: b["epizod_number"].as_i64().unwrap_or(0),
        name: s("epizod_name"),
        media: [
            s("url_360p"), s("size_360p"),
            s("url_480p"), s("size_480p"),
            s("url_720p"), s("size_720p"),
            s("url_1080p"), s("size_1080p"),
        ],
        intros,
    }
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

/// DIQQAT: bu ilovaning nomi EMAS — Telegram'dagi HAQIQIY bot
/// manzili. Uni o'zgartirish botni qayta nomlamaydi: avval
/// @BotFather -> /setusername orqali bot rostdan qayta nomlanadi,
/// SO'NG shu yerdagi qiymat almashtiriladi va worker qayta deploy
/// qilinadi. Aks holda kirish butunlay ishlamay qoladi.
///
/// DIQQAT: bot ALMASHGANI uchun `TELEGRAM_BOT_TOKEN` siri ham
/// yangi botnikiga almashtirilishi SHART (wrangler secret put),
/// aks holda webhook eski botda qolib ketadi.
///
/// Qiymat @BotFather'dagi AYNAN o'sha yozuvda (katta-kichik
/// harfi bilan). Havolada bu muhim emas — Telegram username'ni
/// katta-kichik harfga qaramay topadi — lekin sog'liq tekshiruvi
/// `getMe` qaytargan nom bilan solishtiradi, shu sabab bu yerda
/// ham haqiqiy yozuv turgani tushunarliroq.
const BOT_USERNAME: &str = "ARUmediaTvloginbot";

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

    let url = format!("{origin}/api/telegram/webhook");

    // ── TOPILGAN XATO: BOT ALMASHSA WEBHOOK QO'YILMASDI ──────
    //
    // Ilgari bu yerda FAQAT manzil solishtirilardi. Bot
    // almashtirilganda manzil esa O'ZGARMAYDI — eski bot
    // allaqachon o'sha manzilga ro'yxatdan o'tgan bo'lardi.
    // Natijada tekshiruv "hammasi joyida" deb o'tkazib yuborar,
    // `setWebhook` YANGI botga hech qachon chaqirilmasdi.
    //
    // Oqibati: foydalanuvchi yangi botda START bosadi, Telegram
    // esa u bot uchun webhook bilmaydi — worker hech narsa
    // eshitmaydi va bot JIM qoladi. Aynan shu bo'ldi.
    //
    // Endi belgi ichiga BOTNING O'ZI ham kiradi. Bot tokeni
    // "<bot_id>:<sir>" ko'rinishida; ':' gacha bo'lgan qism —
    // botning IDsi va u sir EMAS (`getMe` ham shuni qaytaradi),
    // shu sabab uni belgida saqlash xavfsiz. Bot almashsa ID
    // o'zgaradi -> belgi mos kelmaydi -> webhook qayta qo'yiladi.
    let bot_id = env
        .secret("TELEGRAM_BOT_TOKEN")
        .ok()
        .map(|t| t.to_string())
        .and_then(|t| t.split(':').next().map(|s| s.to_string()))
        .unwrap_or_default();

    // Kalit ATAYLAB yangi (`tg_webhook_for`): eskisida faqat
    // manzil yotibdi va uni shu yerda qayta ishlatish eski
    // xatoni tirilishtirib qo'yishi mumkin edi.
    let want = format!("{bot_id}|{url}");
    if config_get(env, "tg_webhook_for").await.as_deref() == Some(want.as_str()) {
        WEBHOOK_READY.store(true, Ordering::Relaxed);
        return;
    }

    let res = tg_api(env, "setWebhook", json!({
        "url": url,
        "secret_token": secret,
        "allowed_updates": ["message"],
        "drop_pending_updates": true,
    })).await;

    if res.is_ok() {
        config_put(env, "tg_webhook_for", &want).await;
        config_put(env, "tg_webhook_url", &url).await;
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
    // Foydalanuvchi talabi. Telegramdan FAQAT `telegram_id` olinadi
    // (hisobni tanish uchun). Ism va username ILOVANING O'ZIDA hosil
    // qilinadi va keyingi kirishlarda USTIGA YOZILMAYDI — aks holda
    // foydalanuvchi tanlagan nom har safar Telegramdagisiga qaytib
    // qolardi.
    //
    // Til va "premium" belgisi ilgari saqlanardi, lekin hech qayerda
    // ishlatilmasdi — baza bekorga shishmasligi uchun ustunlar olib
    // tashlandi.
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
        "UPDATE users_db SET last_login_at=? WHERE telegram_id=? RETURNING *",
        vec![TursoArg::int(now), TursoArg::int(tg_id)]).await?;
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
             is_banned,created_at,last_login_at,profile_done)
             VALUES (?,?,?,?,'',0,?,?,1) RETURNING *",
            vec![
                TursoArg::int(new_id), TursoArg::int(tg_id),
                TursoArg::text(&username), TursoArg::text(&first_name),
                TursoArg::int(now), TursoArg::int(now),
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
        // Admin panelini KIM ko'rishi shu bilan hal bo'ladi.
        // Ilgari tugma HAMMAGA ko'rinardi. Ilovadagi tekshiruv
        // shunchaki ekranni yashiradi — haqiqiy to'siq har bir
        // so'rovda serverda (`is_admin`).
        "is_admin": is_admin(u),
        // Ism/username to'ldirilganmi. Yangi hisobga nom
        // AVTOMATIK berilgani uchun bu endi doim 1 — maydon
        // eski ilova versiyalari bilan moslik uchun qoldirilgan.
        "profile_done": u["profile_done"].as_i64().unwrap_or(0) == 1,
        // ── MAXFIYLIK ────────────────────────────────────────
        //
        // Qaysi statistika YASHIRILGAN. Bo'sh ro'yxat — hammasi
        // ochiq (odatiy holat, foydalanuvchi talabi). Sozlamalar
        // oynasi shu ro'yxat bo'yicha tugmalarni chizadi.
        "hidden_stats": hidden_stats_of(u),
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
/// Jurnalda saqlanadigan ma'lumot:
///   • kim kirgan — `user_id` (ism va username `users_db` da);
///   • qaysi qurilma bilan — device, platform, app_version;
///   • qachon — created_at, last_seen_at.
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
            "INSERT INTO sessions_db (id,user_id,session_token,
             device,platform,app_version,created_at,last_seen_at)
             VALUES ((SELECT COALESCE(MAX(id),0)+1 FROM sessions_db),
                     ?,?,?,?,?,?,?)",
            vec![
                TursoArg::int(user_id),
                // Bazaga tokenning XESHI yoziladi, o'zi EMAS
                // (`token_hash` izohiga qarang). Ilovaga esa pastda
                // xom token qaytariladi — u faqat shu yerda va
                // `login_tokens` dagi bir martalik qatorda ko'rinadi.
                TursoArg::text(&token_hash(&token)), TursoArg::text(&device),
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

// ═══════════════════════════════════════════════════════════════
//  SESSIYA TOKENI BAZADA OCHIQ SAQLANMAYDI
// ═══════════════════════════════════════════════════════════════
//
// TOPILGAN XAVF: `sessions_db.session_token` da tokenning O'ZI
// turardi. Baza bir marta oqib ketsa (yoki `TURSO_TOKEN` qo'lga
// tushsa) hujumchi BARCHA faol sessiyalarni o'sha zahoti
// egallardi — hech narsani buzish, parol tiklash kerak emas,
// token tayyor holda yotadi.
//
// ── YECHIM: FAQAT XESH ─────────────────────────────────────
//
// Endi bazada tokenning SHA-256 xeshi saqlanadi. Ilova xom
// tokenni yuboradi, worker uni xeshlab SOLISHTIRADI. Xesh
// o'g'irlansa u bilan hech narsa qilib bo'lmaydi: xeshdan
// tokenni qaytarib hisoblab bo'lmaydi.
//
// Aynan shu mantiq APK imzosi uchun allaqachon ishlatilgan
// (`app_gate` izohi): "xesh — ochiq ma'lumot, u hech narsani
// isbotlamaydi". Sessiya tokeni esa aksincha — u SIR, va sirni
// bazada ochiq saqlash kerak emas.
//
// ── NEGA TUZ (SALT) YO'Q ───────────────────────────────────
//
// Tuz parollar uchun kerak: odam tanlagan parol qisqa va taxmin
// qilinadi, shu sabab lug'at bo'yicha hujumga uchraydi. Bu token
// esa 64 bayt TASODIFIY ma'lumot (`random_hex(32)` ikki marta) —
// uni lug'at bilan ham, kuch bilan ham topib bo'lmaydi. Tuz
// faqat har so'rovga qo'shimcha ish qo'shardi.
//
// ── ESKI SESSIYALAR UZILMAYDI ──────────────────────────────
//
// Bazada allaqachon OCHIQ tokenlar yotadi. Ularni shunchaki
// tashlab yuborish barcha foydalanuvchini ilovadan chiqarib
// yuborardi. Shu sabab `session_user` avval xesh bilan qaraydi,
// topilmasa ESKI (ochiq) ko'rinishda qaraydi va topilgan qatorni
// o'sha zahoti xeshga O'TKAZIB QO'YADI. Ya'ni migratsiya
// foydalanuvchi sezmasdan, o'zi bo'ladi.
//
// Yangi sessiyalar uchun qo'shimcha so'rov YO'Q: xesh birinchi
// urinishda topiladi.
fn token_hash(token: &str) -> String {
    use sha2::Digest;
    let mut h = sha2::Sha256::new();
    h.update(token.as_bytes());
    hex_of(&h.finalize())
}

/// Sessiya tokeni bo'yicha foydalanuvchini topadi va "oxirgi
/// ko'rilgan" vaqtini yangilaydi (4 ta qurilma tartibi shunga
/// qarab hisoblanadi).
/// `sessions_db.last_seen_at` shuncha vaqtda bir martadan ko'p
/// yozilmaydi.
const SEEN_EVERY_MS: i64 = 12 * 3_600_000;

async fn session_user(env: &Env, token: &str) -> Result<Option<Value>> {
    if token.is_empty() { return Ok(None); }
    let now = now_ms();

    // ── IKKI BUYRUQ — BITTA SO'ROV ────────────────────────────
    //
    // Ilgari bu yerda ikkita alohida Turso so'rovi bor edi, ya'ni
    // HAR BIR himoyalangan so'rov ikki marta yo'l yurardi.
    //
    // "Oxirgi ko'rinish" vaqti esa endi FAQAT 12 SOATDA bir
    // marta yoziladi.
    //
    // NEGA 12 SOAT (avval 60 soniya edi): bu bazadagi ENG KO'P
    // takrorlanadigan yozuv edi — 2 soat faol foydalanuvchi
    // kuniga 120 marta yozardi, ya'ni butun xarajatning ~85% i.
    // Kunlik faol foydalanuvchi 24 SOATLIK oyna bilan sanaladi,
    // shu sabab 12 soat aniqlikni buzmaydi: har kuni kiradigan
    // odamning belgisi har doim 24 soatlik oyna ichida qoladi.
    // Sinxronlash paketi ham shu vaqtni yangilaydi (u yerda bu
    // bepul — o'sha quvurning ichida ketadi).
    // Bazada tokenning O'ZI emas, XESHI yotadi (`token_hash` izohi).
    let hashed = token_hash(token);
    let res = turso_many(env, &[
        ("SELECT u.* FROM sessions_db s JOIN users_db u ON u.id = s.user_id
          WHERE s.session_token = ?", vec![TursoArg::text(&hashed)]),
        ("UPDATE sessions_db SET last_seen_at=?
          WHERE session_token=? AND COALESCE(last_seen_at,0) < ?",
         vec![TursoArg::int(now), TursoArg::text(&hashed), TursoArg::int(now - SEEN_EVERY_MS)]),
    ]).await?;
    let u = match res.first().and_then(first_row) {
        Some(u) => u,
        // ── ESKI (XESHLANMAGAN) SESSIYA ───────────────────────
        //
        // Xesh bilan topilmadi — demak bu qator xeshlashdan OLDIN
        // yozilgan bo'lishi mumkin. Ochiq token bilan qaraymiz va
        // topilsa qatorni DARHOL xeshga o'tkazamiz. Shu bilan
        // migratsiya o'z-o'zidan bo'ladi va foydalanuvchi ilovadan
        // chiqib ketmaydi.
        //
        // Bu qo'shimcha so'rov FAQAT eski sessiyalar uchun ketadi;
        // xeshga o'tgach boshqa hech qachon takrorlanmaydi.
        None => {
            let legacy = turso_many(env, &[
                ("SELECT u.* FROM sessions_db s JOIN users_db u ON u.id = s.user_id
                  WHERE s.session_token = ?", vec![TursoArg::text(token)]),
                ("UPDATE sessions_db SET session_token=?, last_seen_at=?
                  WHERE session_token=?",
                 vec![TursoArg::text(&hashed), TursoArg::int(now), TursoArg::text(token)]),
            ]).await?;
            match legacy.first().and_then(first_row) {
                Some(u) => u,
                None => return Ok(None),
            }
        }
    };
    // ── BLOK MUDDATI TUGAGAN BO'LSA O'TKAZAMIZ ────────────
    //
    // `ban_state` muddatli blokning muddati o'tgan bo'lsa
    // "bloklanmagan" deydi, qator esa shu yerda tozalanadi —
    // ya'ni alohida kuzatuvchi vazifa (cron) kerak emas.
    if u["is_banned"].as_i64().unwrap_or(0) == 1 {
        if ban_state(&u, now).is_some() {
            return Ok(None);
        }
        clear_expired_ban(env, u["id"].as_i64().unwrap_or(0)).await;
    }
    Ok(Some(u))
}

// ══════════════════════════════════════════════════════════════
//  BLOKLASH: MUDDATSIZ VA MUDDATLI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "foydalanuvchini bloklaganda muddatsiz va
// muddatli bloklash tizimini qo'sh va bloklanish sababini ham yozsa
// bo'ladigan qil. Foydalanuvchi accountiga kirmoqchi bo'lganda bot
// account qancha muddatga bloklangani va nima sababdan bloklanganini
// chiqaradi".
//
// ── UCH USTUN ───────────────────────────────────────────────
//
//   `is_banned`  — bloklanganmi (eski ustun, o'z joyida);
//   `ban_until`  — 0 bo'lsa MUDDATSIZ, aks holda shu vaqtgacha;
//   `ban_reason` — sabab (bo'sh bo'lishi mumkin).
//
// ── MUDDAT O'ZI TUGAYDI ─────────────────────────────────────
//
// Muddat tugaganini kuzatib turadigan alohida vazifa (cron) YO'Q:
// u shunchaki kirishda tekshiriladi. Ya'ni muddat tugagan zahoti
// odam kira oladi va uning qatori shu paytda tozalanadi. Bu usul
// soat aniqligida ishlaydi va bazaga ortiqcha yuk bermaydi.

/// Bloklangan holat: `(muddat, sabab)`.
///
/// `None` — bloklanmagan YOKI muddati tugagan.
/// Muddat `0` — muddatsiz.
fn ban_state(u: &Value, now: i64) -> Option<(i64, String)> {
    if u["is_banned"].as_i64().unwrap_or(0) == 0 {
        return None;
    }
    let until = u["ban_until"].as_i64().unwrap_or(0);
    // Muddatli blok va muddati o'tgan — bloklangan hisoblanmaydi.
    if until > 0 && until <= now {
        return None;
    }
    Some((until, u["ban_reason"].as_str().unwrap_or("").to_string()))
}

/// Muddati tugagan blokni bazadan olib tashlaydi.
///
/// Javob KUTILMAYDI natijasi uchun emas: chaqiruvchi allaqachon
/// "bloklanmagan" deb qaror qilgan, bu shunchaki qatorni tartibga
/// soladi.
async fn clear_expired_ban(env: &Env, id: i64) {
    let _ = turso_exec(env,
        "UPDATE users_db SET is_banned=0, ban_until=0, ban_reason=''
          WHERE id=? AND is_banned=1 AND ban_until>0 AND ban_until<=?",
        vec![TursoArg::int(id), TursoArg::int(now_ms())]).await;
}

/// Vaqtni `DD.MM.YYYY HH:MM` ko'rinishida yozadi (Toshkent, UTC+5).
///
/// NEGA QO'LDA: worker'da vaqt kutubxonasi yo'q va faqat shu
/// bitta joy uchun butun kutubxona qo'shishning ma'nosi yo'q.
/// Hisob — Howard Hinnant'ning `civil_from_days` algoritmi.
fn fmt_time_uz(ms: i64) -> String {
    // Toshkent yil bo'yi UTC+5 (yozgi vaqt yo'q).
    let secs = ms / 1000 + 5 * 3600;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hh, mm) = (rem / 3600, (rem % 3600) / 60);

    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!("{d:02}.{m:02}.{y} {hh:02}:{mm:02}")
}

/// "3 kun 4 soat" ko'rinishidagi qolgan muddat.
fn fmt_left_uz(ms: i64) -> String {
    if ms <= 0 {
        return "tugadi".to_string();
    }
    let mins = ms / 60_000;
    let days = mins / 1440;
    let hours = (mins % 1440) / 60;
    let m = mins % 60;
    if days > 0 {
        return if hours > 0 {
            format!("{days} kun {hours} soat")
        } else {
            format!("{days} kun")
        };
    }
    if hours > 0 {
        return if m > 0 {
            format!("{hours} soat {m} daqiqa")
        } else {
            format!("{hours} soat")
        };
    }
    format!("{} daqiqa", m.max(1))
}

/// Bloklangan odamga ko'rsatiladigan xabar (bot va ilova uchun
/// bir xil matn — odam ikki joyda ikki xil gap eshitmasin).
fn ban_message(until: i64, reason: &str, now: i64) -> String {
    let muddat = if until <= 0 {
        "Muddatsiz".to_string()
    } else {
        format!("{} gacha ({} qoldi)", fmt_time_uz(until), fmt_left_uz(until - now))
    };
    let sabab = if reason.trim().is_empty() {
        "ko'rsatilmagan".to_string()
    } else {
        reason.trim().to_string()
    };
    format!(
        "\u{1F6AB} Hisobingiz bloklangan.\n\n\
         \u{23F3} Muddat: {muddat}\n\
         \u{1F4DD} Sabab: {sabab}"
    )
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
const MSG_HELP: &str = "\u{1F44B} Salom! Men \u{2014} <b>ARUmediaTV</b> ilovasining kirish yordamchisiman.\n\n\
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

    // ── BLOKLANGAN HISOB ──────────────────────────────────────
    //
    // TALAB (foydalanuvchi): "foydalanuvchi accountiga kirmoqchi
    // bo'lganda bot account qancha muddatga bloklangani va nima
    // sababdan bloklanganini chiqaradi".
    //
    // Tekshiruv AYNAN shu yerda: sessiya ochilishidan OLDIN.
    // Ilgari bloklangan odam bemalol kirardi va faqat keyingi
    // so'rovda "unauthorized" olardi — ya'ni ilova sababsiz
    // "chiqib ketgandek" bo'lardi.
    //
    // Muddati tugagan blok bu yerda ham o'zi tozalanadi.
    if user["is_banned"].as_i64().unwrap_or(0) == 1 {
        let uid = user["id"].as_i64().unwrap_or(0);
        if let Some((until, reason)) = ban_state(&user, now) {
            tg_send(env, chat_id, &format!(
                "{}

Savollaringiz bo'lsa adminga yozing.",
                html_escape(&ban_message(until, &reason, now)),
            )).await;
            return ok(json!({"ok": true}));
        }
        clear_expired_ban(env, uid).await;
    }

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
            // `epizod_number` FAQAT `epizod_db` DAN olinadi —
            // tarix jadvalida bunday ustun yo'q. Admin qism
            // raqamini o'zgartirsa ro'yxatda darhol yangisi
            // ko'rinadi.
            let res = turso_exec(env,
                "SELECT h.anime_id, h.season_id, h.epizod_id,
                        e.epizod_number AS epizod_number,
                        h.video_url, h.last_quality,
                        h.position_ms, h.duration_ms, h.watched_ms, h.view_count,
                        h.updated_at,
                        a.name AS anime_name, a.photo_url AS anime_photo,
                        s.bolim_id AS bolim_id, s.nomi AS season_name,
                        s.photo_url AS season_photo
                   FROM watch_history_db h
                   LEFT JOIN anime_db a ON a.id = h.anime_id
                   LEFT JOIN season_db s
                          ON s.anime_id = h.anime_id AND s.season_id = h.season_id
                   LEFT JOIN epizod_db e
                          ON e.anime_id = h.anime_id AND e.season_id = h.season_id
                         AND e.epizod_id = h.epizod_id
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
            let items = resolve_list(
                &origin_of(&req),
                items,
                &["anime_photo", "season_photo", "video_url"],
            );
            ok_nostore(json!({"items": items}))
        }

        // ── YOZUV ENDI BU YERDA EMAS ──────────────────────────
        //
        // Tomosha tarixini yozish, tarixdan yashirish, baho va
        // sevimlilar — hammasi `POST /api/sync` ga ko'chdi.
        // Sabab va hisob-kitob `sync_route` izohida.

        _ => err404("yo'l topilmadi"),
    }
}

// ═══════════════════════════════════════════════════════════════
//  POST /api/sync — YAGONA YOZUV YO'LI
// ═══════════════════════════════════════════════════════════════
//
// ── NEGA SHUNDAY (foydalanuvchi talabi va hisob-kitob) ────────
//
// TALAB: "barcha yozish va tahrirlash so'rovlari qurilmaning
// o'zida qilinadi va kuniga bir necha marta bitta paket bo'lib
// yuboriladi; bitta foydalanuvchining kunlik yozish so'rovlari
// 50 tadan oshmasin".
//
// Sabab — pul. Turso har bir YOZILGAN QATOR uchun to'lov oladi.
// Eski tartibda bitta qism ko'rilganda 7 ta qator yozilardi
// (tarix + epizod + bo'lim + 4 ta statistika chelagi), ustiga
// `last_seen_at` har 60 soniyada. Bitta faol odam kuniga ~149
// qator, 100 ming odamda oyiga ~420 million — bu $250 dan
// oshadi. Endi hammasi telefonda yig'iladi, siqiladi va bitta
// paket bo'lib keladi: kuniga ~15 qator, ya'ni ~10 barobar kam.
//
// ── PAKET NIMA QILADI ─────────────────────────────────────────
//
// ATIGI IKKI marta bazaga boradi:
//
//   1. BITTA o'qish quvuri — eski holat (tarix, bahoyingiz,
//      sevimlilaringiz, bo'lim hisoblagichlari) va paket raqami;
//   2. BITTA yozuv quvuri — hamma o'zgarish birdan.
//
// Statistika chelaklari PAKETGA bir marta yoziladi (ilgari har
// bir qism uchun alohida), bo'lim hisoblagichlari esa bo'limga
// bir marta — paketda 10 ta qism bo'lsa ham.
//
// ── IKKI MARTA SANALMASLIK ────────────────────────────────────
//
// `batch_id` — paketning bir martalik raqami. Tarmoq uzilib
// ilova o'sha paketni qayta yuborsa, worker uni tanib oladi va
// hech narsa yozmaydi (`duplicate: true`). Bu MUHIM: ko'rishlar
// soni va tomosha vaqti QO'SHILADIGAN raqamlar, ya'ni takror
// yozilsa hisob shishib ketardi.
//
// ── SOXTA RAQAMLARDAN HIMOYA ──────────────────────────────────
//
// Endi ko'rishlar sonini va tomosha vaqtini TELEFON aytadi, ya'ni
// o'zgartirilgan ilova umumiy statistikani shishirib yuborishi
// mumkin. Shu sabab har bir paketda qat'iy chegara bor: tomosha
// vaqti jami 24 soatdan, ko'rishlar 50 tadan, ro'yxatlar esa
// yuqoridagi `MAX_SYNC_*` dan oshmaydi. Telefonning soati ham
// tekshiriladi — kelajakdagi vaqt server vaqtiga tenglashtiriladi.

/// Bitta paketdagi eng ko'p tarix yozuvi.
const MAX_SYNC_HISTORY: usize = 100;

/// Baho va sevimlilar ro'yxatining eng ko'p uzunligi.
const MAX_SYNC_SMALL: usize = 50;

/// Bitta paketda qo'shiladigan eng ko'p tomosha vaqti.
const MAX_SYNC_WATCH_MS: i64 = 24 * 3_600_000;

/// Bitta paketda sanaladigan eng ko'p yangi ko'rish.
const MAX_SYNC_VIEWS: i64 = 50;

/// Bitta paketda qabul qilinadigan eng ko'p trafik (256 GiB).
const MAX_SYNC_TRAFFIC: i64 = 256 * 1024 * 1024 * 1024;

/// `IN (?,?,?)` uchun savol belgilari. Ro'yxat bo'sh bo'lsa hech
/// narsaga to'g'ri kelmaydigan `-1` qaytadi (`IN ()` — sintaksis
/// xatosi).
fn in_marks(n: usize) -> String {
    if n == 0 { return "-1".to_string(); }
    let mut out = String::with_capacity(n * 2);
    for i in 0..n {
        if i > 0 { out.push(','); }
        out.push('?');
    }
    out
}

fn add_unique(out: &mut Vec<i64>, v: i64) {
    if v > 0 && !out.contains(&v) { out.push(v); }
}

/// Bo'lim darajasidagi jamlangan o'zgarishlar.
#[derive(Default, Clone, Copy)]
struct SeasonDelta {
    views: i64,
    watch: i64,
    rating_sum: i64,
    rating_count: i64,
    fav: i64,
}

impl SeasonDelta {
    fn is_zero(&self) -> bool {
        self.views == 0 && self.watch == 0
            && self.rating_sum == 0 && self.rating_count == 0 && self.fav == 0
    }
}

async fn sync_route(mut req: Request, env: &Env) -> Result<Response> {
    let token = bearer(&req);
    let Some(u) = session_user(env, &token).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    if me <= 0 { return json_resp(&json!({"error": "unauthorized"}), 401); }

    let b: Value = req.json().await.unwrap_or(json!({}));
    let batch_id = b["batch_id"].as_str().unwrap_or("").to_string();
    if batch_id.is_empty() || batch_id.len() > 64 {
        return json_resp(&json!({"error": "batch_id noto'g'ri"}), 400);
    }

    let none: Vec<Value> = vec![];
    let history = b["history"].as_array().unwrap_or(&none);
    let ratings = b["ratings"].as_array().unwrap_or(&none);
    let favorites = b["favorites"].as_array().unwrap_or(&none);
    if history.len() > MAX_SYNC_HISTORY
        || ratings.len() > MAX_SYNC_SMALL
        || favorites.len() > MAX_SYNC_SMALL
    {
        return json_resp(&json!({"error": "paket juda katta"}), 413);
    }
    let traffic = b["traffic_bytes"].as_i64().unwrap_or(0).clamp(0, MAX_SYNC_TRAFFIC);

    let now = now_ms();

    // ── TAKROR YOZUVLAR TASHLANADI ────────────────────────────
    //
    // Ilova navbatni allaqachon siqadi, lekin paket buzilgan yoki
    // qasddan yasalgan bo'lishi mumkin: bir xil kalit ikki marta
    // kelsa, ko'rish ikki marta sanalardi.
    let mut hist_in: std::collections::HashMap<(i64, i64, i64), &Value> =
        std::collections::HashMap::new();
    let mut rate_in: std::collections::HashMap<(i64, i64), &Value> =
        std::collections::HashMap::new();
    let mut fav_in: std::collections::HashMap<(i64, i64), &Value> =
        std::collections::HashMap::new();
    let mut anime_ids: Vec<i64> = Vec::new();

    for h in history {
        let (a, s, e) = (
            h["anime_id"].as_i64().unwrap_or(0),
            h["season_id"].as_i64().unwrap_or(0),
            h["epizod_id"].as_i64().unwrap_or(0),
        );
        if a <= 0 || e <= 0 { continue; }
        add_unique(&mut anime_ids, a);
        hist_in.insert((a, s, e), h);
    }
    for r in ratings {
        let (a, s) = (r["anime_id"].as_i64().unwrap_or(0), r["season_id"].as_i64().unwrap_or(0));
        if a <= 0 { continue; }
        add_unique(&mut anime_ids, a);
        rate_in.insert((a, s), r);
    }
    for f in favorites {
        let (a, s) = (f["anime_id"].as_i64().unwrap_or(0), f["season_id"].as_i64().unwrap_or(0));
        if a <= 0 { continue; }
        add_unique(&mut anime_ids, a);
        fav_in.insert((a, s), f);
    }

    // ── 1-QUVUR: ESKI HOLAT BITTA SO'ROVDA ────────────────────
    let marks = in_marks(anime_ids.len());
    let sql_hist = format!(
        "SELECT anime_id,season_id,epizod_id,watched_ms,view_count
           FROM watch_history_db WHERE user_id=? AND anime_id IN ({marks})");
    let sql_rate = format!(
        "SELECT anime_id,season_id,stars
           FROM ratings_db WHERE user_id=? AND anime_id IN ({marks})");
    let sql_fav = format!(
        "SELECT anime_id,season_id
           FROM favorites_db WHERE user_id=? AND anime_id IN ({marks})");
    let sql_season = format!(
        "SELECT anime_id,season_id FROM season_db WHERE anime_id IN ({marks})");

    let mut args_me: Vec<TursoArg> = vec![TursoArg::int(me)];
    for id in &anime_ids { args_me.push(TursoArg::int(*id)); }
    let args_ids: Vec<TursoArg> = anime_ids.iter().map(|i| TursoArg::int(*i)).collect();

    let pre = turso_many(env, &[
        ("SELECT batch_id FROM sync_batches WHERE user_id=?", vec![TursoArg::int(me)]),
        (sql_hist.as_str(), args_me.clone()),
        (sql_rate.as_str(), args_me.clone()),
        (sql_fav.as_str(), args_me),
        (sql_season.as_str(), args_ids),
    ]).await?;

    // O'sha paket allaqachon qabul qilingan — hech narsa yozilmaydi.
    if first_row(&pre[0]).and_then(|r| r["batch_id"].as_str().map(|v| v.to_string()))
        .as_deref() == Some(batch_id.as_str())
    {
        return ok_nostore(json!({"ok": true, "duplicate": true}));
    }

    let rows_of = |res: &Value| -> Vec<Value> {
        let cols = res["cols"].as_array().cloned().unwrap_or_default();
        res["rows"].as_array().cloned().unwrap_or_default().iter()
            .map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![])))
            .collect()
    };
    let num = |v: &Value, k: &str| -> i64 { v[k].as_i64().unwrap_or(0) };

    let mut old_hist: std::collections::HashMap<(i64, i64, i64), (i64, i64)> =
        std::collections::HashMap::new();
    for r in rows_of(&pre[1]) {
        old_hist.insert(
            (num(&r, "anime_id"), num(&r, "season_id"), num(&r, "epizod_id")),
            (num(&r, "watched_ms").max(0), num(&r, "view_count").max(0)),
        );
    }
    let mut old_rate: std::collections::HashMap<(i64, i64), i64> =
        std::collections::HashMap::new();
    for r in rows_of(&pre[2]) {
        old_rate.insert((num(&r, "anime_id"), num(&r, "season_id")), num(&r, "stars"));
    }
    let mut old_fav: Vec<(i64, i64)> = Vec::new();
    for r in rows_of(&pre[3]) {
        old_fav.push((num(&r, "anime_id"), num(&r, "season_id")));
    }
    // Faqat MAVJUD bo'limlarning hisoblagichlari yangilanadi.
    let mut real_season: Vec<(i64, i64)> = Vec::new();
    for r in rows_of(&pre[4]) {
        real_season.push((num(&r, "anime_id"), num(&r, "season_id")));
    }

    // ── HISOB-KITOB (bazaga tegmasdan) ────────────────────────
    let mut seasons: std::collections::HashMap<(i64, i64), SeasonDelta> =
        std::collections::HashMap::new();
    let mut eps: std::collections::HashMap<(i64, i64, i64), (i64, i64)> =
        std::collections::HashMap::new();
    let mut watch_left = MAX_SYNC_WATCH_MS;
    let mut views_left = MAX_SYNC_VIEWS;
    let mut total_views = 0i64;
    let mut total_watch = 0i64;

    let mut stmts: Vec<(&str, Vec<TursoArg>)> = Vec::new();
    let mut hist_args: Vec<Vec<TursoArg>> = Vec::new();
    let mut hide_args: Vec<Vec<TursoArg>> = Vec::new();
    let mut rate_args: Vec<Vec<TursoArg>> = Vec::new();
    let mut fav_add: Vec<Vec<TursoArg>> = Vec::new();
    let mut fav_del: Vec<Vec<TursoArg>> = Vec::new();

    for ((aid, sid, eid), h) in &hist_in {
        let (aid, sid, eid) = (*aid, *sid, *eid);
        // Telefon soatiga ishonilmaydi.
        let at = h["updated_at"].as_i64().unwrap_or(now).clamp(0, now);

        if h["deleted"].as_bool().unwrap_or(false) {
            hide_args.push(vec![
                TursoArg::int(at), TursoArg::int(me),
                TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid),
            ]);
            continue;
        }

        let duration = h["duration_ms"].as_i64().unwrap_or(0).max(0);
        if duration <= 0 { continue; }
        let position = h["position_ms"].as_i64().unwrap_or(0).max(0);
        let watched = h["watched_ms"].as_i64().unwrap_or(0).max(0);
        let video_url = bare_name(h["video_url"].as_str().unwrap_or(""));
        let quality = h["last_quality"].as_str().unwrap_or("").to_string();

        let known = old_hist.get(&(aid, sid, eid)).copied();
        let (old_w, old_v) = known.unwrap_or((0, 0));

        // Tomosha vaqti hech qachon kamaymaydi va qism uzunligidan
        // oshmaydi (eski ilova eskirgan son yuborsa ham).
        let capped = watched.min(duration).max(old_w);
        let delta = (capped - old_w).max(0).min(watch_left.max(0));
        watch_left -= delta;

        // Ko'rish — ODAM BOSHIGA BITTA: umumiy hisob faqat shu
        // odam shu qismni BIRINCHI marta ko'rganda oshadi.
        let first_time = known.is_none() || old_v == 0;
        let view_inc = if h["new_view"].as_bool().unwrap_or(false)
            && first_time && views_left > 0 { views_left -= 1; 1 } else { 0 };

        hist_args.push(vec![
            TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid), TursoArg::int(eid),
            TursoArg::text(&video_url), TursoArg::text(&quality),
            TursoArg::int(position), TursoArg::int(duration),
            TursoArg::int(capped), TursoArg::int(old_v + view_inc),
            TursoArg::int(at),
        ]);

        if view_inc > 0 || delta > 0 {
            total_views += view_inc;
            total_watch += delta;
            let e = eps.entry((aid, sid, eid)).or_insert((0, 0));
            e.0 += view_inc;
            e.1 += delta;
            let s = seasons.entry((aid, sid)).or_default();
            s.views += view_inc;
            s.watch += delta;
        }
    }

    for ((aid, sid), r) in &rate_in {
        let (aid, sid) = (*aid, *sid);
        let stars = r["stars"].as_i64().unwrap_or(0);
        if !(1..=10).contains(&stars) { continue; }
        if !real_season.contains(&(aid, sid)) { continue; }
        let at = r["updated_at"].as_i64().unwrap_or(now).clamp(0, now);
        let old = old_rate.get(&(aid, sid)).copied();
        let s = seasons.entry((aid, sid)).or_default();
        s.rating_sum += stars - old.unwrap_or(0);
        if old.is_none() { s.rating_count += 1; }
        rate_args.push(vec![
            TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid),
            TursoArg::int(stars), TursoArg::int(at), TursoArg::int(at),
        ]);
    }

    for ((aid, sid), f) in &fav_in {
        let (aid, sid) = (*aid, *sid);
        if !real_season.contains(&(aid, sid)) { continue; }
        let on = f["on"].as_bool().unwrap_or(true);
        let existed = old_fav.contains(&(aid, sid));
        if on && !existed {
            seasons.entry((aid, sid)).or_default().fav += 1;
            fav_add.push(vec![
                TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid),
                TursoArg::int(f["updated_at"].as_i64().unwrap_or(now).clamp(0, now)),
            ]);
        } else if !on && existed {
            seasons.entry((aid, sid)).or_default().fav -= 1;
            fav_del.push(vec![
                TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid),
            ]);
        }
    }

    // ── 2-QUVUR: HAMMA YOZUV BIRDAN ───────────────────────────
    for a in &hist_args {
        stmts.push((
            "INSERT INTO watch_history_db
                (user_id,anime_id,season_id,epizod_id,video_url,
                 last_quality,position_ms,duration_ms,watched_ms,view_count,
                 deleted_at,updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?,0,?)
             ON CONFLICT(user_id,anime_id,season_id,epizod_id) DO UPDATE SET
                video_url=excluded.video_url,
                last_quality=excluded.last_quality,
                position_ms=excluded.position_ms,
                duration_ms=excluded.duration_ms,
                watched_ms=excluded.watched_ms,
                view_count=excluded.view_count,
                deleted_at=0,
                updated_at=excluded.updated_at",
            a.clone(),
        ));
    }
    // Tarixdan yashirish — yozuv O'CHIRILMAYDI (foydalanuvchi
    // talabi), faqat `deleted_at` belgilanadi.
    for a in &hide_args {
        stmts.push((
            "UPDATE watch_history_db SET deleted_at=?
              WHERE user_id=? AND anime_id=? AND season_id=? AND epizod_id=?",
            a.clone(),
        ));
    }
    for a in &rate_args {
        stmts.push((
            "INSERT INTO ratings_db (user_id,anime_id,season_id,stars,created_at,updated_at)
             VALUES (?,?,?,?,?,?)
             ON CONFLICT(user_id,anime_id,season_id) DO UPDATE SET
                stars=excluded.stars, updated_at=excluded.updated_at",
            a.clone(),
        ));
    }
    for a in &fav_add {
        stmts.push((
            "INSERT OR IGNORE INTO favorites_db (user_id,anime_id,season_id,created_at)
             VALUES (?,?,?,?)",
            a.clone(),
        ));
    }
    for a in &fav_del {
        stmts.push((
            "DELETE FROM favorites_db WHERE user_id=? AND anime_id=? AND season_id=?",
            a.clone(),
        ));
    }
    for ((aid, sid, eid), (v, w)) in &eps {
        stmts.push((
            "UPDATE epizod_db SET views_total=views_total+?, watch_ms_total=watch_ms_total+?
              WHERE anime_id=? AND season_id=? AND epizod_id=?",
            vec![
                TursoArg::int(*v), TursoArg::int(*w),
                TursoArg::int(*aid), TursoArg::int(*sid), TursoArg::int(*eid),
            ],
        ));
    }
    // Bo'lim qatoriga BITTA yozuv — ko'rish, tomosha vaqti, baho
    // va sevimlilar o'zgarishi birga ketadi.
    //
    // Qiymatlar NISBIY (`+?`) yoziladi: shu vaqt ichida boshqa
    // qurilmadan kelgan o'zgarish ustidan yozib yuborilmaydi.
    for ((aid, sid), d) in &seasons {
        if d.is_zero() || !real_season.contains(&(*aid, *sid)) { continue; }
        stmts.push((
            "UPDATE season_db SET
                views_total = views_total + ?,
                watch_ms_total = watch_ms_total + ?,
                rating_sum = MAX(rating_sum + ?, 0),
                rating_count = MAX(rating_count + ?, 0),
                fav_count = MAX(fav_count + ?, 0)
              WHERE anime_id=? AND season_id=?",
            vec![
                TursoArg::int(d.views), TursoArg::int(d.watch),
                TursoArg::int(d.rating_sum), TursoArg::int(d.rating_count),
                TursoArg::int(d.fav), TursoArg::int(*aid), TursoArg::int(*sid),
            ],
        ));

        // ── BO'LIM HISOBI QISMLARDAN QAYTA YIG'ILADI ──────────
        //
        // TOPILGAN XATO (foydalanuvchi: "bitta bo'lim va bitta
        // qism bor edi, bitta qismni ikkita odam ko'rdi, yig'indi
        // esa nimagadir 3 ta bo'lib qoldi").
        //
        // Qoida O'ZI to'g'ri edi va shunday qoladi:
        //   * qism tagida — shu qismni nechta hisob ko'rgani;
        //   * bo'lim (ma'lumotlar oynasi va kartochka) — o'sha
        //     bo'limning HAMMA qismi bo'yicha shu sonlarning
        //     YIG'INDISI.
        //
        // Xato esa hisoblashda emas, YIG'IB BORISHDA edi: ikkala
        // son ham "ustiga qo'shib" boriladi va bir marta chetga
        // chiqsa (eski tozalash faqat bo'limni nollagan, qismni
        // nollamagan; yoki qator tozalanib, odam qismni qayta
        // ko'rgan) farq MANGU qolib ketardi.
        //
        // Endi bo'lim soni qo'shib borilmaydi — har safar
        // qismlardan QAYTA YIG'ILADI. Ya'ni u ta'rifi bo'yicha
        // qismlar yig'indisiga TENG bo'ladi va hech qachon
        // "yo'q joydan" o'sa olmaydi. Buyruq yuqoridagi
        // `epizod_db` yangilanishidan KEYIN ketadi (quvurdagi
        // tartib saqlanadi), shu sabab yangi son ham hisobga
        // kiradi.
        if d.views != 0 {
            stmts.push((
                "UPDATE season_db SET views_total = (
                    SELECT COALESCE(SUM(e.views_total), 0) FROM epizod_db e
                     WHERE e.anime_id = season_db.anime_id
                       AND e.season_id = season_db.season_id)
                  WHERE anime_id=? AND season_id=?",
                vec![TursoArg::int(*aid), TursoArg::int(*sid)],
            ));
        }
    }

    // ── STATISTIKA CHELAKLARI — PAKETGA BIR MARTA ─────────────
    let hour = hour_key(now);
    let day = day_key(now);
    if total_views > 0 {
        stmts.push((STAT_HOUR_SQL, stat_args(&hour, "views", total_views)));
        stmts.push((STAT_DAY_SQL, stat_args(&day, "views", total_views)));
    }
    if total_watch > 0 {
        stmts.push((STAT_HOUR_SQL, stat_args(&hour, "watch_ms", total_watch)));
        stmts.push((STAT_DAY_SQL, stat_args(&day, "watch_ms", total_watch)));
    }
    if traffic > 0 {
        stmts.push((STAT_HOUR_SQL, stat_args(&hour, "traffic", traffic)));
        stmts.push((STAT_DAY_SQL, stat_args(&day, "traffic", traffic)));
        stmts.push((
            "UPDATE users_db SET traffic_bytes=COALESCE(traffic_bytes,0)+? WHERE id=?",
            vec![TursoArg::int(traffic), TursoArg::int(me)],
        ));
    }

    // Paket belgisi — takrorni tanib olish uchun.
    stmts.push((
        "INSERT INTO sync_batches (user_id,batch_id,at) VALUES (?,?,?)
         ON CONFLICT(user_id) DO UPDATE SET batch_id=excluded.batch_id, at=excluded.at",
        vec![TursoArg::int(me), TursoArg::text(&batch_id), TursoArg::int(now)],
    ));
    // "Oxirgi ko'rinish" — bu yerda bepul (o'sha quvurning ichida).
    if !token.is_empty() {
        stmts.push((
            "UPDATE sessions_db SET last_seen_at=? WHERE session_token=?",
            vec![TursoArg::int(now), TursoArg::text(&token_hash(&token))],
        ));
    }

    turso_batch(env, &stmts).await?;

    ok_nostore(json!({
        "ok": true,
        "duplicate": false,
        // Ilova navbatdan AYNAN shularni o'chiradi.
        "history": hist_args.len() + hide_args.len(),
        "ratings": rate_args.len(),
        "favorites": fav_add.len() + fav_del.len(),
        "traffic": traffic,
        "rows": stmts.len(),
    }))
}

// ═══════════════════════════════════════════════════════════════
//  BALANS, OBUNA VA TO'LOVLAR (tezcheck.uz)
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): profil sahifasida "Obuna olish va Balans
// to'ldirish" tugmasi; uning ichida uchta oyna — Obuna,
// To'ldirish, Tarix.
//
// ── NEGA HAMMASI SERVERDA ─────────────────────────────────────
//
// Pul bilan bog'liq har bir qaror WORKER da qabul qilinadi:
//
//   * tariflar narxi (`PLANS`) shu yerda — ilova aytgan narxga
//     ISHONILMAYDI, aks holda o'zgartirilgan ilova 30 kunlik
//     obunani 1 so'mga sotib olardi;
//   * balansdan pul yechish va obunani uzaytirish BITTA quvurda;
//   * to'lov haqiqatan bo'lganini FAQAT tezcheck.uz tasdiqlaydi.
//
// Kassa kalitlari (`TEZCHECK_TOKEN`, `TEZCHECK_DESK`) worker
// sirlarida turadi va ilovaga hech qachon chiqmaydi.
//
// ── TO'LOV TIZIMI ALMASHTIRILDI ───────────────────────────────
//
// Ilgari `tezchek.uz` (bitta `api_key` so'rov TANASIDA) ishlatilar
// edi. Endi `tezcheck.uz` ning savdogar API si:
//
//   * ikkita kalit va ikkovi ham SARLAVHADA:
//       `Authorization: Bearer aps_...` — hisob tokeni (maxfiy;
//       saytda faqat uning SHA-256 xeshi saqlanadi),
//       `X-Cash-Desk-Code: cdk_...` — kassa kodi;
//   * summa TIYINDA (`amount_minor`), ya'ni so'm × 100;
//   * hisob-faktura `POST /bills` bilan yaratiladi, holati esa
//     `POST /bills/{id}` bilan so'raladi;
//   * qo'shimcha: WEBHOOK — pul tushishi bilan sayt bizga o'zi
//     xabar beradi (`billing_webhook`).
//
// ── PUL IKKI MARTA QO'SHILMASLIGI ─────────────────────────────
//
// "Tekshirish" tugmasini necha marta bossa ham (va webhook necha
// marta takrorlansa ham) balans BIR MARTA oshadi: `payments_db.
// status` `pending` dan `paid` ga faqat SHARTLI o'tadi
// (`WHERE status='pending'`), balans esa o'sha o'tish
// muvaffaqiyatli bo'lgandagina oshiriladi. Ikkinchi urinish
// hech qanday qatorga tegmaydi.

/// Tezcheck savdogar API manzili.
const TEZCHECK_API: &str = "https://api.tezcheck.uz/api/merchant/v1";

/// To'lov havolasi shuncha vaqt faol turadi (foydalanuvchi
/// talabi: "har bitta havola 1 soat faol turadi, undan ko'p
/// emas").
const PAY_LINK_TTL_MS: i64 = 60 * 60 * 1000;

/// Eng kam va eng ko'p to'ldirish miqdori (so'm).
///
/// Pastki chegara tasodifiy emas: tezcheck.uz ning o'zi 1 000
/// so'mdan kam hisob-fakturani qabul qilmaydi.
const PAY_MIN: i64 = 1_000;
const PAY_MAX: i64 = 10_000_000;

/// Qaysi to'lov usullari ko'rsatiladi (bo'sh — HAMMASI).
///
/// ── SAVOL: BANK ILOVASIGA TO'G'RIDAN-TO'G'RI O'TIB BO'LADIMI ──
///
/// Foydalanuvchi so'radi: "avval saytga, saytdan keyin bank
/// ilovaga o'tmasdan to'g'ridan to'g'ri bank ilovasiga o'tsa
/// bo'ladimi".
///
/// Tekshirildi (haqiqiy hisob-faktura yaratib ko'rildi): YO'Q.
/// Tezcheck API si faqat O'Z sahifasining havolasini qaytaradi
/// (`payment_url` -> `tezcheck.uz/pay/plk_...`) va hech qanday
/// maydonda `click://` yoki `payme://` kabi to'g'ridan-to'g'ri
/// havola bermaydi. Bitta usul tanlab qo'yilganda ham o'sha
/// sahifa ochiladi — faqat ro'yxatdan tanlash bosqichi tushib
/// qoladi, telefon raqami baribir o'sha yerda so'raladi.
///
/// Shu sabab bu yerda ro'yxat BO'SH qoldirildi: odam Click va
/// Payme dan xohlaganini tanlaydi. Agar bitta bosqichni kamaytirish
/// muhimroq bo'lsa, `&["click"]` deb yozing — o'shanda ro'yxat
/// ko'rsatilmaydi.
const PAY_PROVIDERS: &[&str] = &[];

/// Obuna tariflari: (kun, narx so'mda).
///
/// Narx FAQAT shu yerda — ilova hech qanday summa yubormaydi,
/// u faqat tarifning kunini aytadi.
///
/// O'ZGARDI (foydalanuvchi talabi): kunlik mayda tariflar
/// (1/5/10/20 kun) OLIB TASHLANDI, o'rniga oylik tariflar.
///
/// ── NARXLAR YANGILANDI (foydalanuvchi talabi) ───────────────
///
/// 1 oylik  — 15 000 (o'zgarmadi)
/// 3 oylik  — 39 000 -> 42 000
/// 6 oylik  — 66 000 -> 80 000
/// 12 oylik — 120 000 -> 150 000
///
/// Chegirma 1 oylik narxga (15 000) nisbatan:
///
///   3 oy:  45 000 o'rniga  42 000  ->  3 000 kam  (~7%)
///   6 oy:  90 000 o'rniga  80 000  -> 10 000 kam  (~11%)
///  12 oy: 180 000 o'rniga 150 000  -> 30 000 kam  (~17%)
///
/// MUHIM: narx SOTIB OLINAYOTGAN paytda shu yerdan o'qiladi
/// (`buy` -> `plan_price`), ilova faqat KUNNI yuboradi. Ya'ni
/// bu ro'yxatni o'zgartirish YETARLI: ilovada ham, bazada ham
/// boshqa hech narsaga tegish kerak emas.
///
/// Allaqachon olingan obunalar TEGILMAYDI — ular to'langan va
/// muddati o'z holicha davom etadi.
const PLANS: [(i64, i64); 4] = [
    (30, 15_000),
    (90, 42_000),
    (180, 80_000),
    (365, 150_000),
];

fn plan_price(days: i64) -> Option<i64> {
    PLANS.iter().find(|(d, _)| *d == days).map(|(_, p)| *p)
}

/// Tarif nomi: "1 oylik obuna", "3 oylik obuna", ...
///
/// Ilovadagi `planLabel()` bilan bir xil qoida — jurnal yozuvlari
/// ekrandagi nom bilan mos tushsin.
fn plan_label(days: i64) -> String {
    if days >= 365 {
        return "12 oylik obuna".to_string();
    }
    if days > 0 && days % 30 == 0 {
        return format!("{} oylik obuna", days / 30);
    }
    format!("{days} kunlik obuna")
}

/// Tezcheck xatosini odam o'qiydigan matnga aylantiradi.
///
/// Sayt xatoni bir necha xil ko'rinishda qaytaradi: ba'zan
/// `{"error":"..."}` satr, ba'zan `{"error":{"message":"..."}}`
/// obyekt, ba'zan esa `{"message":"..."}`. Ilgari faqat bittasi
/// o'qilardi va qolganida ekranda "noma'lum xato" chiqardi.
///
/// Xato KODI (`auth.unauthenticated`, `request.rate_limited`, ...)
/// ham qaraladi: matn topilmasa hech bo'lmasa kod ko'rinadi, aks
/// holda jurnalda "noma'lum xato" dan boshqa hech narsa qolmasdi.
fn tezcheck_why(resp: &Value) -> String {
    // ── KOD HAM KO'RSATILADI ────────────────────────────────
    //
    // TOPILGAN MUAMMO: ekranda faqat sayt yuborgan MATN chiqardi
    // ("Joriy holatda bu amalga ruxsat berilmaydi"). Bunday matn
    // bir necha xil xatoga to'g'ri keladi — kassa to'lov qabul
    // qilmayaptimi, token boshqa kassaga tegishlimi, yoki hisob
    // hali faollashtirilmaganmi — ajratib bo'lmasdi.
    //
    // Kod (`auth.permission_denied`, `resource.state_invalid`,
    // `merchant.suspended`, ...) buni bir zumda ayirib beradi, shu
    // sabab u matn yoniga qo'shiladi.
    let code = [&resp["error"]["code"], &resp["code"]]
        .iter()
        .find_map(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("");
    for v in [
        &resp["error"]["message"], &resp["message"], &resp["error"],
        &resp["reason"], &resp["detail"],
    ] {
        if let Some(s) = v.as_str() {
            if !s.is_empty() {
                return if code.is_empty() {
                    s.to_string()
                } else {
                    format!("{s} [{code}]")
                };
            }
        }
    }
    if !code.is_empty() {
        return code.to_string();
    }
    // 422 da maydonlar bo'yicha xatolar keladi: {"errors":{"amount_minor":["..."]}}
    if let Some(m) = resp["errors"].as_object() {
        if let Some((field, list)) = m.iter().next() {
            if let Some(first) = list.as_array().and_then(|a| a.first()) {
                if let Some(s) = first.as_str() {
                    return format!("{field}: {s}");
                }
            }
        }
    }
    "noma'lum xato".to_string()
}

/// Tezcheck'ga POST so'rovi: `(HTTP holati, javob)`.
///
/// HTTP holati ham qaytariladi, chunki yangi API "bo'ldi/bo'lmadi"
/// ni javob TANASIDAGI bayroq bilan emas, HOLAT KODI bilan
/// bildiradi (muvaffaqiyat — 2xx). Ilgarigi `ok: true` maydoni
/// yo'q.
async fn tezcheck(env: &Env, path: &str, body: Value) -> Result<(u16, Value)> {
    tezcheck_req(env, path, body, true).await
}

/// `tezcheck` ning o'zi, faqat kassa sarlavhasini yubormaslik
/// mumkin: `POST /cash-desks` hujjatga ko'ra AYNAN shusiz
/// chaqiriladi (u kassa kodini bilish uchun mo'ljallangan).
async fn tezcheck_req(env: &Env, path: &str, body: Value, with_desk: bool) -> Result<(u16, Value)> {
    // `wrangler secret put` ba'zan oxiriga qator tashlashni ham
    // qo'shib yuboradi. O'sha ko'rinmas belgi tufayli sayt
    // "Invalid api key" deb javob berardi — shuning uchun
    // kalitlarning chetlarini albatta tozalaymiz.
    let token = env.secret("TEZCHECK_TOKEN")?.to_string().trim().to_string();
    let desk = env.secret("TEZCHECK_DESK")?.to_string().trim().to_string();
    if token.is_empty() || desk.is_empty() {
        return Err(Error::RustError(
            "TEZCHECK_TOKEN yoki TEZCHECK_DESK qo'yilmagan".into(),
        ));
    }

    let h = Headers::new();
    h.set("Content-Type", "application/json")?;
    h.set("Accept", "application/json")?;
    h.set("Authorization", &format!("Bearer {token}"))?;
    if with_desk {
        h.set("X-Cash-Desk-Code", &desk)?;
    }
    let req = Request::new_with_init(
        &format!("{TEZCHECK_API}{path}"),
        RequestInit::new()
            .with_method(Method::Post)
            .with_headers(h)
            .with_body(Some(body.to_string().into())),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let status = r.status_code();
    Ok((status, r.json().await.unwrap_or(json!({}))))
}

/// Kassa nega to'lov qabul qilmayotganini aniqlaydi.
///
/// ── TOPILGAN MUAMMO: `resource.state_invalid` ────────────────
///
/// `POST /bills` 409 `resource.state_invalid` qaytarsa, ekranda
/// faqat "Joriy holatda bu amalga ruxsat berilmaydi" chiqardi —
/// nima qilish kerakligi noma'lum edi. Hujjatga ko'ra bu hisob
/// yaratishda KASSA holati bilan bog'liq: kassa `draft`,
/// `paused`, `suspended` yoki `archived` bo'lsa (yoki unda
/// birorta to'lov usuli yoqilmagan bo'lsa) `accepts_payments`
/// `false` bo'ladi va hisob yaratilmaydi.
///
/// Shu sabab xatodan keyin `POST /cash-desks` so'raladi va
/// BIZNING kassamiz (`TEZCHECK_DESK`) holati matnga qo'shiladi.
/// Bu kod bilan tuzatib bo'lmaydigan narsa — kassani tezcheck.uz
/// kabinetida faollashtirish kerak — lekin endi ekranning o'zi
/// aynan shuni aytadi.
async fn desk_diagnosis(env: &Env) -> Option<String> {
    let desk = env.secret("TEZCHECK_DESK").ok()?.to_string().trim().to_string();
    let (code, resp) = tezcheck_req(env, "/cash-desks", json!({}), false).await.ok()?;
    if !(200..300).contains(&code) {
        return None;
    }
    let list = resp["data"].as_array()?;
    let Some(d) = list.iter().find(|d| d["code"].as_str() == Some(desk.as_str())) else {
        return Some(format!(
            "TEZCHECK_DESK bu tokenga tegishli kassalar orasida yo'q \
             (tokenga {} ta kassa ko'rinadi) — kassa kodini tekshiring",
            list.len()
        ));
    };
    let state = d["state"].as_str().unwrap_or("?");
    // ── MAYDON YO'Q BO'LSA "?" — "false" EMAS ────────────────
    //
    // TOPILGAN XATO: ekranda `rejim=?` chiqdi, ya'ni sayt javobida
    // `mode` maydoni umuman yo'q. `accepts_payments` ham yo'q
    // bo'lishi mumkin edi, lekin u `false` deb ko'rsatilardi va
    // "usullarni yoqing" degan noto'g'ri maslahat chiqardi.
    let mode = d["mode"].as_str().unwrap_or("?");
    let accepts = d["accepts_payments"].as_bool();
    let accepts_txt = accepts.map(|b| b.to_string()).unwrap_or_else(|| "?".into());

    // ── KASSADA HAQIQATDA QAYSI USULLAR BOR ─────────────────
    //
    // `POST /payment-methods` platforma va kassa qoidalari
    // qo'llangandan KEYINGI ro'yxatni beradi. Kabinetda "yoniq"
    // ko'rinsa-yu, bu yerda bo'sh bo'lsa — muammo tezcheck
    // tomonida (provayder ulanmagan, shartnoma tasdiqlanmagan).
    let methods = match tezcheck(env, "/payment-methods", json!({})).await {
        Ok((c, r)) if (200..300).contains(&c) => match r["data"].as_array() {
            Some(a) if a.is_empty() => "usullar=BO'SH".to_string(),
            Some(a) => format!(
                "usullar={}",
                a.iter()
                    .map(|m| format!(
                        "{}({}-{} so'm)",
                        m["provider_code"].as_str().unwrap_or("?"),
                        m["min_amount_minor"].as_i64().unwrap_or(0) / 100,
                        m["max_amount_minor"].as_i64().unwrap_or(0) / 100,
                    ))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            None => "usullar=?".to_string(),
        },
        Ok((c, r)) => format!("usullar: {c} {}", tezcheck_why(&r)),
        Err(_) => "usullar=?".to_string(),
    };

    let hint = match state {
        "draft" => "kassa hali faollashtirilmagan (draft) — kabinetda sozlashni oxiriga yetkazing",
        "paused" => "kassa to'xtatib qo'yilgan (paused) — kabinetda qayta yoqing",
        "suspended" => "kassa tezcheck tomonidan to'xtatilgan (suspended) — qo'llab-quvvatlashga yozing",
        "archived" => "kassa arxivlangan (archived) — faol kassaning kodini qo'ying",
        _ if methods == "usullar=BO'SH" => "kassada birorta ham ishlaydigan to'lov usuli yo'q — tezcheck qo'llab-quvvatlashiga yozing",
        _ => "sabab tezcheck tomonida — request_id bilan qo'llab-quvvatlashga yozing",
    };
    Some(format!(
        "Kassa: holat={state}, rejim={mode}, to'lov qabul qiladi={accepts_txt}, {methods} — {hint}"
    ))
}

/// Obuna tugash vaqti (ms). Obunasi yo'q bo'lsa 0.
async fn sub_until(env: &Env, user: i64) -> i64 {
    let res = turso_exec(env, "SELECT expires_at FROM subs_db WHERE user_id=?",
        vec![TursoArg::int(user)]).await;
    res.ok()
        .and_then(|r| first_row(&r))
        .and_then(|r| r["expires_at"].as_i64())
        .unwrap_or(0)
}

/// So'mni tiyinga: tezcheck.uz barcha summani TIYINDA oladi.
///
/// TOPILGAN XATA XAVFI: bu o'girish unutilsa, 15 000 so'mlik
/// obuna uchun 150 so'm undirilardi (yoki teskarisi — odam 100
/// barobar ko'p to'lardi). Shu sabab o'girish BITTA joyda.
fn to_minor(sum: i64) -> i64 {
    sum * 100
}

/// POST /api/billing/create — to'lov havolasi yaratish.
async fn billing_create(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let amount = b["amount"].as_i64().unwrap_or(0);
    if !(PAY_MIN..=PAY_MAX).contains(&amount) {
        return json_resp(&json!({
            "error": format!("Summa {PAY_MIN} dan {PAY_MAX} gacha bo'lishi kerak")
        }), 400);
    }

    // Bizning tomondagi raqam: sayt uni `external_reference` da
    // qaytaradi va webhook kelganda YOZUVNI TOPISH uchun ishlaydi.
    let reference = format!("aru-{me}-{}", now_ms());

    let mut body = json!({
        "amount_minor": to_minor(amount),
        "title": format!("ARUmediaTV — balans to'ldirish ({amount} so'm)"),
        "external_reference": reference,
    });
    // Bitta to'lov usuli tanlab qo'yilgan bo'lsa — foydalanuvchi
    // ro'yxatdan tanlamaydi (`PAY_PROVIDERS` izohiga qarang).
    if !PAY_PROVIDERS.is_empty() {
        body["allowed_provider_codes"] = json!(PAY_PROVIDERS);
    }

    let (code, resp) = tezcheck(env, "/bills", body).await?;
    // Yangi API muvaffaqiyatni HOLAT KODI bilan bildiradi (201).
    if !(200..300).contains(&code) {
        let mut why = tezcheck_why(&resp);
        // Qo'llab-quvvatlash xatoni aynan shu raqam bilan topadi.
        if let Some(rid) = resp["error"]["request_id"].as_str() {
            why = format!("{why} (request_id: {rid})");
        }
        // 409 — kassa hozir to'lov qabul qilmayapti. Sababi
        // kodda emas, tezcheck kabinetida: `desk_diagnosis`
        // aynan nima qilish kerakligini aytadi.
        if code == 409 {
            if let Some(d) = desk_diagnosis(env).await {
                why = format!("{why}. {d}");
            }
        }
        return json_resp(&json!({
            "error": format!("To'lov yaratilmadi: {why}")
        }), 502);
    }
    let order_id = resp["data"]["bill"]["id"].as_str().unwrap_or("").to_string();
    if order_id.is_empty() {
        return json_resp(&json!({"error": "hisob raqami kelmadi"}), 502);
    }
    // ── HAVOLA BIR MARTA BERILADI ───────────────────────────
    //
    // Sayt `payment_url` ni FAQAT yaratilganda qaytaradi (keyin u
    // `null` bo'ladi). Shu sabab uni shu zahoti bazaga yozamiz —
    // aks holda odam oynani yopsa havola butunlay yo'qolardi.
    let pay_url = resp["data"]["payment_url"].as_str().unwrap_or("").to_string();
    if pay_url.is_empty() {
        return json_resp(&json!({"error": "to'lov havolasi kelmadi"}), 502);
    }

    let now = now_ms();
    let expires = now + PAY_LINK_TTL_MS;
    // Eski, muddati o'tgan havolalar shu yerda ham tozalanadi:
    // odam balans oynasini ochmasdan turib yangi havola
    // yaratishi mumkin va o'sha holda tozalash hech qachon
    // ishga tushmasdi.
    let _ = turso_exec(env,
        "DELETE FROM payments_db WHERE status='pending' AND expires_at < ?",
        vec![TursoArg::int(now)]).await;
    turso_exec(env,
        "INSERT INTO payments_db
            (order_id,user_id,amount,status,pay_url,created_at,expires_at,paid_at)
         VALUES (?,?,?,'pending',?,?,?,0)
         ON CONFLICT(order_id) DO UPDATE SET
            user_id=excluded.user_id, amount=excluded.amount,
            pay_url=excluded.pay_url, expires_at=excluded.expires_at",
        vec![
            TursoArg::text(&order_id), TursoArg::int(me), TursoArg::int(amount),
            TursoArg::text(&pay_url), TursoArg::int(now), TursoArg::int(expires),
        ]).await?;

    ok_nostore(json!({
        "ok": true,
        "order_id": order_id,
        "pay_url": pay_url,
        "amount": amount,
        "expires_at": expires,
    }))
}

/// To'langan to'lovni HISOBGA OLADI: balansni oshiradi va
/// tarixga yozadi. Ikki joydan chaqiriladi — "Tekshirish" tugmasi
/// (`billing_check`) va webhook (`billing_webhook`).
///
/// ── PUL BIR MARTA QO'SHILADI ──────────────────────────────────
///
/// Holat `pending` dan `paid` ga SHARTLI o'tadi. Ikkinchi chaqiruv
/// (tugma qayta bosildi, webhook takrorlandi, ikkovi bir vaqtda
/// keldi) HECH QANDAY qatorga tegmaydi, ya'ni balans ikkinchi
/// marta oshmaydi. Idempotentlik AYNAN shu yerda — webhook
/// hodisasining raqamiga tayanmaydi.
///
/// `true` — aynan shu chaqiruv pulni qo'shdi.
async fn credit_payment(env: &Env, order_id: &str, user: i64, amount: i64)
    -> Result<bool>
{
    let now = now_ms();
    let upd = turso_exec(env,
        "UPDATE payments_db SET status='paid', paid_at=?
          WHERE order_id=? AND status='pending' RETURNING order_id",
        vec![TursoArg::int(now), TursoArg::text(order_id)]).await?;
    if first_row(&upd).is_none() {
        return Ok(false);
    }
    turso_batch(env, &[
        ("UPDATE users_db SET balance=COALESCE(balance,0)+? WHERE id=?",
         vec![TursoArg::int(amount), TursoArg::int(user)]),
        ("INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
          VALUES (?,?,'topup',?,0,?,?)",
         vec![
            TursoArg::text(&format!("t{order_id}")), TursoArg::int(user),
            TursoArg::int(amount),
            TursoArg::text(&format!("Balans to'ldirildi (#{order_id})")),
            TursoArg::int(now),
         ]),
    ]).await?;
    Ok(true)
}

/// POST /api/billing/check — to'lov bo'ldimi?
///
/// Webhook qo'yilgan bo'lsa bu yo'l odatda "allaqachon to'langan"
/// deb qaytadi — pul webhook bilan tushib bo'lgan bo'ladi. Tugma
/// baribir qoldirilgan: webhook kechiksa yoki sayt uni yubora
/// olmasa, odam kutib qolmasligi kerak.
async fn billing_check(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let order_id = b["order_id"].as_str().unwrap_or("").to_string();
    if order_id.is_empty() {
        return json_resp(&json!({"error": "order_id yo'q"}), 400);
    }

    // Havola AYNAN shu odamniki ekanini tekshiramiz.
    let row = turso_exec(env,
        "SELECT * FROM payments_db WHERE order_id=? AND user_id=?",
        vec![TursoArg::text(&order_id), TursoArg::int(me)]).await?;
    let Some(pay) = first_row(&row) else {
        return json_resp(&json!({"error": "to'lov topilmadi"}), 404);
    };
    let amount = pay["amount"].as_i64().unwrap_or(0);
    if pay["status"].as_str() == Some("paid") {
        return ok_nostore(json!({
            "ok": true, "status": "paid", "already": true,
            "balance": u["balance"].as_i64().unwrap_or(0),
        }));
    }

    let (code, resp) = tezcheck(env, &format!("/bills/{order_id}"), json!({})).await?;
    if !(200..300).contains(&code) {
        return json_resp(&json!({
            "error": format!("Tekshirib bo'lmadi: {}", tezcheck_why(&resp))
        }), 502);
    }
    let bill = &resp["data"]["bill"];
    if bill["paid"] != json!(true) {
        return ok_nostore(json!({
            "ok": true,
            "status": "pending",
            "balance": u["balance"].as_i64().unwrap_or(0),
        }));
    }

    // ── SUMMA MOS KELISHI SHART ─────────────────────────────
    //
    // Sayt qaytargan summa bizdagidan farq qilsa, balansni
    // BIZDAGI yozuvga qarab oshirish xato bo'lardi. Bunday holat
    // amalda bo'lmaydi (summani biz belgilaymiz), lekin pul bilan
    // ishlaganda "bo'lmaydi" degan gap yetarli emas.
    if bill["amount_minor"].as_i64().unwrap_or(0) != to_minor(amount) {
        return json_resp(&json!({
            "error": "To'lov summasi mos kelmadi — qo'llab-quvvatlashga murojaat qiling"
        }), 409);
    }

    let added = credit_payment(env, &order_id, me, amount).await?;
    ok_nostore(json!({
        "ok": true,
        "status": "paid",
        "already": !added,
        "balance": u["balance"].as_i64().unwrap_or(0) + if added { amount } else { 0 },
    }))
}

// ═══════════════════════════════════════════════════════════════
//  WEBHOOK — PUL O'ZI TUSHADI
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "ilovani ham tekshirishsiz avto pul
// tushadigan qilish kerak".
//
// Pul tushishi bilan tezcheck.uz SHU manzilga xabar yuboradi va
// balans o'sha zahoti oshadi — odam hech narsa bosmaydi. Ilova esa
// balansni o'zi yangilab turadi, ya'ni raqam ko'z oldida o'zgaradi.
//
// ── NEGA IMZO TEKSHIRILADI ────────────────────────────────────
//
// Bu manzil INTERNETDAN OCHIQ: unga istalgan odam so'rov yubora
// oladi. Imzosiz u "balansimni oshir" tugmasiga aylanardi.
//
// Imzo — HMAC-SHA256, kaliti webhook siri (`wbs_...`), matni esa
// `{timestamp}.{delivery_id}.{tana}`. Tana AYNAN kelgan holida
// olinadi: JSON ni o'qib qayta yozish probel va maydonlar
// tartibini o'zgartiradi va imzo boshqa hech qachon to'g'ri
// chiqmasdi.
//
// Uchta to'siq:
//   1. sir qo'yilmagan bo'lsa manzil UMUMAN ishlamaydi (503) —
//      "sir yo'q ekan, o'tkazib yuboraman" degan yo'l yo'q;
//   2. vaqt tamg'asi 5 daqiqadan eski bo'lsa rad etiladi (eski
//      xabarni ushlab olib qayta yuborish ishlamaydi);
//   3. imzo doimiy vaqtda solishtiriladi (`verify_slice`).
//
// Sayt sirni almashtirganda 24 soat davomida IKKALA imzoni ham
// yuboradi (vergul bilan), shu sabab har bir nomzod alohida
// tekshiriladi.

/// Webhook vaqt tamg'asi shuncha soniyadan eski bo'lsa — rad.
const WEBHOOK_SKEW_SECS: i64 = 300;

/// Baytlarni kichik harfli hex ga.
fn hex_of(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Webhook imzosi to'g'rimi (`X-Checkout-Signature`).
///
/// ── NEGA IKKITA KALIT SINALADI ──────────────────────────────
///
/// Hujjatda ikki xil yozilgan: formulada kalit sifatida
/// `SHA256_secret` ko'rsatilgan, ishlaydigan PHP namunasida esa
/// sirning O'ZI berilgan. Ikkalasi ham hisoblanadi va mos kelgani
/// qabul qilinadi — bu xavfsizlikni susaytirmaydi, chunki ikkala
/// holatda ham kalit faqat bizda va tezcheck.uz da bor.
fn webhook_sig_ok(secret: &str, ts: &str, delivery: &str, sig_header: &str, raw: &str) -> bool {
    if ts.is_empty() || delivery.is_empty() || sig_header.is_empty() {
        return false;
    }
    // Eski xabarni ushlab olib qayta yuborib bo'lmasin.
    if (now_ms() / 1000 - ts.parse::<i64>().unwrap_or(0)).abs() > WEBHOOK_SKEW_SECS {
        return false;
    }
    let msg = format!("{ts}.{delivery}.{raw}");
    let sha_key: [u8; 32] = <sha2::Sha256 as sha2::Digest>::digest(secret.as_bytes()).into();
    let mut expected: Vec<String> = Vec::with_capacity(2);
    for key in [secret.as_bytes(), &sha_key[..]] {
        let Ok(mut mac) = <hmac::Hmac<sha2::Sha256> as hmac::Mac>::new_from_slice(key) else {
            return false;
        };
        hmac::Mac::update(&mut mac, msg.as_bytes());
        expected.push(format!("v1={}", hex_of(&hmac::Mac::finalize(mac).into_bytes())));
    }
    // Sir almashtirilayotgan 24 soat ichida sayt eski va yangi
    // imzoni vergul bilan birga yuboradi.
    sig_header.split(',').any(|c| {
        let c = c.trim();
        expected.iter().any(|e| c.eq_ignore_ascii_case(e))
    })
}

/// POST /api/billing/webhook — tezcheck.uz dan kelgan hodisa.
///
/// ═══════════════════════════════════════════════════════════
///  XABARGA ISHONILMAYDI — TEZCHECK'DAN QAYTA SO'RALADI
/// ═══════════════════════════════════════════════════════════
///
/// TALAB (foydalanuvchi): "tezchek pul tushgani haqida javob
/// qaytarsa worker tekshirishi kerak, agar haqiqiy bo'lsa keyin
/// javob beradi".
///
/// Aynan shunday ishlaydi, va eng muhimi — bu yerda kelgan
/// xabarning HECH BIR RAQAMIGA ishonilmaydi. Xabar faqat
/// "borib tekshir" degan turtki, xolos:
///
///   1. xabardan FAQAT hisob raqami (`bill_id`) olinadi;
///   2. worker tezcheck.uz ga o'zi murojaat qilib so'raydi:
///      "shu hisob to'landimi va qancha?";
///   3. pul AYNAN tezcheck aytgan summa bo'yicha qo'shiladi —
///      xabarda yozilgani bo'yicha emas.
///
/// Shu sabab soxta xabar hech narsa qila olmaydi: u faqat
/// workerni bitta ortiqcha so'rovga majburlaydi. "Menga 1 000 000
/// so'm tushdi" deb yozilgan xabar tezcheck'da tasdiqlanmasa,
/// balans qimirlamaydi.
///
/// ── IMZO ENDI IXTIYORIY ─────────────────────────────────────
///
/// Ilgari sir (`TEZCHECK_WEBHOOK_SECRET`) qo'yilmagan bo'lsa
/// manzil umuman ishlamasdi (503). Endi kerak emas: ishonch
/// yuqoridagi qayta so'rashga tayanadi. Sir qo'yilgan bo'lsa —
/// arzon birinchi filtr sifatida ishlaydi va soxta xabarlar
/// tezcheck'ga so'rov yubormasdanoq to'xtaydi.
async fn billing_webhook(mut req: Request, env: &Env) -> Result<Response> {
    let secret = match env.secret("TEZCHECK_WEBHOOK_SECRET") {
        Ok(s) => s.to_string().trim().to_string(),
        Err(_) => String::new(),
    };

    // Sarlavhalar AVVAL o'qib olinadi: pastdagi `req.text()` so'rovni
    // O'ZGARUVCHAN qilib oladi va bu yerda hali `req.headers()` dan
    // qarz turgan bo'lsa kod yig'ilmasdi.
    let (ts, delivery, sig_header) = {
        let h = req.headers();
        let get = |n: &str| h.get(n).ok().flatten().unwrap_or_default();
        (
            get("X-Checkout-Timestamp"),
            get("X-Checkout-Delivery"),
            get("X-Checkout-Signature"),
        )
    };
    // Tana AYNAN kelgan holida — imzo shu baytlar ustidan qo'yilgan.
    // JSON ni o'qib qayta yozish probel va maydonlar tartibini
    // o'zgartiradi, ya'ni imzo boshqa hech qachon to'g'ri chiqmasdi.
    let raw = req.text().await.unwrap_or_default();

    if !secret.is_empty() && !webhook_sig_ok(&secret, &ts, &delivery, &sig_header, &raw) {
        return json_resp(&json!({"error": "imzo to'g'ri kelmadi"}), 401);
    }

    // ── XABARDAN FAQAT HISOB RAQAMI OLINADI ─────────────────
    let ev: Value = serde_json::from_str(&raw).unwrap_or(json!({}));
    let bill_id = ev["data"]["bill_id"].as_str().unwrap_or("").to_string();
    if bill_id.is_empty() {
        // Turi boshqa hodisa (processing, failed) yoki tanib
        // bo'lmaydigan xabar. 200 qaytaramiz, aks holda sayt uni
        // 8 marta qayta yuborib turardi.
        return ok_nostore(json!({"ok": true, "ignored": true}));
    }

    // Bizda bunday yozuv bormi (va kimniki).
    let row = turso_exec(env, "SELECT * FROM payments_db WHERE order_id=?",
        vec![TursoArg::text(&bill_id)]).await?;
    let Some(pay) = first_row(&row) else {
        return ok_nostore(json!({"ok": true, "unknown": true}));
    };
    let user = pay["user_id"].as_i64().unwrap_or(0);
    let amount = pay["amount"].as_i64().unwrap_or(0);
    if user <= 0 || amount <= 0 {
        return ok_nostore(json!({"ok": true, "ignored": true}));
    }

    // ── ASOSIY QULF: TEZCHECK'NING O'ZIDAN SO'RAYMIZ ────────
    let (code, resp) = tezcheck(env, &format!("/bills/{bill_id}"), json!({})).await?;
    if !(200..300).contains(&code) {
        // So'rab bo'lmadi — 500 qaytaramiz, sayt keyin qayta
        // yuboradi (uning o'z takroriy yuborish tartibi bor).
        return json_resp(&json!({"error": "tasdiqlab bo'lmadi"}), 500);
    }
    let bill = &resp["data"]["bill"];
    if bill["paid"] != json!(true) {
        // Tezcheck "to'lanmagan" deydi — xabarda nima yozilganidan
        // qat'i nazar, pul qo'shilmaydi.
        return ok_nostore(json!({"ok": true, "paid": false}));
    }
    // Summa ham TEZCHECK aytganicha tekshiriladi.
    if bill["amount_minor"].as_i64().unwrap_or(0) != to_minor(amount) {
        return ok_nostore(json!({"ok": true, "mismatch": true}));
    }

    let added = credit_payment(env, &bill_id, user, amount).await?;
    ok_nostore(json!({"ok": true, "credited": added}))
}

/// POST /api/billing/subscribe — balansdan obuna sotib olish.
async fn billing_subscribe(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let days = b["days"].as_i64().unwrap_or(0);
    let Some(price) = plan_price(days) else {
        return json_resp(&json!({"error": "Bunday tarif yo'q"}), 400);
    };
    let balance = u["balance"].as_i64().unwrap_or(0);
    if balance < price {
        return json_resp(&json!({
            "error": "Balansda mablag' yetarli emas",
            "need": price - balance,
        }), 402);
    }

    let now = now_ms();

    // ── OBUNASI BOR ODAM YANGISINI OLA OLMAYDI ────────────────
    //
    // Foydalanuvchi talabi: "Obuna sotib olgan odam obunasi
    // tugamaguncha obuna sotib ola olmaydi". Shuning uchun bu
    // yerda obuna faol bo'lsa — pul umuman yechilmaydi.
    let cur = sub_until(env, me).await;
    if cur > now {
        let left = ((cur - now) as f64 / 86_400_000.0).ceil() as i64;
        return json_resp(&json!({
            "error": format!(
                "Sizda faol obuna bor. Yangisini obuna tugagach olasiz \
                 (yana {left} kun qoldi)."),
            "subscription_until": cur,
        }), 409);
    }
    let until = now + days * 86_400_000;

    // ── PUL AVVAL YECHILADI, KEYIN OBUNA BERILADI ─────────────
    //
    // Tartib MUHIM. Ilgari ikkovi bitta quvurda edi: balansdan
    // yechish SHARTLI (`balance>=?`) bo'lgani uchun u ba'zan
    // qatorga TEGMASLIGI mumkin (ayni damda boshqa qurilmadan
    // ham sotib olingan bo'lsa), obuna esa BARIBIR uzayardi —
    // ya'ni odam pulsiz obuna olardi.
    //
    // Endi avval yechiladi va natija TEKSHIRILADI: qator
    // qaytmasa — mablag' yetmagan, obunaga umuman tegilmaydi.
    let paid = turso_exec(env,
        "UPDATE users_db SET balance=COALESCE(balance,0)-?
          WHERE id=? AND COALESCE(balance,0)>=? RETURNING balance",
        vec![TursoArg::int(price), TursoArg::int(me), TursoArg::int(price)],
    ).await?;
    let Some(row) = first_row(&paid) else {
        return json_resp(&json!({
            "error": "Balansda mablag' yetarli emas",
        }), 402);
    };
    let left = row["balance"].as_i64().unwrap_or(balance - price);

    turso_batch(env, &[
        ("INSERT INTO subs_db (user_id,expires_at,updated_at) VALUES (?,?,?)
          ON CONFLICT(user_id) DO UPDATE SET
             expires_at=excluded.expires_at, updated_at=excluded.updated_at",
         vec![TursoArg::int(me), TursoArg::int(until), TursoArg::int(now)]),
        ("INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
          VALUES (?,?,'subscription',?,?,?,?)",
         vec![
            TursoArg::text(&format!("s{me}-{now}")), TursoArg::int(me),
            TursoArg::int(-price), TursoArg::int(days),
            // Yozuv nomi ham oylik ko'rinishda (30 kun = 1 oy).
            TursoArg::text(&plan_label(days)),
            TursoArg::int(now),
         ]),
    ]).await?;

    ok_nostore(json!({
        "ok": true,
        "balance": left,
        "subscription_until": until,
    }))
}


// ═══════════════════════════════════════════════════════════════
//  IZOHLAR
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "bo'limlar oynasidan keyin izohlar degan
// oyna qo'sh va xuddi YouTube'dek — izoh yozish, izohga javob
// qaytarish, izohga layk bosish; katta platformalardek to'g'ri va
// barqaror ishlasin".
//
// ── "BARQAROR" NIMA DEGANI ──────────────────────────────────
//
// Uchta narsa kafolatlanadi:
//
//   1. LAYK HECH QACHON IKKI MARTA SANALMAYDI. `comment_likes`
//      ning birlamchi kaliti (izoh + odam) buni bazaning O'ZIDA
//      imkonsiz qiladi — tarmoq uzilib so'rov ikki marta kelsa
//      ham hisob qimirlamaydi.
//
//   2. HISOBLAR SURILMAYDI. `likes` va `reply_count` faqat
//      qator HAQIQATAN qo'shilgan/o'chirilganda o'zgaradi
//      (`RETURNING` bilan tekshiriladi), "ehtimol bo'lgandir"
//      degan taxmin bilan emas.
//
//   3. O'CHIRILGAN IZOH JAVOBLARINI YETIM QOLDIRMAYDI. Qator
//      o'chirilmaydi, faqat `deleted=1` qilinadi va matni
//      bo'shatiladi — javoblar joyida turaveradi.
//
// ── SO'ROVLAR SONI ──────────────────────────────────────────
//
// Ro'yxat BITTA so'rovda keladi: izohlar, mualliflari va "men
// layk bosganmi" belgisi — hammasi bitta `JOIN` bilan. Ilgari
// bunday ekranlar har bir izoh uchun alohida so'rov qilardi.

/// Bitta izohning eng uzun uzunligi.
const COMMENT_MAX: usize = 1000;

/// Bir sahifada nechta izoh.
const COMMENT_PAGE: i64 = 30;

/// Izoh qatorini ilova kutgan ko'rinishga aylantiradi.
fn comment_public(origin: &str, r: &Value) -> Value {
    let deleted = r["deleted"].as_i64().unwrap_or(0) != 0;
    let uid = r["user_id"].as_i64().unwrap_or(0);
    let avatar = r["avatar_file"].as_str().unwrap_or("");
    let photo = if avatar.is_empty() {
        format!("{origin}/api/avatar/{uid}")
    } else {
        format!("{origin}/api/image/{avatar}")
    };
    json!({
        "id": r["id"].as_str().unwrap_or(""),
        "parent_id": r["parent_id"].as_str().unwrap_or(""),
        "user_id": uid,
        "first_name": r["first_name"].as_str().unwrap_or(""),
        "username": r["username"].as_str().unwrap_or(""),
        "photo_url": photo,
        // O'chirilgan izohning matni UMUMAN yuborilmaydi.
        "body": if deleted { "" } else { r["body"].as_str().unwrap_or("") },
        "likes": r["likes"].as_i64().unwrap_or(0),
        "reply_count": r["reply_count"].as_i64().unwrap_or(0),
        "liked": r["liked"].as_i64().unwrap_or(0) != 0,
        "deleted": deleted,
        "created_at": r["created_at"].as_i64().unwrap_or(0),
        "edited_at": r["edited_at"].as_i64().unwrap_or(0),
    })
}

/// Izohlarni o'qish uchun umumiy so'rov.
///
/// `parent` bo'sh bo'lsa — bosh izohlar, aks holda o'sha izohning
/// javoblari. `me` — "men layk bosganmi" belgisi uchun.
const COMMENT_SELECT: &str =
    "SELECT c.id, c.parent_id, c.user_id, c.body, c.likes,
            c.reply_count, c.deleted, c.created_at, c.edited_at,
            u.first_name AS first_name, u.username AS username,
            u.avatar_file AS avatar_file,
            (SELECT COUNT(*) FROM comment_likes l
              WHERE l.comment_id = c.id AND l.user_id = ?) AS liked
       FROM comments_db c
       LEFT JOIN users_db u ON u.id = c.user_id
      WHERE c.anime_id = ? AND c.season_id = ? AND c.parent_id = ?
        -- O'chirilgan izoh bazada UMUMAN qolmaydi
        -- (comments_delete izohiga qarang). Bu shart faqat eski
        -- yozuvlar uchun: bir marta belgilangan-u o'chirilmagan
        -- qatorlar ham endi ko'rinmasin.
        AND c.deleted = 0
      ORDER BY ";

/// ── TARTIB: YANGILAR / LAYKLAR / JAVOBLAR ────────────────────
///
/// TALAB (foydalanuvchi): "o'ng yuqori qismida yangilar, layklar,
/// javoblar degan tugma bo'lsin — yangida barcha izohlar chiqadi
/// va yangilari tepada turadi; layklarda layklar soni bo'yicha,
/// javoblarda javob berishlar soni bo'yicha tepada turadi".
///
/// NEGA SERVERDA: ro'yxat sahifalab keladi (20 tadan). Tartib
/// ilovada berilsa, faqat YUKLANGAN sahifa tartiblanardi — ya'ni
/// eng ko'p layk olgan izoh uchinchi sahifada qolib ketishi
/// mumkin edi. Serverda esa butun ro'yxatdan eng yuqorisi
/// birinchi sahifaga tushadi.
///
/// Ikkinchi shart HAR DOIM `created_at DESC`: layki (yoki javobi)
/// teng izohlar orasida yangisi tepada tursin va tartib
/// sahifadan sahifaga o'zgarmasin.
fn comment_order(sort: &str) -> &'static str {
    match sort {
        "layk" => "c.likes DESC, c.created_at DESC",
        "javob" => "c.reply_count DESC, c.created_at DESC",
        // "yangi" va noma'lum qiymat — odatiy tartib.
        _ => "c.created_at DESC",
    }
}

/// Bitta sahifa uchun to'liq so'rov (tartib qo'yilgan holda).
fn comment_query(sort: &str) -> String {
    format!("{COMMENT_SELECT}{} LIMIT ? OFFSET ?", comment_order(sort))
}

/// GET /api/comments/:anime/:season[/:parent]
async fn comments_list(
    req: &Request, env: &Env, origin: &str,
    aid: i64, sid: i64, parent: &str,
) -> Result<Response> {
    // Izohlarni O'QISH uchun kirish SHART EMAS — ular ochiq.
    // Kirilgan bo'lsa "men layk bosganman" belgisi ham keladi.
    let me = session_user(env, &bearer(req)).await?
        .and_then(|u| u["id"].as_i64())
        .unwrap_or(0);
    let url = req.url()?;
    let page: i64 = url.query_pairs()
        .find(|(k, _)| k == "page")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0)
        .max(0);
    // Tartib FAQAT bosh izohlarga tegishli. Javoblar suhbat
    // tartibida qoladi — ular orasida "eng ko'p layk olgani
    // tepada" degani suhbatni buzib yuborardi.
    let sort = if parent.is_empty() {
        url.query_pairs()
            .find(|(k, _)| k == "sort")
            .map(|(_, v)| v.to_string())
            .unwrap_or_default()
    } else {
        String::new()
    };

    let res = turso_exec(env, &comment_query(&sort), vec![
        TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid),
        TursoArg::text(parent),
        TursoArg::int(COMMENT_PAGE), TursoArg::int(page * COMMENT_PAGE),
    ]).await?;

    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows.iter()
        .map(|r| comment_public(origin, &row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))))
        .collect();

    ok_nostore(json!({
        "items": items,
        "page": page,
        // Ro'yxat to'liq kelgan bo'lsa — yana bor bo'lishi mumkin.
        "has_more": items.len() as i64 >= COMMENT_PAGE,
    }))
}

/// POST /api/comments — yangi izoh yoki javob.
async fn comments_add(mut req: Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    if u["is_banned"].as_i64().unwrap_or(0) != 0 {
        return json_resp(&json!({"error": "Sizga izoh yozish taqiqlangan"}), 403);
    }

    let b: Value = req.json().await.unwrap_or(json!({}));
    let aid = b["anime_id"].as_i64().unwrap_or(0);
    let sid = b["season_id"].as_i64().unwrap_or(0);
    let body = b["body"].as_str().unwrap_or("").trim().to_string();

    if body.is_empty() {
        return json_resp(&json!({"error": "Izoh bo'sh"}), 400);
    }
    // Uzunlik BELGI bo'yicha cheklanadi (bayt emas): o'zbekcha
    // harflar ikki bayt egallaydi va bayt bilan cheklansa yozuv
    // o'rtasidan kesilib qolardi.
    let body: String = body.chars().take(COMMENT_MAX).collect();

    // ── JAVOB BOSH IZOHGA BIRIKTIRILADI ───────────────────────
    //
    // Javobga javob yozilsa, u o'sha BOSH izohning javobi bo'ladi
    // (YouTube ham shunday). Shu sabab kelgan `parent_id` ning
    // o'zi javob bo'lsa, uning bosh izohi olinadi.
    let want_parent = b["parent_id"].as_str().unwrap_or("").trim().to_string();
    let mut parent = String::new();
    if !want_parent.is_empty() {
        let p = turso_exec(env,
            "SELECT id, parent_id FROM comments_db
              WHERE id=? AND anime_id=? AND season_id=?",
            vec![TursoArg::text(&want_parent), TursoArg::int(aid), TursoArg::int(sid)],
        ).await?;
        let Some(row) = first_row(&p) else {
            return json_resp(&json!({"error": "Izoh topilmadi"}), 404);
        };
        let pp = row["parent_id"].as_str().unwrap_or("");
        parent = if pp.is_empty() {
            row["id"].as_str().unwrap_or("").to_string()
        } else {
            pp.to_string()
        };
    } else if !season_exists(env, aid, sid).await {
        return json_resp(&json!({"error": "Bo'lim topilmadi"}), 404);
    }

    let id = format!("c{}", random_hex(12));
    let now = now_ms();
    turso_exec(env,
        "INSERT INTO comments_db
            (id,anime_id,season_id,user_id,parent_id,body,
             likes,reply_count,deleted,created_at,edited_at)
         VALUES (?,?,?,?,?,?,0,0,0,?,0)",
        vec![
            TursoArg::text(&id), TursoArg::int(aid), TursoArg::int(sid),
            TursoArg::int(me), TursoArg::text(&parent), TursoArg::text(&body),
            TursoArg::int(now),
        ]).await?;

    // Javob bo'lsa — bosh izohning hisobi oshadi.
    if !parent.is_empty() {
        let _ = turso_exec(env,
            "UPDATE comments_db SET reply_count=reply_count+1 WHERE id=?",
            vec![TursoArg::text(&parent)]).await;
    }

    let avatar = u["avatar_file"].as_str().unwrap_or("");
    let photo = if avatar.is_empty() {
        format!("{origin}/api/avatar/{me}")
    } else {
        format!("{origin}/api/image/{avatar}")
    };
    created(json!({
        "id": id,
        "parent_id": parent,
        "user_id": me,
        "first_name": u["first_name"].as_str().unwrap_or(""),
        "username": u["username"].as_str().unwrap_or(""),
        "photo_url": photo,
        "body": body,
        "likes": 0,
        "reply_count": 0,
        "liked": false,
        "deleted": false,
        "created_at": now,
        "edited_at": 0,
    }))
}

/// Bunday bo'lim bormi (o'ylab topilgan izohlar tushmasin).
async fn season_exists(env: &Env, aid: i64, sid: i64) -> bool {
    turso_exec(env,
        "SELECT COUNT(*) FROM season_db WHERE anime_id=? AND season_id=?",
        vec![TursoArg::int(aid), TursoArg::int(sid)]).await
        .map(|r| scalar(&r) > 0)
        .unwrap_or(false)
}

/// POST /api/comments/like — laykni yoqadi/o'chiradi.
///
/// Javob HAR DOIM yakuniy holatni qaytaradi, ya'ni ilova o'zi
/// hisoblab o'tirmaydi va ikkovi hech qachon farq qilmaydi.
async fn comments_like(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    let id = b["id"].as_str().unwrap_or("").trim().to_string();
    if id.is_empty() {
        return json_resp(&json!({"error": "id yo'q"}), 400);
    }

    // ── QO'SHISH SHARTLI ──────────────────────────────────────
    //
    // Birlamchi kalit tufayli takroriy layk qatorga TEGMAYDI va
    // `RETURNING` hech narsa qaytarmaydi — ya'ni hisob ham
    // oshmaydi. So'rov ikki marta kelsa ham natija bir xil.
    let now = now_ms();
    let ins = turso_exec(env,
        "INSERT INTO comment_likes (comment_id,user_id,created_at)
         VALUES (?,?,?) ON CONFLICT(comment_id,user_id) DO NOTHING
         RETURNING comment_id",
        vec![TursoArg::text(&id), TursoArg::int(me), TursoArg::int(now)],
    ).await?;

    let liked = if first_row(&ins).is_some() {
        let _ = turso_exec(env,
            "UPDATE comments_db SET likes=likes+1 WHERE id=?",
            vec![TursoArg::text(&id)]).await;
        true
    } else {
        // Allaqachon bosilgan — bu ikkinchi bosish, ya'ni bekor
        // qilish. O'chirish ham SHARTLI: qator qaytmasa hisobga
        // tegilmaydi.
        let del = turso_exec(env,
            "DELETE FROM comment_likes WHERE comment_id=? AND user_id=?
             RETURNING comment_id",
            vec![TursoArg::text(&id), TursoArg::int(me)]).await?;
        if first_row(&del).is_some() {
            let _ = turso_exec(env,
                "UPDATE comments_db SET likes=MAX(likes-1,0) WHERE id=?",
                vec![TursoArg::text(&id)]).await;
        }
        false
    };

    let cur = turso_exec(env,
        "SELECT likes FROM comments_db WHERE id=?",
        vec![TursoArg::text(&id)]).await?;
    let likes = first_row(&cur).and_then(|r| r["likes"].as_i64()).unwrap_or(0);
    ok_nostore(json!({"ok": true, "liked": liked, "likes": likes}))
}

/// DELETE /api/comments/:id — FAQAT o'z izohini.
async fn comments_delete(req: &Request, env: &Env, id: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);

    // ── IZOH BUTUNLAY O'CHIRILADI ────────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: izoh o'chirilgan bo'lsa ham
    // profili va bitta javobi ko'rsatilib turibdi, men esa
    // butunlay o'chirib tashlansin degandim).
    //
    // Ilgari qator o'chirilmasdan BELGILANARDI (deleted=1) va
    // javoblari bo'lsa ro'yxatda muallifning ismi va rasmi bilan
    // turaverardi.
    //
    // Endi qator HAQIQATAN o'chiriladi. Bosh izoh o'chirilsa
    // uning JAVOBLARI ham o'chadi: ular o'chgan izohga tegishli
    // edi, yolg'iz qolsa suhbat ma'nosini yo'qotadi.
    //
    // Layklar ham o'chiriladi — aks holda comment_likes jadvalida
    // hech qachon o'qilmaydigan qatorlar yig'ilib borardi.
    //
    // ── ADMIN HAM O'CHIRA OLADI ──────────────────────────────
    //
    // Shikoyat tizimi shusiz ishlamaydi: admin qoidabuzar izohni
    // ko'radi-yu, unga hech narsa qila olmasdi. Boshqa hamma
    // odam uchun shart o'zgarmaydi — faqat O'Z izohi.
    //
    // Tartib MUHIM: avval EGALIK (yoki adminlik) tekshiriladi,
    // shu o'tgandan keyingina qolgani o'chiriladi.
    let res = if is_admin(&u) {
        turso_exec(env,
            "DELETE FROM comments_db WHERE id=? RETURNING id, parent_id",
            vec![TursoArg::text(id)]).await?
    } else {
        turso_exec(env,
            "DELETE FROM comments_db
              WHERE id=? AND user_id=?
              RETURNING id, parent_id",
            vec![TursoArg::text(id), TursoArg::int(me)]).await?
    };
    let Some(row) = first_row(&res) else {
        return json_resp(&json!({"error": "Izoh topilmadi"}), 404);
    };

    let parent = row["parent_id"].as_str().unwrap_or("").to_string();

    // TARTIB MUHIM: javoblarga tegishli qatorlar (layk, shikoyat)
    // javoblarning O'ZIDAN oldin o'chiriladi — ular javoblarni
    // `parent_id` bo'yicha qidiradi, javoblar ketgandan keyin esa
    // topadigan narsasi qolmasdi.
    let mut cleanup: Vec<(&str, Vec<TursoArg>)> = vec![
        // Javoblarning layklari.
        ("DELETE FROM comment_likes
           WHERE comment_id IN (SELECT id FROM comments_db WHERE parent_id=?)",
         vec![TursoArg::text(id)]),
        // Javoblarga kelgan shikoyatlar.
        ("DELETE FROM reports_db
           WHERE kind='comment'
             AND target_id IN (SELECT id FROM comments_db WHERE parent_id=?)",
         vec![TursoArg::text(id)]),
        // Javoblarning o'zi.
        ("DELETE FROM comments_db WHERE parent_id=?", vec![TursoArg::text(id)]),
        // O'chirilgan izohning layklari.
        ("DELETE FROM comment_likes WHERE comment_id=?", vec![TursoArg::text(id)]),
        // Unga kelgan shikoyatlar ham ma'nosini yo'qotdi: izoh
        // endi yo'q, adminning ko'radigan narsasi qolmadi.
        ("DELETE FROM reports_db WHERE kind='comment' AND target_id=?",
         vec![TursoArg::text(id)]),
    ];
    // ── JAVOB O'CHDI — BOSH IZOHNING HISOBI KAMAYADI ─────────
    if !parent.is_empty() {
        cleanup.push((
            "UPDATE comments_db SET reply_count=MAX(reply_count-1,0) WHERE id=?",
            vec![TursoArg::text(&parent)],
        ));
    }
    let _ = turso_batch(env, &cleanup).await;

    ok_nostore(json!({"ok": true, "parent_id": parent}))
}


// ═══════════════════════════════════════════════════════════════
//  ADMIN BILAN YOZISHMA
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "profil sahifasiga admin bilan
// bog'lanadigan chat qo'sh; admin paneliga barcha chatlar bo'limi;
// Telegram chatidek ishlasin".
//
// ── KIM ADMIN ─────────────────────────────────────────────────
//
// Admin — TELEGRAM RAQAMI bo'yicha aniqlanadi. Bu raqam ilovada
// emas, SERVERDA turadi: ilovadagi tekshiruv shunchaki ekranni
// yashiradi, haqiqiy to'siq esa har bir so'rovda shu yerda
// qo'yiladi. Ya'ni o'zgartirilgan ilova bilan ham begona odam
// boshqalarning yozishmasini o'qiy olmaydi.
const ADMIN_TELEGRAM_ID: i64 = 6_805_215_964;

fn is_admin(u: &Value) -> bool {
    u["telegram_id"].as_i64().unwrap_or(0) == ADMIN_TELEGRAM_ID
}

/// Bitta xabarning eng uzun uzunligi.
const CHAT_MAX: usize = 2000;

/// Bir suhbatda ko'rsatiladigan xabarlar soni.
const CHAT_LIMIT: i64 = 200;

/// Xabar qatorini ilova kutgan ko'rinishga aylantiradi.
fn chat_msg_public(origin: &str, r: &Value) -> Value {
    let file = r["media_file"].as_str().unwrap_or("");
    json!({
        "id": r["id"].as_str().unwrap_or(""),
        "from_admin": r["from_admin"].as_i64().unwrap_or(0) != 0,
        "body": r["body"].as_str().unwrap_or(""),
        // Fayl nomi bazada BARE holda turadi — to'liq manzil shu
        // yerda quriladi, ya'ni domen o'zgarsa eski xabarlar ham
        // ishlayveradi.
        "media_url": if file.is_empty() {
            String::new()
        } else {
            format!("{origin}/api/media/{file}")
        },
        "media_type": r["media_type"].as_str().unwrap_or(""),
        "media_ms": r["media_ms"].as_i64().unwrap_or(0),
        // Videoning kadri — oddiy rasm, o'sha `/api/media/` yo'li
        // bilan beriladi. Eski xabarlarda bo'sh.
        "media_thumb_url": match r["media_thumb"].as_str().unwrap_or("") {
            "" => String::new(),
            t => format!("{origin}/api/media/{t}"),
        },
        // Suhbatdosh o'qiganmi: ilovada bitta yoki ikkita belgi.
        "seen": r["seen"].as_i64().unwrap_or(0) != 0,
        "created_at": r["created_at"].as_i64().unwrap_or(0),
    })
}

/// Bitta odamning suhbatini o'qiydi va O'QILDI deb belgilaydi.
///
/// `as_admin` — kim o'qiyapti. Shunga qarab qaysi hisoblagich
/// nollanishi hal bo'ladi.
/// Suhbatni o'qiydi.
///
/// `since` berilgan bo'lsa FAQAT undan keyingi xabarlar qaytadi.
///
/// NEGA KERAK: yozishma ochiq turganda ilova tez-tez so'raydi.
/// Har safar 200 ta xabarni qaytadan tashish ham tarmoqni, ham
/// bazani behuda ishlatardi. `since` bilan javob odatda bo'sh
/// ro'yxat bo'ladi — bir necha o'nlab bayt.
async fn chat_read(
    env: &Env, origin: &str, user: i64, as_admin: bool, since: i64,
) -> Result<Response> {
    let res = if since > 0 {
        turso_exec(env,
            "SELECT id, from_admin, body, media_file, media_type, media_ms, seen, created_at
               FROM chat_messages
              WHERE user_id = ? AND created_at > ?
              ORDER BY created_at DESC LIMIT ?",
            vec![TursoArg::int(user), TursoArg::int(since),
                 TursoArg::int(CHAT_LIMIT)]).await?
    } else {
        turso_exec(env,
            "SELECT id, from_admin, body, media_file, media_type, media_ms, seen, created_at
               FROM chat_messages
              WHERE user_id = ? ORDER BY created_at DESC LIMIT ?",
            vec![TursoArg::int(user), TursoArg::int(CHAT_LIMIT)]).await?
    };
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    // Eskisidan yangisiga — suhbat tartibida.
    let items: Vec<Value> = rows.iter().rev()
        .map(|r| chat_msg_public(origin, &row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))))
        .collect();

    // O'qildi. Qator yo'q bo'lsa yangilanadigan narsa ham yo'q.
    // ── IKKITA BELGI (✓✓) ────────────────────────────────
    //
    // TALAB (foydalanuvchi): "yuborilgach Telegramdagidek bitta
    // ✓ tursin va admin o'qiganidan keyingina ✓✓ ikkita bo'lsin".
    //
    // Ya'ni "o'qildi" belgisi SUHBATDOSHNING xabarlariga
    // qo'yiladi: admin ochsa — foydalanuvchining xabarlariga,
    // foydalanuvchi ochsa — adminning xabarlariga.
    let other = if as_admin { 0 } else { 1 };
    let _ = turso_batch(env, &[
        (if as_admin {
            // `AND ... <> 0` SHART: o'qilmagan xabar bo'lmasa qator
            // UMUMAN tegilmaydi va versiya OSHMAYDI. Ushbu shartsiz
            // har ochilish versiyani oshirardi, ilova o'zgarish deb
            // bilib qayta yuklardi, bu yana "o'qildi" ni ishga
            // tushirardi — CHEKSIZ AYLANISH. Yon foydasi: bekorga
            // yozish ham ketmaydi.
            "UPDATE chat_threads SET unread_admin=0,
                    chat_ver=COALESCE(chat_ver,0)+1
               WHERE user_id=? AND COALESCE(unread_admin,0)<>0"
         } else {
            "UPDATE chat_threads SET unread_user=0,
                    chat_ver=COALESCE(chat_ver,0)+1
               WHERE user_id=? AND COALESCE(unread_user,0)<>0"
         },
         vec![TursoArg::int(user)]),
        ("UPDATE chat_messages SET seen=1
           WHERE user_id=? AND from_admin=? AND seen=0",
         vec![TursoArg::int(user), TursoArg::int(other)]),
    ]).await;

    // ── ESKI XABARLARNING BELGISI ─────────────────────────
    //
    // TOPILGAN MASALA: `since` bilan faqat YANGI xabarlar
    // qaytadi. Lekin "o'qildi" belgisi ESKI xabarlarga
    // qo'yiladi — ya'ni ✓ hech qachon ✓✓ ga aylanmasdi.
    //
    // Shu sabab javobga o'z xabarlaringizdan O'QILGANLARINING
    // ro'yxati ham qo'shiladi. U atigi raqamlar ro'yxati, ya'ni
    // arzon.
    // ── O'CHIRILGAN XABARLAR ──────────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi): "admin o'chirgan yozishmalar
    // foydalanuvchi chatidan o'chib ketmayabdi".
    //
    // SABABI: `since` bilan faqat YANGI xabarlar qaytardi. Xabar
    // o'chirilsa esa YANGI narsa paydo bo'lmaydi — ya'ni ilovaga
    // hech qanday xabar bormasdi va o'chirilgan xabar ekranda ham,
    // diskdagi nusxada ham qolib ketardi.
    //
    // YECHIM: javobga suhbatdagi BARCHA xabarlarning raqamlari
    // (`all_ids`) qo'shiladi. Ilova shu ro'yxatda YO'Q xabarlarni
    // o'zidan olib tashlaydi. Bu atigi raqamlar ro'yxati — xabar
    // matni va fayllari qaytadan tashilmaydi.
    //
    // O'qilgan xabarlar ro'yxati (`seen_ids`) ham SHU BITTA
    // so'rovdan chiqadi — ilgari alohida so'rov ketardi, endi
    // bittasi ikkalasiga yetadi.
    let mine = if as_admin { 1 } else { 0 };
    let ids_res = turso_exec(env,
        "SELECT id, from_admin, seen FROM chat_messages
          WHERE user_id=? ORDER BY created_at DESC LIMIT ?",
        vec![TursoArg::int(user), TursoArg::int(CHAT_LIMIT)]).await?;
    let id_cols = ids_res["cols"].as_array().cloned().unwrap_or_default();
    let id_rows = ids_res["rows"].as_array().cloned().unwrap_or_default();
    let mut seen_ids: Vec<String> = Vec::new();
    let mut all_ids: Vec<String> = Vec::new();
    for r in &id_rows {
        let o = row_to_obj(&id_cols, r.as_array().unwrap_or(&vec![]));
        let id = o["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }
        if o["from_admin"].as_i64().unwrap_or(0) == mine
            && o["seen"].as_i64().unwrap_or(0) == 1
        {
            seen_ids.push(id.clone());
        }
        all_ids.push(id);
    }

    ok_nostore(json!({
        "items": items,
        "since": since,
        "seen_ids": seen_ids,
        "all_ids": all_ids,
        "total": all_ids.len(),
    }))
}

/// GET /api/chat — o'z yozishmasi (foydalanuvchi tomoni).
async fn chat_mine(req: &Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    chat_read(env, origin, me, false, since_of(req)).await
}

/// So'rovdagi `?since=<ms>` — faqat shundan keyingi xabarlar.
fn since_of(req: &Request) -> i64 {
    req.url()
        .ok()
        .and_then(|u| {
            u.query_pairs()
                .find(|(k, _)| k == "since")
                .and_then(|(_, v)| v.parse::<i64>().ok())
        })
        .unwrap_or(0)
        .max(0)
}

/// GET /api/chat/unread — profil sahifasidagi NUQTA uchun.
///
/// Ataylab juda kichik javob: bu so'rov tez-tez qilinadi, shu
/// sabab u xabarlarning O'ZINI olib kelmaydi — faqat sonini.
async fn chat_unread(req: &Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);

    if is_admin(&u) {
        // Admin uchun — hamma suhbatlardagi o'qilmaganlar yig'indisi.
        let res = turso_exec(env,
            "SELECT COALESCE(SUM(unread_admin),0) FROM chat_threads",
            vec![]).await?;
        return ok_nostore(json!({"unread": scalar(&res), "admin": true}));
    }

    let res = turso_exec(env,
        "SELECT COALESCE(unread_user,0) FROM chat_threads WHERE user_id=?",
        vec![TursoArg::int(me)]).await?;
    ok_nostore(json!({"unread": scalar(&res), "admin": false}))
}

/// TIZIM nomidan foydalanuvchining yozishmasiga xabar qo'yadi.
///
/// Bloklash sababi shu yo'l bilan yetkaziladi: botdagi xabar bir
/// marta ko'rinib yo'qoladi, yozishmadagi yozuv esa QOLADI —
/// odam blok tugagach (yoki admin ochgach) nima bo'lganini o'qiy
/// oladi.
///
/// Xabar ADMINDAN kelgan deb belgilanadi va foydalanuvchining
/// o'qilmaganlar sanog'ini oshiradi, ya'ni oddiy xabardan hech
/// qanday farqi yo'q.
async fn chat_admin_note(env: &Env, user_id: i64, body: &str) -> Result<()> {
    let text: String = body.trim().chars().take(CHAT_MAX).collect();
    if text.is_empty() || user_id <= 0 {
        return Ok(());
    }
    let now = now_ms();
    turso_batch(env, &[
        ("INSERT INTO chat_messages
            (id,user_id,from_admin,body,media_file,media_type,media_ms,created_at)
          VALUES (?,?,1,?,'','',0,?)",
         vec![
            TursoArg::text(&format!("m{}", random_hex(12))),
            TursoArg::int(user_id), TursoArg::text(&text), TursoArg::int(now),
         ]),
        ("INSERT INTO chat_threads
            (user_id,last_body,last_at,last_from_admin,unread_user,unread_admin,
             chat_ver)
          VALUES (?,?,?,1,1,0,1)
          ON CONFLICT(user_id) DO UPDATE SET
             last_body=excluded.last_body,
             last_at=excluded.last_at,
             last_from_admin=1,
             unread_user=unread_user+1,
             chat_ver=COALESCE(chat_threads.chat_ver,0)+1",
         vec![TursoArg::int(user_id), TursoArg::text(&text), TursoArg::int(now)]),
    ]).await?;
    Ok(())
}

/// POST /api/chat — xabar yuborish.
///
/// Foydalanuvchi yozsa — adminga; admin `user_id` bilan yozsa —
/// o'sha odamga.
async fn chat_send(mut req: Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    if u["is_banned"].as_i64().unwrap_or(0) != 0 {
        return json_resp(&json!({"error": "Sizga yozish taqiqlangan"}), 403);
    }

    let b: Value = req.json().await.unwrap_or(json!({}));
    let body = b["body"].as_str().unwrap_or("").trim().to_string();

    // ── RASM/VIDEO ────────────────────────────────────────────
    //
    // TALAB: "muammoning rasmi yoki videosini yuborsa bo'ladigan
    // qil". Fayl B2'ga ILOVADAN to'g'ridan yuklanadi (admin
    // panelidagi video yuklash bilan bir xil yo'l), bu yerga esa
    // faqat NOMI keladi.
    let media_file = bare_name(b["media_file"].as_str().unwrap_or("")).trim().to_string();
    let media_type = match b["media_type"].as_str().unwrap_or("") {
        "image" => "image",
        "video" => "video",
        // TALAB (foydalanuvchi): "chatda ovozli xabar yuborish
        // tizimini ham qo'sh".
        "voice" => "voice",
        _ => "",
    };
    // Ovozli xabarning uzunligi — ilova yozib olganda o'lchaydi.
    // 0 dan kichik yoki bemaza katta qiymat qabul qilinmaydi.
    let media_ms = b["media_ms"].as_i64().unwrap_or(0).clamp(0, 3_600_000);
    // Videoning kadri — YUBORUVCHI yasagan kichik JPEG. Faqat
    // fayl NOMI keladi (yo'l emas), xuddi `media_file` kabi.
    let media_thumb = bare_name(b["media_thumb"].as_str().unwrap_or("")).trim().to_string();
    // Nomi bor-u turi yo'q (yoki aksincha) — yaroqsiz juftlik.
    let has_media = !media_file.is_empty() && !media_type.is_empty();
    if body.is_empty() && !has_media {
        return json_resp(&json!({"error": "Xabar bo'sh"}), 400);
    }
    // Uzunlik BELGI bo'yicha (bayt emas): o'zbekcha harflar ikki
    // bayt egallaydi va bayt bilan kesilsa yozuv o'rtasidan
    // uzilib qolardi.
    let body: String = body.chars().take(CHAT_MAX).collect();

    // Suhbat KIMNIKI: admin boshqa odamga yozsa — o'shaniki.
    // ── ADMIN O'ZIGA O'ZI HAM YOZA OLADI ─────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: "admin o'ziga o'zi xabar
    // yuborish ishlamayapti, test qilish qiyin bo'lyapti"):
    // `user_id` berilmasa so'rov XATO bilan qaytarilardi.
    //
    // Aslida javob oddiy: `user_id` berilmagan bo'lsa, gap
    // YOZAYOTGAN odamning o'z suhbati haqida ketyapti — admin
    // uchun ham xuddi shunday. Ya'ni admin profil sahifasidagi
    // "Admin bilan bog'lanish" ni ochsa, u O'Z suhbatini
    // ko'radi va o'ziga yozib, tizimni bemalol sinab ko'ra
    // oladi.
    let admin = is_admin(&u);
    let target = match b["user_id"].as_i64() {
        Some(t) if admin && t > 0 => t,
        _ => me,
    };
    // O'ziga o'zi yozganda xabar "admindan" deb belgilanmaydi:
    // aks holda suhbatda ikkala tomon ham o'ng tarafda turib,
    // sinov ma'nosini yo'qotardi.
    let from_admin = admin && target != me;

    let now = now_ms();
    let id = format!("m{}", random_hex(12));

    // Xabar va suhbat qatori BITTA paketda: ikkovi ham yozilsin
    // yoki hech qaysisi yozilmasin.
    //
    // O'QILMAGANLAR: admin yozsa foydalanuvchiniki oshadi, aksincha
    // ham shunday. `ON CONFLICT` — suhbat birinchi marta
    // boshlanayotgan bo'lsa qator o'zi yaratiladi.
    let (inc_user, inc_admin) = if from_admin { (1, 0) } else { (0, 1) };
    // Ro'yxatda matnsiz rasm/video ham ko'rinib tursin.
    let label = if !body.is_empty() {
        body.clone()
    } else if media_type == "video" {
        "Video".to_string()
    } else if media_type == "voice" {
        "Ovozli xabar".to_string()
    } else {
        "Rasm".to_string()
    };
    turso_batch(env, &[
        ("INSERT INTO chat_messages
            (id,user_id,from_admin,body,media_file,media_type,media_ms,
             media_thumb,created_at)
          VALUES (?,?,?,?,?,?,?,?,?)",
         vec![
            TursoArg::text(&id), TursoArg::int(target),
            TursoArg::int(if from_admin { 1 } else { 0 }),
            TursoArg::text(&body),
            TursoArg::text(if has_media { &media_file } else { "" }),
            TursoArg::text(if has_media { media_type } else { "" }),
            TursoArg::int(if has_media { media_ms } else { 0 }),
            // Kadr FAQAT video uchun ma'noli.
            TursoArg::text(if has_media && media_type == "video" {
                &media_thumb
            } else {
                ""
            }),
            TursoArg::int(now),
         ]),
        ("INSERT INTO chat_threads
            (user_id,last_body,last_at,last_from_admin,unread_user,unread_admin,
             chat_ver)
          VALUES (?,?,?,?,?,?,1)
          ON CONFLICT(user_id) DO UPDATE SET
             last_body=excluded.last_body,
             last_at=excluded.last_at,
             last_from_admin=excluded.last_from_admin,
             unread_user=unread_user+excluded.unread_user,
             unread_admin=unread_admin+excluded.unread_admin,
             chat_ver=COALESCE(chat_threads.chat_ver,0)+1",
         vec![
            TursoArg::int(target), TursoArg::text(&label), TursoArg::int(now),
            TursoArg::int(if from_admin { 1 } else { 0 }),
            TursoArg::int(inc_user), TursoArg::int(inc_admin),
         ]),
    ]).await?;

    created(json!({
        "id": id,
        "from_admin": from_admin,
        "body": body,
        "media_url": if has_media {
            format!("{origin}/api/media/{media_file}")
        } else {
            String::new()
        },
        "media_type": if has_media { media_type } else { "" },
        "media_ms": if has_media { media_ms } else { 0 },
        "media_thumb_url": if has_media && media_type == "video"
            && !media_thumb.is_empty() {
            format!("{origin}/api/media/{media_thumb}")
        } else {
            String::new()
        },
        "seen": false,
        "created_at": now,
    }))
}

// ═══════════════════════════════════════════════════════════════
//  UZOQ KUTISH (LONG POLLING) — XABAR DARHOL YETIB BORSIN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "supportga yuborilgan xabar tez
// kelmayapti; Telegram kodini topib, uning xabar jo'natish
// tizimi qanday ishlashini aniqla va huddi Telegramdek tez
// ishlaydigan qilib ber".
//
// ── TELEGRAM QANDAY QILADI ─────────────────────────────────────
//
// Telegram mijozlari (MTProto) serverga DOIMIY ulanib turadi va
// server yangi xabarni O'ZI itaradi — mijoz so'ramaydi.
//
// Telegramning O'Z Bot API'si esa xuddi shu tezlikni oddiy HTTP
// ustida beradi: `getUpdates` so'rovi `timeout` bilan yuboriladi
// va SERVER javobni darhol bermaydi — yangi xabar paydo
// bo'lgunicha so'rovni OCHIQ ushlab turadi. Xabar kelishi bilan
// javob qaytadi; hech narsa bo'lmasa muddat tugagach bo'sh javob
// beradi va mijoz qaytadan so'raydi.
//
// Bu yerda aynan o'sha usul.
//
// ── NEGA WEBSOCKET EMAS ────────────────────────────────────────
//
// Cloudflare Worker'da haqiqiy "server itarishi" uchun Durable
// Objects kerak — alohida xizmat va butun tizimni qayta qurish.
// Uzoq kutish esa oddiy HTTP so'rovi: hozirgi tizimga hech narsa
// qo'shmaydi, natijasi foydalanuvchi uchun bir xil.
//
// ── ARZONLIGI ──────────────────────────────────────────────────
//
// Kutish paytida bazadan FAQAT BITTA SON so'raladi
// (`MAX(created_at)`), xabarlarning o'zi emas. Yangi narsa
// topilsagina ilova ro'yxatni so'raydi — uni ham `since` bilan,
// ya'ni faqat yangilarini.
//
// So'rovlar soni ham KAMAYADI: ilgari har 10 soniyada bitta
// so'rov ketardi (daqiqasiga 6 ta), endi har ~19 soniyada bitta
// (daqiqasiga 3 ta) — lekin xabar 10 soniya emas, ~1 soniyada
// yetib boradi.

/// Bir so'rovda eng ko'pi shuncha kutamiz.
///
/// Worker'da bitta so'rovdan chiqadigan ichki so'rovlar soni
/// chegaralangan, shu sabab tekshiruvlar soni ham chegarali:
/// 16 ta tekshiruv x 1.2 soniya = ~19 soniya.
const CHAT_WAIT_TICKS: u32 = 16;
const CHAT_WAIT_STEP_MS: u64 = 1200;

/// GET /api/chat/wait?since=<ms>[&user_id=N][&all=1]
async fn chat_wait(req: &Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let admin = is_admin(&u);

    let url = req.url()?;
    let q = |k: &str| -> String {
        url.query_pairs()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.to_string())
            .unwrap_or_default()
    };
    let since: i64 = q("since").parse().unwrap_or(0);
    // Admin butun ro'yxatni kuzatishi mumkin (yangi suhbat ham
    // paydo bo'lishi mumkin), oddiy foydalanuvchi esa faqat
    // O'Z suhbatini. Bu tekshiruv SERVERDA — o'zgartirilgan ilova
    // bilan begona odam boshqalarning suhbatini kuzata olmaydi.
    let watch_all = admin && q("all") == "1";
    let target = match q("user_id").parse::<i64>() {
        Ok(t) if admin && t > 0 => t,
        _ => me,
    };

    // ── NIMA KUZATILADI ──────────────────────────────────
    //
    // Ikkita son: eng oxirgi xabar vaqti VA o'qilgan xabarlar
    // soni. Ikkinchisi kerak, chunki suhbatdosh eski xabarni
    // o'qiganda yangi xabar paydo bo'lmaydi — faqat belgi
    // o'zgaradi (✓ -> ✓✓), va usiz ilova buni sezmasdi.
    //
    // UCHINCHI son: suhbatdagi xabarlar SONI. U o'chirish uchun
    // kerak — admin xabarni o'chirsa eng oxirgi vaqt ORTMAYDI
    // (aksincha kamayadi), shu sabab usiz ilova o'chirishni
    // umuman sezmasdi va xabar ekranda qolib ketardi.
    let seen_before: i64 = q("seen").parse().unwrap_or(-1);
    let count_before: i64 = q("count").parse().unwrap_or(-1);
    let oldest_before: i64 = q("oldest").parse().unwrap_or(-1);

    // ══════════════════════════════════════════════════════════
    //  VERSIYA BO'YICHA KUTISH — 200 QATOR EMAS, 1 QATOR
    // ══════════════════════════════════════════════════════════
    //
    // TALAB (foydalanuvchi): "harajat qancha kam bo'lsa shunchalik
    // yaxshi".
    //
    // ── ILGARIGI NARX ─────────────────────────────────────────
    //
    // Har tekshiruvda suhbatning OXIRGI 200 XABARI o'qilardi
    // (`LIMIT ?` = CHAT_LIMIT), undan esa atigi 4 ta son
    // hisoblanardi. Bitta kutish so'rovi = 16 tekshiruv, ya'ni
    // ~3 200 qator. Chat ekrani ochiq bitta odam sekundiga ~168
    // qator o'qirdi — HECH NARSA bo'lmasa ham. Bu yuklama BEKOR
    // turgan foydalanuvchilar soniga to'g'ri proportsional o'sardi
    // va Turso kvotasining asosiy yeyuvchisi edi.
    //
    // ── ENDI ──────────────────────────────────────────────────
    //
    // `chat_threads.chat_ver` — suhbatda BIROR NARSA o'zgarganda
    // (xabar qo'shildi / o'qildi / o'chirildi) bittaga oshadigan
    // son. Tekshiruv uni ASOSIY KALIT bo'yicha bitta qatordan
    // o'qiydi: 200 qator -> 1 qator, ya'ni ~200 barobar arzon.
    //
    // ── BU ANIQROQ HAM ────────────────────────────────────────
    //
    // Eski usul o'zgarishni 4 ta sonning TAXMINI bilan sezardi va
    // chetki hollarda yanglishardi (masalan o'rtadagi xabar
    // o'chirilsa son o'zgarmasligi mumkin — shu sabab `oldest` ham
    // qo'shilgan edi). Versiya esa o'zgarishni O'TKAZIB YUBORMAYDI:
    // u o'zgarish TURINI emas, o'zgarish BO'LGANINI sanaydi.
    //
    // ── ESKI ILOVALAR UZILMAYDI ───────────────────────────────
    //
    // Eski APK `ver` yubormaydi — unga eski (200 qatorli) yo'l
    // o'sha holicha ishlaydi. Yangi APK `ver` yuboradi va arzon
    // yo'ldan o'tadi.
    let ver_before: i64 = q("ver").parse().unwrap_or(-1);
    if ver_before >= 0 {
        let (vsql, vargs): (&str, Vec<TursoArg>) = if watch_all {
            // Admin butun ro'yxatni kuzatadi. `COUNT(*)` qo'shilgani
            // MUHIM: yangi suhbat paydo bo'lganda yig'indi o'zgarmay
            // qolishi mumkin, qatorlar soni esa albatta o'zgaradi.
            ("SELECT COALESCE(SUM(chat_ver),0) + COUNT(*) FROM chat_threads",
             vec![])
        } else {
            // Bitta qator, asosiy kalit bo'yicha — eng arzon o'qish.
            ("SELECT COALESCE((SELECT chat_ver FROM chat_threads
                                WHERE user_id=?),0)",
             vec![TursoArg::int(target)])
        };
        for i in 0..CHAT_WAIT_TICKS {
            if i > 0 {
                Delay::from(core::time::Duration::from_millis(CHAT_WAIT_STEP_MS)).await;
            }
            let res = turso_exec(env, vsql, vargs.clone()).await?;
            let ver = scalar(&res);
            if ver != ver_before {
                return ok_nostore(json!({"new": true, "ver": ver}));
            }
        }
        return ok_nostore(json!({"new": false, "ver": ver_before}));
    }

    let (sql, args): (&str, Vec<TursoArg>) = if watch_all {
        ("SELECT COALESCE(MAX(last_at),0), 0, COUNT(*), 0 FROM chat_threads", vec![])
    } else {
        // Ilova ekranda eng ko'pi CHAT_LIMIT ta xabar saqlaydi, shu
        // sabab bu yerda ham AYNAN o'sha oyna sanaladi. Aks holda
        // uzun yozishmada sonlar hech qachon teng chiqmasdi va
        // kutish so'rovi darhol qaytaverardi (bo'sh aylanish).
        ("SELECT COALESCE(MAX(created_at),0),
                 COUNT(CASE WHEN seen=1 THEN 1 END),
                 COUNT(*),
                 COALESCE(MIN(created_at),0)
            FROM (SELECT created_at, seen FROM chat_messages
                   WHERE user_id=? ORDER BY created_at DESC LIMIT ?)",
         vec![TursoArg::int(target), TursoArg::int(CHAT_LIMIT)])
    };

    let cell = |res: &Value, i: usize| -> i64 {
        let c = &res["rows"][0][i];
        match c["value"].as_str() {
            Some(v) => v.parse::<i64>().unwrap_or(0),
            None => c.as_i64().unwrap_or(0),
        }
    };

    for i in 0..CHAT_WAIT_TICKS {
        // Birinchi tekshiruv KUTMASDAN: xabar allaqachon kelgan
        // bo'lsa javob darhol qaytadi.
        if i > 0 {
            Delay::from(core::time::Duration::from_millis(CHAT_WAIT_STEP_MS)).await;
        }
        let res = turso_exec(env, sql, args.clone()).await?;
        let last = cell(&res, 0);
        let seen = cell(&res, 1);
        let count = cell(&res, 2);
        let oldest = cell(&res, 3);
        if last > since
            || (seen_before >= 0 && seen != seen_before)
            || (count_before >= 0 && count != count_before)
            // Oynadagi ENG ESKI xabar vaqti. Uzun yozishmada
            // o'rtadagi xabar o'chirilsa son o'zgarmaydi (o'rniga
            // bittasi pastdan ko'tariladi) — lekin bu vaqt
            // o'zgaradi.
            || (oldest_before >= 0 && oldest != oldest_before)
        {
            return ok_nostore(json!({
                "new": true, "last": last, "seen": seen,
                "count": count, "oldest": oldest,
            }));
        }
    }
    ok_nostore(json!({
        "new": false,
        "last": since,
        "seen": seen_before.max(0),
        "count": count_before.max(0),
        "oldest": oldest_before.max(0),
    }))
}

/// GET /api/chat/threads — ADMIN uchun barcha suhbatlar.
///
/// Yangi xabar YUQORIDA (`last_at DESC`) va har bir qatorda odamning
/// ismi va rasmi — foydalanuvchi talabi: "huddi Telegram chatidek".
async fn chat_threads(req: &Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }

    let res = turso_exec(env,
        "SELECT t.user_id, t.last_body, t.last_at, t.last_from_admin,
                t.unread_admin,
                u.first_name AS first_name, u.username AS username,
                u.avatar_file AS avatar_file
           FROM chat_threads t
           LEFT JOIN users_db u ON u.id = t.user_id
          ORDER BY t.last_at DESC
          LIMIT 200",
        vec![]).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows.iter().map(|r| {
        let o = row_to_obj(&cols, r.as_array().unwrap_or(&vec![]));
        let uid = o["user_id"].as_i64().unwrap_or(0);
        let avatar = o["avatar_file"].as_str().unwrap_or("");
        let photo = if avatar.is_empty() {
            format!("{origin}/api/avatar/{uid}")
        } else {
            format!("{origin}/api/image/{avatar}")
        };
        json!({
            "user_id": uid,
            "first_name": o["first_name"].as_str().unwrap_or(""),
            "username": o["username"].as_str().unwrap_or(""),
            "photo_url": photo,
            "last_body": o["last_body"].as_str().unwrap_or(""),
            "last_at": o["last_at"].as_i64().unwrap_or(0),
            "last_from_admin": o["last_from_admin"].as_i64().unwrap_or(0) != 0,
            "unread": o["unread_admin"].as_i64().unwrap_or(0),
        })
    }).collect();

    ok_nostore(json!({"items": items}))
}

/// GET /api/chat/thread/:user_id — ADMIN bitta odamning suhbatini
/// o'qiydi.
async fn chat_one(
    req: &Request, env: &Env, origin: &str, user: i64, since: i64,
) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    chat_read(env, origin, user, true, since).await
}

// ── ADMIN O'CHIRA OLADI ───────────────────────────────────────
//
// TALAB (foydalanuvchi): "admin panelda kelgan xabarni va chatni
// butunlay o'chirib tashlashi mumkin bo'lsin".
//
// Bu yerda "belgilash" emas, HAQIQIY o'chirish: yozishma izohdan
// farqli o'laroq hech narsani ushlab turmaydi va admin uni
// butunlay yo'q qilishni so'ragan.

/// DELETE /api/chat/message/:id — bitta xabar.
async fn chat_del_message(req: &Request, env: &Env, id: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    // ── B2'DAGI FAYL HAM O'CHADI ─────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi savoli: "yuborilgan video,
    // rasm yoki ovozli xabarni o'chirganda B2'dan ham o'chadimi").
    //
    // O'CHMASDI: faqat bazadagi qator o'chirilardi. Fayl esa
    // B2'da qolib ketardi va uni endi HECH KIM o'chira olmasdi —
    // unga ishora qilgan yagona qator ham yo'q bo'lgan bo'lardi.
    // Ya'ni fayl abadiy yotib, ombor uchun pul yeb turardi.
    let row = turso_exec(env,
        "DELETE FROM chat_messages WHERE id=? RETURNING user_id, media_file,
                media_thumb",
        vec![TursoArg::text(id)]).await?;
    let Some(r) = first_row(&row) else {
        return json_resp(&json!({"error": "Xabar topilmadi"}), 404);
    };
    let owner = r["user_id"].as_i64().unwrap_or(0);
    let file = r["media_file"].as_str().unwrap_or("");
    if !file.is_empty() {
        b2_delete(env, file).await;
    }
    // Videoning kadri ham yetim qolmasin: unga ishora qilgan
    // yagona qator hozirgina o'chdi.
    let thumb = r["media_thumb"].as_str().unwrap_or("");
    if !thumb.is_empty() {
        b2_delete(env, thumb).await;
    }

    // Suhbat qatoridagi "oxirgi xabar" endi boshqa bo'lishi
    // mumkin — u qayta hisoblanadi. Hech narsa qolmasa suhbatning
    // o'zi ham olib tashlanadi.
    refresh_thread(env, owner).await;
    ok_nostore(json!({"ok": true}))
}

/// POST /api/chat/messages/delete — BIR NECHTA xabarni birdaniga.
///
/// TALAB (foydalanuvchi): "xabarni bittalab emas, ustiga bosib
/// turadi — xabar tanlandi, keyin qolganlarini qo'lda tanlab
/// o'chirsa bo'ladigan qil; va hammasini bittada tanlab
/// o'chiradigan tugma qo'sh".
///
/// NEGA ALOHIDA YO'L: 200 ta xabar tanlansa, har biri uchun
/// alohida so'rov yuborish 200 ta so'rov degani — bu sekin va
/// yarmida uzilib qolsa yozishma yarim o'chgan holatda qolardi.
/// Bu yerda esa hammasi BITTA so'rovda va BITTA paketda
/// o'chiriladi.
///
/// FAQAT ADMIN — foydalanuvchi o'z xabarini ham o'chira olmaydi
/// (foydalanuvchi talabi).
async fn chat_del_many(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    let b: Value = req.json().await.unwrap_or(json!({}));
    let ids: Vec<String> = b["ids"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .take(CHAT_LIMIT as usize)
                .collect()
        })
        .unwrap_or_default();
    if ids.is_empty() {
        return json_resp(&json!({"error": "Hech narsa tanlanmadi"}), 400);
    }

    // `IN (?,?,...)` — o'rin egalari soni ro'yxat uzunligicha.
    let holes = vec!["?"; ids.len()].join(",");
    let args: Vec<TursoArg> = ids.iter().map(|i| TursoArg::text(i)).collect();

    // Qaysi suhbatlarga tegdi — o'chirishdan OLDIN bilib olamiz,
    // keyin ularning oxirgi xabari qayta hisoblanadi.
    let owners_res = turso_exec(env,
        &format!("SELECT DISTINCT user_id FROM chat_messages WHERE id IN ({holes})"),
        args.clone()).await?;
    let owners: Vec<i64> = owners_res["rows"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| r.as_array())
                .filter_map(|r| r.first())
                .filter_map(|c| c["value"].as_str().and_then(|v| v.parse::<i64>().ok()))
                .collect()
        })
        .unwrap_or_default();

    // B2'dagi fayllar ham o'chiriladi (yuqoridagi izohga qarang).
    let files_res = turso_exec(env,
        &format!("SELECT media_file, media_thumb FROM chat_messages
                   WHERE id IN ({holes})"),
        args.clone()).await?;
    // Qatordagi HAR IKKI ustun olinadi: faylning o'zi va kadri.
    let files: Vec<String> = files_res["rows"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| r.as_array())
                .flat_map(|r| r.iter())
                .filter_map(|c| c["value"].as_str())
                .filter(|v| !v.is_empty())
                .map(|v| v.to_string())
                .collect()
        })
        .unwrap_or_default();

    turso_exec(env,
        &format!("DELETE FROM chat_messages WHERE id IN ({holes})"),
        args).await?;

    for f in files {
        b2_delete(env, &f).await;
    }

    for o in owners {
        refresh_thread(env, o).await;
    }
    ok_nostore(json!({"ok": true, "count": ids.len()}))
}

/// DELETE /api/chat/thread/:user_id — butun yozishma.
async fn chat_del_thread(req: &Request, env: &Env, user: i64) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    // B2'dagi fayllar ham o'chiriladi (`chat_del_message`
    // izohiga qarang).
    let files_res = turso_exec(env,
        "SELECT media_file, media_thumb FROM chat_messages
          WHERE user_id=?",
        vec![TursoArg::int(user)]).await?;
    // Qatordagi HAR IKKI ustun olinadi: faylning o'zi va kadri.
    let files: Vec<String> = files_res["rows"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| r.as_array())
                .flat_map(|r| r.iter())
                .filter_map(|c| c["value"].as_str())
                .filter(|v| !v.is_empty())
                .map(|v| v.to_string())
                .collect()
        })
        .unwrap_or_default();

    turso_batch(env, &[
        ("DELETE FROM chat_messages WHERE user_id=?", vec![TursoArg::int(user)]),
        ("DELETE FROM chat_threads WHERE user_id=?", vec![TursoArg::int(user)]),
    ]).await?;

    for f in files {
        b2_delete(env, &f).await;
    }
    ok_nostore(json!({"ok": true}))
}

/// Suhbat qatorini xabarlarga qarab qayta hisoblaydi.
async fn refresh_thread(env: &Env, user: i64) {
    let last = turso_exec(env,
        "SELECT body, media_type, created_at, from_admin FROM chat_messages
          WHERE user_id=? ORDER BY created_at DESC LIMIT 1",
        vec![TursoArg::int(user)]).await;
    let row = last.ok().and_then(|r| first_row(&r));
    let Some(r) = row else {
        // Bitta ham xabar qolmadi — suhbat ro'yxatdan chiqadi.
        let _ = turso_exec(env, "DELETE FROM chat_threads WHERE user_id=?",
            vec![TursoArg::int(user)]).await;
        return;
    };
    let body = r["body"].as_str().unwrap_or("");
    let mtype = r["media_type"].as_str().unwrap_or("");
    // Matnsiz rasm/video uchun ro'yxatda yozuv ko'rinib tursin.
    let label = if !body.is_empty() {
        body.to_string()
    } else if mtype == "video" {
        "Video".to_string()
    } else if mtype == "image" {
        "Rasm".to_string()
    } else if mtype == "voice" {
        "Ovozli xabar".to_string()
    } else {
        String::new()
    };
    // O'QILMAGANLAR SONI ham qayta hisoblanadi.
    //
    // TOPILGAN XATO: o'qilmagan xabar o'chirilsa, profildagi
    // NUQTA yonib turaverardi — hisoblagich eski qiymatda
    // qolgani uchun. Endi u har safar haqiqiy xabarlarga qarab
    // sanaladi, ya'ni o'chirilgan xabar hisobdan ham chiqadi.
    let _ = turso_exec(env,
        "UPDATE chat_threads SET last_body=?, last_at=?, last_from_admin=?,
                unread_user = (SELECT COUNT(*) FROM chat_messages
                                WHERE user_id=? AND from_admin=1 AND seen=0),
                unread_admin = (SELECT COUNT(*) FROM chat_messages
                                 WHERE user_id=? AND from_admin=0 AND seen=0),
                chat_ver = COALESCE(chat_ver,0)+1
          WHERE user_id=?",
        vec![
            TursoArg::text(&label),
            TursoArg::int(r["created_at"].as_i64().unwrap_or(0)),
            TursoArg::int(r["from_admin"].as_i64().unwrap_or(0)),
            TursoArg::int(user),
            TursoArg::int(user),
            TursoArg::int(user),
        ]).await;
}

// ══════════════════════════════════════════════════════════════
//  SHIKOYATLAR
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "izohning o'ng chetiga 3ta nuqta qo'y,
// bosganda shikoyat qilish chiqsin; pastdan shikoyat yozish
// oynasi ochilsin. Admin panelida shikoyatlar bo'limida shikoyat
// qayerdan kelgani, shikoyat qilingan izoh va shikoyat
// qiluvchining xabari tursin; tagida Tekshirish, Xabar yuborish
// va Tozalash tugmalari bo'lsin".
//
// ── QANDAY QURILGAN ─────────────────────────────────────────
//
// Shikoyat — O'ZGARMAS yozuv: kelgan paytdagi izoh matni va
// muallifi bilan birga saqlanadi. Shu sabab izoh keyin
// o'chirilsa ham admin nimadan shikoyat qilinganini ko'radi.
//
// Ikki qoida suiiste'molni to'xtatadi:
//   * BIR ODAM — BIR MARTA (bazadagi birlamchi indeks);
//   * soatiga eng ko'pi REPORT_HOURLY ta shikoyat.
// Ikkovi ham SERVERDA: o'zgartirilgan ilova ham aylanib o'ta
// olmaydi.

/// Shikoyat matnining eng ko'p uzunligi (BELGI, bayt emas).
const REPORT_MAX: usize = 2000;

/// Eng kam uzunlik. Foydalanuvchidan "batafsil ma'lumot"
/// so'ralyapti — bitta harf yoki nuqta shikoyatni tekshirishga
/// yaramaydi.
const REPORT_MIN: usize = 10;

/// Bir odam bir soatda nechta shikoyat yubora oladi.
const REPORT_HOURLY: i64 = 10;

/// Bir sahifada nechta shikoyat (admin ro'yxati).
const REPORT_PAGE: i64 = 30;

/// POST /api/reports — shikoyat yuborish.
///
/// Tanasi: `{"kind":"comment","target_id":"c...","reason":"..."}`.
async fn report_add(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    if u["is_banned"].as_i64().unwrap_or(0) != 0 {
        return json_resp(&json!({"error": "Sizga yozish taqiqlangan"}), 403);
    }

    let b: Value = req.json().await.unwrap_or(json!({}));
    let target = b["target_id"].as_str().unwrap_or("").trim().to_string();
    if target.is_empty() {
        return json_resp(&json!({"error": "Nimaga shikoyat qilinayotgani noma'lum"}), 400);
    }
    let reason = b["reason"].as_str().unwrap_or("").trim().to_string();
    if reason.chars().count() < REPORT_MIN {
        return json_resp(&json!({
            "error": "Iltimos, shikoyat sababini batafsilroq yozing"
        }), 400);
    }
    // Uzunlik BELGI bo'yicha kesiladi (bayt emas): o'zbekcha
    // harflar ikki bayt egallaydi va bayt bilan kesilsa yozuv
    // o'rtasidan uzilib qolardi.
    let reason: String = reason.chars().take(REPORT_MAX).collect();

    // ── SOATLIK CHEGARA ──────────────────────────────────────
    let hour_ago = now_ms() - 3_600_000;
    let recent = turso_exec(env,
        "SELECT COUNT(*) FROM reports_db WHERE reporter_id=? AND created_at>?",
        vec![TursoArg::int(me), TursoArg::int(hour_ago)]).await?;
    if scalar(&recent) >= REPORT_HOURLY {
        return json_resp(&json!({
            "error": "Juda ko'p shikoyat yubordingiz. Birozdan keyin urinib ko'ring"
        }), 429);
    }

    // ── NIMAGA SHIKOYAT: NUSXASINI OLAMIZ ────────────────────
    //
    // Matn va muallif SHIKOYAT KELGAN PAYTDAGI holatda saqlanadi
    // — keyin o'chirilsa ham admin nimadan shikoyat qilinganini
    // ko'radi.
    let c = turso_exec(env,
        "SELECT id, user_id, body, anime_id, season_id
           FROM comments_db WHERE id=?",
        vec![TursoArg::text(&target)]).await?;
    let Some(row) = first_row(&c) else {
        return json_resp(&json!({"error": "Izoh topilmadi"}), 404);
    };
    let author = row["user_id"].as_i64().unwrap_or(0);
    if author == me {
        return json_resp(&json!({
            "error": "O'z izohingizga shikoyat qila olmaysiz"
        }), 400);
    }

    // ── BIR ODAM — BIR MARTA ─────────────────────────────────
    //
    // Bazada birlamchi indeks ham bor, lekin bu yerdagi tekshiruv
    // foydalanuvchiga TUSHUNARLI javob beradi (baza xatosi emas).
    let dup = turso_exec(env,
        "SELECT COUNT(*) FROM reports_db
          WHERE kind=? AND target_id=? AND reporter_id=?",
        vec![TursoArg::text("comment"), TursoArg::text(&target), TursoArg::int(me)]).await?;
    if scalar(&dup) > 0 {
        return json_resp(&json!({
            "error": "Siz bu izohga allaqachon shikoyat qilgansiz"
        }), 409);
    }

    turso_exec(env,
        "INSERT INTO reports_db
            (id,kind,target_id,target_body,target_user_id,
             anime_id,season_id,reporter_id,reason,created_at)
         VALUES (?,?,?,?,?,?,?,?,?,?)",
        vec![
            TursoArg::text(&format!("r{}", random_hex(12))),
            TursoArg::text("comment"),
            TursoArg::text(&target),
            TursoArg::text(row["body"].as_str().unwrap_or("")),
            TursoArg::int(author),
            TursoArg::int(row["anime_id"].as_i64().unwrap_or(0)),
            TursoArg::int(row["season_id"].as_i64().unwrap_or(0)),
            TursoArg::int(me),
            TursoArg::text(&reason),
            TursoArg::int(now_ms()),
        ]).await?;

    ok_nostore(json!({"ok": true}))
}

/// Shikoyat qatorini ilova kutgan ko'rinishga aylantiradi.
fn report_public(origin: &str, r: &Value) -> Value {
    let photo = |uid: i64, file: &str| -> String {
        if file.is_empty() {
            format!("{origin}/api/avatar/{uid}")
        } else {
            format!("{origin}/api/image/{file}")
        }
    };
    let rep_id = r["reporter_id"].as_i64().unwrap_or(0);
    let tgt_id = r["target_user_id"].as_i64().unwrap_or(0);
    json!({
        "id": r["id"].as_str().unwrap_or(""),
        "kind": r["kind"].as_str().unwrap_or("comment"),
        "target_id": r["target_id"].as_str().unwrap_or(""),
        "target_body": r["target_body"].as_str().unwrap_or(""),
        "anime_id": r["anime_id"].as_i64().unwrap_or(0),
        "season_id": r["season_id"].as_i64().unwrap_or(0),
        "reason": r["reason"].as_str().unwrap_or(""),
        "created_at": r["created_at"].as_i64().unwrap_or(0),
        // Shikoyat qilingan izohning muallifi.
        "target_user": {
            "id": tgt_id,
            "first_name": r["t_first"].as_str().unwrap_or(""),
            "username": r["t_username"].as_str().unwrap_or(""),
            "photo_url": photo(tgt_id, r["t_avatar"].as_str().unwrap_or("")),
        },
        // Shikoyat qiluvchi — "Xabar yuborish" tugmasi shu odamga
        // yozadi.
        "reporter": {
            "id": rep_id,
            "first_name": r["r_first"].as_str().unwrap_or(""),
            "username": r["r_username"].as_str().unwrap_or(""),
            "photo_url": photo(rep_id, r["r_avatar"].as_str().unwrap_or("")),
        },
        // Izoh HALI HAM turibdimi. `false` bo'lsa admin ro'yxatda
        // "izoh o'chirilgan" deb ko'radi va bekorga qidirmaydi.
        "target_alive": r["alive"].as_i64().unwrap_or(0) != 0,
    })
}

/// GET /api/admin/reports?page=N — ADMIN uchun ro'yxat.
///
/// Yangi shikoyat tepada. Bitta so'rovda hammasi keladi: shikoyat,
/// shikoyat qiluvchi va izoh muallifi — ilgari bunday ekranlar har
/// bir qator uchun alohida so'rov qilardi.
async fn admin_reports(req: &Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    let url = req.url()?;
    let page: i64 = url.query_pairs()
        .find(|(k, _)| k == "page")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0)
        .max(0);

    let res = turso_exec(env,
        "SELECT p.id, p.kind, p.target_id, p.target_body, p.target_user_id,
                p.anime_id, p.season_id, p.reporter_id, p.reason, p.created_at,
                t.first_name AS t_first, t.username AS t_username,
                t.avatar_file AS t_avatar,
                r.first_name AS r_first, r.username AS r_username,
                r.avatar_file AS r_avatar,
                (SELECT COUNT(*) FROM comments_db c WHERE c.id = p.target_id)
                  AS alive
           FROM reports_db p
           LEFT JOIN users_db t ON t.id = p.target_user_id
           LEFT JOIN users_db r ON r.id = p.reporter_id
          ORDER BY p.created_at DESC
          LIMIT ? OFFSET ?",
        vec![TursoArg::int(REPORT_PAGE), TursoArg::int(page * REPORT_PAGE)]).await?;

    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows.iter()
        .map(|r| report_public(origin, &row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))))
        .collect();

    // Tugmadagi son uchun — umumiy hisob.
    let total = turso_exec(env, "SELECT COUNT(*) FROM reports_db", vec![]).await?;

    ok_nostore(json!({
        "items": items,
        "page": page,
        "total": scalar(&total),
        "has_more": items.len() as i64 >= REPORT_PAGE,
    }))
}

/// GET/POST /api/admin/app — ILOVA VERSIYASI VA IMZOSI.
///
/// TALAB (foydalanuvchi): "admin panelga versiya raqam yozadigan
/// bo'lim qo'sh, ya'ni versiya raqamini yozaman 0.0.9+9 yoki
/// 0.0.9 qilib yozaman. Worker esa shu va shundan katta
/// versiyalarda ishlaydi, agar versiya past bo'lsa ishlamaydi" va
/// "worker ilovaning haqiqiyligini tekshirishi kerak".
///
/// GET — hozirgi holat. POST — yangi qiymat.
///
/// ── IMZO ODDIY QO'YILADI ────────────────────────────────────
///
/// Admin panelni O'Z ilovasidan ochadi, ya'ni uning so'rovi
/// AYNAN o'sha ilovaning imzosi bilan keladi. Shu sabab
/// `{"trust_me": true}` yuborilsa — server so'rov sarlavhasidagi
/// hash'ni kutilganlar ro'yxatiga qo'shadi. Hech narsa
/// ko'chirib yozish shart emas.
async fn admin_app_config(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }

    // So'rov KIMDAN kelgani — POST'dan oldin o'qiladi
    // (`req.json()` tanani yeb qo'yadi).
    let my_sig = req.headers().get("X-App-Sig").ok().flatten().unwrap_or_default();

    if req.method() == Method::Post {
        let b: Value = req.json().await.unwrap_or(json!({}));

        // Versiya. Bo'sh satr — tekshiruvni o'chirish.
        if let Some(v) = b["min_version"].as_str() {
            let v = v.trim();
            if !v.is_empty() && version_rank(v) <= 0 {
                return json_resp(&json!({
                    "error": "Versiya noto'g'ri. Masalan: 0.0.9 yoki 0.0.9+9"
                }), 400);
            }
            config_put(env, "app_min_version", v).await;
            // Shu izolyatdagi nusxa ham darhol yangilansin.
            MIN_VERSION_CACHE.with(|c| *c.borrow_mut() = None);
        }

        // ── SHU ILOVAGA ISHONISH ─────────────────────────────
        //
        // Admin o'z ilovasidan bosadi va uning imzosi
        // ro'yxatga qo'shiladi. Eskilari JOYIDA QOLADI: aks
        // holda yangi imzoli APK tarqatilguncha hamma uzilib
        // qolardi.
        if b["trust_me"].as_bool() == Some(true) {
            if my_sig.is_empty() {
                return json_resp(&json!({
                    "error": "Ilova imzosi kelmadi. Eski APK bo'lishi mumkin."
                }), 400);
            }
            let cur = config_get(env, "app_sig").await.unwrap_or_default();
            let mut list: Vec<String> = cur
                .split(',')
                .map(|x| x.trim().to_string())
                .filter(|x| !x.is_empty())
                .collect();
            if !list.iter().any(|x| x == &my_sig) {
                list.push(my_sig.clone());
            }
            config_put(env, "app_sig", &list.join(",")).await;
        }

        // Faqat SHU imzoni qoldirish (eskilarini bekor qilish).
        if b["only_me"].as_bool() == Some(true) {
            if my_sig.is_empty() {
                return json_resp(&json!({
                    "error": "Ilova imzosi kelmadi"
                }), 400);
            }
            config_put(env, "app_sig", &my_sig).await;
        }

        // Tekshiruvni butunlay o'chirish.
        if b["clear"].as_bool() == Some(true) {
            config_put(env, "app_sig", "").await;
        }
    }

    let min = config_get(env, "app_min_version").await.unwrap_or_default();
    let sigs = config_get(env, "app_sig").await.unwrap_or_default();
    let list: Vec<String> = sigs
        .split(',')
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .collect();

    ok_nostore(json!({
        "min_version": min,
        // Nechta imzo qabul qilinadi.
        "sig_count": list.len(),
        // Shu so'rov yuborgan ilova ro'yxatdami.
        "my_sig": my_sig,
        "my_sig_trusted": !my_sig.is_empty() && list.iter().any(|x| x == &my_sig),
        // ── HIMOYA HOLATI ENDI IMZO SIRIGA QARAB ─────────────
        //
        // TOPILGAN XATO: bu yerda `app_sig` ro'yxati bo'sh bo'lsa
        // "himoya o'chiq" deb ko'rsatilardi. Endi esa himoya
        // butunlay boshqa narsaga tayanadi — har so'rovdagi HMAC
        // imzosiga. Natijada admin oynasida "o'chiq" yozilib
        // turardi, aslida esa eshik QAT'IY yopiq edi.
        "gate_on": !env.secret("APP_SIGN_SECRET")
            .map(|s| s.to_string().trim().to_string())
            .unwrap_or_default()
            .is_empty()
            || !list.is_empty(),
    }))
}

/// GET /api/admin/badges?since_reports=..&since_users=.. — YANGILIKLAR.
///
/// TALAB (foydalanuvchi): "admin paneliga yangilik kelsa, ya'ni
/// shikoyat, support, yangi foydalanuvchi va boshqa narsalar
/// kelganda admin paneli tugmasida qizil nuqta yonib tursin va
/// o'sha yangi narsa ustida ham yonib tursin".
///
/// ── NEGA "SINCE" ILOVADAN KELADI ────────────────────────────
///
/// "Yangi" degani — ADMIN OXIRGI MARTA KO'RGANIDAN keyingisi.
/// Bu vaqtni bazada saqlash mumkin edi, lekin u holda har
/// bo'lim ochilganda yana bitta yozish so'rovi ketardi. Ilova
/// esa uni o'zida (diskda) saqlaydi va so'rovga qo'shib
/// yuboradi — bazaga hech narsa yozilmaydi.
///
/// Yozishmalar bundan farq qiladi: u yerda "o'qilmagan" tushunchasi
/// allaqachon bazada bor (`chat_threads.unread_admin`), shu sabab
/// vaqt kerak emas.
async fn admin_badges(req: &Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    let url = req.url()?;
    let q = |k: &str| -> i64 {
        url.query_pairs()
            .find(|(n, _)| n == k)
            .and_then(|(_, v)| v.parse::<i64>().ok())
            .unwrap_or(0)
            .max(0)
    };
    let since_reports = q("since_reports");
    let since_users = q("since_users");

    // Uchtasi BITTA paketda: uchta alohida so'rov chekkadan
    // uch marta yo'l yurardi.
    let res = turso_many(env, &[
        ("SELECT COUNT(*) FROM reports_db WHERE created_at > ?",
         vec![TursoArg::int(since_reports)]),
        ("SELECT COALESCE(SUM(unread_admin),0) FROM chat_threads", vec![]),
        ("SELECT COUNT(*) FROM users_db WHERE created_at > ?",
         vec![TursoArg::int(since_users)]),
    ]).await?;

    let n = |i: usize| -> i64 { res.get(i).map(scalar).unwrap_or(0) };
    ok_nostore(json!({
        "reports": n(0),
        "chat": n(1),
        "users": n(2),
        // Ilova shu vaqtni "ko'rildi" deb saqlaydi — o'z soatiga
        // emas, SERVERNIKIGA qaraydi. Telefon soati noto'g'ri
        // bo'lsa ham hisob buzilmaydi.
        "now": now_ms(),
    }))
}

/// DELETE /api/admin/report/:id — "Tozalash" tugmasi.
///
/// Shikoyat bazadan BUTUNLAY o'chadi (foydalanuvchi talabi:
/// "tozalash orqali kelgan shikoyatni bazadan tozalaydi").
async fn admin_report_delete(req: &Request, env: &Env, id: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    if !is_admin(&u) {
        return json_resp(&json!({"error": "forbidden"}), 403);
    }
    turso_exec(env, "DELETE FROM reports_db WHERE id=?",
        vec![TursoArg::text(id)]).await?;
    ok_nostore(json!({"ok": true}))
}

/// POST /api/me/privacy — maxfiylik sozlamalari.
///
/// TALAB (foydalanuvchi): "sozlamalardan avvalgi yashirish
/// tugmasini olib tashla va o'rniga har bitta statistika uchun
/// alohida yashirish tugmalarini qo'yib chiq ... qaysi statistika
/// yashirilgani bazada ham saqlanishi kerak".
///
/// Tanasi: `{"hidden_stats": ["episodes", "comments"]}`.
///
/// Ro'yxat TO'LIQ keladi va eskisining O'RNINI BOSADI: "qaysi
/// biri yoqildi/o'chirildi" deb yuborish ikki qurilmada bir vaqtda
/// o'zgartirilganda chalkashardi.
async fn me_privacy(mut req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let b: Value = req.json().await.unwrap_or(json!({}));
    // Maydon kelmagan bo'lsa HECH NARSA o'zgartirilmaydi: yarim
    // to'ldirilgan so'rov sozlamani nolga tushirib yubormasin.
    let Some(list) = b["hidden_stats"].as_array() else {
        return json_resp(&json!({"error": "hidden_stats kelmadi"}), 400);
    };
    // Faqat TANISH nomlar saqlanadi (`STAT_KEYS`) va har biri bir
    // marta — aks holda ustunga cheksiz axlat yozish mumkin edi.
    let mut keep: Vec<&str> = Vec::new();
    for v in list {
        if let Some(k) = v.as_str() {
            if STAT_KEYS.contains(&k) && !keep.contains(&k) { keep.push(k); }
        }
    }
    let value = keep.join(",");
    turso_exec(env, "UPDATE users_db SET hidden_stats=? WHERE id=?",
        vec![TursoArg::text(&value), TursoArg::int(me)]).await?;
    ok_nostore(json!({"ok": true, "hidden_stats": keep}))
}

/// GET /api/user/:id — OMMAVIY profil.
///
/// TALAB (foydalanuvchi): "biron bir foydalanuvchi boshqa
/// foydalanuvchini profiliga kirganda: chap tarafda rasm, obunasi
/// bor bo'lsa premium belgisi, o'ng tarafda ism, username va
/// nusxalasa bo'ladigan ID raqam. Pastida yashirilmagan
/// statistikalar ko'rinib tursin va boshqa foydalanuvchi ko'ringan
/// statistikani bemalol account egasidek ochib ko'rishi mumkin
/// bo'lsin — bu majburiy".
///
/// Ya'ni endi statistika ODATDA OCHIQ. Egasi sozlamalardan qaysi
/// birini yashirgan bo'lsa (`hidden_stats`), AYNAN o'sha javobga
/// umuman qo'shilmaydi — ilovani o'zgartirish bilan ham ko'rib
/// bo'lmaydi.
///
/// Telegram raqami, balans va obuna esa HECH QACHON yuborilmaydi
/// (admin ko'rinishidan tashqari).
async fn public_profile(
    req: &Request, env: &Env, origin: &str, id: i64,
) -> Result<Response> {
    // ── ADMIN KO'PROQ KO'RADI ─────────────────────────────────
    //
    // Bu faqat qo'llab-quvvatlash ishi uchun (kim yozayotganini,
    // obunasi bor-yo'qligini bilish).
    let viewer = session_user(env, &bearer(req)).await?;
    let as_admin = viewer.as_ref().map(is_admin).unwrap_or(false);
    let me = viewer.as_ref().and_then(|v| v["id"].as_i64()).unwrap_or(0);

    let res = turso_exec(env,
        "SELECT id, username, first_name, last_name, avatar_file,
                telegram_id, balance, traffic_bytes, hidden_stats,
                created_at, last_login_at
           FROM users_db WHERE id=?",
        vec![TursoArg::int(id)]).await?;
    let Some(u) = first_row(&res) else {
        return json_resp(&json!({"error": "Foydalanuvchi topilmadi"}), 404);
    };
    let avatar = u["avatar_file"].as_str().unwrap_or("");
    let photo = if avatar.is_empty() {
        format!("{origin}/api/avatar/{id}")
    } else {
        format!("{origin}/api/image/{avatar}")
    };

    // Raqamlar — shaxsiy statistikadagi bilan BIR XIL hisob
    // (`me_stats_route`), ya'ni odam o'z profilida ko'rgan son
    // boshqalarda ham aynan shunday chiqadi.
    let st = turso_many(env, &[
        ("SELECT COUNT(DISTINCT anime_id) AS a, COUNT(*) AS e,
                 COALESCE(SUM(watched_ms),0) AS w,
                 COUNT(DISTINCT anime_id || '/' || season_id) AS s
            FROM watch_history_db WHERE user_id=?", vec![TursoArg::int(id)]),
        ("SELECT COUNT(*) FROM favorites_db WHERE user_id=?", vec![TursoArg::int(id)]),
        ("SELECT COUNT(*) FROM ratings_db WHERE user_id=?", vec![TursoArg::int(id)]),
        ("SELECT COUNT(*) FROM comments_db WHERE user_id=? AND deleted=0",
         vec![TursoArg::int(id)]),
    ]).await?;
    let r = first_row(&st[0]).unwrap_or(json!({}));

    // Obuna — faqat "bormi yoki yo'q". Muddat sanasi boshqa
    // odamga kerak emas.
    let premium = sub_until(env, id).await > now_ms();

    // Egasi va admin hammasini ko'radi.
    let hidden = hidden_stats_of(&u);
    let full = me == id || as_admin;
    let visible = |key: &str| full || !hidden.iter().any(|h| h == key);

    let mut out = json!({
        // ID endi HAR DOIM ko'rinadi: foydalanuvchi talabi
        // ("nusxalasa bo'ladigan id raqam bo'lsin").
        "id": id,
        "username": u["username"].as_str().unwrap_or(""),
        "first_name": u["first_name"].as_str().unwrap_or(""),
        "last_name": u["last_name"].as_str().unwrap_or(""),
        "photo_url": photo,
        "premium": premium,
        "admin_view": as_admin,
        // Ilova qaysi katakni umuman chizmasligini bilsin.
        "hidden": hidden,
    });
    if let Some(m) = out.as_object_mut() {
        if visible("anime") { m.insert("animes".into(), json!(r["a"].as_i64().unwrap_or(0))); }
        if visible("episodes") { m.insert("episodes".into(), json!(r["e"].as_i64().unwrap_or(0))); }
        if visible("seasons") { m.insert("seasons".into(), json!(r["s"].as_i64().unwrap_or(0))); }
        if visible("watch") { m.insert("watch_ms".into(), json!(r["w"].as_i64().unwrap_or(0))); }
        if visible("favorites") { m.insert("favorites".into(), json!(scalar(&st[1]))); }
        if visible("rated") { m.insert("rated".into(), json!(scalar(&st[2]))); }
        if visible("comments") { m.insert("comments".into(), json!(scalar(&st[3]))); }
    }

    if as_admin {
        let until = sub_until(env, id).await;
        if let Some(m) = out.as_object_mut() {
            m.insert("telegram_id".into(),
                json!(u["telegram_id"].as_i64().unwrap_or(0)));
            m.insert("balance".into(),
                json!(u["balance"].as_i64().unwrap_or(0)));
            m.insert("traffic".into(),
                json!(u["traffic_bytes"].as_i64().unwrap_or(0)));
            m.insert("created_at".into(),
                json!(u["created_at"].as_i64().unwrap_or(0)));
            m.insert("last_login_at".into(),
                json!(u["last_login_at"].as_i64().unwrap_or(0)));
            m.insert("subscription_until".into(), json!(until));
        }
    }
    ok_nostore(out)
}

// ═══════════════════════════════════════════════════════════════
//  STATISTIKA OYNALARI — RO'YXATNING O'ZI
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "qismlar, sevimlilar, bo'limlar,
// baholangan, kommentariya statistikalari ustiga bossa o'sha
// statistikaga tegishli oyna ochilishi va barchasini ko'ra olishi
// kerak ... boshqa foydalanuvchi ko'ringan statistikani bemalol
// account egasidek ochib ko'rishi mumkin bo'lsin".
//
// Shu sabab BITTA yo'l hammasiga xizmat qiladi:
//
//   GET /api/user/:id/stats/:kind?page=0
//
// `kind`:
//   episodes  — ko'rilgan HAR BIR qism (tomosha tarixidagidek,
//               tarixdan tozalangani ham: u bazada `deleted_at`
//               bilan turadi va foydalanuvchi talabiga ko'ra shu
//               oynada KO'RINADI);
//   seasons   — ko'rilgan bo'limlar (bosh sahifadagidek kartochka);
//   favorites — sevimlilar;
//   rated     — baholanganlar (kartochkada berilgan baho ham);
//   comments  — yozilgan izohlar (bo'lim posteri bilan).
//
// Yashirilgan statistika 403 bilan qaytadi va ro'yxat javobga
// UMUMAN qo'shilmaydi.

/// Bitta sahifada nechta yozuv.
const STATS_PAGE: i64 = 40;

async fn user_stats_list(
    req: &Request, env: &Env, origin: &str, id: i64, kind: &str,
) -> Result<Response> {
    let viewer = session_user(env, &bearer(req)).await?;
    let as_admin = viewer.as_ref().map(is_admin).unwrap_or(false);
    let me = viewer.as_ref().and_then(|v| v["id"].as_i64()).unwrap_or(0);

    let res = turso_exec(env, "SELECT hidden_stats FROM users_db WHERE id=?",
        vec![TursoArg::int(id)]).await?;
    let Some(u) = first_row(&res) else {
        return json_resp(&json!({"error": "Foydalanuvchi topilmadi"}), 404);
    };
    if me != id && !as_admin && hidden_stats_of(&u).iter().any(|h| h == kind) {
        return json_resp(&json!({"error": "Bu statistika yashirilgan"}), 403);
    }

    let url = req.url()?;
    let page: i64 = url.query_pairs()
        .find(|(k, _)| k == "page")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0)
        .max(0);
    let off = page * STATS_PAGE;

    // Har bir ro'yxat ILOVAGA TAYYOR holda keladi: bo'lim qatori
    // (poster, nom, yil) allaqachon ichida. Aks holda ilova har
    // bir qator uchun alohida so'rov yuborardi.
    let (sql, args, keys): (&str, Vec<TursoArg>, &[&str]) = match kind {
        // Maydonlar `/api/history` BILAN BIR XIL: tomosha tarixi
        // kartochkasi shu ro'yxatni ham hech o'zgarishsiz chiza
        // oladi (foydalanuvchi talabi: "huddi tomosha tarixidagi
        // bilan bir xil ko'rinishda").
        //
        // FARQ BITTA: `deleted_at = 0` sharti YO'Q — tarixdan
        // tozalangan qismlar ham chiqadi (ular bazada shunchaki
        // belgilangan, o'chirilmagan).
        "episodes" => (
            "SELECT h.anime_id, h.season_id, h.epizod_id,
                    e.epizod_number AS epizod_number,
                    h.video_url, h.last_quality,
                    h.position_ms, h.duration_ms, h.watched_ms, h.view_count,
                    h.updated_at, h.deleted_at,
                    a.name AS anime_name, a.photo_url AS anime_photo,
                    s.bolim_id AS bolim_id, s.nomi AS season_name,
                    s.photo_url AS season_photo
               FROM watch_history_db h
               LEFT JOIN anime_db a ON a.id = h.anime_id
               LEFT JOIN season_db s
                      ON s.anime_id = h.anime_id AND s.season_id = h.season_id
               LEFT JOIN epizod_db e
                      ON e.anime_id = h.anime_id AND e.season_id = h.season_id
                     AND e.epizod_id = h.epizod_id
              WHERE h.user_id = ?
              ORDER BY h.updated_at DESC
              LIMIT ? OFFSET ?",
            vec![TursoArg::int(id), TursoArg::int(STATS_PAGE), TursoArg::int(off)],
            &["anime_photo", "season_photo", "video_url"],
        ),
        "seasons" => (
            "SELECT s.*, MAX(h.updated_at) AS seen_at
               FROM watch_history_db h
               JOIN season_db s
                 ON s.anime_id = h.anime_id AND s.season_id = h.season_id
              WHERE h.user_id = ?
              GROUP BY s.anime_id, s.season_id
              ORDER BY seen_at DESC
              LIMIT ? OFFSET ?",
            vec![TursoArg::int(id), TursoArg::int(STATS_PAGE), TursoArg::int(off)],
            SEASON_URL_KEYS,
        ),
        "favorites" => (
            "SELECT s.*, f.created_at AS fav_at
               FROM favorites_db f
               JOIN season_db s
                 ON s.anime_id = f.anime_id AND s.season_id = f.season_id
              WHERE f.user_id = ?
              ORDER BY f.created_at DESC
              LIMIT ? OFFSET ?",
            vec![TursoArg::int(id), TursoArg::int(STATS_PAGE), TursoArg::int(off)],
            SEASON_URL_KEYS,
        ),
        "rated" => (
            "SELECT s.*, r.stars AS my_stars, r.updated_at AS rated_at
               FROM ratings_db r
               JOIN season_db s
                 ON s.anime_id = r.anime_id AND s.season_id = r.season_id
              WHERE r.user_id = ?
              ORDER BY r.updated_at DESC
              LIMIT ? OFFSET ?",
            vec![TursoArg::int(id), TursoArg::int(STATS_PAGE), TursoArg::int(off)],
            SEASON_URL_KEYS,
        ),
        "comments" => (
            "SELECT c.id, c.parent_id, c.anime_id, c.season_id, c.body,
                    c.likes, c.reply_count, c.created_at, c.edited_at,
                    s.nomi AS season_name, s.photo_url AS photo_url,
                    a.name AS anime_name
               FROM comments_db c
               LEFT JOIN season_db s
                      ON s.anime_id = c.anime_id AND s.season_id = c.season_id
               LEFT JOIN anime_db a ON a.id = c.anime_id
              WHERE c.user_id = ? AND c.deleted = 0
              ORDER BY c.created_at DESC
              LIMIT ? OFFSET ?",
            vec![TursoArg::int(id), TursoArg::int(STATS_PAGE), TursoArg::int(off)],
            &["photo_url"],
        ),
        _ => return json_resp(&json!({"error": "Noma'lum statistika"}), 400),
    };

    let res = turso_exec(env, sql, args).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows.iter()
        .map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![])))
        .collect();
    let n = items.len() as i64;
    ok_nostore(json!({
        "items": resolve_list(origin, items, keys),
        "page": page,
        "has_more": n >= STATS_PAGE,
    }))
}

// ═══════════════════════════════════════════════════════════════
//  FOYDALANUVCHILARNI BOSHQARISH (ADMIN)
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "admin paneliga foydalanuvchilarni
// boshqaradigan bo'lim qo'sh: oxirgi ro'yxatdan o'tgan va oxirgi
// onlayn bo'lgan vaqti bo'yicha ikkita ro'yxat, yuqorida ID yoki
// username bilan izlash, balansni qo'lda to'ldirish, bloklash va
// yana kerakli narsalar".
//
// ── HAR BIR AMAL SERVERDA TEKSHIRILADI ──────────────────────
//
// Ilovadagi "admin paneli" tugmasi shunchaki ekranni ko'rsatadi.
// Haqiqiy to'siq esa SHU YERDA: har bir so'rovda `is_admin`
// qayta tekshiriladi. Ya'ni o'zgartirilgan ilova bilan begona
// odam birovning balansini o'zgartira olmaydi.

/// Bir sahifada nechta foydalanuvchi.
const ADMIN_PAGE: i64 = 40;

/// Faqat admin o'tadigan tekshiruv.
///
/// Muvaffaqiyatli bo'lsa `None`, aks holda tayyor rad javobi.
async fn admin_only(req: &Request, env: &Env) -> Result<Option<Response>> {
    let Some(u) = session_user(env, &bearer(req)).await? else {
        return Ok(Some(json_resp(&json!({"error": "unauthorized"}), 401)?));
    };
    if !is_admin(&u) {
        return Ok(Some(json_resp(&json!({"error": "forbidden"}), 403)?));
    }
    Ok(None)
}

/// GET /api/admin/users?sort=new|online&q=...&page=N
async fn admin_users(req: &Request, env: &Env, origin: &str) -> Result<Response> {
    if let Some(deny) = admin_only(req, env).await? {
        return Ok(deny);
    }
    let url = req.url()?;
    let q = |k: &str| -> String {
        url.query_pairs()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.to_string())
            .unwrap_or_default()
    };

    // ── IKKI RO'YXAT ──────────────────────────────────────────
    //
    // `new`    — oxirgi ro'yxatdan o'tganlar (`created_at`);
    // `online` — oxirgi onlayn bo'lganlar (`last_login_at`).
    //
    // Ustun nomi FOYDALANUVCHIDAN kelmaydi — bu yerda ikkita
    // aniq qiymatdan biriga aylantiriladi. Aks holda so'rovga
    // begona matn qo'shib yuborish mumkin bo'lardi.
    let order = if q("sort") == "new" { "created_at" } else { "last_login_at" };

    let search = q("q").trim().to_string();
    let page: i64 = q("page").parse().unwrap_or(0).max(0);

    // ── IZLASH: ID YOKI USERNAME ──────────────────────────────
    //
    // Raqam yozilsa — ID bo'yicha aniq moslik; matn yozilsa —
    // username ichidan qidiriladi. Ikkovi ham bitta maydondan
    // ishlaydi, foydalanuvchi qaysi turini yozganini o'ylab
    // o'tirmaydi.
    let by_id: i64 = search.parse().unwrap_or(0);
    let like = format!("%{}%", search.to_lowercase());

    let (sql, args): (String, Vec<TursoArg>) = if search.is_empty() {
        (
            format!(
                "SELECT u.id AS id, u.username AS username,
                        u.first_name AS first_name, u.last_name AS last_name,
                        u.avatar_file AS avatar_file,
                        u.telegram_id AS telegram_id, u.balance AS balance,
                        u.is_banned AS is_banned, u.ban_until AS ban_until,
                        u.ban_reason AS ban_reason,
                        u.created_at AS created_at,
                        u.last_login_at AS last_login_at,
                        COALESCE(s.expires_at,0) AS sub_until
                   FROM users_db u
                   LEFT JOIN subs_db s ON s.user_id = u.id
                  ORDER BY u.{order} DESC LIMIT ? OFFSET ?"
            ),
            vec![TursoArg::int(ADMIN_PAGE), TursoArg::int(page * ADMIN_PAGE)],
        )
    } else {
        (
            format!(
                "SELECT u.id AS id, u.username AS username,
                        u.first_name AS first_name, u.last_name AS last_name,
                        u.avatar_file AS avatar_file,
                        u.telegram_id AS telegram_id, u.balance AS balance,
                        u.is_banned AS is_banned, u.ban_until AS ban_until,
                        u.ban_reason AS ban_reason,
                        u.created_at AS created_at,
                        u.last_login_at AS last_login_at,
                        COALESCE(s.expires_at,0) AS sub_until
                   FROM users_db u
                   LEFT JOIN subs_db s ON s.user_id = u.id
                  WHERE u.id = ? OR LOWER(COALESCE(u.username,'')) LIKE ?
                     OR LOWER(COALESCE(u.first_name,'')) LIKE ?
                  ORDER BY u.{order} DESC LIMIT ? OFFSET ?"
            ),
            vec![
                TursoArg::int(by_id), TursoArg::text(&like), TursoArg::text(&like),
                TursoArg::int(ADMIN_PAGE), TursoArg::int(page * ADMIN_PAGE),
            ],
        )
    };

    let res = turso_exec(env, &sql, args).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows.iter().map(|r| {
        let o = row_to_obj(&cols, r.as_array().unwrap_or(&vec![]));
        let uid = o["id"].as_i64().unwrap_or(0);
        let avatar = o["avatar_file"].as_str().unwrap_or("");
        let photo = if avatar.is_empty() {
            format!("{origin}/api/avatar/{uid}")
        } else {
            format!("{origin}/api/image/{avatar}")
        };
        json!({
            "id": uid,
            "username": o["username"].as_str().unwrap_or(""),
            "first_name": o["first_name"].as_str().unwrap_or(""),
            "last_name": o["last_name"].as_str().unwrap_or(""),
            "photo_url": photo,
            "telegram_id": o["telegram_id"].as_i64().unwrap_or(0),
            "balance": o["balance"].as_i64().unwrap_or(0),
            "banned": o["is_banned"].as_i64().unwrap_or(0) != 0,
            // 0 — muddatsiz (yoki bloklanmagan).
            "ban_until": o["ban_until"].as_i64().unwrap_or(0),
            "ban_reason": o["ban_reason"].as_str().unwrap_or(""),
            "created_at": o["created_at"].as_i64().unwrap_or(0),
            "last_login_at": o["last_login_at"].as_i64().unwrap_or(0),
            // Obuna qachon tugaydi (0 — obuna yo'q). Admin
            // oynasida "hozir necha kun qolgan" shu yerdan.
            "sub_until": o["sub_until"].as_i64().unwrap_or(0),
        })
    }).collect();

    // Umumiy son — ro'yxat tepasida ko'rsatish uchun (izlashsiz).
    let total = if search.is_empty() {
        turso_exec(env, "SELECT COUNT(*) FROM users_db", vec![]).await
            .map(|r| scalar(&r)).unwrap_or(0)
    } else {
        items.len() as i64
    };

    ok_nostore(json!({
        "items": items,
        "page": page,
        "total": total,
        "has_more": items.len() as i64 >= ADMIN_PAGE,
    }))
}

/// POST /api/admin/user/:id — bitta foydalanuvchi ustida amal.
///
/// Tanadagi `action`:
///   * `balance`  — balansga `amount` qo'shadi (manfiy ham bo'ladi);
///   * `set_balance` — balansni AYNAN `amount` ga tenglaydi;
///   * `ban` / `unban` — bloklash va ochish;
///   * `sub`      — obunaga `days` kun qo'shadi (manfiy bo'lsa ayiradi);
///   * `sub_clear` — obunani butunlay bekor qiladi.
///
/// Har bir amal `billing_log` ga yoziladi: keyin "bu pul qayerdan
/// keldi" degan savol tug'ilmasin.
async fn admin_user_action(
    mut req: Request, env: &Env, id: i64,
) -> Result<Response> {
    if let Some(deny) = admin_only(&req, env).await? {
        return Ok(deny);
    }
    let b: Value = req.json().await.unwrap_or(json!({}));
    let action = b["action"].as_str().unwrap_or("");
    let now = now_ms();

    match action {
        "balance" | "set_balance" => {
            let amount = b["amount"].as_i64().unwrap_or(0);
            let row = if action == "balance" {
                if amount == 0 {
                    return json_resp(&json!({"error": "Summa yo'q"}), 400);
                }
                turso_exec(env,
                    "UPDATE users_db SET balance=MAX(COALESCE(balance,0)+?,0)
                      WHERE id=? RETURNING balance",
                    vec![TursoArg::int(amount), TursoArg::int(id)]).await?
            } else {
                if amount < 0 {
                    return json_resp(&json!({"error": "Manfiy bo'lmasin"}), 400);
                }
                turso_exec(env,
                    "UPDATE users_db SET balance=? WHERE id=? RETURNING balance",
                    vec![TursoArg::int(amount), TursoArg::int(id)]).await?
            };
            let Some(r) = first_row(&row) else {
                return json_resp(&json!({"error": "Foydalanuvchi topilmadi"}), 404);
            };
            let left = r["balance"].as_i64().unwrap_or(0);
            // Jurnalga yoziladi — foydalanuvchi ham Tarix oynasida
            // ko'radi va "pul qayerdan keldi" degan savol qolmaydi.
            let _ = turso_exec(env,
                "INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
                 VALUES (?,?,'topup',?,0,?,?)",
                vec![
                    TursoArg::text(&format!("a{}", random_hex(10))),
                    TursoArg::int(id),
                    TursoArg::int(if action == "balance" { amount } else { left }),
                    TursoArg::text(if action == "set_balance" {
                        "Admin balansni tenglashtirdi"
                    } else if amount > 0 {
                        "Admin qo'shdi"
                    } else {
                        "Admin yechdi"
                    }),
                    TursoArg::int(now),
                ]).await;
            ok_nostore(json!({"ok": true, "balance": left}))
        }

        // ── BLOKLASH: MUDDATSIZ VA MUDDATLI ──────────────────
        //
        // TALAB (foydalanuvchi): "foydalanuvchini bloklaganda
        // muddatsiz va muddatli bloklash tizimini qo'sh va
        // bloklanish sababini ham yozsa bo'ladigan qil".
        //
        // Tanadagi maydonlar:
        //   `days`   — 0 yoki yo'q bo'lsa MUDDATSIZ, aks holda
        //              shuncha kunga;
        //   `reason` — sabab (ixtiyoriy, 300 belgigacha).
        //
        // Ochishda ikkovi ham tozalanadi: eski sabab qolib
        // ketsa, keyingi blokda noto'g'ri matn chiqardi.
        "ban" | "unban" => {
            if action == "unban" {
                let row = turso_exec(env,
                    "UPDATE users_db SET is_banned=0, ban_until=0, ban_reason='',
                            banned_at=0
                      WHERE id=? RETURNING is_banned",
                    vec![TursoArg::int(id)]).await?;
                if first_row(&row).is_none() {
                    return json_resp(&json!({"error": "Foydalanuvchi topilmadi"}), 404);
                }
                return ok_nostore(json!({"ok": true, "banned": false}));
            }

            let days = b["days"].as_i64().unwrap_or(0).max(0);
            // Uzunlik BELGI bo'yicha kesiladi (bayt emas):
            // o'zbekcha harflar ikki bayt egallaydi.
            let reason: String = b["reason"].as_str().unwrap_or("")
                .trim().chars().take(300).collect();
            let until = if days > 0 { now + days * 86_400_000 } else { 0 };

            let row = turso_exec(env,
                "UPDATE users_db SET is_banned=1, ban_until=?, ban_reason=?,
                        banned_at=?
                  WHERE id=? RETURNING is_banned",
                vec![
                    TursoArg::int(until), TursoArg::text(&reason),
                    TursoArg::int(now), TursoArg::int(id),
                ]).await?;
            if first_row(&row).is_none() {
                return json_resp(&json!({"error": "Foydalanuvchi topilmadi"}), 404);
            }
            // Bloklangan odamning sessiyalari DARHOL yopiladi —
            // aks holda u chiqmaguncha ilovadan foydalanaverardi.
            let _ = turso_exec(env, "DELETE FROM sessions_db WHERE user_id=?",
                vec![TursoArg::int(id)]).await;

            // ── SABAB YOZISHMAGA HAM TUSHADI ─────────────────
            //
            // Odam ilovaga kira olmaydi, lekin blok tugagach
            // (yoki admin ochgach) yozishmani ochib nima
            // bo'lganini o'qiy oladi. Botdagi xabar bir marta
            // ko'rinadi va yo'qoladi — bu esa QOLADI.
            let text = ban_message(until, &reason, now);
            let _ = chat_admin_note(env, id, &text).await;

            ok_nostore(json!({
                "ok": true,
                "banned": true,
                "ban_until": until,
                "ban_reason": reason,
            }))
        }

        // ── OBUNA: KUN QO'SHISH VA AYIRISH ───────────────────
        //
        // TALAB (foydalanuvchi): "obuna ham shunaqa bo'lsin —
        // qo'lda necha kunligini yozadi va xohlasa kun qo'shadi,
        // xohlasa olib tashlaydi".
        //
        // `days` musbat bo'lsa qo'shiladi, manfiy bo'lsa ayiriladi.
        // Ayirilganda muddat hozirgi vaqtdan oldinga tushsa —
        // obuna butunlay olib tashlanadi (yarim o'chgan holat
        // qolmasin).
        "sub" => {
            let days = b["days"].as_i64().unwrap_or(0);
            if days == 0 {
                return json_resp(&json!({"error": "Kun soni yo'q"}), 400);
            }
            // Muddati o'tgan obuna 0 dan boshlab qo'shiladi.
            let base = sub_until(env, id).await.max(now);
            let until = base + days * 86_400_000;

            if until <= now {
                let _ = turso_batch(env, &[
                    ("DELETE FROM subs_db WHERE user_id=?",
                     vec![TursoArg::int(id)]),
                    ("INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
                      VALUES (?,?,'subscription',0,?,?,?)",
                     vec![
                        TursoArg::text(&format!("a{}", random_hex(10))),
                        TursoArg::int(id), TursoArg::int(days),
                        TursoArg::text("Obuna tugatildi (admin)"),
                        TursoArg::int(now),
                     ]),
                ]).await;
                return ok_nostore(json!({"ok": true, "subscription_until": 0}));
            }

            let note = if days > 0 {
                format!("{days} kun obuna qo'shildi (admin)")
            } else {
                format!("{} kun obuna olindi (admin)", -days)
            };
            let _ = turso_batch(env, &[
                ("INSERT INTO subs_db (user_id,expires_at,updated_at) VALUES (?,?,?)
                  ON CONFLICT(user_id) DO UPDATE SET
                     expires_at=excluded.expires_at, updated_at=excluded.updated_at",
                 vec![TursoArg::int(id), TursoArg::int(until), TursoArg::int(now)]),
                ("INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
                  VALUES (?,?,'subscription',0,?,?,?)",
                 vec![
                    TursoArg::text(&format!("a{}", random_hex(10))),
                    TursoArg::int(id), TursoArg::int(days),
                    TursoArg::text(&note),
                    TursoArg::int(now),
                 ]),
            ]).await;
            ok_nostore(json!({"ok": true, "subscription_until": until}))
        }

        // Obunani BUTUNLAY olib tashlash.
        "sub_clear" => {
            let _ = turso_batch(env, &[
                ("DELETE FROM subs_db WHERE user_id=?", vec![TursoArg::int(id)]),
                ("INSERT INTO billing_log (id,user_id,kind,amount,days,note,created_at)
                  VALUES (?,?,'subscription',0,0,?,?)",
                 vec![
                    TursoArg::text(&format!("a{}", random_hex(10))),
                    TursoArg::int(id),
                    TursoArg::text("Obuna bekor qilindi (admin)"),
                    TursoArg::int(now),
                 ]),
            ]).await;
            ok_nostore(json!({"ok": true, "subscription_until": 0}))
        }

        _ => json_resp(&json!({"error": "Noma'lum amal"}), 400),
    }
}

/// GET /api/billing — balans, obuna, faol havolalar va tarix.
async fn billing_state(req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let now = now_ms();

    let res = turso_many(env, &[
        ("SELECT expires_at FROM subs_db WHERE user_id=?",
         vec![TursoArg::int(me)]),
        // Faol havolalar: to'lanmagan va muddati o'tmagan.
        ("SELECT order_id,amount,pay_url,expires_at FROM payments_db
           WHERE user_id=? AND status='pending' AND expires_at > ?
           ORDER BY created_at DESC LIMIT 20",
         vec![TursoArg::int(me), TursoArg::int(now)]),
        ("SELECT kind,amount,days,note,created_at FROM billing_log
           WHERE user_id=? ORDER BY created_at DESC LIMIT 100",
         vec![TursoArg::int(me)]),
        // ── MUDDATI O'TGAN HAVOLA BAZADAN O'CHADI ────────
        //
        // TALAB (foydalanuvchi): "balans to'ldirish havolasi
        // yaratilgach bir soatdan o'tgach bazadan o'chirib
        // tashlanishi kerak".
        //
        // `expires_at` = yaratilgan vaqt + 1 soat, ya'ni shart
        // AYNAN shuni bildiradi. Ilgari qator yana bir kun
        // yotardi.
        //
        // To'langan qatorga TEGILMAYDI (`status='pending'`) —
        // u pul yozuvi va tarixda turishi kerak.
        ("DELETE FROM payments_db
           WHERE status='pending' AND expires_at < ?",
         vec![TursoArg::int(now)]),
    ]).await?;

    let rows_of = |r: &Value| -> Vec<Value> {
        let cols = r["cols"].as_array().cloned().unwrap_or_default();
        r["rows"].as_array().cloned().unwrap_or_default().iter()
            .map(|x| row_to_obj(&cols, x.as_array().unwrap_or(&vec![])))
            .collect()
    };

    let until = res.first().and_then(first_row)
        .and_then(|r| r["expires_at"].as_i64()).unwrap_or(0);

    ok_nostore(json!({
        "balance": u["balance"].as_i64().unwrap_or(0),
        "subscription_until": until,
        "active": until > now,
        "plans": PLANS.iter().map(|(d, p)| json!({"days": d, "price": p}))
                      .collect::<Vec<_>>(),
        "links": rows_of(res.get(1).unwrap_or(&json!({}))),
        "history": rows_of(res.get(2).unwrap_or(&json!({}))),
        "link_ttl_ms": PAY_LINK_TTL_MS,
        "now": now,
    }))
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

// ═══════════════════════════════════════════════════════════════
//  TRAFIKNI ENDI ILOVA SANAYDI (worker emas)
// ═══════════════════════════════════════════════════════════════
//
// ── NEGA O'ZGARTIRILDI (foydalanuvchi topgan xato) ────────────
//
// Ilgari worker javob tanasini `TransformStream` orqali o'tkazib,
// yuborilgan baytlarni o'zi sanardi. Ikki muammo chiqdi:
//
//   1) HISOB NOTO'G'RI edi. Pleyer `Range: bytes=0-` deb butun
//      qolgan faylni so'raydi, bir necha megabayt bufer yig'ib
//      ulanishni uzadi va keyingi joydan qayta so'raydi — shu
//      sabab 166 MB lik video "1,14 GB" bo'lib ko'rinardi.
//   2) IJRO BUZILDI. O'ralgan oqim ba'zan uzilib qolar va
//      pleyerda "yuklanmadi" xatosi chiqardi.
//
// Ijro yo'li — loyihaning eng nozik joyi, shu sabab u endi
// BUTUNLAY tegilmagan holda qoldirildi: worker javobni qanday
// olsa shundayligicha uzatadi.
//
// Hisobni ILOVANING O'ZI yuritadi (`lib/services/traffic_service.dart`):
// u qurilma darajasida HAQIQATAN qabul qilingan baytlarni sanaydi
// va SUTKADA BIR MARTA `POST /api/traffic` bilan bitta son
// yuboradi. Worker esa o'sha sonni umumiy va shaxsiy hisobga
// qo'shadi. Trafik raqami real vaqtda kerak emas, shu sabab bu
// yo'l ham arzon (kuniga bitta so'rov), ham aniq.


/// Trafikni umumiy chelaklarga VA shaxsiy hisobga qo'shadi.
///
/// ── QAYSI RAQAM QAYERDAN ──────────────────────────────────────
///
/// TALAB (foydalanuvchi): "bosh sahifadagi trafik statistikasi
/// yana ilovadagi shaxsiy trafik statistikasidan olinsin".
///
/// Ya'ni yagona manba — ILOVA. U qurilma darajasida HAQIQATAN
/// qabul qilingan baytni sanaydi (`traffic_service.dart`), keyin
/// sinxronlash paketi bilan bir marta yuboradi. Worker o'sha
/// sonni ikki joyga qo'shadi:
///
///   * UMUMIY — `stats_hourly` / `stats_daily` chelaklari
///     (bosh sahifadagi banner, `/api/stats`);
///   * SHAXSIY — `users_db.traffic_bytes` (profil sahifasi,
///     `/api/me/stats`; buni faqat egasi ko'radi).
///
/// ── NEGA CLOUDFLARE ANALYTICS EMAS ────────────────────────────
///
/// Bir muddat umumiy raqam Cloudflare'ning
/// `workersInvocationsAdaptive.sum.responseBodySize` maydonidan
/// olindi. Texnik jihatdan ishladi, LEKIN raqam telefon
/// qabul qilganidan ~10 barobar katta chiqdi: pleyer
/// `Range: bytes=0-` bilan so'rab, bir necha megabaytdan keyin
/// ulanishni uzadi — Cloudflare esa yo'lga chiqqan baytni
/// sanaydi. Foydalanuvchiga ko'rsatiladigan raqam sifatida bu
/// noto'g'ri (foydalanuvchi talabi: "bu soxta"), shu sabab
/// Cloudflare manbasi BUTUNLAY olib tashlandi.
async fn note_traffic(env: &Env, bytes: i64, user: i64) {
    if bytes <= 0 { return; }
    ensure_db(env).await;
    let now = now_ms();
    let mut stmts: Vec<(&str, Vec<TursoArg>)> = vec![
        (STAT_HOUR_SQL, stat_args(&hour_key(now), "traffic", bytes)),
        (STAT_DAY_SQL, stat_args(&day_key(now), "traffic", bytes)),
    ];
    if user > 0 {
        stmts.push((
            "UPDATE users_db SET traffic_bytes=COALESCE(traffic_bytes,0)+? WHERE id=?",
            vec![TursoArg::int(bytes), TursoArg::int(user)],
        ));
    }
    let _ = turso_batch(env, &stmts).await;
}

// ═══════════════════════════════════════════════════════════════
//  GET /api/stats — SHAFFOF STATISTIKA
// ═══════════════════════════════════════════════════════════════
//
// Hammasi BITTA so'rovda (5 ta buyruq bitta quvurda) va chekkada
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

    let res = turso_many(env, &[
        // Foydalanuvchilar: jami + davr bo'yicha yangi hisoblar.
        //
        // YILLIK ko'rsatkich ATAYLAB YO'Q (foydalanuvchi talabi):
        // kunlik, haftalik, oylik va umumiy yetarli.
        ("SELECT COUNT(*),
                 SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END),
                 SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END)
            FROM users_db",
         vec![
            TursoArg::int(now - 7 * day_ms),
            TursoArg::int(now - 30 * day_ms),
         ]),
        // Kunlik: oxirgi 24 soatda onlayn bo'lganlar.
        ("SELECT COUNT(DISTINCT user_id) FROM sessions_db WHERE last_seen_at >= ?",
         vec![TursoArg::int(now - day_ms)]),
        // Oxirgi 24 soat — soatlik chelaklar.
        ("SELECT metric, SUM(value) FROM stats_hourly WHERE hour >= ? GROUP BY metric",
         vec![TursoArg::text(&h24)]),
        // Hafta / oy / jami — kunlik chelaklar.
        ("SELECT metric,
                 SUM(CASE WHEN day >= ? THEN value ELSE 0 END),
                 SUM(CASE WHEN day >= ? THEN value ELSE 0 END),
                 SUM(value)
            FROM stats_daily GROUP BY metric",
         vec![TursoArg::text(&d7), TursoArg::text(&d30)]),
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
    let mut periods: std::collections::HashMap<String, (i64, i64, i64)> =
        std::collections::HashMap::new();
    if let Some(rows) = res[3]["rows"].as_array() {
        for r in rows {
            let m = r[0]["value"].as_str().unwrap_or("").to_string();
            periods.insert(m, (cell(r, 1), cell(r, 2), cell(r, 3)));
        }
    }
    for (metric, key) in [("views", "views"), ("traffic", "traffic"), ("watch_ms", "watch")] {
        let (w, m, t) = periods.get(metric).copied().unwrap_or((0, 0, 0));
        out.insert(key.into(), json!({
            "daily": daily.get(metric).copied().unwrap_or(0),
            "weekly": w, "monthly": m, "total": t,
        }));
    }
    out.insert("tz".into(), json!("UTC+5"));
    ok(Value::Object(out))
}

// ═══════════════════════════════════════════════════════════════
//  BO'LIM SAHIFASI: MA'LUMOT, BAHO, SEVIMLILAR
// ═══════════════════════════════════════════════════════════════

/// Reyting — ODDIY O'RTACHA, ikki kasr xonagacha.
///
/// TALAB (foydalanuvchi): "birinchi odam 10 baho bersa reyting ham
/// 10 bo'lishi kerak, iloji boricha ANIQ bo'lsin".
///
/// Shu sabab IMDb uslubidagi vaznli (bayes) o'rtacha OLIB
/// TASHLANDI: u bitta baho bo'lganda 10 ni 8.5 ga tushirardi.
fn average_rating(sum: i64, count: i64) -> f64 {
    if count <= 0 { return 0.0; }
    ((sum as f64 / count as f64) * 100.0).round() / 100.0
}

async fn season_detail(env: &Env, origin: &str, req: &Request, aid: i64, sid: i64) -> Result<Response> {
    let me = match session_user(env, &bearer(req)).await? {
        Some(u) => u["id"].as_i64().unwrap_or(0),
        None => 0,
    };
    let res = turso_many(env, &[
        ("SELECT * FROM season_db WHERE anime_id=? AND season_id=?",
         vec![TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT stars FROM ratings_db WHERE user_id=? AND anime_id=? AND season_id=?",
         vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)]),
        ("SELECT 1 FROM favorites_db WHERE user_id=? AND anime_id=? AND season_id=?",
         vec![TursoArg::int(me), TursoArg::int(aid), TursoArg::int(sid)]),
    ]).await?;

    let Some(row) = first_row(&res[0]) else { return err404("Bo'lim topilmadi") };
    let my_stars = first_row(&res[1]).and_then(|r| r["stars"].as_i64()).unwrap_or(0);
    let is_fav = res[2]["rows"].as_array().map(|r| !r.is_empty()).unwrap_or(false);

    let rating = average_rating(
        row["rating_sum"].as_i64().unwrap_or(0),
        row["rating_count"].as_i64().unwrap_or(0),
    );

    ok_nostore(json!({
        "season": resolve_fields(origin, row, SEASON_URL_KEYS),
        "rating": rating,
        "my_stars": my_stars,
        "is_fav": is_fav,
    }))
}

/// GET /api/me/stats — PROFIL SAHIFASIDAGI SHAXSIY STATISTIKA.
///
/// To'rtta raqam, BITTA so'rovda:
///
///   * nechta ANIME ko'rgan (bo'lim emas — `anime_id` bo'yicha
///     noyob);
///   * nechta qism ko'rgan;
///   * necha soat ko'rgan (1x tezlikdagi haqiqiy vaqt);
///   * qancha trafik sarflagan.
///
/// Tarixdan yashirilgan (`deleted_at`) yozuvlar ham hisobga
/// kiradi: ular O'CHIRILMAGAN, faqat ro'yxatda ko'rinmaydi.
async fn me_stats_route(req: Request, env: &Env) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let res = turso_many(env, &[
        ("SELECT COUNT(DISTINCT anime_id) AS a, COUNT(*) AS e,
                 COALESCE(SUM(watched_ms),0) AS w,
                 COUNT(DISTINCT anime_id || '/' || season_id) AS s
            FROM watch_history_db WHERE user_id=?",
         vec![TursoArg::int(me)]),
        ("SELECT COUNT(*) FROM favorites_db WHERE user_id=?",
         vec![TursoArg::int(me)]),
        ("SELECT COUNT(*) FROM ratings_db WHERE user_id=?",
         vec![TursoArg::int(me)]),
        ("SELECT COUNT(*) FROM comments_db WHERE user_id=? AND deleted=0",
         vec![TursoArg::int(me)]),
    ]).await?;
    let r = first_row(&res[0]).unwrap_or(json!({}));
    ok_nostore(json!({
        "animes": r["a"].as_i64().unwrap_or(0),
        "episodes": r["e"].as_i64().unwrap_or(0),
        "watch_ms": r["w"].as_i64().unwrap_or(0),
        "seasons": r["s"].as_i64().unwrap_or(0),
        "favorites": scalar(&res[1]),
        "rated": scalar(&res[2]),
        "comments": scalar(&res[3]),
        "traffic": u["traffic_bytes"].as_i64().unwrap_or(0),
    }))
}

// ══════════════════════════════════════════════════════════════
//  QAYSI STATISTIKA YASHIRILGAN
// ══════════════════════════════════════════════════════════════
//
// Ro'yxat `users_db.hidden_stats` da oddiy satr bo'lib yotadi:
// "episodes,comments". Bo'sh satr — hammasi ochiq (odatiy holat,
// foydalanuvchi talabi).
//
// `anime` ATAYLAB yo'q: "Anime statistikasini hech kim ko'ra
// olmaydi" — unga alohida oyna yo'q, lekin RAQAMI profilda
// ko'rinadi va uni ham yashirish mumkin.

/// Ilova va server BITTA ro'yxatni biladi. Boshqa nom kelsa
/// e'tiborsiz qoldiriladi — eski ilova yangi serverga kelib
/// sozlamani buzib ketmasin.
const STAT_KEYS: &[&str] = &[
    "anime", "episodes", "seasons", "favorites", "rated", "comments", "watch",
];

/// Foydalanuvchi qatoridan yashirilganlar ro'yxati.
fn hidden_stats_of(u: &Value) -> Vec<String> {
    u["hidden_stats"].as_str().unwrap_or("")
        .split(',')
        .map(|v| v.trim())
        .filter(|v| STAT_KEYS.contains(v))
        .map(|v| v.to_string())
        .collect()
}

/// GET /api/favorites — foydalanuvchining sevimli BO'LIMLARI.
///
/// Javob bo'lim qatorlarining O'ZI bo'ladi, ya'ni Kutubxonadagi
/// "Sevimlilar" oynasi kartochkani darhol chiza oladi va pleyer
/// ham shu ma'lumot bilan ochiladi — qo'shimcha so'rov yo'q.
async fn favorites_route(req: Request, env: &Env, origin: &str) -> Result<Response> {
    let Some(u) = session_user(env, &bearer(&req)).await? else {
        return json_resp(&json!({"error": "unauthorized"}), 401);
    };
    let me = u["id"].as_i64().unwrap_or(0);
    let res = turso_exec(env,
        "SELECT s.*, f.created_at AS fav_at
           FROM favorites_db f
           JOIN season_db s
             ON s.anime_id = f.anime_id AND s.season_id = f.season_id
          WHERE f.user_id = ?
          ORDER BY f.created_at DESC
          LIMIT 300",
        vec![TursoArg::int(me)]).await?;
    let cols = res["cols"].as_array().cloned().unwrap_or_default();
    let rows = res["rows"].as_array().cloned().unwrap_or_default();
    let items: Vec<Value> = rows
        .iter()
        .map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![])))
        .collect();
    ok_nostore(json!({"items": resolve_list(origin, items, SEASON_URL_KEYS)}))
}

/// POST /api/rating — bitta bo'limga bitta baho (1..10).

/// POST /api/favorite — bo'limni sevimlilarga qo'shish/olib tashlash.

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
                 device,platform,app_version,created_at,expires_at)
                 VALUES (?,'pending',0,'',?,?,?,?,?)",
                vec![
                    TursoArg::text(&token),
                    TursoArg::text(b["device"].as_str().unwrap_or("")),
                    TursoArg::text(b["platform"].as_str().unwrap_or("")),
                    TursoArg::text(b["app_version"].as_str().unwrap_or("")),
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

            // ── WEBHOOK HOLATI TELEGRAMNING O'ZIDAN ──────────
            //
            // Ilgari bu yerda workerning O'Z yozuvi ko'rsatilardi
            // ("men qachondir qo'ygandim"). Bot almashganda o'sha
            // yozuv joyida turaverdi va tekshiruv
            // `webhook_registered: true` deb YOLG'ON aytdi —
            // holbuki yangi botda webhook umuman yo'q edi va bot
            // jim turardi.
            //
            // Endi HAQIQIY manba so'raladi: `getWebhookInfo`
            // Telegramning o'zida nima turganini aytadi.
            let (hook_url, hook_err, hook_pending) =
                match tg_api(env, "getWebhookInfo", json!({})).await {
                    Ok(w) => (
                        w["url"].as_str().unwrap_or("").to_string(),
                        w["last_error_message"].as_str().unwrap_or("").to_string(),
                        w["pending_update_count"].as_i64().unwrap_or(0),
                    ),
                    Err(_) => (String::new(), "getWebhookInfo xatosi".into(), 0),
                };

            let want_hook = format!("{origin}/api/telegram/webhook");
            let hook_ok = hook_url == want_hook;

            ok_nostore(json!({
                "bot_token_configured": token_ok,
                "bot_reachable": bot_ok,
                "bot_username": bot_username,
                "expected_bot": BOT_USERNAME,
                // Telegram AYTGAN manzil (workerning taxmini emas).
                "webhook_registered": hook_ok,
                "webhook_url": hook_url,
                "webhook_expected": want_hook,
                "webhook_last_error": hook_err,
                "webhook_pending": hook_pending,
                "max_devices": MAX_SESSIONS_PER_USER,
                // Katta-kichik harf E'TIBORGA OLINMAYDI: Telegram
                // username'ni shunday tushunadi, ya'ni yozuvdagi
                // farq xato EMAS. Ilgari bu qat'iy `==` edi va
                // sog'liq tekshiruvi bekordan-bekorga "ishlamayapti"
                // deb turardi.
                // Webhook ham shartga KIRDI: usiz bot jim turadi,
                // lekin tekshiruv "hammasi joyida" derdi.
                "ok": token_ok && bot_ok && hook_ok
                    && bot_username.eq_ignore_ascii_case(BOT_USERNAME),
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

            // ── PROFIL RASMI: URINAMIZ, LEKIN BLOKLAMAYMIZ ────
            //
            // TOPILGAN XATO (foydalanuvchi: "accountni umuman
            // o'chirib bo'lmayapti").
            //
            // Ilgari rasm o'chmasa BUTUN amal to'xtardi va 502
            // qaytardi. B2 bir zumga javob bermasa yoki kalit
            // muddati o'tsa, foydalanuvchi hisobini UMUMAN
            // o'chira olmasdi — bu esa eng yomon holat.
            //
            // Endi rasm o'chmasa ham hisob o'chadi, fayl nomi esa
            // `orphan_files` ga yoziladi. Ya'ni fayl "yo'qolib"
            // ketmaydi: uni keyin topib o'chirish mumkin.
            let avatar = u["avatar_file"].as_str().unwrap_or("").to_string();
            let avatar_gone = avatar.is_empty()
                || b2_delete_checked(env, &avatar).await;

            // ── NIMA O'CHADI, NIMA QOLADI ─────────────────────
            //
            // TALAB (foydalanuvchi): "hisob o'chirilganda unga
            // tegishli va Turso'dagi statistikaga ta'sir
            // qilmaydigan ma'lumotlar tozalab tashlansin".
            //
            // O'CHADI — odamning O'ZIGA tegishli hamma narsa:
            // hisob, sessiyalar, kirish kodlari, tomosha tarixi,
            // sevimlilar va BAHOLAR.
            //
            // QOLADI — TARIXIY jamlanmalar: statistika chelaklari
            // (`stats_hourly` / `stats_daily`) hamda qism va
            // bo'limning `views_total` / `watch_ms_total`
            // hisoblagichlari. Ular "o'tgan kuni shuncha bo'lgan"
            // degan yozuv, ya'ni bir odam ketgani bilan o'tmish
            // o'zgarmasligi kerak.
            //
            // TUZATILADI — HOZIRGI holatni sanaydigan raqamlar:
            // `season_db.fav_count` (nechta odamning sevimlisida
            // turibdi) va reyting (`rating_sum` / `rating_count`).
            //
            // NEGA BAHO HAM O'CHADI: bir odam hisobini 3-4 marta
            // o'chirib, har safar yangi hisobdan baho bersa
            // reyting soxtalashadi (foydalanuvchi topgan xato).
            let mine = turso_many(env, &[
                ("SELECT anime_id,season_id,stars FROM ratings_db WHERE user_id=?",
                 vec![TursoArg::int(me)]),
                ("SELECT anime_id,season_id FROM favorites_db WHERE user_id=?",
                 vec![TursoArg::int(me)]),
            ]).await?;

            let rows_of = |res: &Value| -> Vec<Value> {
                let cols = res["cols"].as_array().cloned().unwrap_or_default();
                res["rows"].as_array().cloned().unwrap_or_default().iter()
                    .map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![])))
                    .collect()
            };

            // Bo'lim bo'yicha jamlanadi: bitta odam bitta bo'limga
            // bitta baho va bitta sevimli qo'ya oladi, lekin
            // yozuvlar bo'lim bo'yicha guruhlansa yozuv soni ham
            // kamayadi.
            let mut fix: std::collections::HashMap<(i64, i64), (i64, i64, i64)> =
                std::collections::HashMap::new();
            let empty = json!({});
            for r in rows_of(mine.first().unwrap_or(&empty)) {
                let k = (r["anime_id"].as_i64().unwrap_or(0), r["season_id"].as_i64().unwrap_or(0));
                let e = fix.entry(k).or_insert((0, 0, 0));
                e.0 -= r["stars"].as_i64().unwrap_or(0);
                e.1 -= 1;
            }
            for r in rows_of(mine.get(1).unwrap_or(&empty)) {
                let k = (r["anime_id"].as_i64().unwrap_or(0), r["season_id"].as_i64().unwrap_or(0));
                fix.entry(k).or_insert((0, 0, 0)).2 -= 1;
            }

            let mut stmts: Vec<(&str, Vec<TursoArg>)> = Vec::new();
            for ((aid, sid), (rsum, rcount, fav)) in &fix {
                stmts.push((
                    "UPDATE season_db SET
                        rating_sum = MAX(rating_sum + ?, 0),
                        rating_count = MAX(rating_count + ?, 0),
                        fav_count = MAX(fav_count + ?, 0)
                      WHERE anime_id=? AND season_id=?",
                    vec![
                        TursoArg::int(*rsum), TursoArg::int(*rcount), TursoArg::int(*fav),
                        TursoArg::int(*aid), TursoArg::int(*sid),
                    ],
                ));
            }
            if !avatar_gone {
                stmts.push((
                    "INSERT OR IGNORE INTO orphan_files (file_name,noted_at)
                     VALUES (?,?)",
                    vec![TursoArg::text(&avatar), TursoArg::int(now_ms())],
                ));
            }
            for sql in [
                "DELETE FROM ratings_db WHERE user_id=?",
                "DELETE FROM favorites_db WHERE user_id=?",
                "DELETE FROM watch_history_db WHERE user_id=?",
                "DELETE FROM sync_batches WHERE user_id=?",
                "DELETE FROM payments_db WHERE user_id=?",
                "DELETE FROM subs_db WHERE user_id=?",
                "DELETE FROM billing_log WHERE user_id=?",
            ] {
                stmts.push((sql, vec![TursoArg::int(me)]));
            }
            // ── IKKI BOSQICH: BIRINCHISI YIQILSA HAM HISOB O'CHADI ──
            //
            // Turso quvurida bitta buyruq yiqilsa BUTUN quvur
            // to'xtaydi. Agar hisoblagichlarni tuzatish yiqilsa
            // (masalan bo'lim allaqachon o'chirilgan bo'lsa),
            // hisobning O'ZI ham o'chmay qolardi — foydalanuvchi
            // esa hisobidan abadiy qutula olmasdi.
            //
            // Shu sabab: 1) tuzatish va shaxsiy yozuvlar —
            // XOHISHGA KO'RA (xatosi yutiladi); 2) hisobning
            // o'zi — MAJBURIY.
            let _ = turso_batch(env, &stmts).await;

            let must: Vec<(&str, Vec<TursoArg>)> = [
                "DELETE FROM sessions_db WHERE user_id=?",
                "DELETE FROM login_tokens WHERE user_id=?",
                "DELETE FROM users_db WHERE id=?",
            ].iter().map(|sql| (*sql, vec![TursoArg::int(me)])).collect();
            if let Err(e) = turso_batch(env, &must).await {
                return json_resp(&json!({
                    "error": format!("Hisobni o'chirib bo'lmadi: {e}")
                }), 500);
            }

            ok_nostore(json!({"success": true, "orphan_avatar": !avatar_gone}))
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
                // Xesh VA eski ochiq ko'rinish — ikkovi ham o'chiriladi:
                // hali xeshga o'tmagan qator ham chiqib ketsin.
                let _ = turso_exec(env,
                    "DELETE FROM sessions_db WHERE session_token IN (?, ?)",
                    vec![TursoArg::text(&token_hash(&t)), TursoArg::text(&t)]).await;
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
                    // Bazadagi qiymat — XESH, shu sabab solishtirishdan
                    // oldin bearer ham xeshlanadi. Eski (xeshlanmagan)
                    // qator uchun xom token bilan ham solishtiriladi.
                    let th = token_hash(&t);
                    let is_current = m.get("session_token")
                        .and_then(|v| v.as_str())
                        .map(|s| s == th || s == t)
                        .unwrap_or(false);
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

// ══════════════════════════════════════════════════════════════
//  FAQAT ILOVAGA JAVOB BERAMIZ
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi):
//   * "Workerni faqat ilovaga javob beradigan qil, tashqi
//      so'rovlar rad etilsin va hujumlarga chidamli qil";
//   * "admin panelga versiya raqam yozadigan bo'lim qo'sh ...
//      Worker shu va shundan katta versiyalarda ishlaydi";
//   * "APP_KEY nimaga kerak? ... busiz ishlaydigan qilish kerak,
//      ya'ni worker ilovaning haqiqiyligini tekshirishi kerak".
//
// ── NEGA KALIT EMAS, IMZO ───────────────────────────────────
//
// Foydalanuvchi haq edi. APK'ga qo'yilgan sir — shunchaki APK
// ichidagi matn: uni ochib o'qish mumkin va u hech narsani
// ISBOTLAMAYDI.
//
// Imzo sertifikati esa boshqacha: uni ilova o'zi tanlamaydi,
// TIZIM beradi. Kimdir ilovani o'zgartirib qayta yig'sa, uni
// O'Z kaliti bilan imzolashga majbur — bizning kalitimiz unda
// yo'q. Natijada hash boshqacha chiqadi va bu yerda rad
// etiladi. Ustiga GitHub Secrets ham, APK'ni qayta yig'ish ham
// kerak emas: hash admin panelidan bir bosishda qo'yiladi.
//
// ── IKKI SARLAVHA ───────────────────────────────────────────
//
//   `X-App-Sig`     — APK imzosining SHA-256 hash'i (base64).
//   `X-App-Version` — ilova versiyasi (`0.0.9+230`).
//
// ── ROSTINI AYTISH KERAK ────────────────────────────────────
//
// Hash'ning O'ZINI APK'dan o'qib, so'rovni qo'lda yasash
// mumkin. Ya'ni bu:
//   * O'ZGARTIRILGAN ILOVANI to'xtatadi — asosiy maqsad shu;
//   * brauzer, qidiruv botlari va oddiy skriptlarni to'xtatadi
//     (so'rovlarning aksariyati);
//   * maqsadli hujumchini to'xtatmaydi.
// Mutlaq yechim (Play Integrity) Play Store'ni talab qiladi,
// bu ilova esa APK bo'lib tarqatiladi. Haqiqiy himoya baribir
// sessiya tekshiruvi, admin huquqlari va so'rov chegarasida.
//
// ── XAVFSIZ ODATIY HOLAT ────────────────────────────────────
//
// Kutilgan hash SOZLANMAGAN bo'lsa tekshiruv umuman ishlamaydi.
// Aks holda uni qo'yishni unutish butun ilovani o'chirib
// qo'yardi — tuzatib bo'lmaydigan holat, chunki eski ilovalar
// ham kira olmay qolardi.

/// Bu yo'lga ilova tekshiruvi shartmi.
fn needs_app_check(path: &str) -> bool {
    // Telegram webhook — Telegram serveridan keladi, unda bizning
    // kalitimiz yo'q. U o'z siri bilan himoyalangan.
    if path.starts_with("/api/telegram/") {
        return false;
    }
    // ── TO'LOV WEBHOOK'I ─────────────────────────────────────
    //
    // TOPILGAN XATO: ilova imzosi tekshiruvi yoqilganda bu yo'l
    // 403 qaytarardi va webhook HECH QACHON ishlamasdi.
    //
    // Sabab: uni tezcheck.uz SERVERI chaqiradi, ilova emas. Unda
    // APK imzosi yo'q va hech qachon bo'lmaydi — xuddi Telegram
    // webhook'idagi kabi.
    //
    // Himoyasiz qolmaydi: haqiqiyligini HMAC-SHA256 IMZOSI
    // tasdiqlaydi (`billing_webhook` izohiga qarang), va u APK
    // imzosidan kuchliroq — APK imzosining hash'ini ilovani
    // ochgan har kim topa oladi, webhook sirini esa faqat biz va
    // tezcheck.uz bilamiz.
    if path == "/api/billing/webhook" {
        return false;
    }
    // ── VIDEO VA RASM YO'LLARI ENDI OCHIQ EMAS ───────────────
    //
    // TALAB (foydalanuvchi): "worker faqat yangi xavfsiz ilovaga
    // javob bersin va tashqaridan hech kim hech narsa so'ray
    // olmasin".
    //
    // Ilgari bu yo'llar (`/api/image/`, `/api/avatar/`,
    // `/api/media/`, `/api/play`, `/api/warm`) ro'yxatdan OZOD
    // edi. Sabab texnik edi: bu so'rovlarni Flutter emas, Rust
    // yadrosi yuboradi va u imzo yasay olmasdi. Oqibati: eski
    // (imzosiz) ilovada ham video bemalol ochilaverardi.
    //
    // Endi yadro ham imzolaydi (`rust/src/video_cache.rs` dagi
    // `signed()` va `crate::sign_v2`), shu sabab ozodlik kerak
    // emas va u OLIB TASHLANDI.
    //
    // DIQQAT: yadro va ilova AYNAN bir xil kalit bilan
    // yig'ilishi shart. Aks holda video ham, posterlar ham
    // ochilmay qoladi. Zudlik bilan qaytarish yo'li:
    // `wrangler secret delete APP_SIGN_SECRET` — o'shanda
    // tekshiruv butunlay o'chadi.
    // Qolgan HAMMA `/api/` so'rovi ilovadan kelishi kerak.
    path.starts_with("/api/")
}

/// `0.0.9+230` yoki `0.0.9` ni solishtirsa bo'ladigan songa
/// aylantiradi.
///
/// TALAB (foydalanuvchi): "versiya raqamini yozaman 0.0.9+9 yoki
/// 0.0.9 qilib yozaman".
///
/// Ikkala ko'rinish ham qabul qilinadi. Hisob:
///   `major*1_000_000_000 + minor*1_000_000 + patch*1000 + build`
/// Bo'lak yo'q bo'lsa 0 deb olinadi, ya'ni `0.0.9` = `0.0.9+0`
/// va u `0.0.9+9` dan KICHIK — eng past chegara `0.0.9` deb
/// qo'yilsa, `0.0.9+9` ham o'tadi.
fn version_rank(v: &str) -> i64 {
    let v = v.trim();
    if v.is_empty() {
        return -1;
    }
    let (ver, build) = match v.split_once('+') {
        Some((a, b)) => (a, b.trim().parse::<i64>().unwrap_or(0)),
        None => (v, 0),
    };
    let mut parts = ver.split('.');
    let num = |p: Option<&str>| -> i64 {
        p.and_then(|x| x.trim().parse::<i64>().ok()).unwrap_or(0)
    };
    let major = num(parts.next());
    let minor = num(parts.next());
    let patch = num(parts.next());
    major * 1_000_000_000 + minor * 1_000_000 + patch * 1000 + build.clamp(0, 999)
}

// ── ENG PAST VERSIYA IZOLYAT XOTIRASIDA ─────────────────────
//
// TOPILGAN XATO (foydalanuvchi: "pleyer va yozishmadagi video
// judayam sekin ochilyapti").
//
// Ilovadan kelgan HAR BIR so'rov (jumladan yadroning videoni
// isitish, kadr va yuklab olish uchun yuboradigan o'nlab oraliq
// so'rovlari) `app_min_version` ni Turso bazasidan o'qirdi — ya'ni
// har bir so'rovga yana bitta tarmoq borib-kelishi qo'shilardi.
//
// Qiymat juda kam o'zgaradi (admin qo'lda qo'yadi), shu sabab u
// izolyat xotirasida 60 soniya saqlanadi. Admin o'zgartirsa shu
// izolyatdagi nusxa darhol tozalanadi, boshqalarida esa ko'pi
// bilan bir daqiqada yangilanadi.
const MIN_VERSION_TTL_MS: i64 = 60_000;

thread_local! {
    static MIN_VERSION_CACHE: std::cell::RefCell<Option<(i64, Option<String>)>> =
        const { std::cell::RefCell::new(None) };
}

async fn min_version_cached(env: &Env) -> Option<String> {
    let now = now_ms();
    let hit = MIN_VERSION_CACHE.with(|c| {
        c.borrow()
            .as_ref()
            .filter(|(at, _)| now - *at < MIN_VERSION_TTL_MS)
            .map(|(_, v)| v.clone())
    });
    if let Some(v) = hit {
        return v;
    }
    let v = config_get(env, "app_min_version").await;
    MIN_VERSION_CACHE.with(|c| *c.borrow_mut() = Some((now, v.clone())));
    v
}

/// Imzo shuncha soniyadan eski bo'lsa qabul qilinmaydi.
///
/// 120 soniya — telefon soati bir oz og'ishiga va sekin tarmoqqa
/// yetadigan, lekin nusxa ko'chirilgan sarlavhani uzoq ishlatishga
/// imkon bermaydigan oraliq.
const APP_SIG_SKEW_SECS: i64 = 120;

/// `X-App-Sig: v2.<vaqt>.<hex>` ni tekshiradi.
///
/// Imzolanadigan matn: `"<vaqt>.<METOD>.<yo'l>"`.
fn verify_app_sig(secret: &str, got: &str, method: &str, path: &str) -> bool {
    let mut parts = got.split('.');
    if parts.next() != Some("v2") {
        return false;
    }
    let (Some(ts), Some(mac)) = (parts.next(), parts.next()) else {
        return false;
    };
    // Ortiqcha bo'lak bo'lsa — yaroqsiz.
    if parts.next().is_some() {
        return false;
    }
    let Ok(ts_num) = ts.parse::<i64>() else {
        return false;
    };
    if (now_ms() / 1000 - ts_num).abs() > APP_SIG_SKEW_SECS {
        return false;
    }

    let Ok(mut h) = <hmac::Hmac<sha2::Sha256> as hmac::Mac>::new_from_slice(secret.as_bytes())
    else {
        return false;
    };
    hmac::Mac::update(&mut h, format!("{ts}.{}.{path}", method.to_uppercase()).as_bytes());
    let want = hex_of(&hmac::Mac::finalize(h).into_bytes());
    // Uzunligi bir xil bo'lsa — belgi-belgi solishtirish.
    want.len() == mac.len() && want.eq_ignore_ascii_case(mac)
}

/// `/api/play/...` va `/api/media/...` uchun manzildagi tokenni
/// tekshiradi.
///
/// ── NEGA PLEYER UCHUN ALOHIDA YO'L ──────────────────────────
///
/// TOPILGAN XATO: bu manzilni bizning kodimiz emas, ExoPlayer'ning
/// o'zi ochadi (`VideoPlayerController.networkUrl`). Unga sarlavha
/// qo'shib bo'lmaydi — ya'ni yo'l yopilgach video butunlay
/// ishlamay qoldi.
///
/// Sarlavha o'rniga manzilning o'zida token keladi:
///
///     /api/play/<fayl>?t=<muddat>.<hex HMAC>
///     imzolanadigan matn: "play.<yo'l>.<muddat>"
///
/// Oddiy imzo bu yerda yaramaydi: u 2 daqiqada o'ladi, ijro esa
/// soatlab davom etadi va ExoPlayer butun davomida oraliq
/// so'rovlar yuboradi.
///
/// Token AYNAN SHU faylga bog'langan va muddati bor. Uni yasash
/// uchun kalit kerak — begona dastur o'zi yasay olmaydi.
fn verify_play_token(secret: &str, token: &str, path: &str) -> bool {
    let Some((exp, mac)) = token.split_once('.') else {
        return false;
    };
    let Ok(exp_num) = exp.parse::<i64>() else {
        return false;
    };
    if now_ms() / 1000 > exp_num {
        return false;
    }
    let Ok(mut h) = <hmac::Hmac<sha2::Sha256> as hmac::Mac>::new_from_slice(secret.as_bytes())
    else {
        return false;
    };
    hmac::Mac::update(&mut h, format!("play.{path}.{exp}").as_bytes());
    let want = hex_of(&hmac::Mac::finalize(h).into_bytes());
    want.len() == mac.len() && want.eq_ignore_ascii_case(mac)
}

/// So'rovni o'tkazamizmi. `None` — o'tadi, `Some(resp)` — rad.
async fn app_gate(req: &Request, env: &Env, path: &str) -> Option<Response> {
    if !needs_app_check(path) {
        return None;
    }
    let head = |k: &str| -> String {
        req.headers().get(k).ok().flatten().unwrap_or_default()
    };

    // ── 1. SO'ROV IMZOSI ─────────────────────────────────────
    //
    // ── NEGA ESKI USUL YETARLI EMAS EDI ────────────────────
    //
    // Ilgari `X-App-Sig` da APK sertifikatining hash'i turardi va
    // u O'ZGARMAS satr edi. Ikkita jiddiy kamchilik:
    //
    //   1. U SIR EMAS. Hash — ochiq ma'lumot: APK'ni ochgan har
    //      kim uni hisoblab oladi, admin oynasida ham ko'rinadi.
    //   2. U O'ZGARMAYDI. Bir marta nusxa ko'chirilgach abadiy
    //      ishlaydi — istalgan skriptga qo'yib yuborish kifoya.
    //
    // (Bu nazariy gap emas: tirik serverda sinab ko'rilganda
    // skrinshotdan ko'chirilgan hash bemalol o'tdi.)
    //
    // ── YANGI USUL ──────────────────────────────────────────
    //
    //   X-App-Sig: v2.<vaqt>.<hex HMAC-SHA256>
    //   imzolanadigan matn: "<vaqt>.<METOD>.<yo'l>"
    //   kalit: `APP_SIGN_SECRET` — ilova va server IKKALASI
    //          biladigan sir.
    //
    // Nima o'zgaradi:
    //   * nusxa ko'chirilgan sarlavha 2 DAQIQADAN keyin o'lik
    //     (vaqt tamg'asi tekshiriladi);
    //   * bitta yo'l uchun olingan imzo BOSHQA yo'lga yaramaydi
    //     (metod va yo'l imzo ichida);
    //   * sir ilovada Rust yadrosida (native `.so`) turadi —
    //     uni chiqarib olish Dart satridan ko'chirishdan ancha
    //     qiyin.
    //
    // ── SIR QO'YILMAGAN BO'LSA ──────────────────────────────
    //
    // Eski qoida (`app_config` dagi hash) ishlaydi. Bu ATAYLAB:
    // sir qo'yilishidan OLDIN deploy qilinsa, ilova uzilib
    // qolmasligi kerak. Sir qo'yilgan zahoti tekshiruv QAT'IY
    // bo'ladi va eski imzo umuman qabul qilinmaydi.
    // ── FAQAT YANGI USUL ─────────────────────────────────────
    //
    // TALAB (foydalanuvchi): "faqat yangi APK'lar ishlaydigan qil".
    //
    // O'tish davri tugadi. Sir qo'yilgan bo'lsa — SO'ROV FAQAT
    // `v2.<vaqt>.<HMAC>` imzosi bilan o'tadi. Eski o'zgarmas hash
    // endi umuman qabul qilinmaydi.
    //
    // MUHIM OQIBAT: admin oynasidagi "Shu ilovaga ishonish"
    // tugmasi endi bu eshikka TA'SIR QILMAYDI. Ilgari u imzolar
    // ro'yxatini to'ldirib, eski APK'larni qayta o'tkazardi.
    // Endi ro'yxat to'ldirilgani bilan eski APK baribir 403
    // oladi — chunki uning imzosi `v2` emas.
    //
    // ── SIR QO'YILMAGAN BO'LSA ──────────────────────────────
    //
    // Eski qoida ishlaydi. Bu ataylab: sir tasodifan o'chib
    // ketsa yoki hali qo'yilmagan bo'lsa, ilova butunlay
    // ishlamay qolgandan ko'ra eski yo'l bilan ishlagani
    // yaxshiroq.
    let secret = env
        .secret("APP_SIGN_SECRET")
        .map(|s| s.to_string().trim().to_string())
        .unwrap_or_default();
    let got = head("X-App-Sig");

    // ── MANZILDAGI TOKEN ────────────────────────────────────
    //
    // Ba'zi manzillarni ilova emas, ANDROID'NING O'ZI ochadi va
    // ularga sarlavha qo'shib bo'lmaydi:
    //
    //   `/api/play/`   — ExoPlayer (video oqimi);
    //   `/api/media/`  — yozishmadagi video;
    //   `/api/image/`  — admin oynasidagi `Image.network` ko'rinishi;
    //   `/api/avatar/` — xuddi shunday.
    //
    // Ular uchun ruxsat manzilning o'zida keladi
    // (`verify_play_token` izohiga qarang).
    //
    // MUHIM: token bo'lmasa DARHOL rad etilmaydi — pastdagi
    // odatdagi sarlavha tekshiruviga o'tiladi. Chunki aynan shu
    // yo'llarni Rust yadrosi ham so'raydi va u SARLAVHA bilan
    // keladi. Ikkala yo'l ham ochiq bo'lishi shart.
    if !secret.is_empty()
        && (path.starts_with("/api/play/")
            || path.starts_with("/api/media/")
            || path.starts_with("/api/image/")
            || path.starts_with("/api/avatar/"))
    {
        let token = req
            .url()
            .ok()
            .and_then(|u| {
                u.query_pairs()
                    .find(|(k, _)| k == "t")
                    .map(|(_, v)| v.to_string())
            })
            .unwrap_or_default();
        if !token.is_empty() && verify_play_token(&secret, &token, path) {
            return None;
        }
    }

    if !secret.is_empty() {
        if !verify_app_sig(&secret, &got, req.method().to_string().as_str(), path) {
            return Some(
                json_resp(&json!({"error": "forbidden"}), 403)
                    .unwrap_or_else(|_| Response::empty().unwrap()),
            );
        }
    } else if let Some(want) = config_get(env, "app_sig").await {
        let ok = !got.is_empty() && want.split(',').any(|w| w.trim() == got);
        if !ok {
            return Some(
                json_resp(&json!({"error": "forbidden"}), 403)
                    .unwrap_or_else(|_| Response::empty().unwrap()),
            );
        }
    }

    // ── 2. VERSIYA ───────────────────────────────────────────
    //
    // Eng past ruxsat etilgan versiya admin panelidan
    // o'rnatiladi. Qo'yilmagan bo'lsa tekshiruv yo'q.
    let Some(min) = min_version_cached(env).await else {
        return None;
    };
    let min_rank = version_rank(&min);
    if min_rank <= 0 {
        return None;
    }
    let got = head("X-App-Version");
    // Versiyasini aytmagan ilova — eski ilova. O'tkazilmaydi.
    let rank = version_rank(&got);
    if rank < min_rank {
        return Some(
            json_resp(&json!({
                "error": "Ilovaning yangi versiyasini o'rnating",
                "min_version": min,
                "upgrade": true,
            }), 426)
            .unwrap_or_else(|_| Response::empty().unwrap()),
        );
    }
    None
}

// ── Router ─────────────────────────────────────────────────────

#[event(fetch)]
async fn main(req: Request, env: Env, ctx: Context) -> Result<Response> {
    let url = req.url()?;
    let path = url.path().to_string();
    let query = url.query().map(|q| q.to_string());
    let method = req.method();

    // ── FAQAT ILOVADAN (foydalanuvchi talabi) ────────────────
    //
    // Tekshiruv keshdan ham OLDIN: aks holda tashqi so'rov
    // keshdagi javobni olib ketardi.
    //
    // `OPTIONS` (CORS oldindan so'rovi) o'tkaziladi — brauzer uni
    // sarlavhalarsiz yuboradi va rad etilsa haqiqiy so'rov ham
    // ketmasdi.
    if method != Method::Options {
        if let Some(deny) = app_gate(&req, &env, &path).await {
            let mut deny = deny;
            set_cors(&mut deny);
            return Ok(deny);
        }
    }

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
        || path == "/api/favorites"
        || path.starts_with("/api/me/")
        || path == "/api/sync"
        || path.starts_with("/api/billing")
        // Izohlarda "men layk bosganmi" belgisi bor — ya'ni javob
        // HAR BIR ODAM uchun boshqacha. Uni chekkada keshlash
        // boshqa odamning belgisini ko'rsatib qo'yardi.
        || path.starts_with("/api/comments")
        // Yozishma HAR BIR ODAM uchun boshqacha va u katalogga
        // umuman aloqasi yo'q — keshni kuydirmaydi.
        || path.starts_with("/api/chat")
        // Admin amallari katalogga aloqasi yo'q — keshni
        // kuydirmaydi.
        || path.starts_with("/api/admin/")
        // Shikoyat yuborish ham katalogga tegmaydi.
        || path.starts_with("/api/reports");
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
            // Javob HECH O'ZGARTIRILMASDAN uzatiladi — trafikni
            // endi ilovaning o'zi sanaydi (`note_traffic` izohi).
            return b2_proxy(&env, &ctx, fname, range_header).await;
        }
        // Yozishmadagi rasm/video — oraliq qisqartirilmaydi
        // (`b2_media` izohiga qarang).
        if let Some(fname) = path.strip_prefix("/api/media/") {
            return b2_media(&env, fname, range_header).await;
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

    // ── YAGONA YOZUV YO'LI ────────────────────────────────────
    //
    // Tomosha tarixi, baho, sevimlilar va trafik — hammasi BITTA
    // paketda keladi (`sync_route` izohiga qarang).
    if path == "/api/sync" && method == Method::Post {
        return sync_route(req, &env).await;
    }

    // ── BALANS, OBUNA VA TO'LOVLAR ────────────────────────────
    if path == "/api/billing" && method == Method::Get {
        return billing_state(req, &env).await;
    }
    if path == "/api/billing/create" && method == Method::Post {
        return billing_create(req, &env).await;
    }
    if path == "/api/billing/check" && method == Method::Post {
        return billing_check(req, &env).await;
    }
    if path == "/api/billing/subscribe" && method == Method::Post {
        return billing_subscribe(req, &env).await;
    }
    // Webhook — tezcheck.uz chaqiradi, foydalanuvchi emas. Shu
    // sabab bu yerda sessiya tekshirilmaydi: haqiqiyligini IMZO
    // tasdiqlaydi (`billing_webhook` izohiga qarang).
    if path == "/api/billing/webhook" && method == Method::Post {
        return billing_webhook(req, &env).await;
    }
    // ── MANZIL TEKSHIRUVI UCHUN 200 ─────────────────────────────
    //
    // TOPILGAN MUAMMO: tezcheck kabinetida bu manzilni qo'shib
    // bo'lmasdi. GET/HEAD ga 404 qaytardik, ya'ni tashqaridan
    // manzil "yo'q" bo'lib ko'rinardi. Endi oddiy 200: bu yo'l
    // hech narsa o'qimaydi va yozmaydi.
    if path == "/api/billing/webhook" && (method == Method::Get || method == Method::Head) {
        return ok_nostore(json!({"ok": true}));
    }
    // ── ILDIZ MANZIL HAM WEBHOOK ─────────────────────────────────
    //
    // TALAB (foydalanuvchi): tezcheck kabinetida faqat
    // `https://arumediatv.uzcom.workers.dev` manzili qo'shildi.
    // Ildizda boshqa hech narsa yo'q (ilgari 404 edi), shu sabab
    // bu yerga kelgan POST aynan o'sha `billing_webhook` ga
    // uzatiladi — imzo va tezcheck API orqali qayta tekshirish
    // xuddi o'sha.
    if path == "/" {
        if method == Method::Post {
            return billing_webhook(req, &env).await;
        }
        if method == Method::Get || method == Method::Head {
            return ok_nostore(json!({"ok": true}));
        }
    }

    // ── ADMIN BILAN YOZISHMA ──────────────────────────────────
    if path == "/api/chat" {
        if method == Method::Get {
            return chat_mine(&req, &env, &origin).await;
        }
        if method == Method::Post {
            return chat_send(req, &env, &origin).await;
        }
    }
    if path == "/api/chat/unread" && method == Method::Get {
        return chat_unread(&req, &env).await;
    }
    // Uzoq kutish — xabar kelishi bilan javob qaytadi
    // (`chat_wait` izohiga qarang).
    if path == "/api/chat/wait" && method == Method::Get {
        return chat_wait(&req, &env).await;
    }
    if path == "/api/chat/threads" && method == Method::Get {
        return chat_threads(&req, &env, &origin).await;
    }
    if path == "/api/chat/messages/delete" && method == Method::Post {
        return chat_del_many(req, &env).await;
    }
    if let Some(idv) = path.strip_prefix("/api/chat/thread/") {
        if let Ok(uid) = idv.parse::<i64>() {
            if method == Method::Get {
                return chat_one(&req, &env, &origin, uid, since_of(&req)).await;
            }
            if method == Method::Delete {
                return chat_del_thread(&req, &env, uid).await;
            }
        }
    }
    if method == Method::Delete {
        if let Some(mid) = path.strip_prefix("/api/chat/message/") {
            return chat_del_message(&req, &env, mid).await;
        }
    }

    // ── ADMIN: FOYDALANUVCHILARNI BOSHQARISH ──────────────────
    if path == "/api/admin/b2-cleanup" && method == Method::Post {
        return b2_cleanup(req, &env).await;
    }
    if path == "/api/admin/users" && method == Method::Get {
        return admin_users(&req, &env, &origin).await;
    }
    if method == Method::Post {
        if let Some(idv) = path.strip_prefix("/api/admin/user/") {
            if let Ok(uid) = idv.parse::<i64>() {
                return admin_user_action(req, &env, uid).await;
            }
        }
    }

    // ── MAXFIYLIK SOZLAMASI ───────────────────────────────────
    if path == "/api/me/privacy" && method == Method::Post {
        return me_privacy(req, &env).await;
    }

    // ── SHIKOYATLAR ───────────────────────────────────────────
    if path == "/api/reports" && method == Method::Post {
        return report_add(req, &env).await;
    }
    if path == "/api/admin/reports" && method == Method::Get {
        return admin_reports(&req, &env, &origin).await;
    }
    if path == "/api/admin/badges" && method == Method::Get {
        return admin_badges(&req, &env).await;
    }
    if path == "/api/admin/app"
        && (method == Method::Get || method == Method::Post)
    {
        return admin_app_config(req, &env).await;
    }
    if method == Method::Delete {
        if let Some(rid) = path.strip_prefix("/api/admin/report/") {
            return admin_report_delete(&req, &env, rid).await;
        }
    }

    // ── OMMAVIY PROFIL VA UNING STATISTIKA OYNALARI ───────────
    if method == Method::Get {
        if let Some(rest) = path.strip_prefix("/api/user/") {
            let parts: Vec<&str> = rest.split('/').collect();
            // /api/user/:id
            if parts.len() == 1 {
                if let Ok(uid) = parts[0].parse::<i64>() {
                    return public_profile(&req, &env, &origin, uid).await;
                }
            }
            // /api/user/:id/stats/:kind
            if parts.len() == 3 && parts[1] == "stats" {
                if let Ok(uid) = parts[0].parse::<i64>() {
                    return user_stats_list(&req, &env, &origin, uid, parts[2]).await;
                }
            }
        }
    }

    // ── IZOHLAR ───────────────────────────────────────────────
    //
    // O'qish OCHIQ (kirmagan odam ham ko'radi), yozish esa faqat
    // kirgan odamga.
    if path == "/api/comments" && method == Method::Post {
        return comments_add(req, &env, &origin).await;
    }
    if path == "/api/comments/like" && method == Method::Post {
        return comments_like(req, &env).await;
    }
    if let Some(rest) = path.strip_prefix("/api/comments/") {
        let parts: Vec<&str> = rest.split('/').collect();
        // /api/comments/:anime/:season[/:parent]
        if (parts.len() == 2 || parts.len() == 3) && method == Method::Get {
            if let (Ok(a), Ok(sd)) =
                (parts[0].parse::<i64>(), parts[1].parse::<i64>())
            {
                let parent = if parts.len() == 3 { parts[2] } else { "" };
                return comments_list(&req, &env, &origin, a, sd, parent).await;
            }
        }
        // /api/comments/:id — o'z izohini o'chirish
        if parts.len() == 1 && method == Method::Delete {
            return comments_delete(&req, &env, parts[0]).await;
        }
    }

    // ── SHAXSIY STATISTIKA VA SEVIMLILAR RO'YXATI ─────────────
    if path == "/api/me/stats" && method == Method::Get {
        return me_stats_route(req, &env).await;
    }
    if path == "/api/favorites" && method == Method::Get {
        return favorites_route(req, &env, &origin).await;
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
                "INSERT INTO anime_db (id,photo_url,name,davlat,studiya,janri,tavsif)
                 VALUES (?,?,?,?,?,?,?) RETURNING *",
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
                "INSERT INTO season_db (anime_id,season_id,bolim_id,photo_url,nomi,studio,tarjimon,yili,janri,turi,holati,tavsif,yosh,created_at)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::int(anime_id), TursoArg::int(sid), TursoArg::int(bid),
                    TursoArg::text(&pu), TursoArg::text(&nomi), TursoArg::text(&studio),
                    TursoArg::text(&tarjimon), TursoArg::text(&yili), TursoArg::text(&janri_text),
                    TursoArg::text(&turi), TursoArg::text(&holati), TursoArg::text(&tavsif),
                    // Yosh chegarasi BO'LIMning o'ziga yoziladi
                    // (foydalanuvchi talabi: "yosh chegarasi bitta
                    // bo'lim uchun amal qiladi").
                    TursoArg::int(yosh_of(&b["yosh"])),
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
            let ef = epizod_fields(&b);
            let new_id = next_epizod_id(&env).await?;
            let mut args = vec![
                TursoArg::text(&anime_id), TursoArg::text(&season_id), TursoArg::int(new_id),
                TursoArg::int(ef.number), TursoArg::text(&ef.name),
            ];
            for m in &ef.media { args.push(TursoArg::text(m)); }
            for v in &ef.intros { args.push(TursoArg::text(v)); }
            args.push(TursoArg::int(now_ms()));
            let res = turso_exec(&env,
                "INSERT INTO epizod_db (anime_id,season_id,epizod_id,epizod_number,epizod_name,url_360p,size_360p,url_480p,size_480p,url_720p,size_720p,url_1080p,size_1080p,intro_1,intro_2,intro_3,intro_4,intro_5,intro_6,intro_7,intro_8,intro_9,intro_10,created_at)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                args,
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
                            let ef = epizod_fields(&b);
                            let mut args = vec![
                                TursoArg::int(ef.number), TursoArg::text(&ef.name),
                            ];
                            for m in &ef.media { args.push(TursoArg::text(m)); }
                            for v in &ef.intros { args.push(TursoArg::text(v)); }
                            args.push(TursoArg::int(aid));
                            args.push(TursoArg::int(sid));
                            args.push(TursoArg::int(eid));
                            let res = turso_exec(&env,
                                "UPDATE epizod_db SET epizod_number=?,epizod_name=?,url_360p=?,size_360p=?,url_480p=?,size_480p=?,url_720p=?,size_720p=?,url_1080p=?,size_1080p=?,
                                        intro_1=?,intro_2=?,intro_3=?,intro_4=?,intro_5=?,intro_6=?,intro_7=?,intro_8=?,intro_9=?,intro_10=?
                                 WHERE anime_id=? AND season_id=? AND epizod_id=? RETURNING *",
                                args,
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
                                "UPDATE season_db SET bolim_id=?,photo_url=?,nomi=?,studio=?,tarjimon=?,yili=?,janri=?,turi=?,holati=?,tavsif=?,yosh=?
                                 WHERE anime_id=? AND season_id=? RETURNING *",
                                vec![
                                    TursoArg::int(bid), TursoArg::text(&pu), TursoArg::text(&nomi),
                                    TursoArg::text(&studio), TursoArg::text(&tarjimon), TursoArg::text(&yili),
                                    TursoArg::text(&janri), TursoArg::text(&turi), TursoArg::text(&holati),
                                    TursoArg::text(&tavsif), TursoArg::int(yosh_of(&b["yosh"])),
                                    TursoArg::int(aid), TursoArg::int(sid),
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
                            // 4. season_db va unga bog'liq yozuvlar
                            let _ = turso_batch(&env, &[
                                ("DELETE FROM season_janr WHERE anime_id=? AND season_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid)]),
                                ("DELETE FROM ratings_db WHERE anime_id=? AND season_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid)]),
                                ("DELETE FROM favorites_db WHERE anime_id=? AND season_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid)]),
                                ("DELETE FROM season_db WHERE anime_id=? AND season_id=?",
                                 vec![TursoArg::int(aid), TursoArg::int(sid)]),
                            ]).await;
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

