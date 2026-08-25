// src/lib.rs — Cloudflare Worker (Rust + WASM)
// worker crate v0.8.5
//
// Ikkita jadval:
//   anime_db  — admin uchun "qaysi anime" registri (Animelarni boshqarish)
//   season_db — bosh sahifada ko'rinadigan bo'limlar (nomi, rasm, janr va h.k.)
// Hech qanday maydon majburiy emas.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use worker::*;

// ── CORS + JSON yordamchi funksiyalar ─────────────────────────

fn set_cors(resp: &mut Response) {
    let h = resp.headers_mut();
    let _ = h.set("Access-Control-Allow-Origin", "*");
    let _ = h.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    let _ = h.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
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
        RequestInit::new().with_method(Method::Post).with_headers(h).with_body(Some(body.to_string().into())),
    )?;
    let mut resp = Fetch::Request(req).send().await?;
    let data: Value = resp.json().await?;
    let r = &data["results"][0];
    if r["type"] == "error" {
        return Err(Error::RustError(r["error"]["message"].as_str().unwrap_or("Turso xato").to_string()));
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
        RequestInit::new().with_method(Method::Post).with_headers(h).with_body(Some(json!({"requests": reqs}).to_string().into())),
    )?;
    Fetch::Request(req).send().await?;
    Ok(())
}

async fn init_db(env: &Env) {
    let _ = turso_batch(env, &[
        ("CREATE TABLE IF NOT EXISTS anime_db (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            photo_url TEXT,
            name TEXT,
            davlat TEXT,
            studiya TEXT,
            janri TEXT,
            tavsif TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_name ON anime_db(name)", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_janri ON anime_db(janri)", vec![]),
        ("CREATE TABLE IF NOT EXISTS season_db (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            anime_id INTEGER,
            season_id INTEGER,
            photo_url TEXT,
            nomi TEXT,
            studio TEXT,
            tarjimon TEXT,
            yili TEXT,
            janri TEXT,
            turi TEXT,
            holati TEXT,
            tavsif TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_season_anime ON season_db(anime_id)", vec![]),
        ("CREATE INDEX IF NOT EXISTS idx_season_janri ON season_db(janri)", vec![]),
    ]).await;
}

// ── Backblaze B2 ──────────────────────────────────────────────

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

async fn b2_auth(env: &Env) -> Result<Value> {
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
        return Err(Error::RustError(format!("B2 auth xato: {}", d["message"].as_str().unwrap_or("unknown"))));
    }
    Ok(d)
}

async fn b2_bucket_id(api_url: &str, auth_token: &str) -> Result<String> {
    let mut h = Headers::new();
    h.set("Authorization", auth_token)?;
    let req = Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_buckets?bucketName=aniraxuz"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    let mut r = Fetch::Request(req).send().await?;
    let d: Value = r.json().await?;
    // MUHIM: agar B2 xato qaytarsa (status != 200) yoki "buckets" bo'sh
    // bo'lsa — bo'sh bucketId bilan davom etish o'rniga aniq xato beramiz.
    if r.status_code() != 200 {
        return Err(Error::RustError(format!(
            "B2 list_buckets xato: {}",
            d["message"].as_str().unwrap_or("unknown")
        )));
    }
    let bucket_id = d["buckets"][0]["bucketId"].as_str().unwrap_or("").to_string();
    if bucket_id.is_empty() {
        return Err(Error::RustError("B2 bucket 'aniraxuz' topilmadi".to_string()));
    }
    Ok(bucket_id)
}

async fn b2_get_upload_url(env: &Env) -> Result<Value> {
    let auth = b2_auth(env).await?;
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let bucket_id = b2_bucket_id(&api_url, &token).await?;
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
    // MUHIM: B2'ning o'z status kodini tekshiramiz. Xato bo'lsa, worker
    // ham xato statusi bilan javob beradi — Flutter buni to'g'ri ushlaydi
    // (avval bu yerda tekshiruv yo'q edi, shuning uchun "muvaffaqiyatli"
    // deb noto'g'ri hisoblanib, keyin uploadUrl==null xatosiga olib kelgan).
    if r.status_code() != 200 || d["uploadUrl"].is_null() {
        return Err(Error::RustError(format!(
            "B2 upload URL olishda xato: {}",
            d["message"].as_str().unwrap_or("uploadUrl topilmadi")
        )));
    }
    Ok(d)
}

