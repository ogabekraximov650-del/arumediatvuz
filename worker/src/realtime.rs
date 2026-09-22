//! ══════════════════════════════════════════════════════════════
//!  REAL VAQT: ONLAYN HOLAT, "YOZMOQDA" VA QO'NG'IROQ
//! ══════════════════════════════════════════════════════════════
//!
//! TALAB (foydalanuvchi):
//!   * "foydalanuvchi onlayn yoki oflayn o'tirganini ham aniq
//!      ko'rsatib turishning iloji bormi, huddi telegramdagidek";
//!   * "admin bilan jonli suhbat (audio qo'ng'iroq) tizimini
//!      qo'shsa bo'ladimi";
//!   * "xabar kelganda ilova tepasida bildirishnoma chiqsin".
//!
//! Uchalasiga ham bitta narsa kerak: SERVER BILAN DOIMIY ULANISH.
//! Shu sabab uchalasi ham shu bitta modulda.
//!
//! ── NEGA `last_seen_at` EMAS ──────────────────────────────────
//!
//! Bazada `sessions_db.last_seen_at` bor, lekin u ATAYLAB 12
//! soatda bir marta yoziladi (`SEEN_EVERY_MS` izohiga qarang):
//! ilgari u 60 soniyada yozilardi va butun Turso xarajatining
//! ~85% ini yeb turardi.
//!
//! Ya'ni u bilan "hozir onlayn" ni ko'rsatib bo'lmaydi — aniqligi
//! 12 soat. Uni qaytarib 60 soniyaga tushirish esa o'sha
//! xarajatni qaytarish degani.
//!
//! ── YECHIM: DURABLE OBJECT ────────────────────────────────────
//!
//! Onlayn holat DO ning O'Z XOTIRASIDA turadi:
//!
//!   ulanish ochiq  → odam onlayn
//!   ulanish uzildi → oflayn, uzilgan vaqt esdа qoladi
//!
//! BAZAGA HECH NARSA YOZILMAYDI. Ya'ni Turso xarajati
//! O'ZGARMAYDI — bu shu loyihadagi eng muhim shart.
//!
//! ── UYQU (HIBERNATION) ────────────────────────────────────────
//!
//! Odam chatni ochib qo'yib, soatlab hech narsa yozmasligi
//! mumkin. Oddiy WebSocket'da DO shu vaqt davomida xotirada
//! turadi va HAR SONIYASI uchun pul olinadi.
//!
//! Hibernation API'si buni hal qiladi: xabar kelmayotgan paytda
//! DO xotiradan chiqariladi, WebSocket esa OCHIQ qoladi. Xabar
//! kelganda qaytadan tiklanadi. Ya'ni jim turgan soatlar bepul.
//!
//! Buning ikki sharti bor va ikkalasi ham shu yerda bajarilgan:
//!
//!   1. Ulanish `accept_websocket_with_tags` bilan qabul
//!      qilinadi (oddiy `accept()` bilan EMAS — u DO ni xotirada
//!      ushlab turadi va hibernation ishlamaydi);
//!   2. Kim ulanganini bilish uchun ma'lumot WebSocket'ning
//!      O'ZIGA biriktiriladi (`serialize_attachment`), DO ning
//!      maydonlariga emas — chunki DO uyg'onganda maydonlar
//!      bo'sh bo'ladi.
//!
//! Tirik ushlab turuvchi "ping" ham DO ni uyg'otmaydi:
//! `set_websocket_auto_response` bilan unga runtime O'ZI javob
//! beradi.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use worker::*;

/// Ulanishning yorlig'i — kim ulangani.
///
/// Yorliq bo'yicha suhbatdoshning ulanishlarini topamiz
/// (`get_websockets_with_tag`), ya'ni xabar aynan kerakli
/// tomonga boradi.
const TAG_ADMIN: &str = "admin";
const TAG_USER: &str = "user";

/// Ulanishga biriktiriladigan ma'lumot.
///
/// DO uyquga ketib qaytganda maydonlari bo'sh bo'ladi, lekin
/// BU narsa WebSocket bilan birga saqlanadi va uyg'onganda
/// o'z holicha qaytadi.
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Peer {
    /// Ulangan odam admin'mi.
    admin: bool,
    /// Suhbat egasining raqami (admin uchun ham — u qaysi
    /// suhbatni ochgan bo'lsa, o'shaniki).
    uid: i64,
    /// Ko'rsatiladigan ism.
    name: String,
    /// `@username` (bo'sh bo'lishi mumkin).
    username: String,
    /// Profil rasmining to'liq manzili (bo'sh bo'lishi mumkin).
    avatar: String,
    /// Shu ULANISHNING o'z raqami.
    ///
    /// NEGA KERAK: ulanish uzilganda "u endi oflaynmi" degan
    /// savolga javob berish uchun AYNAN shu ulanishni ro'yxatdan
    /// chiqarib tashlash kerak. `WebSocket` ni to'g'ridan-to'g'ri
    /// taqqoslab bo'lmaydi (`PartialEq` yo'q), shu sabab har
    /// biriga o'z raqami beriladi.
    cid: String,
}

