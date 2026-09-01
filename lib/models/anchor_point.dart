import 'dart:ui';

/// Represents an anchor (datum) point on a receipt template.
class AnchorPoint {
  final String id;
  final String label;
  final String type; // 'header_a' | 'header_b' | 'footer_c'
  final Rect roi; // Region of Interest [left, top, right, bottom]
  final String expectedText; // Expected OCR text at this anchor
  final String imageFingerprint; // Image hash/fingerprint for matching
  final double position; // Relative Y position (0.0 = top, 1.0 = bottom)
  final double size; // Size of ROI area
  final double confidenceThreshold; // Minimum confidence to accept match (0.0-1.0)

  const AnchorPoint({
    required this.id,
    required this.label,
    required this.type,
    required this.roi,
    required this.expectedText,
    this.imageFingerprint = '',
    this.position = 0.0,
    this.size = 0.0,
    this.confidenceThreshold = 0.7,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type,
        'roi_left': roi.left,
        'roi_top': roi.top,
        'roi_right': roi.right,
        'roi_bottom': roi.bottom,
        'expectedText': expectedText,
        'imageFingerprint': imageFingerprint,
        'position': position,
        'size': size,
        'confidenceThreshold': confidenceThreshold,
      };

  factory AnchorPoint.fromJson(Map<String, dynamic> json) => AnchorPoint(
        id: json['id'] as String,
        label: json['label'] as String,
        type: json['type'] as String,
        roi: Rect.fromLTRB(
          (json['roi_left'] as num).toDouble(),
          (json['roi_top'] as num).toDouble(),
          (json['roi_right'] as num).toDouble(),
          (json['roi_bottom'] as num).toDouble(),
        ),
        expectedText: json['expectedText'] as String,
        imageFingerprint: json['imageFingerprint'] as String? ?? '',
        position: (json['position'] as num?)?.toDouble() ?? 0.0,
        size: (json['size'] as num?)?.toDouble() ?? 0.0,
        confidenceThreshold:
            (json['confidenceThreshold'] as num?)?.toDouble() ?? 0.7,
      );
}
