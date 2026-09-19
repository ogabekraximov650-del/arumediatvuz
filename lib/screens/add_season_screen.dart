import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../data/janrlar.dart';
import '../services/app_http.dart';
import '../services/storage_janitor.dart';
import '../services/ui_state.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

const String API_BASE = 'https://arumediatv.uzcom.workers.dev';

const List<String> _turlar = ['TV', 'FILM', 'OVA'];
const List<String> _holatlar = ['Davom etmoqda', 'Tugallangan'];

/// "Yangi bo'lim qo'shish" oynasi — season_db uchun.
class AddSeasonScreen extends StatefulWidget {
  final String animeId;
  final Map<String, dynamic>? initialSeason;
  const AddSeasonScreen({super.key, required this.animeId, this.initialSeason});

  @override
  State<AddSeasonScreen> createState() => _AddSeasonScreenState();
}

class _AddSeasonScreenState extends State<AddSeasonScreen> {
  // bolim_id — foydalanuvchi qo'lda kiritadigan bo'lim raqami (1, 2, 3...)
  final _bolimIdCtrl = TextEditingController();
  final _nomiCtrl = TextEditingController();
  final _studioCtrl = TextEditingController();
  final _tarjimonCtrl = TextEditingController();
  final _yiliCtrl = TextEditingController();
  final _tavsifCtrl = TextEditingController();

  // ══════════════════════════════════════════════════════════
  //  YOSH CHEGARASI
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "epizod qo'shish oynasidagi yosh
  // chegarasini yozadigan joyni olib tashla va bo'lim qo'shish
  // oynasiga qo'sh — yosh chegarasi bitta BO'LIM uchun amal
  // qiladi".
  //
  // Ilgari chegara HAR BIR QISMga alohida yozilardi va bo'limniki
  // qismlardagi eng kattasi deb hisoblanardi. Bu ortiqcha ish edi:
  // bitta bo'limning barcha qismlari bir xil chegarada bo'ladi.
  // Endi u shu yerda BIR MARTA yoziladi.
  //
  // Faqat RAQAM qabul qilinadi (`FilteringTextInputFormatter`):
  // yozuvga `+` yoki bo'sh joy tushib qolsa, bir bo'limda `18+`,
  // boshqasida `18 +` bo'lib, ro'yxatda ikki xil belgi chiqardi.
  // `+` ni ilova O'ZI qo'shib ko'rsatadi.
  //
  // Bo'sh qoldirilsa — "belgilanmagan": kartochkada hech qanday
  // belgi ko'rsatilmaydi.
  final _yoshCtrl = TextEditingController();

  /// Tanlangan janrlar. Endi qo'lda yozilmaydi — tugmalar
  /// bosiladi (`lib/data/janrlar.dart`).
  final Set<String> _janrlar = {};

  String _turi = _turlar.first;
  String _holati = _holatlar.first;

  File? _selectedImage;
  // _photoUrl — to'liq URL, faqat lokal oldindan ko'rish (Image.network) uchun.
  String? _photoUrl;
  // _photoFileName — B2'dagi BARE fayl nomi, serverga aynan shu yuboriladi.
  // MUHIM: Turso'da to'liq URL emas, faqat fayl nomi saqlanadi — domen
  // o'zgarsa ham eski yozuvlar buzilmaydi (worker o'qishda to'liq URL'ni
  // o'zi joriy domen asosida quradi).
  String? _photoFileName;
  bool _isLoading = false;
  String? _errorMsg;