/// Oflayn bo'lgan vaqt shu kalitlar ostida saqlanadi.
///
/// Bu YAGONA yozuv joyi va u faqat ULANISH UZILGANDA bosiladi —
/// ya'ni bir sessiyaga bitta yozuv.
const KEY_LAST_ADMIN: &str = "last_admin";
const KEY_LAST_USER: &str = "last_user";

#[durable_object]
pub struct PresenceHub {
    state: State,
    #[allow(dead_code)]
    env: Env,
}

impl DurableObject for PresenceHub {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let path = req.path();
        match path.as_str() {
            // Ilovadan keladigan WebSocket ulanishi.
            p if p.ends_with("/ws") => self.open_socket(req).await,
            // Worker ichidan keladigan itarish (yangi xabar,
            // xabar o'chirildi va hokazo).
            p if p.ends_with("/notify") => {
                let body: Value = req.json().await.unwrap_or(json!({}));
                self.push(&body, None);
                Response::ok("ok")
            }
            // Holatni bir martalik so'rash (WebSocket'siz).
            p if p.ends_with("/state") => {
                let (admin_on, user_on) = self.who_is_online();
                Response::from_json(&json!({
                    "admin_online": admin_on,
                    "user_online": user_on,
                    "admin_last": self.last_seen(true).await,
                    "user_last": self.last_seen(false).await,
                }))
            }
            _ => Response::error("not found", 404),
        }
    }

    // ── XABAR KELDI ───────────────────────────────────────────
    //
    // Bu yerga faqat HAQIQIY xabar keladi: tirik ushlab turuvchi
    // "ping" ga runtime o'zi javob beradi va DO umuman
    // uyg'onmaydi (`set_websocket_auto_response`).
    async fn websocket_message(
        &self,
        ws: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let WebSocketIncomingMessage::String(text) = message else {
            // Ikkilik xabar kutilmaydi — e'tiborsiz qoldiriladi.
            return Ok(());
        };
        let Ok(msg) = serde_json::from_str::<Value>(&text) else {
            return Ok(());
        };
        let Some(me) = ws.deserialize_attachment::<Peer>().ok().flatten() else {
            // Kimligi noma'lum ulanish — bo'lmasligi kerak.
            return Ok(());
        };

        match msg["t"].as_str().unwrap_or("") {
            // Holatni qaytadan so'rash (ilova fon'dan qaytganda).
            "sync" => {
                let payload = self.presence_for(&me).await;
                let _ = ws.send_with_str(payload.to_string());
            }

            // ── "XABAR YOZMOQDA" / "OVOZLI XABAR YOZMOQDA" ────
            //
            // Bu HECH QAYERGA yozilmaydi: holat o'tkinchi, uni
            // saqlashning ma'nosi yo'q. Shunchaki suhbatdoshga
            // uzatiladi va u bir necha soniyada o'zi so'nadi.
            "typing" => {
                let kind = match msg["kind"].as_str().unwrap_or("text") {
                    "voice" => "voice",
                    "sending" => "sending",
                    _ => "text",
                };
                self.push(
                    &json!({
                        "t": "typing",
                        "kind": kind,
                        "from_admin": me.admin,
                        // `false` — yozish to'xtadi.
                        "on": msg["on"].as_bool().unwrap_or(true),
                    }),
                    Some(me.admin),
                );
            }

            // ── QO'NG'IROQ SIGNALIZATSIYASI ───────────────────
            //
            // Server bu yerda HECH NARSANI tushunmaydi: SDP va
            // ICE — ikki telefon o'rtasidagi gap, worker esa
            // shunchaki pochtachi.
            //
            // Bu ataylab shunday. Signalizatsiya mazmuniga
            // aralashish har WebRTC yangilanishida serverni ham
            // o'zgartirishni talab qilardi.
            "call" => {
                let mut out = msg.clone();
                out["from_admin"] = json!(me.admin);
                // Kim chaqirayotgani ilovada ko'rinishi uchun:
                // banner'da ism, `@user` va rasm turadi.
                out["from_name"] = json!(me.name);
                out["from_username"] = json!(me.username);
                out["from_avatar"] = json!(me.avatar);
                self.push(&out, Some(me.admin));
            }

            _ => {}
        }
        Ok(())
    }

    async fn websocket_close(
        &self,
        ws: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        self.on_gone(&ws).await;
        Ok(())
    }

    async fn websocket_error(&self, ws: WebSocket, _error: Error) -> Result<()> {
        self.on_gone(&ws).await;
        Ok(())
    }
}

