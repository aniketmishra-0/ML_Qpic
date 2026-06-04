import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart' show XFile, XTypeGroup;

import '../../core/api_client.dart';
import '../../core/download_service.dart';
import '../../models/crop.dart';

enum BatchItemStatus { pending, processing, done, error }

class BatchQueueItem {
  BatchQueueItem({
    required this.file,
    required this.bytes,
  });

  final XFile file;
  final Uint8List bytes;
  BatchItemStatus status = BatchItemStatus.pending;
  CropResponse? result;
  String? errorText;
}

class BatchQueueController extends ChangeNotifier {
  final List<BatchQueueItem> _items = [];
  List<BatchQueueItem> get items => _items;

  bool _processing = false;
  bool get isProcessing => _processing;

  double _progress = 0.0;
  double get progress => _progress;

  int _currentIndex = 0;
  int get currentIndex => _currentIndex;

  bool get hasSuccessfulItems =>
      _items.any((item) => item.status == BatchItemStatus.done);

  Future<void> addFiles(List<XFile> files) async {
    if (_processing) return;
    for (final file in files) {
      if (_items.any((item) => item.file.path == file.path)) {
        continue; // Skip duplicates
      }
      final bytes = await file.readAsBytes();
      _items.add(BatchQueueItem(file: file, bytes: bytes));
    }
    notifyListeners();
  }

  void removeFile(int index) {
    if (_processing) return;
    if (index >= 0 && index < _items.length) {
      _items.removeAt(index);
      notifyListeners();
    }
  }

  void clear() {
    if (_processing) return;
    _items.clear();
    _progress = 0.0;
    _currentIndex = 0;
    notifyListeners();
  }

  Future<void> processAll({
    required ApiClient client,
    required int dpi,
    required int padding,
    required String markerStyle,
    required bool hasQuestions,
    required String? questionPages,
    required bool hasAnswers,
    required String? answerPages,
    required String? skipPages,
    required String questionPrefix,
    required String solutionPrefix,
    required int startNumber,
    required String imageFormat,
    required int jpgQuality,
    required bool useAi,
    required bool answerSheet,
    required String layoutColumns,
    required bool binarize,
    required double contrast,
    required double brightness,
    required int watermarkThreshold,
    required bool deskew,
    required String? customRegex,
    required double? confidence,
  }) async {
    if (_processing || _items.isEmpty) return;

    _processing = true;
    _progress = 0.0;
    _currentIndex = 0;
    notifyListeners();

    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item.status == BatchItemStatus.done) {
        _currentIndex = i + 1;
        _progress = _currentIndex / _items.length;
        notifyListeners();
        continue;
      }

      _currentIndex = i;
      item.status = BatchItemStatus.processing;
      notifyListeners();

      try {
        final cropRes = await client.crop(
          fileBytes: item.bytes,
          filename: item.file.name,
          dpi: dpi,
          padding: padding,
          markerStyle: markerStyle,
          hasQuestions: hasQuestions,
          questionPages: questionPages,
          hasAnswers: hasAnswers,
          answerPages: answerPages,
          skipPages: skipPages,
          questionPrefix: questionPrefix,
          solutionPrefix: solutionPrefix,
          startNumber: startNumber,
          imageFormat: imageFormat,
          jpgQuality: jpgQuality,
          useAi: useAi,
          answerSheet: answerSheet,
          layoutColumns: layoutColumns,
          binarize: binarize,
          contrast: contrast,
          brightness: brightness,
          watermarkThreshold: watermarkThreshold,
          deskew: deskew,
          customRegex: customRegex,
          confidence: confidence,
        );
        item.result = cropRes;
        item.status = BatchItemStatus.done;
      } catch (e) {
        item.status = BatchItemStatus.error;
        item.errorText = e.toString();
      }

      _currentIndex = i + 1;
      _progress = _currentIndex / _items.length;
      notifyListeners();
    }

    _processing = false;
    notifyListeners();
  }

  Future<void> downloadItem(int index, DownloadService ds,
      String questionPrefix, String solutionPrefix) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final res = item.result;
    if (res == null) return;

    final Uri downloadUri = ds.apiClient.cropDownloadUri(
      res.jobId,
      kind: 'combined',
      questionPrefix: questionPrefix,
      solutionPrefix: solutionPrefix,
    );

    final baseName =
        item.file.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final suggestedName =
        '${baseName}_${questionPrefix}${solutionPrefix}combined.zip';

    await ds.download(
      engineUrl: downloadUri.toString(),
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ZIP Archive', extensions: ['zip'])
      ],
    );
  }

  Future<void> downloadAll(
      DownloadService ds, String questionPrefix, String solutionPrefix) async {
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].status == BatchItemStatus.done) {
        await downloadItem(i, ds, questionPrefix, solutionPrefix);
      }
    }
  }
}
