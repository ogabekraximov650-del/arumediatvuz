import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../theme/app_background.dart';
import '../widgets/glass.dart';

const String API_BASE = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

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
  final _seasonIdCtrl = TextEditingController();
  final _nomiCtrl = TextEditingController();
  final _studioCtrl = TextEditingController();
  final _tarjimonCtrl = TextEditingController();
  final _yiliCtrl = TextEditingController();
  final _janriCtrl = TextEditingController();
  final _tavsifCtrl = TextEditingController();

  String _turi = _turlar.first;
  String _holati = _holatlar.first;

  File? _selectedImage;
  String? _photoUrl;
  bool _isLoading = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSeason;
    if (s != null) {
      _seasonIdCtrl.text = (s['season_id'] ?? '').toString();
      _nomiCtrl.text = s['nomi'] ?? '';
      _studioCtrl.text = s['studio'] ?? '';
      _tarjimonCtrl.text = s['tarjimon'] ?? '';
      _yiliCtrl.text = s['yili'] ?? '';
      _janriCtrl.text = s['janri'] ?? '';
      _tavsifCtrl.text = s['tavsif'] ?? '';
      _photoUrl = s['photo_url'];
      if (_turlar.contains(s['turi'])) _turi = s['turi'];
      if (_holatlar.contains(s['holati'])) _holati = s['holati'];
    }
  }

  @override
  void dispose() {
    _seasonIdCtrl.dispose();
    _nomiCtrl.dispose();
    _studioCtrl.dispose();
    _tarjimonCtrl.dispose();
    _yiliCtrl.dispose();
    _janriCtrl.dispose();
    _tavsifCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
        _errorMsg = null;
      });
    }
  }

  Future<String?> _uploadImageToB2() async {
    if (_selectedImage == null) return _photoUrl;
    setState(() => _isLoading = true);
    try {
      final tokenRes = await http.post(Uri.parse('$API_BASE/api/upload-token'));
      if (tokenRes.statusCode != 200) {
        throw 'Upload token olib bo\'lmadi: ${tokenRes.body}';
      }
      final tokenData = jsonDecode(tokenRes.body);
      final uploadUrl = tokenData['uploadUrl'] as String;
      final authToken = tokenData['authToken'] as String;

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
      _photoUrl = '$API_BASE/api/image/$b2FileName';
      return _photoUrl;
    } catch (e) {
      setState(() => _errorMsg = 'Rasm yuklashda xato: $e');
      return null;
    } finally {
      setState(() => _isLoading = false);
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

      final method = widget.initialSeason == null ? 'POST' : 'PUT';
      final endpoint = widget.initialSeason == null
          ? '$API_BASE/api/seasons'
          : '$API_BASE/api/seasons/${widget.initialSeason!['id']}';

      final body = jsonEncode({
        'anime_id': widget.animeId,
        'season_id': int.tryParse(_seasonIdCtrl.text) ?? 0,
        'photo_url': _photoUrl ?? '',
        'nomi': _nomiCtrl.text,
        'studio': _studioCtrl.text,
        'tarjimon': _tarjimonCtrl.text,
        'yili': _yiliCtrl.text,
        'janri': _janriCtrl.text,
        'turi': _turi,
        'holati': _holati,
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
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          widget.initialSeason == null
                              ? 'Yangi bo\'lim qo\'shish'
                              : 'Bo\'limni tahrirlash',
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.bold, color: Colors.white),
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
                      // 1) Rasm yuklash
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
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _selectedImage != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.file(_selectedImage!, fit: BoxFit.cover),
                                  )
                                : _photoUrl != null && _photoUrl!.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Image.network(_photoUrl!, fit: BoxFit.cover),
                                      )
                                    : Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.image_outlined,
                                              size: 44, color: Colors.white54),
                                          const SizedBox(height: 8),
                                          Text('Rasm tanlang (ixtiyoriy)',
                                              style: TextStyle(
                                                  color: Colors.white.withOpacity(0.6))),
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
                            color: Colors.red.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.red.withOpacity(0.5)),
                          ),
                          child: Text(_errorMsg!,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // 2) Bo'lim IDsi
                      _buildTextField('Bo\'lim IDsi (raqam)', _seasonIdCtrl, Icons.tag_rounded,
                          keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      // 3) Nomi
                      _buildTextField('Nomi', _nomiCtrl, Icons.movie_creation_outlined),
                      const SizedBox(height: 12),
                      // 4) Studiya
                      _buildTextField('Studiya', _studioCtrl, Icons.business_outlined),
                      const SizedBox(height: 12),
                      // 5) Tarjimon
                      _buildTextField('Tarjimon', _tarjimonCtrl, Icons.translate_rounded),
                      const SizedBox(height: 12),
                      // 6) Yili
                      _buildTextField('Yili', _yiliCtrl, Icons.calendar_today_outlined,
                          keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      // 7) Janri
                      _buildTextField('Janri', _janriCtrl, Icons.label_outline),
                      const SizedBox(height: 16),

                      // 8) Turi — tugma ko'rinishida
                      _buildSectionLabel('Turi'),
                      const SizedBox(height: 8),
                      _buildSegmentedButtons(_turlar, _turi, (v) => setState(() => _turi = v)),
                      const SizedBox(height: 16),

                      // 9) Holat — tugma ko'rinishida
                      _buildSectionLabel('Holat'),
                      const SizedBox(height: 8),
                      _buildSegmentedButtons(
                          _holatlar, _holati, (v) => setState(() => _holati = v)),
                      const SizedBox(height: 16),

                      // 10) Tavsif
                      _buildTextField('Tavsif', _tavsifCtrl, Icons.description_outlined,
                          maxLines: 4),
                      const SizedBox(height: 24),

                      // 11) Bekor qilish / Qo'shish
                      Row(
                        children: [
                          Expanded(
                            child: Glass(
                              borderRadius: 14,
                              blur: 14,
                              padding: EdgeInsets.zero,
                              child: FilledButton(
                                onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.1),
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
                                          valueColor: AlwaysStoppedAnimation(Colors.white),
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
              color: Colors.white.withOpacity(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
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
                  color: isSelected ? AppColors.accent : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? AppColors.accent : Colors.white.withOpacity(0.12),
                  ),
                ),
                child: Center(
                  child: Text(
                    opt,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white.withOpacity(0.6),
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
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

  Widget _buildTextField(String label, TextEditingController ctrl, IconData icon,
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
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
          prefixIcon: Icon(icon, color: Colors.white54),
          border: InputBorder.none,
        ),
      ),
    );
  }
}