impl PresenceHub {
    /// WebSocket ulanishini ochadi.
    async fn open_socket(&self, req: Request) -> Result<Response> {
        let h = req.headers();
        let admin = h.get("X-Rt-Admin").ok().flatten().as_deref() == Some("1");
        let uid = h
            .get("X-Rt-Uid")
            .ok()
            .flatten()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0);
        // ── KIMLIGI ONALTILIK KO'RINISHDA KELADI ──────────────
        //
        // Ism emoji yoki kirill bo'lishi mumkin, HTTP sarlavhasi
        // esa faqat ASCII qabul qiladi. Shu sabab worker uni
        // JSON qilib, onaltilik ko'rinishda yuboradi
        // (`rt_socket` izohiga qarang).
        let who = h
            .get("X-Rt-Who")
            .ok()
            .flatten()
            .and_then(|hex| un_hex(&hex))
            .and_then(|b| String::from_utf8(b).ok())
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .unwrap_or_else(|| json!({}));

        let peer = Peer {
            admin,
            uid,
            name: who["name"].as_str().unwrap_or("").to_string(),
            username: who["username"].as_str().unwrap_or("").to_string(),
            avatar: who["avatar"].as_str().unwrap_or("").to_string(),
            cid: crate::random_hex(16),
        };

        let pair = WebSocketPair::new()?;
        let server = pair.server;

        // ── HIBERNATION UCHUN ─────────────────────────────────
        //
        // `server.accept()` EMAS: u ulanishni DO ning o'z
        // xotirasiga bog'laydi va DO soatlab tirik qoladi.
        // Bu yerdagi usul esa ulanishni RUNTIME ga topshiradi.
        self.state
            .accept_websocket_with_tags(&server, &[if admin { TAG_ADMIN } else { TAG_USER }]);
        // Kimligi ulanishning O'ZIGA yoziladi — DO uyg'onganda
        // maydonlardan emas, shu yerdan o'qiladi.
        server.serialize_attachment(&peer)?;

        // ── TIRIK USHLAB TURUVCHI PING ────────────────────────
        //
        // Mobil operatorlar jim turgan ulanishni ~1-2 daqiqada
        // uzib qo'yadi, shu sabab ilova vaqti-vaqti bilan "p"
        // yuboradi.
        //
        // Bu juftlik ro'yxatga olinganda RUNTIME o'zi "P" deb
        // javob beradi va DO UMUMAN uyg'onmaydi. Ya'ni jim
        // turgan ulanish haqiqatan ham bepul.
        if let Ok(pairs) = worker_sys::WebSocketRequestResponsePair::new("p", "P") {
            self.state.set_websocket_auto_response(&pairs);
        }

        // Yangi kelganga hozirgi holat darhol yuboriladi...
        let mine = self.presence_for(&peer).await;
        let _ = server.send_with_str(mine.to_string());
        // ...suhbatdoshga esa "u ulandi" deb aytiladi.
        self.broadcast_presence(Some(peer.admin)).await;

