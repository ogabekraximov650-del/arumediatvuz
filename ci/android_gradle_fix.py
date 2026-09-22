# Android `build.gradle` ni qo'ng'iroq va bildirishnoma
# paketlariga moslaydi.
#
# UCHTA narsa kerak:
#
#   1. compileSdk 36 — `flutter_webrtc` olib keladigan androidx
#      kutubxonalari API 36 ga qarshi yig'ilishni talab qiladi
#      (35 bilan build YIQILADI, xato matni aniq shuni aytadi).
#
#   2. minSdk 23 — `flutter_webrtc` ning eng past chegarasi.
#
#   3. Core library desugaring — `flutter_local_notifications`
#      buni MAJBURAN talab qiladi. Usiz `checkDebugAarMetadata`
#      bosqichida build yiqiladi.
#
# Flutter 3.29 dan beri shablon Kotlin DSL (`.kts`) yaratadi,
# lekin eski loyihalarda Groovy (`.gradle`) bo'lishi mumkin —
# shu sabab ikkalasi ham qo'llanadi.

import os
import re
import sys

KTS = 'android/app/build.gradle.kts'
GRADLE = 'android/app/build.gradle'
DESUGAR = 'com.android.tools:desugar_jdk_libs:2.1.5'

path = KTS if os.path.exists(KTS) else GRADLE
if not os.path.exists(path):
    sys.exit('❌ build.gradle topilmadi')
kts = path.endswith('.kts')
s = open(path, encoding='utf-8').read()

# ── 1. compileSdk ──────────────────────────────────────────
s = re.sub(r'compileSdk(Version)?\s*=?\s*flutter\.compileSdkVersion',
           'compileSdk = 36' if kts else 'compileSdkVersion 36', s)
s = re.sub(r'compileSdk\s*=\s*\d+', 'compileSdk = 36', s)
s = re.sub(r'compileSdkVersion\s+\d+', 'compileSdkVersion 36', s)

# ── 2. minSdk ──────────────────────────────────────────────
s = re.sub(r'minSdk(Version)?\s*=?\s*flutter\.minSdkVersion',
           'minSdk = 23' if kts else 'minSdkVersion 23', s)
s = re.sub(r'minSdk\s*=\s*\d+', 'minSdk = 23', s)
s = re.sub(r'minSdkVersion\s+\d+', 'minSdkVersion 23', s)

# ── 3. Desugaring ──────────────────────────────────────────
if 'isCoreLibraryDesugaringEnabled' not in s and \
        'coreLibraryDesugaringEnabled' not in s:
    if kts:
        s = s.replace(
            'compileOptions {',
            'compileOptions {\n'
            '        // `flutter_local_notifications` talabi.\n'
            '        isCoreLibraryDesugaringEnabled = true', 1)
    else:
        s = s.replace(
            'compileOptions {',
            'compileOptions {\n'
            '        // `flutter_local_notifications` talabi.\n'
            '        coreLibraryDesugaringEnabled true', 1)

if 'desugar_jdk_libs' not in s:
    block = ('\ndependencies {\n'
             f'    coreLibraryDesugaring("{DESUGAR}")\n'
             '}\n') if kts else (
             '\ndependencies {\n'
             f"    coreLibraryDesugaring '{DESUGAR}'\n"
             '}\n')
    s = s.rstrip() + '\n' + block

open(path, 'w', encoding='utf-8').write(s)
print(f'✅ {path} moslandi (compileSdk 36, minSdk 23, desugaring)')
for line in s.splitlines():
    if any(k in line for k in
           ('compileSdk', 'minSdk', 'Desugar', 'desugar')):
        print('   ', line.strip())
