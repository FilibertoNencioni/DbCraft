-- Test matrix dataset for PostgreSQL (docs/test-plan.md §3.3).
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
DROP SCHEMA IF EXISTS molte CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE reparti (id INTEGER PRIMARY KEY, nome TEXT NOT NULL UNIQUE, sede TEXT);
CREATE TABLE dipendenti (
  id SERIAL PRIMARY KEY, nome VARCHAR(60) NOT NULL, cognome VARCHAR(60) NOT NULL, email VARCHAR(120),
  stipendio NUMERIC(10,2), assunto_il DATE, reparto_id INTEGER REFERENCES reparti(id), responsabile_id INTEGER REFERENCES dipendenti(id));
CREATE INDEX ix_dipendenti_cognome ON dipendenti(cognome);
CREATE TABLE progetti (codice VARCHAR(10) PRIMARY KEY, titolo TEXT NOT NULL, budget DOUBLE PRECISION, reparto_id INTEGER REFERENCES reparti(id));
CREATE TABLE assegnazioni (dipendente_id INTEGER REFERENCES dipendenti(id), progetto_codice VARCHAR(10) REFERENCES progetti(codice),
  ore INTEGER DEFAULT 0, PRIMARY KEY (dipendente_id, progetto_codice));
CREATE VIEW v_dipendenti_reparto AS SELECT d.id, d.nome || ' ' || d.cognome AS dipendente, r.nome AS reparto, d.stipendio
  FROM dipendenti d LEFT JOIN reparti r ON r.id = d.reparto_id;
INSERT INTO reparti VALUES (1,'Ricerca e Sviluppo','Milano'),(2,'Vendite','Roma'),(3,'Amministrazione','Torino'),(4,'Supporto','Bologna');
INSERT INTO dipendenti(nome, cognome, email, stipendio, assunto_il, reparto_id, responsabile_id)
SELECT (ARRAY['Giulia','Marco','Sara','Luca','Chiara','Andrea','Elena','Paolo'])[i % 8 + 1],
  (ARRAY['Rossi','Bianchi','Verdi','Esposito','Romano','Colombo','Ricci'])[i % 7 + 1],
  'utente' || i || '@esempio.it', round(1800 + (i * 37 % 2500) + 0.5, 2), DATE '2015-01-01' + i * 11, (i % 4) + 1,
  CASE WHEN i > 4 THEN (i % 4) + 1 END
FROM generate_series(1, 500) i;
INSERT INTO progetti VALUES ('CAS-01','DbCraft desktop',120000,1),('CRM-22','Nuovo CRM',80000,2),('ERP-07','Migrazione ERP',250000,3),('HD-03','Help desk 24/7',40000,4);
INSERT INTO assegnazioni SELECT id, (ARRAY['CAS-01','CRM-22','ERP-07','HD-03'])[id % 4 + 1], (id * 7) % 160 FROM dipendenti;

CREATE TYPE umore AS ENUM ('felice', 'triste');
CREATE TABLE tipi (
  id INTEGER PRIMARY KEY, i_small SMALLINT, i_big BIGINT, dec_38 NUMERIC(38,10), r REAL, dbl DOUBLE PRECISION,
  b BOOLEAN, d DATE, t TIME, ts TIMESTAMP(3), tz TIMESTAMPTZ, iv INTERVAL, u UUID, j JSONB, x XML, arr INTEGER[], e umore,
  m MONEY, inet_ INET, bin BYTEA, testo TEXT, nota VARCHAR(200));
INSERT INTO tipi VALUES
 (1, -32768, -9223372036854775808, -1234567890123456789012345678.0123456789, -1.5e-38, 3.141592653589793, true,
  '2024-02-29', '23:59:59', '2024-02-29 23:59:59.123', '2024-02-29 23:59:59+01', '1 year 2 mons 3 days 04:05:06',
  '0b5f6c1e-7d4a-4c3e-9b1a-2f6e8d9c0a11', '{"a":[1,2,{"b":null}],"è":"ü"}', '<r a="1"><c>ü</c></r>', '{1,2,3}', 'felice',
  -1234.56, '192.168.1.1', '\x00ff10ab', 'normale', 'minimo'),
 (2, 32767, 9223372036854775807, 1234567890123456789012345678.0123456789, 3.4e38, -0.0, false,
  '1900-01-01', '00:00:00', '1970-01-01 00:00:00', '1970-01-01 00:00:00+00', '-1 day', NULL, '[]', NULL, '{}', 'triste',
  0, '::1', '\x', 'accenti àèéìòù — CJK 漢字 — emoji 😀👍🏽 — RTL שלום', 'massimo'),
 (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'tutto NULL'),
 (4, 0, 0, 0, 0, 0, false, '2000-01-01', '12:00:00', '2000-01-01 12:00:00', '2000-01-01 12:00:00+00', '0', '00000000-0000-0000-0000-000000000000',
  '""', '<a/>', '{}', 'felice', 0, '0.0.0.0', '\x00', '', 'stringhe vuote'),
 (5, 1, 1, 0.0000000001, 1e-10, 1e10, true, '9999-12-31', '12:34:56', '9999-12-31 23:59:59', '9999-12-31 23:59:59+00', '1 second', NULL,
  '{}', '<a/>', '{1}', 'felice', 1, '10.0.0.1', decode(repeat('00', 5242880), 'hex'),
  'apice '' doppio " backslash \ tab' || chr(9) || 'fine' || chr(10) || 'a capo', 'speciali e blob 5MB'),
 (6, 2, 2, 2, 2, 2, true, '2024-01-01', '01:02:03', '2024-01-01 01:02:03', '2024-01-01 01:02:03+00', '2 hours', NULL, '{}', '<a/>', '{2}', 'triste',
  2, '10.0.0.2', '\x01', repeat('ab', 524288), 'testo 1MB');

