# Phase A — 双引擎 OCR 跨验证 (Dual Engine OCR Cross-Validator)

## 完成时间
2026-07-28 11:30 GMT+8

## 目标
实现 ML Kit + Tesseract 双引擎 OCR 支持，在 ROI 级和全页级进行交叉验证，提升提取准确率。

## 实现文件

### 1. 新增: `lib/services/cross_validator.dart`
**核心跨验证引擎**，包含：
- `CrossValidationResult` — 融合文本、置信度、双方是否同意、验证描述
- `CrossValidator.validate(textA, textB)` — 四级融合策略：
  - **高 (100%)** 精确匹配 → 置信度 0.95
  - **高 (>75%)** 编辑相似度 → 取较长的文本，置信度 = 相似度
  - **中 (40-75%)** 字符级融合 → 按编辑操作对齐，优先 alphanumeric (ML Kit 通常比 Tesseract 处理 ROI 准确)
  - **低 (<40%)** → 取更长结果，置信度 0.25
- `_normalizedSimilarity()` — 归一化 Levenshtein 相似度 (0.0-1.0)
- `_fuseTexts()` — 字符级文本融合，处理插入/删除/替换

### 2. 更新: `lib/services/ocr_service.dart`
新增 Tesseract 方法，保持 ML Kit 方法不变：
- `recognizeTextTesseract(File)` — 全页 Tesseract OCR (PSM 6)
- `recognizeRoiTesseract(File, Rect)` — ROI 裁剪 → 临时文件 → Tesseract (PSM 8)
- `recognizeFullTesseract(File)` — 全页自动分割 (PSM 3)
- **`recognizeRoiDual(File, Rect)`** — ROI 双引擎并发 → `CrossValidator.validate()`
- **`recognizeFullDual(File)`** — 全页逐行融合：分别获取 M Kit/Tesseract 全文 → 按行分割 → 逐行 `validate()` → 行重新拼接
- `DualOcrResult` 类 — 融合结果 + 单引擎独立结果 + 验证描述
- 依赖: `flutter_tesseract_ocr: ^0.4.31`

### 3. 更新: `lib/services/match_engine.dart`
- `_extractRoiText()` 新增 `useDual` 参数 (default false)
- 当 `field.ocrEngine == 'both'` 时调用 `recognizeRoiDual()` → 返回 `dualResult.fusedText`
- 旁路：模板编辑器中默认单引擎（快速响应），用户创建模板时可选字段级双引擎模式

### 4. 新增资源: `assets/tessdata/eng.traineddata` (23.4 MB)
- 来源: `https://github.com/tesseract-ocr/tessdata/raw/main/eng.traineddata`
- 仅包含英文 (eng) 模型，后续可扩展 msa (马来语)

### 5. 配置文件: `assets/tessdata_config.json`
```json
{
  "files": ["eng.traineddata"]
}
```

### 6. 更新: `pubspec.yaml`
- 新增依赖: `flutter_tesseract_ocr: ^0.4.31`
- 新增 assets: `assets/tessdata/`, `assets/tessdata_config.json`

## 双引擎调用流程

```
用户拍照 → match_engine.extractWithTemplate()
  ├── 锚点匹配 (Anchor A/B/C → ML Kit, 保持单引擎)
  ├── 坐标映射
  └── 字段 ROI 提取
       ├── ocrEngine == 'mlkit' → _ocr.recognizeRoi() [ML Kit only]
       └── ocrEngine == 'both' → _ocr.recognizeRoiDual()
            ├── Future.wait([ML Kit ROI, Tesseract ROI])
            ├── CrossValidator.validate() → 四级融合
            └── return fusedText
```

## 适配要点

| 组件 | ML Kit (primary) | Tesseract (secondary) |
|------|-------------------|-----------------------|
| 全页 OCR | PSM 未指定 (默认) | PSM 6 (统一文本块) |
| ROI OCR | InputImage.fromBytes | PSM 8 (单字/行) |
| 速度 | 快 (<500ms ROI) | 慢 (~2-5x slower) |
| 准确性 | 更好 (ML model) | 更好 (传统LSTM, 对倾斜更鲁棒) |
| APK 增量 | 已存在 | +70MB debug / +15MB release |

## 构建状态
- `flutter pub get`: ✅ 成功
- `dart analyze`: ✅ 0 errors (7 warnings, 32 infos, 均为 pre-existing 或无关)
- `flutter build apk --debug`: ✅ 成功, APK: `app-debug.apk` (247MB)
- 安装: `flutter install` 因设备未连接失败
- Desktop副本: `C:\Users\MK-User\Desktop\IntelliOCR-Dual.apk`

## Phase B 后续计划
- 升级 `tessdata` 到 msa+chi_sim (马来语+简体中文)
- UI 显示提取引擎标记 ("ML Kit" / "Dual-Validated" / "Tesseract")
- 为所有字段类型添加可视化置信度指示器
- 自动纠正表 (common confusions: 0→O, 1→l, S→5)
