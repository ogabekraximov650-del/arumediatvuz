import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/app_http.dart';
import '../services/storage_janitor.dart';
import '../services/ui_state.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

const String API_BASE = 'https://arumediatv.uzcom.workers.dev';

class AddAnimeScreen extends StatefulWidget {
  final Map<String, dynamic>? initialAnime;
  const AddAnimeScreen({super.key, this.initialAnime});

  @override
  State<AddAnimeScreen> createState() => _AddAnimeScreenState();
}

class _AddAnimeScreenState extends State<AddAnimeScreen> {
  final _nameCtrl = TextEditingController();
  final _davlatCtrl = TextEditingController();
  final _studiyaCtrl = TextEditingController();
  final _janriCtrl = TextEditingController();
  final _tavsifCtrl = TextEditingController();

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

  @override
  void initState() {
    super.initState();
    if (widget.initialAnime != null) {
      _nameCtrl.text = widget.initialAnime!['name'] ?? '';
      _davlatCtrl.text = widget.initialAnime!['davlat'] ?? '';
      _studiyaCtrl.text = widget.initialAnime!['studiya'] ?? '';
      _janriCtrl.text = widget.initialAnime!['janri'] ?? '';
      _tavsifCtrl.text = widget.initialAnime!['tavsif'] ?? '';
      _photoUrl = widget.initialAnime!['photo_url'];
      _photoFileName = _extractFileName(_photoUrl);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _davlatCtrl.dispose();
    _studiyaCtrl.dispose();
    _janriCtrl.dispose();
    _tavsifCtrl.dispose();
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
    // Tizim ilovani shu paytda yopib qo'yishi mumkin — qaytganda
    // admin paneli tiklanishi uchun belgi qo'yamiz.
    UiState.setAdminPicking(true);
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
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
      // MUHIM TUZATISH: B2'ning haqiqiy javob maydoni "authToken" emas,
      // balki "authorizationToken" deb ataladi. Noto'g'ri kalit tufayli
      // qiymat har doim null bo'lib, keyin String'ga cast qilishda
      // "type 'Null' is not a subtype of type 'String'" xatosi kelib
      // chiqqan edi.
      final uploadUrl = tokenData['uploadUrl'] as String;
      final authToken = tokenData['authorizationToken'] as String;

      final fileName = 'anime_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
        throw 'Rasm B2ga yuklashda xato (${uploadRes.statusCode}): ${uploadRes.body}';
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

  /// Saqlash — hech qanday maydon MAJBURIY EMAS. Foydalanuvchi xohlagan
  /// maydonni to'ldiradi, qolganlari bo'sh qoldirilsa ham saqlanadi.
  Future<void> _saveAnime() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      if (_selectedImage != null) {
        final uploaded = await _uploadImageToB2();
        if (uploaded == null) return;
      }

      final method = widget.initialAnime == null ? 'POST' : 'PUT';
      final endpoint = widget.initialAnime == null
          ? '$API_BASE/api/anime'
          : '$API_BASE/api/anime/${widget.initialAnime!['id']}';

      final body = jsonEncode({
        'photo_url': _photoFileName ?? '',
        'name': _nameCtrl.text,
        'davlat': _davlatCtrl.text,
        'studiya': _studiyaCtrl.text,
        'janri': _janriCtrl.text,
        'tavsif': _tavsifCtrl.text,
      });

      final res = method == 'POST'
          ? await http.post(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body)
          : await http.put(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'}, body: body);

      if (res.statusCode == 200 || res.statusCode == 201) {
        if (mounted) Navigator.of(context).pop(true);
      } else {
        throw 'Saqlashda xato (${res.statusCode}): ${res.body}';
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
                          widget.initialAnime == null
                              ? 'Anime qo\'shish'
                              : 'Animeni tahrirlash',
                          style: const TextStyle(
                              fontSize: 20,
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
                            height: 200,
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
                                : _photoUrl != null
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
                                              size: 48, color: Colors.white54),
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
                      _buildTextField('Anime nomi (ixtiyoriy)', _nameCtrl,
                          Icons.movie_creation_outlined),
                      const SizedBox(height: 12),
                      _buildTextField('Davlat (ixtiyoriy)', _davlatCtrl,
                          Icons.location_on_outlined),
                      const SizedBox(height: 12),
                      _buildTextField('Studiya (ixtiyoriy)', _studiyaCtrl,
                          Icons.business_outlined),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Janri (ixtiyoriy)', _janriCtrl, Icons.label_outline),
                      const SizedBox(height: 12),
                      _buildTextField('Tavsif (ixtiyoriy)', _tavsifCtrl,
                          Icons.description_outlined,
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
                                child: const Text('Bekor'),
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
                                onPressed:
                                    _isLoading ? null : () => _saveAnime(),
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
                                    : const Text('Saqlash'),
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

  Widget _buildTextField(
      String label, TextEditingController ctrl, IconData icon,
      {int maxLines = 1}) {
    return Glass(
      borderRadius: 14,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
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
