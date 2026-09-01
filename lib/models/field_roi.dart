import 'dart:ui';

/// Represents a configured ROI (Region of Interest) field on a receipt template.
class FieldROI {
  final String id;
  final String fieldName; // 'store_name', 'date', 'time', 'receipt_number', etc.
  final String displayLabel; // Human-readable label
  Rect roi; // Region of Interest [left, top, right, bottom]
  final String ocrEngine; // 'mlkit' | 'both'
  double confidenceThreshold;
  bool isRequired;
  String validationRule; // 'date', 'numeric', 'currency', 'text', 'none'
  String? customFieldName; // Only if fieldName == 'custom_field'

  FieldROI({
    required this.id,
    required this.fieldName,
    required this.displayLabel,
    required this.roi,
    this.ocrEngine = 'mlkit',
    this.confidenceThreshold = 0.6,
    this.isRequired = false,
    this.validationRule = 'text',
    this.customFieldName,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fieldName': fieldName,
        'displayLabel': displayLabel,
        'roi_left': roi.left,
        'roi_top': roi.top,
        'roi_right': roi.right,
        'roi_bottom': roi.bottom,
        'ocrEngine': ocrEngine,
        'confidenceThreshold': confidenceThreshold,
        'isRequired': isRequired,
        'validationRule': validationRule,
        'customFieldName': customFieldName,
      };

  factory FieldROI.fromJson(Map<String, dynamic> json) => FieldROI(
        id: json['id'] as String,
        fieldName: json['fieldName'] as String,
        displayLabel: json['displayLabel'] as String,
        roi: Rect.fromLTRB(
          (json['roi_left'] as num).toDouble(),
          (json['roi_top'] as num).toDouble(),
          (json['roi_right'] as num).toDouble(),
          (json['roi_bottom'] as num).toDouble(),
        ),
        ocrEngine: json['ocrEngine'] as String? ?? 'mlkit',
        confidenceThreshold:
            (json['confidenceThreshold'] as num?)?.toDouble() ?? 0.6,
        isRequired: json['isRequired'] as bool? ?? false,
        validationRule: json['validationRule'] as String? ?? 'text',
        customFieldName: json['customFieldName'] as String?,
      );

  static const List<Map<String, String>> availableFields = [
    {'name': 'store_name', 'label': 'Store Name'},
    {'name': 'date', 'label': 'Date'},
    {'name': 'time', 'label': 'Time'},
    {'name': 'receipt_number', 'label': 'Receipt Number'},
    {'name': 'cashier', 'label': 'Cashier'},
    {'name': 'terminal_id', 'label': 'Terminal ID'},
    {'name': 'currency', 'label': 'Currency'},
    {'name': 'item_table', 'label': 'Item Table'},
    {'name': 'quantity', 'label': 'Quantity'},
    {'name': 'item_description', 'label': 'Item Description'},
    {'name': 'unit_price', 'label': 'Unit Price'},
    {'name': 'discount', 'label': 'Discount'},
    {'name': 'tax', 'label': 'Tax'},
    {'name': 'service_charge', 'label': 'Service Charge'},
    {'name': 'subtotal', 'label': 'Subtotal'},
    {'name': 'total', 'label': 'Total'},
    {'name': 'payment_method', 'label': 'Payment Method'},
    {'name': 'membership_number', 'label': 'Membership Number'},
    {'name': 'custom_field', 'label': 'Custom Field'},
  ];
}

/// Column definition within the YELLOW box (ROI Fields)
/// Each column is defined by user via vertical draggable lines
class YellowBoxColumn {
  final String id;
  final String name;           // 'item_description', 'unit_price', 'quantity', etc.
  final String displayName;    // Human-readable label
  double x;                    // X position (left edge) RELATIVE to YELLOW box left
  double width;                // Column width in pixels
  bool isRequired;
  int order;                   // Display order (left to right)