CREATE TABLE "Tabella Strana" ("Id" INTEGER PRIMARY KEY, "order" TEXT, "select" INTEGER, "colonna con spazi" TEXT,
  "MaiuscoleMinuscole" TEXT, "città" TEXT, "punto.nel.nome" TEXT);
INSERT INTO "Tabella Strana" VALUES (1,'primo',10,'a b','Mm','Città di Castello','p.1'),(2,'secondo',20,'c d','mM','Forlì','p.2');
CREATE TABLE senza_pk (codice TEXT, valore INTEGER);
INSERT INTO senza_pk VALUES ('a',1),('b',2),('b',2),('c',NULL);
CREATE TABLE solo_unique (codice TEXT NOT NULL UNIQUE, valore INTEGER);
INSERT INTO solo_unique VALUES ('x',1),('y',2);
CREATE TABLE grande (id INTEGER PRIMARY KEY, gruppo INTEGER, testo TEXT, importo NUMERIC(12,2), creato TIMESTAMP);
INSERT INTO grande SELECT i, i % 100, 'riga ' || i, round(((i * 7919) % 100000) / 100.0, 2), TIMESTAMP '2020-01-01' + (i % 1500) * INTERVAL '1 day'
  FROM generate_series(1, 200000) i;
CREATE INDEX ix_grande_gruppo ON grande(gruppo);
CREATE TABLE audit (id SERIAL PRIMARY KEY, tabella TEXT, azione TEXT, quando TIMESTAMP DEFAULT now());
CREATE FUNCTION f_audit_progetti() RETURNS trigger AS $$
BEGIN
  INSERT INTO audit(tabella, azione) VALUES ('progetti', 'update ' || NEW.codice);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_progetti_upd AFTER UPDATE ON progetti FOR EACH ROW EXECUTE FUNCTION f_audit_progetti();
CREATE TABLE con_check (id INTEGER PRIMARY KEY, eta INTEGER CHECK (eta BETWEEN 0 AND 150), stato TEXT CHECK (stato IN ('A','B')));
INSERT INTO con_check VALUES (1, 30, 'A'), (2, 99, 'B');
CREATE VIEW v_progetti_ore AS SELECT p.codice, p.titolo, SUM(a.ore) AS ore FROM progetti p JOIN assegnazioni a ON a.progetto_codice = p.codice GROUP BY p.codice, p.titolo;
CREATE MATERIALIZED VIEW mv_reparti AS SELECT reparto_id, COUNT(*) AS n FROM dipendenti GROUP BY reparto_id;
CREATE SEQUENCE seq_fatture START 1000 INCREMENT 10;
CREATE FUNCTION calcola_bonus(p_id INTEGER, p_perc NUMERIC DEFAULT 10) RETURNS NUMERIC AS $$
DECLARE s NUMERIC; b NUMERIC;
BEGIN
  SELECT stipendio INTO s FROM dipendenti WHERE id = p_id;
  b := s * p_perc / 100;
  RAISE NOTICE 'bonus di %: %', p_id, b;
  RETURN b;
END $$ LANGUAGE plpgsql;
CREATE PROCEDURE aumenta(p_reparto INTEGER, p_perc NUMERIC) LANGUAGE plpgsql AS $$
BEGIN
  UPDATE dipendenti SET stipendio = stipendio * (1 + p_perc / 100) WHERE reparto_id = p_reparto;
END $$;
-- Large schema for the navigator.
CREATE SCHEMA molte;
DO $$ BEGIN FOR i IN 1..1000 LOOP EXECUTE format('CREATE TABLE molte.t_%s (id INTEGER PRIMARY KEY, v TEXT)', lpad(i::text, 4, '0')); END LOOP; END $$;
ANALYZE;