  // Tahrirlash rejimida boshlang'ich season_id ni eslab qolamiz —
  // PUT so'rovi manzili shu asosda quriladi (season_db'da
  // alohida "id" ustuni yo'q, anime_id+season_id kalit hisoblanadi).
  int? _originalSeasonId;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSeason;
    if (s != null) {
      _bolimIdCtrl.text = (s['bolim_id'] ?? '').toString();
      _originalSeasonId = s['season_id'] is int
          ? s['season_id']
          : int.tryParse((s['season_id'] ?? '').toString());
      _nomiCtrl.text = s['nomi'] ?? '';
      _studioCtrl.text = s['studio'] ?? '';
      _tarjimonCtrl.text = s['tarjimon'] ?? '';
      _yiliCtrl.text = s['yili'] ?? '';
      _tavsifCtrl.text = s['tavsif'] ?? '';
      final yosh = int.tryParse('${s['yosh'] ?? 0}') ?? 0;
      if (yosh > 0) _yoshCtrl.text = '$yosh';
      // Eski yozuvlarda janrlar vergul bilan ajratilgan matn.
      for (final part in (s['janri'] ?? '').toString().split(',')) {
        final t = part.trim();
        if (t.isNotEmpty) _janrlar.add(t);
      }
      _photoUrl = s['photo_url'];
      _photoFileName = _extractFileName(_photoUrl);
      if (_turlar.contains(s['turi'])) _turi = s['turi'];
      if (_holatlar.contains(s['holati'])) _holati = s['holati'];
    }
  }

  @override
  void dispose() {
    _bolimIdCtrl.dispose();
    _nomiCtrl.dispose();
    _studioCtrl.dispose();
    _tarjimonCtrl.dispose();
    _yiliCtrl.dispose();
    _tavsifCtrl.dispose();
    _yoshCtrl.dispose();
    super.dispose();
  }

  // Worker javobi (yoki eski qatorlar) to'liq URL bo'lishi mumkin —
  // '/api/image/' dan keyingi qismini ajratib, bare fayl nomini oladi.
  String? _extractFileName(String? url) {
    if (url == null || url.isEmpty) return null;
    const marker = '/api/image/';
    final idx = url.indexOf(marker);
    return idx == -1 ? url : url.substring(idx + marker.length);
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    UiState.setAdminPicking(true);
    final pickedFile =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    UiState.setAdminPicking(false);
    // Rasm tanlash oynasi ochiq turganda ekran yopilgan bo'lishi
    // mumkin — `setState` o'shanda istisno tashlaydi.
    if (!mounted) return;
    if (pickedFile != null) {
      // `image_picker` rasmni ilovaning vaqtinchalik papkasiga
      // NUSXALAYDI. Avvalgi nusxa endi keraksiz — o'chiramiz,
      // aks holda har tanlash ilova hajmini oshirardi
      // (storage_janitor.dart izohiga qarang).
      final old = _selectedImage;
      if (old != null) unawaited(StorageJanitor.dropPicked(old.path));
      setState(() {
        _selectedImage = File(pickedFile.path);
        _errorMsg = null;
      });
    }
  }

  Future<String?> _uploadImageToB2() async {
    if (_selectedImage == null) return _photoFileName;
    setState(() => _isLoading = true);
    try {
      final tokenRes = await http.post(Uri.parse('$API_BASE/api/upload-token'));
      if (tokenRes.statusCode != 200) {
        throw 'Upload token olib bo\'lmadi: ${tokenRes.body}';
      }
      final tokenData = jsonDecode(tokenRes.body);
      final uploadUrl = tokenData['uploadUrl'] as String;
      final authToken = tokenData['authorizationToken'] as String;

      final fileName = 'season_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final fileBytes = await _selectedImage!.readAsBytes();

      final uploadRes = await http.post(
        Uri.parse(uploadUrl),
        headers: {
          'Authorization': authToken,
          'X-Bz-File-Name': fileName,
          'Content-Type': 'image/jpeg',
          'X-Bz-Content-Sha1': 'do_not_verify',
        },
        body: fileBytes,
      );
      if (uploadRes.statusCode != 200) {
        throw 'Rasm B2ga yuklashda xato (${uploadRes.statusCode})';
      }
      final uploadData = jsonDecode(uploadRes.body);
      final b2FileName = uploadData['fileName'] as String;
      // Lokal oldindan ko'rish uchun to'liq URL, serverga esa bare nom.
      _photoUrl = '$API_BASE/api/image/$b2FileName';
      _photoFileName = b2FileName;
      // Rasm B2'ga o'tdi — ilovaning vaqtinchalik papkasidagi
      // nusxa endi keraksiz. XATO bo'lganda o'chirilmaydi:
      // foydalanuvchi qayta urinib ko'rishi mumkin.
      final copy = _selectedImage;
      if (copy != null) unawaited(StorageJanitor.dropPicked(copy.path));
      return _photoFileName;
    } catch (e) {
      if (mounted) setState(() => _errorMsg = 'Rasm yuklashda xato: $e');
      return null;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      if (_selectedImage != null) {
        final uploaded = await _uploadImageToB2();
        if (uploaded == null) return;
      }

      final isEdit = widget.initialSeason != null;
      final method = isEdit ? 'PUT' : 'POST';
      // MUHIM: season_db'da alohida "id" ustuni yo'q — PUT/DELETE
      // manzili anime_id + (eski) season_id juftligidan quriladi.
      final endpoint = isEdit
          ? '$API_BASE/api/seasons/${widget.animeId}/$_originalSeasonId'
          : '$API_BASE/api/seasons';

      // MUHIM: `season_id` YUBORILMAYDI — uni server o'zi beradi
      // (shu anime uchun MAX+1). Ilgari u qo'lda kiritilardi va
      // band raqam kiritilganda server 500 xato qaytarardi.
      final janrlar = _janrlar.toList()..sort();
      final body = jsonEncode({
        'anime_id': widget.animeId,
        'bolim_id': int.tryParse(_bolimIdCtrl.text) ?? 0,
        'photo_url': _photoFileName ?? '',
        'nomi': _nomiCtrl.text,
        'studio': _studioCtrl.text,
        'tarjimon': _tarjimonCtrl.text,
        'yili': _yiliCtrl.text,
        'janrlar': janrlar,
        'janri': janrlar.join(', '),
        'turi': _turi,
        'holati': _holati,
        'tavsif': _tavsifCtrl.text,
        // Yosh chegarasi — butun bo'lim uchun.
        'yosh': int.tryParse(_yoshCtrl.text.trim()) ?? 0,
      });

      final res = method == 'POST'
          ? await http.post(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body)
          : await http.put(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body);

      if (res.statusCode == 200 || res.statusCode == 201) {
        if (mounted) Navigator.of(context).pop(true);
      } else {
        // Server tushunarli sabab yuborsa — aynan shuni
        // ko'rsatamiz ("2-bo'lim allaqachon mavjud" kabi).
        String why = 'Saqlashda xato (${res.statusCode})';
        try {
          final j = jsonDecode(res.body);
          if (j is Map && j['error'] is String) why = j['error'] as String;
        } catch (_) {}
        throw why;
      }
    } catch (e) {
      setState(() => _errorMsg = 'Xato: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
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
                          widget.initialSeason == null
                              ? 'Yangi bo\'lim qo\'shish'
                              : 'Bo\'limni tahrirlash',
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
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  child: Column(
                    children: [
                      GlassTappable(
                        onTap: _isLoading ? () {} : () => _pickImage(),
                        child: Glass(
                          borderRadius: 20,
                          blur: 16,
                          padding: const EdgeInsets.all(16),
                          child: Container(
                            width: double.infinity,
                            height: 180,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _selectedImage != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    // Galereyadan olingan rasm 12 MP
                                    // bo'lishi mumkin (~48 MB xotira) —
                                    // ko'rish oynasi uchun shuncha
                                    // kerak emas.
                                    child: Image.file(_selectedImage!,
                                        cacheWidth: 1080,
                                        fit: BoxFit.cover),
                                  )
                                : _photoUrl != null && _photoUrl!.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Image.network(
                                            // `Image.network` ni tizim
                                            // yuklaydi — unga sarlavha
                                            // qo'shib bo'lmaydi, shu sabab
                                            // ruxsat manzilda keladi
                                            // (`nativeMediaUrl` izohi).
                                            nativeMediaUrl(_photoUrl!),
                                            cacheWidth: 1080,
                                            fit: BoxFit.cover),
                                      )
                                    : Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.image_outlined,
                                              size: 44, color: Colors.white54),
                                          const SizedBox(height: 8),
                                          Text('Rasm tanlang (ixtiyoriy)',
                                              style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.6))),
                                        ],
                                      ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

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

                      // Bo'lim raqami: 1-bo'lim, 2-bo'lim...
                      //
                      // Texnik `season_id` endi SO'RALMAYDI — uni
                      // server o'zi beradi.
                      _buildTextField('Bo\'lim raqami (N-bo\'lim)',
                          _bolimIdCtrl, Icons.tag_rounded,
                          keyboardType: TextInputType.number),
                      const SizedBox(height: 12),

                      _buildTextField(
                          'Nomi', _nomiCtrl, Icons.movie_creation_outlined),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Studiya', _studioCtrl, Icons.business_outlined),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Tarjimon', _tarjimonCtrl, Icons.translate_rounded),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Yili', _yiliCtrl, Icons.calendar_today_outlined,
                          keyboardType: TextInputType.number),
                      const SizedBox(height: 12),

                      // Yosh chegarasi — BO'LIM uchun bir marta.
                      _buildYoshCard(),
                      const SizedBox(height: 12),
                      _buildSectionLabel('Janri'),
                      const SizedBox(height: 8),
                      _buildJanrChips(),
                      const SizedBox(height: 16),

                      _buildSectionLabel('Turi'),
                      const SizedBox(height: 8),
                      _buildSegmentedButtons(
                          _turlar, _turi, (v) => setState(() => _turi = v)),
                      const SizedBox(height: 16),

                      _buildSectionLabel('Holat'),
                      const SizedBox(height: 8),
                      _buildSegmentedButtons(_holatlar, _holati,
                          (v) => setState(() => _holati = v)),
                      const SizedBox(height: 16),

                      _buildTextField(
                          'Tavsif', _tavsifCtrl, Icons.description_outlined,
                          maxLines: 4),
                      const SizedBox(height: 24),

                      Row(
                        children: [
                          Expanded(
                            child: Glass(
                              borderRadius: 14,
                              blur: 14,
                              padding: EdgeInsets.zero,
                              child: FilledButton(
                                onPressed: _isLoading
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
                                onPressed: _isLoading ? null : () => _save(),
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(
                                              Colors.white),
                                        ),
                                      )
                                    : Text(widget.initialSeason == null
                                        ? 'Qo\'shish'
                                        : 'Saqlash'),
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

  Widget _buildSectionLabel(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildSegmentedButtons(
      List<String> options, String selected, ValueChanged<String> onSelect) {
    return Row(
      children: options.map((opt) {
        final isSelected = opt == selected;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: opt == options.last ? 0 : 8),
            child: GestureDetector(
              onTap: () => onSelect(opt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.accent
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Center(
                  child: Text(
                    opt,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.6),
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Janr tugmalari — ALIFBO tartibida, bir nechtasini tanlash
  /// mumkin. Bosilganda rangi o'zgaradi va bazaga shu tanlov
  /// saqlanadi (`season_janr` jadvali).
  Widget _buildJanrChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: kJanrlar.map((j) {
        final active = _janrlar.contains(j);
        return GestureDetector(
          onTap: () => setState(() {
            if (!_janrlar.remove(j)) _janrlar.add(j);
          }),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: active
                  ? AppColors.accent.withValues(alpha: 0.22)
                  : AppColors.card,
              border: Border.all(
                color: active ? AppColors.accent : AppColors.border,
                width: 1,
              ),
            ),
            child: Text(
              j,
              style: TextStyle(
                color: active ? Colors.white : Colors.white60,
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Yosh chegarasi — QO'LDA yoziladigan oyna.
  ///
  /// O'ngida yozilgan raqam `18+` ko'rinishida darhol ko'rsatilib
  /// turadi: admin nimani saqlayotganini yozayotgan paytda ko'radi.
  Widget _buildYoshCard() {
    return Glass(
      borderRadius: 14,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _yoshCtrl,
        keyboardType: TextInputType.number,
        // Faqat raqam — ko'pi bilan ikki xona.
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        style: const TextStyle(color: Colors.white),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Yosh chegarasi (masalan 18)',
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          prefixIcon: const Icon(Icons.shield_outlined, color: Colors.white54),
          border: InputBorder.none,
          // Yozilgan raqam qanday ko'rinishini ko'rsatib turadi.
          suffixIcon: _yoshCtrl.text.trim().isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    widthFactor: 1,
                    child: Text(
                      '${_yoshCtrl.text.trim()}+',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
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
