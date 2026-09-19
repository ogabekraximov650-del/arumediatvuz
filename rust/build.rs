// rust/build.rs — KALIT O'ZGARSA QAYTA YIG'ILSIN.
//
// ── TOPILGAN XAVF ──────────────────────────────────────────────
//
// `APP_SIGN_SECRET` yadro ichiga KOMPILYATSIYA paytida kiritiladi
// (`option_env!`). Lekin cargo oddiy muhit o'zgaruvchisining
// o'zgarganini SEZMAYDI: kalitni almashtirsangiz ham u keshdagi
// eski artefaktni qayta ishlatib yuborardi.
//
// CI'da bu ayniqsa xavfli — u yerda `rust-cache` ishlaydi. Natija:
// kalitni almashtirasiz, worker yangi kalitni kutadi, APK esa
// ESKISI bilan yig'ilgan bo'lib chiqadi va butun ilova 403 oladi.
//
// Bu qator o'sha bog'liqlikni cargo'ga aniq aytib qo'yadi.
fn main() {
    println!("cargo:rerun-if-env-changed=APP_SIGN_SECRET");
}
