import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import '../services/storage_janitor.dart';
import '../services/ui_state.dart';
import '../theme/app_background.dart';
import '../services/intro_times.dart';
import '../widgets/glass.dart';

const String _apiBase = 'https://arumediatv.uzcom.workers.dev';

// Worker javobi (yoki eski qatorlar) to'liq URL bo'lishi mumkin —
// '/api/image/' dan keyingi qismini ajratib, bare fayl nomini oladi.
// MUHIM: Turso'da endi faqat B2 fayl nomi saqlanadi, to'liq URL emas —
// domen o'zgarsa ham eski yozuvlar buzilmaydi.
String? _extractFileName(String? url) {
  if (url == null || url.isEmpty) return null;
  const marker = '/api/image/';
  final idx = url.indexOf(marker);
  return idx == -1 ? url : url.substring(idx + marker.length);
}

// ── Model: bitta sifat uchun holat ──────────────────────────────
class _QualityState {
  final String label; // "360p", "480p", "720p", "1080p"
  final String urlKey; // "url_360p", ...
  final String sizeKey; // "size_360p", ...

  // BARE B2 fayl nomi (to'liq URL emas) — server shu holda kutadi.
  String? url;
  String? size;
  bool isUploading = false;
  double progress = 0; // 0.0 – 1.0
  int uploadedBytes = 0;
  int totalBytes = 0;

  _QualityState({
    required this.label,
    required this.urlKey,
    required this.sizeKey,
  });

  bool get hasFile => url != null && url!.isNotEmpty;
}

/// Epizod qo'shish / tahrirlash sahifasi.
class AddEpizodScreen extends StatefulWidget {
  final String animeId;
  final String seasonId;
  final Map<String, dynamic>? initialEpizod;

  const AddEpizodScreen({
    super.key,
    required this.animeId,
    required this.seasonId,
    this.initialEpizod,
  });

  @override
  State<AddEpizodScreen> createState() => _AddEpizodScreenState();
}

class _AddEpizodScreenState extends State<AddEpizodScreen> {
  final _numberCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  // ══════════════════════════════════════════════════════════
  //  YOSH CHEGARASI BU YERDA EMAS
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "epizod qo'shish oynasidagi yosh
  // chegarasini yozadigan joyni olib tashla va bo'lim qo'shish
  // oynasiga qo'sh — yosh chegarasi bitta BO'LIM uchun amal
  // qiladi".
  //
  // Shu sabab bu ekranda yosh oynasi YO'Q va serverga `yosh`
  // yuborilmaydi. U `add_season_screen.dart` da.

  // ══════════════════════════════════════════════════════════
  //  OPENINGNI O'TKAZIB YUBORISH — VAQT OYNALARI
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "video yuklash oynasining tagiga eniga
  // 2 ta, bo'yiga 5 ta qilib vaqtni yozadigan oynalar qo'sh.
  // `1:23   2:12` deb yozib qo'yilsa pleyerdagi video aynan shu
  // 1:23 ga kelganda `o'tkazib yuborish` tugmasi chiqadi va
  // foydalanuvchi tugmani bossa video 2:12 ga sakrab o'tadi."
  //
  // 5 ta qator — o'tkazib yuboriladigan joyi ko'p animelar uchun.
  //
  // Vaqt AYNAN yozilgan ko'rinishida saqlanadi (`5:14`, `6:44`) —
  // foydalanuvchi talabi: "intro vaqtini 5:14 va 6:44 qilib
  // yoziladigan qil, soniya bilan emas".
  //
  // Ilgari bu yerda ikki marta o'girish bor edi (yozishda matn ->
  // soniya, ochishda soniya -> matn). Endi u qatlam YO'Q: bazada
  // ham, ekranda ham bir xil matn turadi. Pleyer matnni qism
  // ochilganda bir marta millisekundga o'giradi.
  late final List<TextEditingController> _introFrom;
  late final List<TextEditingController> _introTo;

  bool _isSaving = false;
  String? _errorMsg;

  late final List<_QualityState> _qualities;

  @override
  void initState() {
    super.initState();
    _qualities = [
      _QualityState(label: '360p', urlKey: 'url_360p', sizeKey: 'size_360p'),
      _QualityState(label: '480p', urlKey: 'url_480p', sizeKey: 'size_480p'),
      _QualityState(label: '720p', urlKey: 'url_720p', sizeKey: 'size_720p'),
      _QualityState(label: '1080p', urlKey: 'url_1080p', sizeKey: 'size_1080p'),
    ];

    _introFrom =
        List.generate(kIntroRows, (_) => TextEditingController());
    _introTo = List.generate(kIntroRows, (_) => TextEditingController());

    final ep = widget.initialEpizod;
    if (ep != null) {
      for (var i = 0; i < kIntroRows; i++) {
        // `intro_1`/`intro_2` — 1-oraliq, `intro_3`/`intro_4` — 2-si...
        _introFrom[i].text = introText(ep['intro_${i * 2 + 1}']);
        _introTo[i].text = introText(ep['intro_${i * 2 + 2}']);
      }
      _numberCtrl.text = (ep['epizod_number'] ?? '').toString();
      _nameCtrl.text = ep['epizod_name'] ?? '';
      for (final q in _qualities) {
        // Worker GET javobida to'liq URL keladi — bare nomga qaytaramiz,
        // saqlashda serverga aynan shu (bare) holida yuboriladi.
        q.url = _extractFileName(ep[q.urlKey] as String?);
        q.size = ep[q.sizeKey] as String?;
      }
    }
  }

