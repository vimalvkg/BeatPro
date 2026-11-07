import 'dart:async';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// The rep's target this month, from Odoo. Only reps paid on salary +
/// targets and incentive have one.
class MyTarget {
  MyTarget(this.json);

  final Map<String, dynamic> json;

  double _n(String key) => (json[key] as num?)?.toDouble() ?? 0;

  String get monthLabel => json['month_label'] as String? ?? '';
  double get target => _n('target');
  double get achieved => _n('achieved');
  double get progress => _n('progress');
  double get earned => _n('earned');
  double get projected => _n('projected');
  double get projectedEarned => _n('projected_earned');
  double get perDay => _n('per_day');
  int get daysLeft => (json['days_left'] as num?)?.toInt() ?? 0;
  String? get plan => json['plan'] is String ? json['plan'] as String : null;
  bool get approved => json['approved'] == true;

  /// The next commission line: `{amount, rate, earns, text}`, or null when all are reached.
  Map<String, dynamic>? get nextStep => json['next_step'] is Map ? (json['next_step'] as Map).cast<String, dynamic>() : null;

  /// The plan's commission lines in words: `{from, text, rate, from_amount}`.
  List<Map<String, dynamic>> get lines => ((json['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// Product targets: `{name, qty, achieved, unit}`.
  List<Map<String, dynamic>> get products => ((json['products'] as List?) ?? const []).cast<Map<String, dynamic>>();
}

class SurveyQuestion {
  SurveyQuestion(this.json);

  final Map<String, dynamic> json;

  int get id => json['id'] as int;
  String get name => json['name'] as String;

  /// `yes_no`, `number`, `price`, `choice` or `text`.
  String get kind => json['kind'] as String;
  List<String> get choices => ((json['choices'] as List?) ?? const []).cast<String>();
  String get suffix => json['suffix'] as String? ?? '';
  bool get required => json['required'] != false;
}

/// A shop survey set up in Odoo: questions and the shelf photos needed.
class Survey {
  Survey(this.json);

  final Map<String, dynamic> json;

  int get id => json['id'] as int;
  String get name => json['name'] as String;
  List<SurveyQuestion> get questions =>
      ((json['questions'] as List?) ?? const []).cast<Map<String, dynamic>>().map(SurveyQuestion.new).toList();

  /// `(tag, how many)` photos needed at the shop.
  List<(String, int)> get photos => [
        for (final p in ((json['photos'] as List?) ?? const []).cast<Map<String, dynamic>>())
          (p['tag'] as String, (p['count'] as num?)?.toInt() ?? 1),
      ];
}

/// Takes a photo with the phone's camera.
abstract class PhotoService {
  /// JPEG bytes, or null when the rep cancelled.
  Future<Uint8List?> take();
}

class CameraPhotoService implements PhotoService {
  const CameraPhotoService();

  @override
  Future<Uint8List?> take() async {
    // Shelf photos don't need full resolution: smaller files sync faster on a weak signal.
    final file = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 70);
    return file?.readAsBytes();
  }
}
