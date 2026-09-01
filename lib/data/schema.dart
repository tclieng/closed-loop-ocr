// lib/data/schema.dart
//
// Versioned SQLite schema for Closed Loop OCR.
// v1 — fresh, 12-engine aware, audit-trail-first.
//
// Holds:
//   suppliers, versioned templates, receipts, per-field provenance,
//   per-engine OCR runs, validations, anchors, decisions, audit, benchmark.

const int currentSchemaVersion = 1;

class Migration {
  final int to;
  final List<String> upSql;
  const Migration(this.to, this.upSql);
}

const List<Migration> schemaMigrations = [
  Migration(1, [
    // meta
    'CREATE TABLE schema_meta ('
        'version INTEGER PRIMARY KEY, '
        'applied_at TEXT NOT NULL);',

    // suppliers
    'CREATE TABLE suppliers ('
        'id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'normalized_name TEXT NOT NULL, '
        'created_at TEXT NOT NULL);',
    'CREATE UNIQUE INDEX idx_suppliers_norm ON suppliers(normalized_name);',

    // templates (versioned; a supplier can have many template versions,
    // one is 'active' at any time)
    'CREATE TABLE templates ('
        'id TEXT PRIMARY KEY, '
        'supplier_id TEXT NOT NULL, '
        'version INTEGER NOT NULL, '
        'status TEXT NOT NULL, ' // 'draft'|'active'|'retired'
        'definition_json TEXT NOT NULL, '
        'created_at TEXT NOT NULL, '
        'FOREIGN KEY (supplier_id) REFERENCES suppliers(id));',
    'CREATE UNIQUE INDEX idx_templates_supplier_version '
        'ON templates(supplier_id, version);',
    'CREATE TABLE template_active ('
        'supplier_id TEXT PRIMARY KEY, '
        'template_id TEXT NOT NULL, '
        'FOREIGN KEY (supplier_id) REFERENCES suppliers(id), '
        'FOREIGN KEY (template_id) REFERENCES templates(id));',

    // receipts
    'CREATE TABLE receipts ('
        'id TEXT PRIMARY KEY, '
        'supplier_id TEXT, '
        'template_id TEXT, '
        'template_version INTEGER, '
        'image_uri TEXT NOT NULL, '
        'image_sha256 TEXT, '
        'image_quality_score REAL, '
        'rectified_image_uri TEXT, '
        'captured_at TEXT NOT NULL, '
        'overall_status TEXT NOT NULL, ' // 'green'|'yellow'|'red'|'rejected'
        'decision_policy_version INTEGER NOT NULL, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL);',
    'CREATE INDEX idx_receipts_status ON receipts(overall_status);',
    'CREATE INDEX idx_receipts_supplier ON receipts(supplier_id);',

    // per-field extractions (provenance + decision)
    'CREATE TABLE receipt_field_values ('
        'id TEXT PRIMARY KEY, '
        'receipt_id TEXT NOT NULL, '
        'field_key TEXT NOT NULL, '
        'raw_text TEXT, '
        'normalized_value TEXT, '
        'consensus_text TEXT, '
        'confidence_avg REAL, '
        'engines_json TEXT, ' // JSON: [{engine,text,confidence,bbox}]
        'bbox_json TEXT, '
        'risk_class TEXT NOT NULL, ' // 'critical'|'high'|'medium'|'low'
        'status TEXT NOT NULL, ' // 'green'|'yellow'|'red'
        'rationale TEXT, '
        'decided_at TEXT, '
        'FOREIGN KEY (receipt_id) REFERENCES receipts(id));',
    'CREATE INDEX idx_rfv_receipt ON receipt_field_values(receipt_id);',
    'CREATE INDEX idx_rfv_status ON receipt_field_values(status);',

    // per-engine OCR runs
    'CREATE TABLE receipt_ocr_runs ('
        'id TEXT PRIMARY KEY, '
        'receipt_id TEXT NOT NULL, '
        'engine TEXT NOT NULL, '
        'text TEXT, '
        'blocks_json TEXT, '
        'confidence_avg REAL, '
        'ran_at TEXT NOT NULL, '
        'FOREIGN KEY (receipt_id) REFERENCES receipts(id));',
    'CREATE INDEX idx_ocr_receipt ON receipt_ocr_runs(receipt_id, engine);',

    // validations
    'CREATE TABLE receipt_validations ('
        'id TEXT PRIMARY KEY, '
        'receipt_id TEXT NOT NULL, '
        'rule TEXT NOT NULL, '
        'target_field TEXT, '
        'passed INTEGER NOT NULL, '
        'message TEXT, '
        'ran_at TEXT NOT NULL, '
        'FOREIGN KEY (receipt_id) REFERENCES receipts(id));',
    'CREATE INDEX idx_val_receipt ON receipt_validations(receipt_id);',

    // anchors (datum points)
    'CREATE TABLE receipt_anchors ('
        'id TEXT PRIMARY KEY, '
        'receipt_id TEXT NOT NULL, '
        'anchor_index INTEGER NOT NULL, '
        'detected_x REAL, detected_y REAL, '
        'template_x REAL, template_y REAL, '
        'score REAL, '
        'FOREIGN KEY (receipt_id) REFERENCES receipts(id));',

    // decisions (the policy verdicts, versioned)
    'CREATE TABLE receipt_decisions ('
        'id TEXT PRIMARY KEY, '
        'receipt_id TEXT NOT NULL, '
        'policy_version INTEGER NOT NULL, '
        'overall_status TEXT NOT NULL, '
        'per_field_json TEXT NOT NULL, '
        'rationale TEXT, '
        'decided_at TEXT NOT NULL, '
        'FOREIGN KEY (receipt_id) REFERENCES receipts(id));',

    // audit (every state change)
    'CREATE TABLE audit_events ('
        'id TEXT PRIMARY KEY, '
        'entity_type TEXT NOT NULL, '
        'entity_id TEXT NOT NULL, '
        'event_type TEXT NOT NULL, '
        'payload_json TEXT, '
        'actor TEXT, '
        'at TEXT NOT NULL);',
    'CREATE INDEX idx_audit_entity ON audit_events(entity_type, entity_id);',

    // benchmark
    'CREATE TABLE benchmark_runs ('
        'id TEXT PRIMARY KEY, '
        'started_at TEXT NOT NULL, '
        'finished_at TEXT, '
        'dataset TEXT, '
        'metrics_json TEXT);',
  ]),
];
