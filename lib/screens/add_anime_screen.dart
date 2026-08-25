import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../theme/app_background.dart';
import '../widgets/glass.dart';

const String API_BASE = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

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
  String? _photoUrl;
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

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
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

      _photoUrl = '$API_BASE/api/image/$b2FileName';
      return _photoUrl;
    } catch (e) {
      setState(() => _errorMsg = 'Rasm yuklashda xato: $e');
      return null;
    } finally {
      setState(() => _isLoading = false);
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
        final uploadedUrl = await _uploadImageToB2();
        if (uploadedUrl == null) return;
      }

      final method = widget.initialAnime == null ? 'POST' : 'PUT';
      final endpoint = widget.initialAnime == null
          ? '$API_BASE/api/anime'
          : '$API_BASE/api/anime/${widget.initialAnime!['id']}';

      final body = jsonEncode({
        'photo_url': _photoUrl ?? '',
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
                          widget.initialAnime == null ? 'Anime qo\'shish' : 'Animeni tahrirlash',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
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
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _selectedImage != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.file(_selectedImage!, fit: BoxFit.cover),
                                  )
                                : _photoUrl != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Image.network(_photoUrl!, fit: BoxFit.cover),
                                      )
                                    : Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.image_outlined,
                                              size: 48, color: Colors.white54),
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
                      // Barcha maydonlar ixtiyoriy — istagan qismini
                      // to'ldirib, qolganini bo'sh qoldirish mumkin.
                      _buildTextField(
                          'Anime nomi (ixtiyoriy)', _nameCtrl, Icons.movie_creation_outlined),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Davlat (ixtiyoriy)', _davlatCtrl, Icons.location_on_outlined),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Studiya (ixtiyoriy)', _studiyaCtrl, Icons.business_outlined),
                      const SizedBox(height: 12),
                      _buildTextField('Janri (ixtiyoriy)', _janriCtrl, Icons.label_outline),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Tavsif (ixtiyoriy)', _tavsifCtrl, Icons.description_outlined,
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
                                onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.1),
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
                                onPressed: _isLoading ? null : () => _saveAnime(),
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(Colors.white),
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

  Widget _buildTextField(String label, TextEditingController ctrl, IconData icon,
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
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
          prefixIcon: Icon(icon, color: Colors.white54),
          border: InputBorder.none,
        ),
      ),
    );
  }
}
