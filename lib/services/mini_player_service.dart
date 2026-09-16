import 'package:flutter/foundation.dart';

class MiniPlayerData {
  final Map<String, dynamic> season;
  final Map<String, dynamic> episode;
  final String url;
  final Duration position;
  final String title;

  MiniPlayerData({
    required this.season,
    required this.episode,
    required this.url,
    required this.position,
    required this.title,
  });
}

class MiniPlayerService extends ChangeNotifier {
  MiniPlayerService._();
  static final instance = MiniPlayerService._();

  MiniPlayerData? _data;
  bool _active = false;

  MiniPlayerData? get data => _data;
  bool get active => _active;

  void activate(MiniPlayerData data) {
    _data = data;
    _active = true;
    notifyListeners();
  }

  void deactivate() {
    _data = null;
    _active = false;
    notifyListeners();
  }

  void updatePosition(Duration pos) {
    if (_data != null) {
      _data = MiniPlayerData(
        season: _data!.season,
        episode: _data!.episode,
        url: _data!.url,
        position: pos,
        title: _data!.title,
      );
    }
  }
}
