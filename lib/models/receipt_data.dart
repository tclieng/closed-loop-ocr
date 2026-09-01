class ReceiptData {
  final String filename;
  String date;
  String time;
  String supplier;
  String number;
  double amount;
  String description;
  String category;
  String paymentMethod;
  double subtotal;
  double tax;
  String currency;
  String cashier;
  String terminalId;
  String membershipNumber;
  List<ItemRow> items;
  Map<String, String> customFields;
  double confidence;
  bool isValidated;

  ReceiptData({
    required this.filename,
    this.date = '',
    this.time = '',
    this.supplier = '',
    this.number = '',
    this.amount = 0.0,
    this.description = '',
    this.category = '',
    this.paymentMethod = '',
    this.subtotal = 0.0,
    this.tax = 0.0,
    this.currency = 'RM',
    this.cashier = '',
    this.terminalId = '',
    this.membershipNumber = '',
    List<ItemRow>? items,
    Map<String, String>? customFields,
    this.confidence = 0.0,
    this.isValidated = false,
  })  : items = items ?? [],
        customFields = customFields ?? {};

  List<dynamic> toExcelRow() {
    return [
      filename,
      supplier,
      number,
      date,
      amount,
      currency,
      paymentMethod,
      subtotal,
      tax,
      time,
      description,
      cashier,
      terminalId,
      membershipNumber,
      items.length,
    ];
  }

  /// Excel headers per user spec:
  /// RED → Invoice Number, BLUE → Invoice Date,
  /// YELLOW → Description/Qty/UOM/Unit Price/Sub Total,
  /// GREEN → Grand Total, Supplier = matched template name
  static List<String> get excelHeaders => [
        'Filename',
        'Supplier',
        'Invoice Number',
        'Invoice Date',
        'Grand Total (RM)',
        'Currency',
        'Payment Method',
        'Subtotal',
        'Tax',
        'Time',
        'Description',
        'Cashier',
        'Terminal ID',
        'Membership No',
        'Items Count',
      ];
}

class ItemRow {
  int quantity;
  String description;
  String uom;
  double unitPrice;
  double discount;
  double amount;
  double subtotal;

  ItemRow({
    this.quantity = 1,
    this.description = '',
    this.uom = '',
    this.unitPrice = 0.0,
    this.discount = 0.0,
    this.amount = 0.0,
    this.subtotal = 0.0,
  });

  String toBriefString() =>
      '$description x$quantity${uom.isNotEmpty ? ' $uom' : ''} RM${amount.toStringAsFixed(2)}';
}