async fn b2_proxy(env: &Env, file_name: &str) -> Result<Response> {
    let auth = b2_auth(env).await?;
    let dl_url = auth["apiInfo"]["storageApi"]["downloadUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let mut h = Headers::new();
    h.set("Authorization", &token)?;
    let req = Request::new_with_init(
        &format!("{dl_url}/file/aniraxuz/{file_name}"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    )?;
    let mut img = Fetch::Request(req).send().await?;
    if img.status_code() != 200 {
        let mut r = Response::empty()?.with_status(404);
        set_cors(&mut r);
        return Ok(r);
    }
    let ct = img.headers().get("Content-Type")?.unwrap_or_else(|| "image/jpeg".to_string());
    let bytes = img.bytes().await?;
    let mut resp = Response::from_bytes(bytes)?;
    set_cors(&mut resp);
    resp.headers_mut().set("Content-Type", &ct)?;
    resp.headers_mut().set("Cache-Control", "public, max-age=86400")?;
    Ok(resp)
}

async fn b2_delete(env: &Env, photo_url: &str) {
    let file_name = match photo_url.find("/api/image/") {
        Some(p) => &photo_url[p + 11..],
        None => return,
    };
    let auth = match b2_auth(env).await { Ok(a) => a, Err(_) => return };
    let api_url = auth["apiInfo"]["storageApi"]["apiUrl"].as_str().unwrap_or("").to_string();
    let token = auth["authorizationToken"].as_str().unwrap_or("").to_string();
    let bucket_id = match b2_bucket_id(&api_url, &token).await { Ok(id) => id, Err(_) => return };

    let mut h = Headers::new();
    let _ = h.set("Authorization", &token);
    let req = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_list_file_names?bucketId={bucket_id}&prefix={file_name}&maxFileCount=1"),
        RequestInit::new().with_method(Method::Get).with_headers(h),
    ) { Ok(r) => r, Err(_) => return };
    let mut r = match Fetch::Request(req).send().await { Ok(r) => r, Err(_) => return };
    let d: Value = match r.json().await { Ok(d) => d, Err(_) => return };
    let file_id = match d["files"][0]["fileId"].as_str() { Some(id) => id.to_string(), None => return };

    let mut h2 = Headers::new();
    let _ = h2.set("Authorization", &token);
    let _ = h2.set("Content-Type", "application/json");
    let req2 = match Request::new_with_init(
        &format!("{api_url}/b2api/v3/b2_delete_file_version"),
        RequestInit::new().with_method(Method::Post).with_headers(h2)
            .with_body(Some(json!({"fileName": file_name, "fileId": file_id}).to_string().into())),
    ) { Ok(r) => r, Err(_) => return };
    let _ = Fetch::Request(req2).send().await;
}

// ── season_db yordamchilari ─────────────────────────────────────

fn season_fields(b: &Value) -> (i64, String, String, String, String, String, String, String, String, String, String) {
    let season_id = b["season_id"].as_i64().unwrap_or(0);
    let photo_url = b["photo_url"].as_str().unwrap_or("").to_string();
    let nomi = b["nomi"].as_str().unwrap_or("").to_string();
    let studio = b["studio"].as_str().unwrap_or("").to_string();
    let tarjimon = b["tarjimon"].as_str().unwrap_or("").to_string();
    let yili = b["yili"].as_str().unwrap_or("").to_string();
    let janri = b["janri"].as_str().unwrap_or("").to_string();
    let turi = b["turi"].as_str().unwrap_or("").to_string();
    let holati = b["holati"].as_str().unwrap_or("").to_string();
    let tavsif = b["tavsif"].as_str().unwrap_or("").to_string();
    let anime_id = b["anime_id"].as_str().map(|s| s.to_string()).unwrap_or_default();
    (season_id, photo_url, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, anime_id)
}

// ── Router ────────────────────────────────────────────────────

#[event(fetch)]
async fn main(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let url = req.url()?;
    let path = url.path();
    let method = req.method();

    if method == Method::Options {
        let mut r = Response::empty()?;
        set_cors(&mut r);
        return Ok(r);
    }

    if method == Method::Get {
        if let Some(fname) = path.strip_prefix("/api/image/") {
            return b2_proxy(&env, fname).await;
        }
    }

    init_db(&env).await;

    match (method.clone(), path) {

        (Method::Get, "/api/anime") => {
            let res = turso_exec(&env, "SELECT * FROM anime_db ORDER BY id DESC LIMIT 100", vec![]).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            ok(json!(rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>()))
        }

        (Method::Post, "/api/anime") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let (pu, na, da, st, ja, ta) = (
                b["photo_url"].as_str().unwrap_or(""),
                b["name"].as_str().unwrap_or(""),
                b["davlat"].as_str().unwrap_or(""),
                b["studiya"].as_str().unwrap_or(""),
                b["janri"].as_str().unwrap_or(""),
                b["tavsif"].as_str().unwrap_or(""),
            );
            let res = turso_exec(&env,
                "INSERT INTO anime_db (photo_url,name,davlat,studiya,janri,tavsif) VALUES (?,?,?,?,?,?) RETURNING *",
                vec![TursoArg::text(pu), TursoArg::text(na), TursoArg::text(da), TursoArg::text(st), TursoArg::text(ja), TursoArg::text(ta)],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Qo'shib bo'lmadi"); }
            created(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])))
        }

        (Method::Post, "/api/upload-token") => {
            ok(b2_get_upload_url(&env).await?)
        }

        (Method::Get, "/api/seasons") => {
            let res = turso_exec(&env, "SELECT * FROM season_db ORDER BY id DESC LIMIT 200", vec![]).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            ok(json!(rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>()))
        }

        (Method::Post, "/api/seasons") => {
            let mut req = req;
            let b: Value = req.json().await?;
            let (season_id, pu, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, anime_id) = season_fields(&b);
            let res = turso_exec(&env,
                "INSERT INTO season_db (anime_id,season_id,photo_url,nomi,studio,tarjimon,yili,janri,turi,holati,tavsif)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                vec![
                    TursoArg::text(&anime_id), TursoArg::int(season_id), TursoArg::text(&pu),
                    TursoArg::text(&nomi), TursoArg::text(&studio), TursoArg::text(&tarjimon),
                    TursoArg::text(&yili), TursoArg::text(&janri), TursoArg::text(&turi),
                    TursoArg::text(&holati), TursoArg::text(&tavsif),
                ],
            ).await?;
            let cols = res["cols"].as_array().cloned().unwrap_or_default();
            let rows = res["rows"].as_array().cloned().unwrap_or_default();
            if rows.is_empty() { return err500("Bo'lim qo'shib bo'lmadi"); }
            created(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])))
        }

        _ => {
            if method == Method::Get {
                if let Some(janr) = path.strip_prefix("/api/anime/janr/") {
                    let res = turso_exec(&env, "SELECT * FROM anime_db WHERE janri = ? ORDER BY id DESC",
                        vec![TursoArg::text(janr)]).await?;
                    let cols = res["cols"].as_array().cloned().unwrap_or_default();
                    let rows = res["rows"].as_array().cloned().unwrap_or_default();
                    return ok(json!(rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>()));
                }
            }

            if method == Method::Get {
                if let Some(anime_id) = path.strip_prefix("/api/seasons/anime/") {
                    let res = turso_exec(&env, "SELECT * FROM season_db WHERE anime_id = ? ORDER BY season_id ASC",
                        vec![TursoArg::text(anime_id)]).await?;
                    let cols = res["cols"].as_array().cloned().unwrap_or_default();
                    let rows = res["rows"].as_array().cloned().unwrap_or_default();
                    return ok(json!(rows.iter().map(|r| row_to_obj(&cols, r.as_array().unwrap_or(&vec![]))).collect::<Vec<_>>()));
                }
            }

            if let Some(id_str) = path.strip_prefix("/api/seasons/") {
                if let Ok(id) = id_str.parse::<i64>() {
                    if method == Method::Put {
                        let mut req = req;
                        let b: Value = req.json().await?;
                        let (season_id, pu, nomi, studio, tarjimon, yili, janri, turi, holati, tavsif, anime_id) = season_fields(&b);

                        let old = turso_exec(&env, "SELECT photo_url FROM season_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let old_rows = old["rows"].as_array().cloned().unwrap_or_default();
                        if old_rows.is_empty() { return err404("Bo'lim topilmadi"); }
                        let old_cols = old["cols"].as_array().cloned().unwrap_or_default();
                        let old_photo = row_to_obj(&old_cols, old_rows[0].as_array().unwrap_or(&vec![]))
                            ["photo_url"].as_str().unwrap_or("").to_string();
                        if !old_photo.is_empty() && old_photo != pu { b2_delete(&env, &old_photo).await; }

                        turso_exec(&env, "DELETE FROM season_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let res = turso_exec(&env,
                            "INSERT INTO season_db (anime_id,season_id,photo_url,nomi,studio,tarjimon,yili,janri,turi,holati,tavsif)
                             VALUES (?,?,?,?,?,?,?,?,?,?,?) RETURNING *",
                            vec![
                                TursoArg::text(&anime_id), TursoArg::int(season_id), TursoArg::text(&pu),
                                TursoArg::text(&nomi), TursoArg::text(&studio), TursoArg::text(&tarjimon),
                                TursoArg::text(&yili), TursoArg::text(&janri), TursoArg::text(&turi),
                                TursoArg::text(&holati), TursoArg::text(&tavsif),
                            ],
                        ).await?;
                        let cols = res["cols"].as_array().cloned().unwrap_or_default();
                        let rows = res["rows"].as_array().cloned().unwrap_or_default();
                        if rows.is_empty() { return err500("Yangilashda xato"); }
                        return ok(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])));
                    }

                    if method == Method::Delete {
                        let old = turso_exec(&env, "SELECT photo_url FROM season_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let old_rows = old["rows"].as_array().cloned().unwrap_or_default();
                        if old_rows.is_empty() { return err404("Bo'lim topilmadi"); }
                        let old_cols = old["cols"].as_array().cloned().unwrap_or_default();
                        let old_photo = row_to_obj(&old_cols, old_rows[0].as_array().unwrap_or(&vec![]))
                            ["photo_url"].as_str().unwrap_or("").to_string();
                        if !old_photo.is_empty() { b2_delete(&env, &old_photo).await; }
                        turso_exec(&env, "DELETE FROM season_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        return ok(json!({"success": true}));
                    }
                }
            }

            if let Some(id_str) = path.strip_prefix("/api/anime/") {
                if let Ok(id) = id_str.parse::<i64>() {

                    if method == Method::Get {
                        let res = turso_exec(&env, "SELECT * FROM anime_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let cols = res["cols"].as_array().cloned().unwrap_or_default();
                        let rows = res["rows"].as_array().cloned().unwrap_or_default();
                        if rows.is_empty() { return err404("Anime topilmadi"); }
                        return ok(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])));
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

                        let old = turso_exec(&env, "SELECT photo_url FROM anime_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let old_rows = old["rows"].as_array().cloned().unwrap_or_default();
                        if old_rows.is_empty() { return err404("Anime topilmadi"); }
                        let old_cols = old["cols"].as_array().cloned().unwrap_or_default();
                        let old_photo = row_to_obj(&old_cols, old_rows[0].as_array().unwrap_or(&vec![]))
                            ["photo_url"].as_str().unwrap_or("").to_string();

                        if !old_photo.is_empty() && old_photo != pu { b2_delete(&env, &old_photo).await; }
                        turso_exec(&env, "DELETE FROM anime_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let res = turso_exec(&env,
                            "INSERT INTO anime_db (photo_url,name,davlat,studiya,janri,tavsif) VALUES (?,?,?,?,?,?) RETURNING *",
                            vec![TursoArg::text(&pu), TursoArg::text(&na), TursoArg::text(&da), TursoArg::text(&st), TursoArg::text(&ja), TursoArg::text(&ta)],
                        ).await?;
                        let cols = res["cols"].as_array().cloned().unwrap_or_default();
                        let rows = res["rows"].as_array().cloned().unwrap_or_default();
                        if rows.is_empty() { return err500("Yangilashda xato"); }
                        return ok(row_to_obj(&cols, rows[0].as_array().unwrap_or(&vec![])));
                    }

                    if method == Method::Delete {
                        let old = turso_exec(&env, "SELECT photo_url FROM anime_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        let old_rows = old["rows"].as_array().cloned().unwrap_or_default();
                        if old_rows.is_empty() { return err404("Anime topilmadi"); }
                        let old_cols = old["cols"].as_array().cloned().unwrap_or_default();
                        let old_photo = row_to_obj(&old_cols, old_rows[0].as_array().unwrap_or(&vec![]))
                            ["photo_url"].as_str().unwrap_or("").to_string();
                        if !old_photo.is_empty() { b2_delete(&env, &old_photo).await; }
                        turso_exec(&env, "DELETE FROM anime_db WHERE id = ?", vec![TursoArg::int(id)]).await?;
                        return ok(json!({"success": true}));
                    }
                }
            }

            err404("Not found")
        }
    }
}
