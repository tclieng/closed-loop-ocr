# IntelliOCR Scanner

> Version 1.0 | Package: `com.closedloop.ocr` | Android APK — [Releases ↗](https://github.com/tclieng/intelliocr-scanner/releases)

**Receipt OCR scanner for Android with 3-Anchor template system and dual-engine OCR.**

![Platform](https://img.shields.io/badge/Platform-Android-32CD32?style=flat-square)
![Flutter](https://img.shields.io/badge/Flutter-3.22-02569B?style=flat-square&logo=flutter)
![License](https://img.shields.io/badge/License-Proprietary-red?style=flat-square)

---

## 概述

IntelliOCR 是一个基于 **3-Anchor 模板系统** 的企业级收据 OCR 应用。
- **包名**: `com.closedloop.ocr`
- **主题色**: 橙色 `#FF6B35`
- **AI 引擎**: Google ML Kit Text Recognition + Tesseract OCR (双引擎，on-device)
- **状态**: ✅ APK 构建成功并发布

## 架构

### 3-Anchor 系统

```
┌──────────────────────┐
│  Anchor A (Header)   │ ← 固定位置：店名/LOGO（模板定义）
├──────────────────────┤
│      ROI 字段 1      │
│      ROI 字段 2      │
│      ...             │
├──────────────────────┤
│  Anchor B (Header 2) │ ← 固定位置：地址/税号（模板定义）
├──────────────────────┤
│   商品表格（动态行）   │ ← Anchor B → Anchor C 之间
│   Item 1             │
│   Item 2             │
│   ...                │
├──────────────────────┤
│  Anchor C (Footer)   │ ← 动态位置：TOTAL/SUM（模板定义）
├──────────────────────┤
│     付款信息行        │
│     小计(TOTAL)      │
└──────────────────────┘
```

- **Anchor A**: 表头锚点（固定值，如店名）
- **Anchor B**: 第二表头锚点（固定值，如公司注册号/GST号）
- **Anchor C**: 页脚锚点（动态值，每次收据可能不同，但模式固定，如 `TOTAL: RM XXX`）
- **字段 ROI**: 相对于 A+B 锚点定位的偏移区域
- **动态表格**: A→B 或 B→C 之间的可变行数区域

## 文件结构

```
intelliocr-scanner/
├── lib/
│   ├── main.dart                                         # 入口，主题色 #FF6B35
│   ├── models/
│   │   ├── anchor_point.dart                             # Anchor A/B/C 数据模型
│   │   ├── field_roi.dart                                # 字段 ROI + ItemTableConfig 模型
│   │   ├── receipt_data.dart                             # 收据数据模型
│   │   └── receipt_template.dart                          # 供应商模板模型
│   ├── screens/
│   │   ├── home_screen.dart                              # 主界面（Captures + Results 状态）
│   │   ├── capture_screen.dart                           # 拍照/相册界面
│   │   ├── scan_screen.dart                              # Phase 2 扫描流程
│   │   ├── template_list_screen.dart                     # 模板列表（Suppliers）
│   │   ├── master_templates_screen.dart                   # 只读模板浏览
│   │   ├── template_view_screen.dart                      # 模板详情（叠加显示锚点）
│   │   └── template_editor_screen.dart                    # Phase 1 模板创建向导（6步）
│   └── services/
│       ├── image_processor.dart                           # 图像预处理（尺寸 ≤1600px）
│       ├── ocr_service.dart                               # 双引擎 OCR（ML Kit + Tesseract）
│       ├── cross_validator.dart                           # 文本融合（4级 Levenshtein 策略）
│       ├── match_engine.dart                              # 锚点匹配 + ROI 字段提取
│       ├── template_service.dart                          # 模板 CRUD 持久化（JSON）
│       ├── excel_service.dart                             # Excel 导出（Receipts + Items 表）
│       └── sd_card_service.dart                           # 本地存储（IntelliOCR/Captures/）
├── assets/
│   └── tessdata/
│       └── eng.traineddata                                # Tesseract English 模型（需下载，~22MB）
└── pubspec.yaml
```

## 依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| `google_mlkit_text_recognition` | ^0.15.0 | 核心 OCR 引擎（ML Kit） |
| `image_picker` | ^1.1.2 | 拍照/相册选择 |
| `excel` | ^4.0.6 | Excel 导出 |
| `share_plus` | ^9.0.0 | 系统分享 |
| `permission_handler` | ^11.3.1 | 权限管理 |
| `path_provider` | ^2.1.5 | 文件路径 |
| `image` | ^4.3.0 | 图像预处理 |
| `shared_preferences` | ^2.3.3 | 本地设置存储 |
| `http` | ^1.6.0 | 网络请求 |
| `file_picker` | ^8.0.7 | 文件选择 |
| `google_mlkit_text_recognition` | bundled Tesseract | 双引擎备选 OCR |

## 文件结构

```
intelliocr-scanner/
├── lib/
│   ├── main.dart                                        # 入口，主题色 #FF6B35
│   ├── models/
│   │   ├── receipt_data.dart                             # 收据数据模型
│   │   ├── anchor_point.dart                             # 锚点数据模型
│   │   ├── field_roi.dart                                # 字段 ROI 模型 + ItemTableConfig
│   │   └── receipt_template.dart                        # 供应商模板模型
│   ├── services/
│   │   ├── image_processor.dart                          # 图像预处理(灰度→去噪→增强→标准化)
│   │   ├── ocr_service.dart                              # Google ML Kit OCR 封装
│   │   ├── template_service.dart                         # 模板 CRUD 持久化(JSON)
│   │   ├── excel_service.dart                            # Excel 导出(Receipts+Items 表, 橙色表头)
│   │   └── sd_card_service.dart                          # 本地存储(IntelliOCR/Captures/)
│   └── screens/
│       ├── home_screen.dart                              # 主界面(Phase 2 自动识别 UI)
│       ├── capture_screen.dart                           # 拍照/选择图库界面
│       ├── template_list_screen.dart                     # 模板列表(Suppliers)
│       └── template_editor_screen.dart                   # Phase 1 模板创建向导(6步)
├── android/
│   ├── build.gradle                                      # applicationId "com.closedloop.ocr"
│   └── app/src/main/
│       ├── AndroidManifest.xml                           # app label "IntelliOCR"
│       └── kotlin/com/intelliocr/scanner/MainActivity.kt
├── test/
│   └── widget_test.dart                                  # 烟雾测试
└── pubspec.yaml                                          # 项目配置
```

## 数据流

### Phase 1 (模板创建)
```
用户拍照/选择 → 预处理(灰度/去噪/增强) → 保存到 Masters/
→ Step 2: 选择 Anchor A 区域 + 输入预期文本
→ Step 3: 添加字段 ROI (选中文字+下拉选择字段类型)
→ Step 4: 配置商品表格区域+列定义(Qty/Desc/Price/Disc/Amt)
→ Step 5: 选择 Anchor C 区域 + 输入模式(如 "TOTAL:\s*RM\s*\d+\.\d{2}")
→ Step 6: 保存 JSON 模板到 templates/
```

### Phase 2 (自动识别)
```
拍照/选择 → 预处理 → Google ML Kit OCR
→ 加载模板列表 → 对每个模板：
  1. 在 OCR 结果中搜索 Anchor A 文本 ✓/✗
  2. 搜索 Anchor B 文本 ✓/✗
  3. 基于 A+B 偏移计算 ROI → 提取字段值
  4. 搜索 Anchor C 并提取表格区域内容行
  5. 解析商品行(根据列定义提取 Qty/Desc/Price...)
→ 最佳匹配模板 → 生成 ReceiptData
→ 导出 Excel(Receipts + Items 表, 橙色表头)
→ 系统分享(含 Gmail 选项)
```

## API

### ImageProcessor

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `processReceipt(Uint8List)` | 图片字节 | `Future<Uint8List>` | 全流水线处理 |
| `processAndSave(File)` | 源文件 | `Future<File>` | 处理并保存到同目录 |

预处理算法链：`自动白边裁剪 → 去偏斜 → 高斯模糊去噪 → 灰度+对比度增强 → 缩放标准化(600-1200px宽)`

### OcrService

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `recognizeText(File)` | 图片文件 | `Future<String>` | 全图 OCR |
| `recognizeBytes(Uint8List)` | 字节 | `Future<String>` | 字节 OCR |
| `recognizeRoi(File, Rect)` | 文件+ROI矩形 | `Future<String>` | ROI裁剪OCR |
| `recognizeDetailed(File)` | 文件 | `Future<RecognizedText?>` | 详细块/行级结果 |

### TemplateService (单例)

| 方法 | 返回 | 说明 |
|------|------|------|
| `loadTemplates()` | `Future<void>` | 从 storage 加载所有模板 |
| `saveTemplate(ReceiptTemplate)` | `Future<void>` | 保存/覆盖模板 |
| `deleteTemplate(String)` | `Future<void>` | 删除模板 |
| `getTemplate(String)` | `Future<ReceiptTemplate?>` | 按供应商名称查找 |
| `templates` | `List<ReceiptTemplate>` (getter) | 当前内存中的所有模板 |

### ExcelService (单例)

| 方法 | 说明 |
|------|------|
| `createExcel(List<ReceiptData>, String supplier)` | 生成 Excel (Receipts + Items 表, 橙色表头) |
| `shareExcel(String path, String supplier)` | 系统分享 |
| `shareViaGmail(String path, String supplier)` | Gmail 快捷分享 |

### SdCardService

| 方法 | 说明 |
|------|------|
| `saveCapture(File)` | 保存到 `IntelliOCR/Captures/` |
| `saveMaster(File)` | 保存到 `IntelliOCR/Masters/` |
| `capturesDir` | Captures 目录路径 |
| `mastersDir` | Masters 目录路径 |

## Excel 输出格式

### Receipts 表
| Filename | Supplier | Number | Date | Amount (RM) |
|----------|----------|--------|------|-------------|

### Items 表
| Receipt File | Qty | Description | Unit Price | Discount | Amount |
|-------------|-----|-------------|------------|----------|--------|
表头样式：橙色 `#FF6B35` 背景 + 白色粗体字

## 模板 JSON 结构

```json
{
  "id": "uuid",
  "supplierName": "THE BOTANIST",
  "description": "The Botanist receipt template",
  "createdAt": "2026-07-26T12:00:00Z",
  "updatedAt": "2026-07-26T12:00:00Z",
  "masterReceiptImage": "templates/master_botanist.jpg",
  "receiptWidth": 600,
  "receiptHeight": 800,
  "anchors": {
    "header_a": { "roi": {"x":10,"y":10,"w":580,"h":40}, "expectedText":"THE BOTANIST" },
    "header_b": { "roi": {"x":10,"y":50,"w":580,"h":30}, "expectedText":"No\\." },
    "footer_c": { "roi": {"x":300,"y":700,"w":300,"h":40}, "expectedPattern":"TOTAL\\s*RM\\s*\\d+\\.\\d{2}" }
  },
  "fields": [
    { "type": "store_name", "label": "Store Name", "roi": {"x":10,"y":10,"w":580,"h":40} },
    { "type": "receipt_number", "label": "Receipt No", "roi": {"x":200,"y":50,"w":200,"h":30} },
    { "type": "date", "label": "Date", "roi": {"x":400,"y":50,"w":100,"h":30} },
    { "type": "total", "label": "Total", "roi": {"x":450,"y":760,"w":100,"h":30} }
  ],
  "itemTableConfig": {
    "tableRoi": {"x":10,"y":80,"w":580,"h":620},
    "columnDefs": [
      {"label":"Qty","colIndex":0,"headerText":"Qty","alignment":"left"},
      {"label":"Description","colIndex":1,"headerText":"Description","alignment":"left"},
      {"label":"Unit Price","colIndex":2,"headerText":"Unit Price","alignment":"right"},
      {"label":"Discount","colIndex":3,"headerText":"Discount","alignment":"right"},
      {"label":"Amount","colIndex":4,"headerText":"Amount","alignment":"right"}
    ],
    "separatorChar": " ",
    "startAfterKeyword": "Qty",
    "endBeforeKeyword": "TOTAL"
  },
  "validationRules": {
    "requiredFields": ["total"],
    "minAmount": 0.01,
    "maxAmount": 100000
  }
}
```

## Tesseract 模型安装

> 双引擎 OCR 需要 Tesseract English 模型（~22MB）。首次构建前必须下载：

1. 从 [tesseract-ocr/tessdata](https://github.com/tesseract-ocr/tessdata/blob/main/eng.traineddata) 下载 `eng.traineddata`
2. 放入 `assets/tessdata/eng.traineddata`
3. 重新运行 `flutter pub get`

如果不安装，Tesseract 引擎会跳过，仅使用 ML Kit 引擎。

## 构建与部署

```bash
# 依赖
flutter pub get

# 开发
flutter run

# 分析
flutter analyze

# 构建 debug APK
flutter build apk --debug

# 构建 release APK（需签名密钥）
flutter build apk --release
```

> **Windows 本地构建**（需要 Java 17 + Android SDK）：
> ```powershell
> $env:JAVA_HOME = "C:\jdk17\jdk-17.0.19+10"
> $env:ANDROID_HOME = "C:\android-sdk"
> flutter build apk --debug
> ```

## GitHub Release

推送一个 `v*` 标签即可触发 GitHub Actions 自动构建：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 已知限制

1. **图像预处理**：preview 图像 ROI 交互已基准实现，但实际 Alignment/透视校正需要更多测试
2. **动态表格检测**：行/列检测算法（Phase 2）尚未实现
3. **权限**：`Permission.storage` 在 Android 11+ 已弃用，当前使用 `READ_MEDIA_IMAGES` + 作用域存储
4. **动画/过渡**：全橙色背景需保持 Material 3 统一体验
5. **模板编辑器**：6步向导的 ROI 框选使用 `GestureDetector`，真实收据的缩放/旋转对齐待完善

## 许可

专有软件 — 保留所有权利
