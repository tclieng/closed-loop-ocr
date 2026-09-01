import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/receipt_data.dart';

/// Excel sheet name has a 31-char limit and must not contain []:*?/\\
String _safeSheetName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
}

/// Service for exporting receipt OCR results to Excel spreadsheets.
class ExcelService {
  static final ExcelService _instance = ExcelService._();
  factory ExcelService() => _instance;
  ExcelService._();

  /// Create an Excel file from receipt data and return the file path.
  /// Receipts sheet: one row per receipt (grand total summary only).
  /// Item sheets: one sheet per supplier name (NOT "Items"), containing
  /// the itemised line items for that supplier.
  Future<String> createExcel(
      List<ReceiptData> receipts, String supplierName) async {
    final excel = Excel.createExcel();
    // Remove default empty sheet
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    // ── Receipts sheet (grand total summary, one row per receipt) ──
    final sheet = excel['Receipts'];

    final headers = ReceiptData.excelHeaders;
    for (int i = 0; i < headers.length; i++) {
      sheet.setColumnWidth(i, 20);
    }

    final headerStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString('#FF6B35'),
      fontFamily: getFontFamily(FontFamily.Calibri),
      bold: true,
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
    );
    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(
        columnIndex: i,
        rowIndex: 0,
      ));
      cell.value = TextCellValue(headers[i]);
      cell.cellStyle = headerStyle;
    }
    sheet.setDefaultRowHeight(20);

    // Data rows
    for (int r = 0; r < receipts.length; r++) {
      final row = receipts[r].toExcelRow();
      for (int c = 0; c < row.length; c++) {
        final cell = sheet.cell(CellIndex.indexByColumnRow(
          columnIndex: c,
          rowIndex: r + 1,
        ));
        final value = row[c];
        if (value is double) {
          cell.value = DoubleCellValue(value);
        } else if (value is int) {
          cell.value = IntCellValue(value);
        } else {
          cell.value = TextCellValue(value?.toString() ?? '');
        }
      }
    }

    // ── Item sheets: one per supplier ──
    // Group receipts by supplier name
    final supplierGroups = <String, List<ReceiptData>>{};
    for (final r in receipts) {
      final name = r.supplier.isNotEmpty ? r.supplier : 'Unknown Supplier';
      print('[EXCEL_GROUP] Receipt ${r.filename} -> supplier="$name"');
      supplierGroups.putIfAbsent(name, () => []).add(r);
    }
    print('[EXCEL_GROUP] Total groups: ${supplierGroups.length}');
    for (final e in supplierGroups.entries) {
      print('[EXCEL_GROUP]   "${e.key}": ${e.value.length} receipts');
    }

    final itemHeaders = [
      'Receipt File',
      'Description',
      'Quantity',
      'UOM',
      'Unit Price',
      'Sub Total',
    ];
    final itemHeaderStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString('#FF6B35'),
      fontFamily: getFontFamily(FontFamily.Calibri),
      bold: true,
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
    );
    final totalStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#FFE0CC'),
      fontColorHex: ExcelColor.fromHexString('#C2410C'),
    );

    for (final entry in supplierGroups.entries) {
      final supplier = entry.key;
      final supplierReceipts = entry.value;
      final sheetName = _safeSheetName(supplier);
      final itemSheet = excel[sheetName];

      // Header row
      for (int i = 0; i < itemHeaders.length; i++) {
        final cell = itemSheet.cell(CellIndex.indexByColumnRow(
          columnIndex: i,
          rowIndex: 0,
        ));
        cell.value = TextCellValue(itemHeaders[i]);
        cell.cellStyle = itemHeaderStyle;
      }

      int itemRow = 1;
      for (final receipt in supplierReceipts) {
        for (final item in receipt.items) {
          // Receipt File — ensure clean filename
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 0, rowIndex: itemRow))
              .value = TextCellValue(_cleanFilename(receipt.filename));
          // Description
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 1, rowIndex: itemRow))
              .value = TextCellValue(item.description);
          // Quantity
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 2, rowIndex: itemRow))
              .value = IntCellValue(item.quantity);
          // UOM
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 3, rowIndex: itemRow))
              .value =
              TextCellValue(item.uom.isNotEmpty ? item.uom : '');
          // Unit Price
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 4, rowIndex: itemRow))
              .value = DoubleCellValue(item.unitPrice);
          // Sub Total (per-item amount)
          itemSheet
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 5, rowIndex: itemRow))
              .value = DoubleCellValue(
                  item.subtotal > 0 ? item.subtotal : item.amount);

          itemRow++;
        }
      }

      // TOTAL row
      if (itemRow > 1) {
        double total = 0;
        int itemCount = 0;
        for (final r in supplierReceipts) {
          for (final it in r.items) {
            total += it.amount;
            itemCount++;
          }
        }
        final labelCell = itemSheet.cell(
            CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: itemRow));
        labelCell.value = TextCellValue('TOTAL ($itemCount items)');
        labelCell.cellStyle = totalStyle;
        final sumCell = itemSheet.cell(
            CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: itemRow));
        sumCell.value = DoubleCellValue(total);
        sumCell.cellStyle = totalStyle;
      }
    }

    // Save file
    final appDir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${appDir.path}/downloads');
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = supplierName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final filename = '${safeName}_$timestamp.xlsx';
    final filePath = '${downloadsDir.path}/$filename';

    final fileBytes = excel.encode();
    if (fileBytes == null) throw Exception('Failed to encode Excel file');

    await File(filePath).writeAsBytes(fileBytes);
    return filePath;
  }

  /// Clean up a capture filename for display in Excel.
  /// Strips internal prefixes like CAP_, _scaled_, _proc suffixes,
  /// and ensures .jpg extension is present.
  String _cleanFilename(String raw) {
    var f = raw;
    // Remove leading "CAP_" prefix with timestamp (CAP_1787147765564_)
    f = f.replaceAll(RegExp(r'^CAP_\d+_'), '');
    // Remove _scaled_\d+ suffix
    f = f.replaceAll(RegExp(r'_scaled_\d+'), '');
    // Remove _proc suffix
    f = f.replaceAll(RegExp(r'_proc$'), '');
    // Remove _scaled suffix
    f = f.replaceAll(RegExp(r'_scaled$'), '');
    // Ensure .jpg extension
    if (!f.toLowerCase().endsWith('.jpg') &&
        !f.toLowerCase().endsWith('.jpeg') &&
        !f.toLowerCase().endsWith('.png')) {
      f = '$f.jpg';
    }
    return f;
  }

  /// Share the Excel file via the system share sheet.
  Future<void> shareExcel(String filePath, String supplierName) async {
    final file = XFile(filePath, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    await Share.shareXFiles(
      [file],
      subject: 'IntelliOCR Report - $supplierName',
      text: 'IntelliOCR receipt report for $supplierName',
    );
  }

  /// Share an Excel file via system share (Gmail available in options).
  Future<void> shareViaGmail(String filePath, String supplierName) async {
    final file = XFile(filePath);
    await Share.shareXFiles(
      [file],
      subject: 'IntelliOCR Report - $supplierName',
      text: 'IntelliOCR receipt processing results for $supplierName\n\nProcessed at: ${DateTime.now().toString()}',
    );
  }

  /// Share Excel via native Android Gmail intent with file attachment.
  /// Works on APK (native intent); falls back to web compose on desktop.
  Future<void> shareViaGmailWithAttachment(String filePath, String supplierName) async {
    // Use share_plus XFiles for native Android Gmail intent (supports attachment)
    final file = XFile(
      filePath,
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );

    await Share.shareXFiles(
      [file],
      subject: 'IntelliOCR Report - $supplierName',
      text: 'IntelliOCR receipt report for $supplierName\n'
          'Processed: ${DateTime.now().toString().split('.').first}\n'
          'Source: IntelliOCR Scanner',
    );
  }
}