  YellowBoxColumn({
    required this.id,
    required this.name,
    required this.displayName,
    required this.x,
    required this.width,
    this.isRequired = false,
    required this.order,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'displayName': displayName,
        'x': x,
        'width': width,
        'isRequired': isRequired,
        'order': order,
      };

  factory YellowBoxColumn.fromJson(Map<String, dynamic> json) => YellowBoxColumn(
        id: json['id'] as String,
        name: json['name'] as String,
        displayName: json['displayName'] as String,
        x: (json['x'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        isRequired: json['isRequired'] as bool? ?? false,
        order: json['order'] as int? ?? 0,
      );

  /// Get absolute X position in image coordinates
  double getAbsoluteX(double yellowBoxLeft) => yellowBoxLeft + x;

  /// Get absolute Rect in image coordinates
  Rect getAbsoluteRect(double yellowBoxLeft, double yellowBoxTop, double yellowBoxHeight) {
    return Rect.fromLTWH(
      yellowBoxLeft + x,
      yellowBoxTop,
      width,
      yellowBoxHeight,
    );
  }

  /// Predefined column types for user selection
  static const List<Map<String, String>> availableColumns = [
    {'name': 'item_description', 'label': 'Item Description'},
    {'name': 'quantity', 'label': 'Quantity'},
    {'name': 'unit_price', 'label': 'Unit Price'},
    {'name': 'discount', 'label': 'Discount'},
    {'name': 'amount', 'label': 'Amount/Subtotal'},
    {'name': 'barcode', 'label': 'Barcode/SKU'},
    {'name': 'tax', 'label': 'Tax'},
    {'name': 'custom', 'label': 'Custom Field'},
  ];
}

/// YELLOW Box Configuration (ROI Fields)
/// Contains ALL purchase items with user-defined columns
/// Row detection is based on right-side subtotal delimiter
class YellowBoxConfig {
  final String id;
  Rect roi;                           // YELLOW box bounding rectangle (absolute image coords)
  List<YellowBoxColumn> columns;      // User-defined columns
  double estimatedRowHeight;          // Approximate row height for detection (pixels)
  bool detectRowsBySubtotal;          // Use right-side subtotal as line delimiter

  YellowBoxConfig({
    required this.id,
    required this.roi,
    List<YellowBoxColumn>? columns,
    this.estimatedRowHeight = 35.0,
    this.detectRowsBySubtotal = true,
  }) : columns = columns ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'roi_left': roi.left,
        'roi_top': roi.top,
        'roi_right': roi.right,
        'roi_bottom': roi.bottom,
        'columns': columns.map((c) => c.toJson()).toList(),
        'estimatedRowHeight': estimatedRowHeight,
        'detectRowsBySubtotal': detectRowsBySubtotal,
      };

  factory YellowBoxConfig.fromJson(Map<String, dynamic> json) => YellowBoxConfig(
        id: json['id'] as String,
        roi: Rect.fromLTRB(
          (json['roi_left'] as num).toDouble(),
          (json['roi_top'] as num).toDouble(),
          (json['roi_right'] as num).toDouble(),
          (json['roi_bottom'] as num).toDouble(),
        ),
        columns: (json['columns'] as List<dynamic>? ?? [])
            .map((c) => YellowBoxColumn.fromJson(c as Map<String, dynamic>))
            .toList(),
        estimatedRowHeight: (json['estimatedRowHeight'] as num?)?.toDouble() ?? 35.0,
        detectRowsBySubtotal: json['detectRowsBySubtotal'] as bool? ?? true,
      );

  /// Get column by name
  YellowBoxColumn? getColumn(String name) {
    try {
      return columns.firstWhere((c) => c.name == name);
    } catch (_) {
      return null;
    }
  }

  /// Get sorted columns (by order)
  List<YellowBoxColumn> get sortedColumns {
    final list = List<YellowBoxColumn>.from(columns);
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  /// Default column setup for typical receipt
  static YellowBoxConfig createDefault(Rect roi) {
    final w = roi.width;
    return YellowBoxConfig(
      id: 'yellow_${DateTime.now().millisecondsSinceEpoch}',
      roi: roi,
      columns: [
        YellowBoxColumn(
          id: 'col_item',
          name: 'item_description',
          displayName: 'Item Description',
          x: 0,
          width: w * 0.45,
          order: 0,
        ),
        YellowBoxColumn(
          id: 'col_qty',
          name: 'quantity',
          displayName: 'Qty',
          x: w * 0.45,
          width: w * 0.10,
          order: 1,
        ),
        YellowBoxColumn(
          id: 'col_price',
          name: 'unit_price',
          displayName: 'Unit Price',
          x: w * 0.55,
          width: w * 0.15,
          order: 2,
        ),
        YellowBoxColumn(
          id: 'col_disc',
          name: 'discount',
          displayName: 'Disc',
          x: w * 0.70,
          width: w * 0.10,
          order: 3,
        ),
        YellowBoxColumn(
          id: 'col_amt',
          name: 'amount',
          displayName: 'Amount',
          x: w * 0.80,
          width: w * 0.20,
          isRequired: true,
          order: 4,
        ),
      ],
    );
  }
}

/// LEGACY: Column definitions for the dynamic item table
/// DEPRECATED: Use YellowBoxConfig instead
/// Kept for backward compatibility with existing templates
class ItemTableConfig {
  final String id;
  Rect tableRoi;
  Rect quantityColumn;
  Rect descriptionColumn;
  Rect unitPriceColumn;
  Rect discountColumn;
  Rect amountColumn;

  ItemTableConfig({
    required this.id,
    required this.tableRoi,
    required this.quantityColumn,
    required this.descriptionColumn,
    required this.unitPriceColumn,
    required this.discountColumn,
    required this.amountColumn,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'tableRoi_left': tableRoi.left,
        'tableRoi_top': tableRoi.top,
        'tableRoi_right': tableRoi.right,
        'tableRoi_bottom': tableRoi.bottom,
        'qty_left': quantityColumn.left,
        'qty_top': quantityColumn.top,
        'qty_right': quantityColumn.right,
        'qty_bottom': quantityColumn.bottom,
        'desc_left': descriptionColumn.left,
        'desc_top': descriptionColumn.top,
        'desc_right': descriptionColumn.right,
        'desc_bottom': descriptionColumn.bottom,
        'price_left': unitPriceColumn.left,
        'price_top': unitPriceColumn.top,
        'price_right': unitPriceColumn.right,
        'price_bottom': unitPriceColumn.bottom,
        'discount_left': discountColumn.left,
        'discount_top': discountColumn.top,
        'discount_right': discountColumn.right,
        'discount_bottom': discountColumn.bottom,
        'amount_left': amountColumn.left,
        'amount_top': amountColumn.top,
        'amount_right': amountColumn.right,
        'amount_bottom': amountColumn.bottom,
      };

  factory ItemTableConfig.fromJson(Map<String, dynamic> json) =>
      ItemTableConfig(
        id: json['id'] as String,
        tableRoi: Rect.fromLTRB(
          (json['tableRoi_left'] as num).toDouble(),
          (json['tableRoi_top'] as num).toDouble(),
          (json['tableRoi_right'] as num).toDouble(),
          (json['tableRoi_bottom'] as num).toDouble(),
        ),
        quantityColumn: Rect.fromLTRB(
          (json['qty_left'] as num).toDouble(),
          (json['qty_top'] as num).toDouble(),
          (json['qty_right'] as num).toDouble(),
          (json['qty_bottom'] as num).toDouble(),
        ),
        descriptionColumn: Rect.fromLTRB(
          (json['desc_left'] as num).toDouble(),
          (json['desc_top'] as num).toDouble(),
          (json['desc_right'] as num).toDouble(),
          (json['desc_bottom'] as num).toDouble(),
        ),
        unitPriceColumn: Rect.fromLTRB(
          (json['price_left'] as num).toDouble(),
          (json['price_top'] as num).toDouble(),
          (json['price_right'] as num).toDouble(),
          (json['price_bottom'] as num).toDouble(),
        ),
        discountColumn: Rect.fromLTRB(
          (json['discount_left'] as num).toDouble(),
          (json['discount_top'] as num).toDouble(),
          (json['discount_right'] as num).toDouble(),
          (json['discount_bottom'] as num).toDouble(),
        ),
        amountColumn: Rect.fromLTRB(
          (json['amount_left'] as num).toDouble(),
          (json['amount_top'] as num).toDouble(),
          (json['amount_right'] as num).toDouble(),
          (json['amount_bottom'] as num).toDouble(),
        ),
      );

  /// Convert legacy ItemTableConfig to new YellowBoxConfig
  YellowBoxConfig toYellowBoxConfig() {
    return YellowBoxConfig(
      id: id,
      roi: tableRoi,
      columns: [
        YellowBoxColumn(
          id: 'col_qty',
          name: 'quantity',
          displayName: 'Qty',
          x: quantityColumn.left - tableRoi.left,
          width: quantityColumn.width,
          order: 0,
        ),
        YellowBoxColumn(
          id: 'col_desc',
          name: 'item_description',
          displayName: 'Description',
          x: descriptionColumn.left - tableRoi.left,
          width: descriptionColumn.width,
          order: 1,
        ),
        YellowBoxColumn(
          id: 'col_price',
          name: 'unit_price',
          displayName: 'Price',
          x: unitPriceColumn.left - tableRoi.left,
          width: unitPriceColumn.width,
          order: 2,
        ),
        YellowBoxColumn(
          id: 'col_disc',
          name: 'discount',
          displayName: 'Disc',
          x: discountColumn.left - tableRoi.left,
          width: discountColumn.width,
          order: 3,
        ),
        YellowBoxColumn(
          id: 'col_amt',
          name: 'amount',
          displayName: 'Amount',
          x: amountColumn.left - tableRoi.left,
          width: amountColumn.width,
          isRequired: true,
          order: 4,
        ),
      ],
    );
  }
}
