-- Test matrix dataset for SQLite: applied after sample/demo.sql.
-- See docs/test-plan.md §3.3.

-- Every type affinity and the awkward values.
CREATE TABLE tipi (
  id INTEGER PRIMARY KEY,
  i_small SMALLINT, i_big BIGINT, dec_38 DECIMAL(38,10), r REAL, dbl DOUBLE PRECISION,
  b BOOLEAN, d DATE, t TIME, ts TIMESTAMP, u VARCHAR(36), j TEXT, x TEXT,
  bin BLOB, testo TEXT, nota VARCHAR(200)
);
INSERT INTO tipi VALUES
 (1, -32768, -9223372036854775808, '-1234567890123456789012345678.0123456789', -1.5e-300, 3.141592653589793,
  1, '2024-02-29', '23:59:59', '2024-02-29 23:59:59.123', '0b5f6c1e-7d4a-4c3e-9b1a-2f6e8d9c0a11',
  '{"a":[1,2,{"b":null}],"è":"ü"}', '<r a="1"><c>ü</c></r>', X'00FF10AB', 'normale', 'minimo'),
 (2, 32767, 9223372036854775807, '1234567890123456789012345678.0123456789', 1.7e308, -0.0,
  0, '1900-01-01', '00:00:00', '1970-01-01 00:00:00', NULL,
  '[]', NULL, X'', 'accenti àèéìòù — CJK 漢字 — emoji 😀👍🏽 — RTL שלום', 'massimo'),
 (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'tutto NULL'),
 (4, 0, 0, '0', 0, 0, 0, '2000-01-01', '12:00:00', '2000-01-01 12:00:00', '', '', '', X'00', '', 'stringhe vuote'),
 (5, 1, 1, '0.0000000001', 1e-10, 1e10, 1, '9999-12-31', '12:34:56', '9999-12-31 23:59:59',
  'x', '{}', '<a/>', zeroblob(5242880), 'apice '' doppio " backslash \ tab	fine' || char(10) || 'a capo', 'speciali e blob 5MB'),
 (6, 2, 2, '2', 2, 2, 1, '2024-01-01', '01:02:03', '2024-01-01 01:02:03', 'y', '{}', '<a/>', X'01',
  replace(hex(zeroblob(524288)), '00', 'ab'), 'testo 1MB');

-- Identifiers that need quoting.
CREATE TABLE "Tabella Strana" (
  "Id" INTEGER PRIMARY KEY,
  "order" TEXT,
  "select" INTEGER,
  "colonna con spazi" TEXT,
  "MaiuscoleMinuscole" TEXT,
  "città" TEXT,
  "punto.nel.nome" TEXT
);
INSERT INTO "Tabella Strana" VALUES (1,'primo',10,'a b','Mm','Città di Castello','p.1'),(2,'secondo',20,'c d','mM','Forlì','p.2');

-- No primary key at all, and a key that is only UNIQUE.
CREATE TABLE senza_pk (codice TEXT, valore INTEGER);
INSERT INTO senza_pk VALUES ('a',1),('b',2),('b',2),('c',NULL);
CREATE TABLE solo_unique (codice TEXT NOT NULL UNIQUE, valore INTEGER);
INSERT INTO solo_unique VALUES ('x',1),('y',2);

-- Big table for paging, scrolling, streaming export and data compare.
CREATE TABLE grande (id INTEGER PRIMARY KEY, gruppo INTEGER, testo TEXT, importo DECIMAL(12,2), creato TIMESTAMP);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 200000)
INSERT INTO grande SELECT i, i % 100, 'riga ' || i, round((i * 7919 % 100000) / 100.0, 2),
  datetime('2020-01-01', '+' || (i % 1500) || ' days') FROM n;
CREATE INDEX ix_grande_gruppo ON grande(gruppo);

-- Trigger and audit table.
CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, tabella TEXT, azione TEXT, quando TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TRIGGER trg_progetti_upd AFTER UPDATE ON progetti
BEGIN
  INSERT INTO audit(tabella, azione) VALUES ('progetti', 'update ' || NEW.codice);
END;

-- CHECK constraint and a second view.
CREATE TABLE con_check (id INTEGER PRIMARY KEY, eta INTEGER CHECK (eta BETWEEN 0 AND 150), stato TEXT CHECK (stato IN ('A','B')));
INSERT INTO con_check VALUES (1, 30, 'A'), (2, 99, 'B');
CREATE VIEW v_progetti_ore AS
  SELECT p.codice, p.titolo, SUM(a.ore) AS ore FROM progetti p JOIN assegnazioni a ON a.progetto_codice = p.codice GROUP BY p.codice, p.titolo;