  @override
  void dispose() {
    _numberCtrl.dispose();
    _nameCtrl.dispose();
    for (final c in _introFrom) {
      c.dispose();
    }
    for (final c in _introTo) {
      c.dispose();
    }
    super.dispose();
  }



  // ── Fayl tanlash va B2'ga yuklash (Dio — real progress) ─────────
  Future<void> _pickAndUpload(_QualityState q) async {
    final picker = ImagePicker();
    // Video tanlash eng "og'ir" holat: galereya ochilganda tizim
    // ilovani yopib qo'yishi mumkin. Belgi qo'yamiz — qaytganda
    // admin paneli tiklanadi.
    UiState.setAdminPicking(true);
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    UiState.setAdminPicking(false);
    if (picked == null) return;

    final file = File(picked.path);
    final fileSizeBytes = await file.length();
    // `image_picker` tanlangan videoni ILOVANING vaqtinchalik
    // papkasiga NUSXALAYDI. Nusxa yuklash tugashi bilan
    // o'chiriladi — aks holda ilova hajmi har yuklangan qism
    // hajmicha o'sib borardi (storage_janitor.dart izohiga
    // qarang). Galereyadagi ASL faylga tegilmaydi.
    Future<void> dropCopy() => StorageJanitor.dropPicked(picked.path);
    final ext = picked.path.split('.').last.toLowerCase();
    final contentType = ext == 'mkv' ? 'video/x-matroska' : 'video/mp4';
    final fileName =
        'ep_${widget.animeId}_${widget.seasonId}_${q.label}_${DateTime.now().millisecondsSinceEpoch}.$ext';

    // 1. B2 upload token olish
    http.Response tokenRes;
    try {
      tokenRes = await http.post(Uri.parse('$_apiBase/api/upload-token'));
    } catch (e) {
      await dropCopy();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Token xato: $e')));
      }
      return;
    }
    if (tokenRes.statusCode != 200) {
      await dropCopy();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload token olib bo\'lmadi')));
      }
      return;
    }
    final tokenData = jsonDecode(tokenRes.body);
    final uploadUrl = tokenData['uploadUrl'] as String;
    final authToken = tokenData['authorizationToken'] as String;

    // 2. Progress state'ni boshlash
    if (!mounted) {
      await dropCopy();
      return;
    }
    setState(() {
      q.isUploading = true;
      q.progress = 0;
      q.uploadedBytes = 0;
      q.totalBytes = fileSizeBytes;
    });

    // 3. Dio orqali fayl yuklash — real-time network progress
    try {
      final dio = Dio();
      final response = await dio.post(
        uploadUrl,
        data: file.openRead(), // stream — fayl to'liq xotiraga yuklanmaydi
        options: Options(
          headers: {
            'Authorization': authToken,
            'X-Bz-File-Name': fileName,
            'Content-Type': contentType,
            'X-Bz-Content-Sha1': 'do_not_verify',
            'Content-Length': fileSizeBytes,
          },
          receiveDataWhenStatusError: true,
        ),
        onSendProgress: (sent, total) {
          // Real vaqt: har chunk yuborilganda ishlaydi
          if (mounted) {
            setState(() {
              q.uploadedBytes = sent;
              q.totalBytes = total > 0 ? total : fileSizeBytes;
              q.progress = total > 0 ? sent / total : 0;
            });
          }
        },
      );

      if (response.statusCode == 200) {
        final data = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        final b2Name = data['fileName'] as String;
        final sizeTxt = _formatSize(fileSizeBytes);
        if (mounted) {
          setState(() {
            // Serverga BARE fayl nomi saqlanadi (to'liq URL emas).
            q.url = b2Name;
            q.size = sizeTxt;
            q.isUploading = false;
            q.progress = 1.0;
          });
        }
      } else {
        throw 'B2 xato (${response.statusCode}): ${response.data}';
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          q.isUploading = false;
          q.progress = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${q.label} yuklashda xato: ${e.message}')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          q.isUploading = false;
          q.progress = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${q.label} yuklashda xato: $e')));
      }
    } finally {
      // Yuklash qanday tugashidan qat'i nazar — nusxa o'chadi.
      await dropCopy();
    }
  }

  // ── Bitta sifat faylini o'chirish ──────────────────────────────
  Future<void> _deleteQualityFile(_QualityState q) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('${q.label} faylni o\'chirish?',
            style: const TextStyle(color: Colors.white)),
        content: Text(
          'Fayl B2dan ham, bazadan ham o\'chiriladi. Davom etasizmi?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Yo\'q',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Ha, o\'chirish'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // Tasdiqlash oynasi yopilgunicha ekran ham yopilgan bo'lishi
    // mumkin.
    if (!mounted) return;

    final ep = widget.initialEpizod;
    if (ep == null) {
      // Hali saqlanmagan — faqat local tozalash
      setState(() {
        q.url = null;
        q.size = null;
      });
      return;
    }

    // Worker'ga: B2dan o'chir + DB ustunni tozala
    // URL: DELETE /api/epizods/:animeId/:seasonId/:epizodId/:quality
    try {
      final res = await http.delete(
        Uri.parse(
          '$_apiBase/api/epizods/${widget.animeId}/${widget.seasonId}/${ep['epizod_id']}/${q.label}',
        ),
      );
      if (res.statusCode == 200) {
        if (mounted)
          setState(() {
            q.url = null;
            q.size = null;
          });
      } else {
        throw res.body;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('O\'chirishda xato: $e')));
      }
    }
  }

  // ── Saqlash ────────────────────────────────────────────────────
  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMsg = null;
    });
    try {
      final isEdit = widget.initialEpizod != null;
      final endpoint = isEdit
          ? '$_apiBase/api/epizods/${widget.animeId}/${widget.seasonId}/${widget.initialEpizod!['epizod_id']}'
          : '$_apiBase/api/epizods';

      final body = jsonEncode({
        'anime_id': widget.animeId,
        'season_id': widget.seasonId,
        'epizod_number': int.tryParse(_numberCtrl.text) ?? 0,
        'epizod_name': _nameCtrl.text,
        'url_360p': _qualities[0].url ?? '',
        'size_360p': _qualities[0].size ?? '',
        'url_480p': _qualities[1].url ?? '',
        'size_480p': _qualities[1].size ?? '',
        'url_720p': _qualities[2].url ?? '',
        'size_720p': _qualities[2].size ?? '',
        'url_1080p': _qualities[3].url ?? '',
        'size_1080p': _qualities[3].size ?? '',
        // Intro oraliqlari — YOZILGAN KO'RINISHIDA (`"5:14"`),
        // juftlik bo'lib. Ikki nuqtasiz yozilgan bo'lsa
        // (`514`) to'g'rilanadi.
        for (var i = 0; i < kIntroRows; i++) ...{
          'intro_${i * 2 + 1}': normalizeIntroInput(_introFrom[i].text),
          'intro_${i * 2 + 2}': normalizeIntroInput(_introTo[i].text),
        },
      });

      final res = isEdit
          ? await http.put(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body)
          : await http.post(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body);

      if (res.statusCode == 200 || res.statusCode == 201) {
        if (mounted) Navigator.of(context).pop(true);
      } else {
        throw 'Saqlashda xato (${res.statusCode}): ${res.body}';
      }
    } catch (e) {
      setState(() => _errorMsg = 'Xato: $e');
    } finally {
      setState(() => _isSaving = false);
    }
  }

  // ── Yordamchi ──────────────────────────────────────────────────
  String _formatSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(2)} MB';
  }

  String _progressText(_QualityState q) {
    final pct = (q.progress * 100).toStringAsFixed(1);
    final done = _formatSize(q.uploadedBytes);
    final tot = _formatSize(q.totalBytes);
    return '$pct% ($done / $tot)';
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initialEpizod != null;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              // ── Header ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Glass(
                  borderRadius: 20,
                  blur: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          isEdit ? 'Epizodni tahrirlash' : 'Epizod qo\'shish',
                          style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Form ──
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  child: Column(
                    children: [
                      if (_errorMsg != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: Colors.red.withValues(alpha: 0.5)),
                          ),
                          child: Text(_errorMsg!,
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 12)),
                        ),
                        const SizedBox(height: 16),
                      ],

                      _buildTextField('Epizod raqami (0 dan boshlash)',
                          _numberCtrl, Icons.format_list_numbered_rounded,
                          keyboardType: TextInputType.number),
                      const SizedBox(height: 12),

                      _buildTextField('Epizod nomi (ixtiyoriy)', _nameCtrl,
                          Icons.title_rounded),
                      const SizedBox(height: 20),

                      // ── 4 ta sifat yuklash oynasi ──
                      for (final q in _qualities) ...[
                        _QualityCard(
                          quality: q,
                          onUpload: () => _pickAndUpload(q),
                          onDelete: () => _deleteQualityFile(q),
                          progressText: _progressText(q),
                        ),
                        const SizedBox(height: 12),
                      ],

                      const SizedBox(height: 8),
                      _buildIntroCard(),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: Glass(
                              borderRadius: 14,
                              blur: 14,
                              padding: EdgeInsets.zero,
                              child: FilledButton(
                                onPressed: _isSaving
                                    ? null
                                    : () => Navigator.of(context).pop(),
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.1),
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Bekor qilish'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Glass(
                              borderRadius: 14,
                              blur: 14,
                              padding: EdgeInsets.zero,
                              child: FilledButton(
                                onPressed: _isSaving ? null : _save,
                                child: _isSaving
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(
                                              Colors.white),
                                        ),
                                      )
                                    : Text(isEdit ? 'Saqlash' : 'Qo\'shish'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Openingni o'tkazib yuborish oraliqlari — 2 ustun x 5 qator.
  Widget _buildIntroCard() {
    return Glass(
      borderRadius: 16,
      blur: 14,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fast_forward_rounded,
                  size: 18, color: Colors.white70),
              const SizedBox(width: 8),
              const Text(
                'O\'tkazib yuboriladigan joylar',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Chapga boshlanish, o\'ngga tugash vaqti: 5:14 va 6:44.\n'
            'Video 5:14 ga kelganda pleyerda "Introni o\'tkazish" '
            'tugmasi chiqadi. Bo\'sh qatorlar e\'tiborga olinmaydi.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < kIntroRows; i++) ...[
            Row(
              children: [
                SizedBox(
                  width: 20,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(child: _introField(_introFrom[i], 'boshi')),
                const SizedBox(width: 10),
                Expanded(child: _introField(_introTo[i], 'oxiri')),
              ],
            ),
            if (i != kIntroRows - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _introField(TextEditingController ctrl, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: ctrl,
        // ── KLAVIATURADA IKKI NUQTA BO'LISHI SHART ───────────
        //
        // TOPILGAN XATO (foydalanuvchi: "intro vaqtini yozib
        // bo'lmayapti, boshqacha keyboard chiqishi kerak edi").
        //
        // Bu yerda `TextInputType.phone` turardi — telefon
        // klaviaturasida `-`, `+`, `*#` bor, LEKIN `:` YO'Q.
        // Ya'ni `5:14` deb yozishning iloji yo'q edi.
        //
        // `datetime` — aynan vaqt uchun: raqamlar bilan birga
        // `:` chiqadi. Ustiga pastdagi filtr faqat raqam va ikki
        // nuqtani o'tkazadi, saqlashda esa `514` ham `5:14` ga
        // to'g'rilanadi (`normalizeIntroInput`).
        keyboardType: TextInputType.datetime,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
          LengthLimitingTextInputFormatter(8),
        ],
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          hintText: hint,
          hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.3), fontSize: 13),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildTextField(
      String label, TextEditingController ctrl, IconData icon,
      {int maxLines = 1, TextInputType? keyboardType}) {
    return Glass(
      borderRadius: 14,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: label,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          prefixIcon: Icon(icon, color: Colors.white54),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

// ── Bitta sifat uchun karta ──────────────────────────────────────
class _QualityCard extends StatelessWidget {
  final _QualityState quality;
  final VoidCallback onUpload;
  final VoidCallback onDelete;
  final String progressText;

  const _QualityCard({
    required this.quality,
    required this.onUpload,
    required this.onDelete,
    required this.progressText,
  });

  @override
  Widget build(BuildContext context) {
    final q = quality;
    return Glass(
      borderRadius: 16,
      blur: 14,
      tint: 0.08,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${q.label} sifat',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 10),
          if (q.isUploading) ...[
            // ── Yuklanmoqda ──
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: q.progress,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation(AppColors.accent),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              progressText,
              style:
                  TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
            ),
          ] else if (q.hasFile) ...[
            // ── Yuklangan ──
            Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Colors.greenAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    q.size ?? '',
                    style: TextStyle(
                        fontSize: 13, color: Colors.white.withValues(alpha: 0.8)),
                  ),
                ),
                GlassTappable(
                  onTap: onDelete,
                  child: Glass(
                    borderRadius: 10,
                    blur: 10,
                    padding: const EdgeInsets.all(8),
                    child: const Icon(Icons.delete_outline_rounded,
                        color: Colors.redAccent, size: 20),
                  ),
                ),
              ],
            ),
          ] else ...[
            // ── Bo'sh ──
            SizedBox(
              width: double.infinity,
              child: GlassTappable(
                onTap: onUpload,
                child: Glass(
                  borderRadius: 12,
                  blur: 10,
                  tint: 0.05,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.upload_file_rounded,
                          color: AppColors.accent, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '${q.label} fayl yuklash',
                        style: TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