        Response::from_websocket(pair.client)
    }

    /// Ulanish uzildi: oflayn vaqtini yozib, suhbatdoshga
    /// xabar beramiz.
    async fn on_gone(&self, ws: &WebSocket) {
        let Some(me) = ws.deserialize_attachment::<Peer>().ok().flatten() else {
            return;
        };
        // ── YAGONA YOZUV ──────────────────────────────────────
        //
        // Bu DO ning O'Z omborига yoziladi, Turso'ga EMAS. Va
        // faqat uzilganda — ya'ni bir sessiyaga bitta yozuv.
        let key = if me.admin { KEY_LAST_ADMIN } else { KEY_LAST_USER };
        let _ = self.state.storage().put(key, now_ms()).await;

        // ── NEGA DARHOL EMAS ──────────────────────────────────
        //
        // `websocket_close` chaqirilganda ulanish RO'YXATDAN hali
        // olib tashlanmagan bo'lishi mumkin. Shu sabab "kim
        // onlayn" ni sanashda AYNAN shu ulanish chiqarib
        // tashlanadi — aks holda uzilgan odam bir zum "onlayn"
        // bo'lib ko'rinardi.
        let _ = ws;
        self.broadcast_presence_excluding(Some(me.admin), Some(&me.cid)).await;
    }

    /// Qaysi tomon onlayn: `(admin, foydalanuvchi)`.
    fn who_is_online(&self) -> (bool, bool) {
        (
            !self.state.get_websockets_with_tag(TAG_ADMIN).is_empty(),
            !self.state.get_websockets_with_tag(TAG_USER).is_empty(),
        )
    }

    /// Oflayn bo'lgan vaqt (ms). Hech qachon ulanmagan bo'lsa 0.
    async fn last_seen(&self, admin: bool) -> i64 {
        let key = if admin { KEY_LAST_ADMIN } else { KEY_LAST_USER };
        self.state
            .storage()
            .get::<i64>(key)
            .await
            .ok()
            .flatten()
            .unwrap_or(0)
    }

    /// Shu odam uchun holat xabari: SUHBATDOSHNING holati.
    ///
    /// Ya'ni foydalanuvchiga adminning holati, adminga esa
    /// foydalanuvchining holati yuboriladi.
    async fn presence_for(&self, me: &Peer) -> Value {
        let (admin_on, user_on) = self.who_is_online();
        let peer_online = if me.admin { user_on } else { admin_on };
        json!({
            "t": "presence",
            "online": peer_online,
            "last_seen": self.last_seen(!me.admin).await,
            "uid": me.uid,
        })
    }

    /// Holat o'zgardi — suhbatdoshga aytamiz.
    ///
    /// `changed_side` — kim o'zgardi (`true` — admin). Xabar
    /// QARAMA-QARSHI tomonga ketadi.
    async fn broadcast_presence(&self, changed_side: Option<bool>) {
        self.broadcast_presence_excluding(changed_side, None).await;
    }

    async fn broadcast_presence_excluding(
        &self,
        changed_side: Option<bool>,
        skip: Option<&str>,
    ) {
        let Some(side) = changed_side else { return };
        // O'zgargan tomon hali ro'yxatda turgan bo'lishi mumkin —
        // uni chiqarib tashlab sanaymiz.
        let same_tag = if side { TAG_ADMIN } else { TAG_USER };
        let alive = self
            .state
            .get_websockets_with_tag(same_tag)
            .into_iter()
            .filter(|w| match skip {
                // Uzilayotgan ulanish sanoqqa kirmaydi.
                Some(cid) => {
                    w.deserialize_attachment::<Peer>()
                        .ok()
                        .flatten()
                        .map(|p| p.cid != *cid)
                        .unwrap_or(true)
                }
                None => true,
            })
            .count();
        let online = alive > 0;
        let last = self.last_seen(side).await;

        let target = if side { TAG_USER } else { TAG_ADMIN };
        let payload = json!({
            "t": "presence",
            "online": online,
            "last_seen": last,
        })
        .to_string();
        for w in self.state.get_websockets_with_tag(target) {
            let _ = w.send_with_str(&payload);
        }
    }

    /// Xabarni SUHBATDOSHGA yuboradi.
    ///
    /// `from_admin` — yuboruvchi kim. `None` bo'lsa (worker
    /// ichidan kelgan itarish) IKKALA tomonga ham boradi: xabar
    /// bir nechta qurilmada ochiq turgan bo'lishi mumkin va
    /// ularning hammasi yangilanishi kerak.
    fn push(&self, payload: &Value, from_admin: Option<bool>) {
        let text = payload.to_string();
        let targets: Vec<&str> = match from_admin {
            Some(true) => vec![TAG_USER],
            Some(false) => vec![TAG_ADMIN],
            None => vec![TAG_ADMIN, TAG_USER],
        };
        for tag in targets {
            for w in self.state.get_websockets_with_tag(tag) {
                let _ = w.send_with_str(&text);
            }
        }
    }
}

/// Hozirgi vaqt (ms).
fn now_ms() -> i64 {
    Date::now().as_millis() as i64
}

/// Onaltilik matnni baytlarga qaytaradi.
///
/// Juft bo'lmagan uzunlik yoki noto'g'ri belgi — `None`, ya'ni
/// buzuq sarlavha ulanishni yiqitmaydi, shunchaki kimligi bo'sh
/// qoladi.
fn un_hex(s: &str) -> Option<Vec<u8>> {
    let b = s.as_bytes();
    if b.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(b.len() / 2);
    for pair in b.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
    }
    Some(out)
}
