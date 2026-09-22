# ── BARCHA PAKETLARNI BIR XIL compileSdk GA KELTIRADI ─────────
#
# TOPILGAN XATO: `flutter_webrtc` o'z `build.gradle` sida ESKI
# `compileSdk` yozgan, ilovaniki esa 36. Paket ichidagi androidx
# kutubxonalari API 36 talab qilgani uchun build AYNAN PAKET
# ichida yiqiladi (`:flutter_webrtc:checkDebugAarMetadata`).
#
# Ilovaning `compileSdk` i paket kichik loyihalariga TARQALMAYDI —
# har biri o'zinikini e'lon qiladi. Shu sabab ildiz `build.gradle`
# ga barcha kichik loyihalarni bir xil qiymatga keltiruvchi blok
# qo'shiladi.
#
# Bu Flutter jamoasining O'ZI tavsiya qiladigan yo'l va u faqat
# YIG'ISH vaqtidagi API darajasini oshiradi — paket kodiga yoki
# ilovaning xulqiga tegmaydi.

import os
import sys

KTS = 'android/build.gradle.kts'
GRADLE = 'android/build.gradle'
MARK = 'ARU_COMPILE_SDK_ALIGN'

path = KTS if os.path.exists(KTS) else GRADLE
if not os.path.exists(path):
    sys.exit('❌ ildiz build.gradle topilmadi')
s = open(path, encoding='utf-8').read()
if MARK in s:
    print('✅ allaqachon moslangan')
    sys.exit(0)

if path.endswith('.kts'):
    block = '''
// ''' + MARK + '''
// Har bir Flutter paketi o'z `compileSdk` ini e'lon qiladi va
// ularning ba'zilari eskirib qoladi. Bu blok hammasini bitta
// darajaga keltiradi — aks holda build paket ichida yiqiladi.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.BaseExtension
            android.compileSdkVersion(36)
        }
    }
}
'''
else:
    block = '''
// ''' + MARK + '''
subprojects {
    afterEvaluate { project ->
        if (project.hasProperty('android')) {
            project.android {
                compileSdkVersion 36
            }
        }
    }
}
'''

# ── JOYI MUHIM ────────────────────────────────────────────────
#
# TOPILGAN XATO: blok fayl OXIRIGA qo'yilganda Gradle
# "Cannot run Project.afterEvaluate(Action) when the project is
# already evaluated" deb yiqilardi.
#
# Sababi yuqoridagi `subprojects { evaluationDependsOn(":app") }`:
# u kichik loyihalarni DARHOL baholaydi. Undan keyin qo'shilgan
# `afterEvaluate` esa allaqachon o'tib ketgan paytga yozilgan
# bo'lardi.
#
# Shu sabab blok o'sha qatordan OLDIN qo'yiladi.
ANCHOR = 'subprojects {'
at = s.find(ANCHOR)
if at < 0:
    out = s.rstrip() + '\n' + block
else:
    out = s[:at] + block.lstrip('\n') + '\n' + s[at:]
open(path, 'w', encoding='utf-8').write(out)
print(f'✅ {path} ga compileSdk moslash bloki qo\'shildi')
