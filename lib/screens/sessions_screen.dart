import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

/// KIRGAN QURILMALAR.
///
/// Bitta hisobga eng ko'pi 4 ta qurilma kira oladi. 5-chisi
/// kirganda eng oldin onlayn bo'lgan qurilma serverda avtomatik
/// hisobdan chiqariladi — bu ekran shu holatni ko'rsatib turadi.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Map<String, dynamic>>? _items;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await AuthService.instance.sessions();
    if (!mounted) return;
    setState(() {
      _items = s;
      _loading = false;
    });
  }

  Future<void> _revoke(Map<String, dynamic> item) async {
    final id = (item['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return;
    final ok = await AuthService.instance.revoke(id);
    if (!mounted) return;
    if (ok) {
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chiqarib bo\'lmadi — qaytadan urinib ko\'ring')),
      );
    }
  }

  /// Epoch millisekundni `12:36/01/01/2026` ko'rinishiga o'giradi.
  ///
  /// Ya'ni: soat:daqiqa / kun / oy / yil. Kun, oy va soat har doim
  /// ikki xonali (`01`, `09`) — ustunlar bir xil enda turadi.
  String _when(dynamic ms) {
    final v = (ms as num?)?.toInt() ?? 0;
    if (v == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(v).toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(d.hour)}:${p2(d.minute)}/${p2(d.day)}/${p2(d.month)}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Kirgan qurilmalar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white54),
      );
    }
    final items = _items;
    if (items == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 40),
            const SizedBox(height: 14),
            const Text('Ro\'yxatni olib bo\'lmadi',
                style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 18),
            TextButton(onPressed: _load, child: const Text('Qayta urinish')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics:
            const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14, left: 4),
            child: Text(
              '${items.length} / 4 qurilma. Chegara to\'lganda yangi qurilma '
              'kirsa, eng oldin onlayn bo\'lgani avtomatik chiqariladi.',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                  height: 1.45),
            ),
          ),
          for (final s in items) _tile(s),
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> s) {
    final current = s['current'] == true;
    final device = (s['device'] ?? '').toString();
    final platform = (s['platform'] ?? '').toString();
    final version = (s['app_version'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glass(
        borderRadius: 18,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  current
                      ? Icons.phone_iphone_rounded
                      : Icons.devices_other_rounded,
                  color: current ? AppColors.success : Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    device.isEmpty ? 'Noma\'lum qurilma' : device,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (current)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Shu qurilma',
                        style: TextStyle(
                            color: AppColors.success,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  )
                else
                  IconButton(
                    tooltip: 'Hisobdan chiqarish',
                    icon: const Icon(Icons.logout_rounded,
                        color: Colors.white38, size: 18),
                    onPressed: () => _revoke(s),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _row('Tizim', platform),
            _row('Ilova', version.isEmpty ? '—' : 'v$version'),
            _row('Kirgan', _when(s['created_at'])),
            _row('Oxirgi faollik', _when(s['last_seen_at'])),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(k,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.42), fontSize: 12.5)),
          ),
          Expanded(
            child: Text(v.isEmpty ? '—' : v,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78), fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
