-- Database demo per DbCraft (SQLite via ODBC)
PRAGMA foreign_keys = ON;
CREATE TABLE reparti (
  id INTEGER PRIMARY KEY,
  nome TEXT NOT NULL UNIQUE,
  sede TEXT
);
CREATE TABLE dipendenti (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nome VARCHAR(60) NOT NULL,
  cognome VARCHAR(60) NOT NULL,
  email VARCHAR(120),
  stipendio DECIMAL(10,2),
  assunto_il DATE,
  reparto_id INTEGER REFERENCES reparti(id),
  responsabile_id INTEGER REFERENCES dipendenti(id)
);
CREATE INDEX ix_dipendenti_cognome ON dipendenti(cognome);
CREATE TABLE progetti (
  codice VARCHAR(10) PRIMARY KEY,
  titolo TEXT NOT NULL,
  budget REAL,
  reparto_id INTEGER REFERENCES reparti(id)
);
CREATE TABLE assegnazioni (
  dipendente_id INTEGER REFERENCES dipendenti(id),
  progetto_codice VARCHAR(10) REFERENCES progetti(codice),
  ore INTEGER DEFAULT 0,
  PRIMARY KEY (dipendente_id, progetto_codice)
);
CREATE VIEW v_dipendenti_reparto AS
  SELECT d.id, d.nome || ' ' || d.cognome AS dipendente, r.nome AS reparto, d.stipendio
  FROM dipendenti d LEFT JOIN reparti r ON r.id = d.reparto_id;
INSERT INTO reparti VALUES (1,'Ricerca e Sviluppo','Milano'),(2,'Vendite','Roma'),(3,'Amministrazione','Torino'),(4,'Supporto','Bologna');
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 500)
INSERT INTO dipendenti(nome, cognome, email, stipendio, assunto_il, reparto_id, responsabile_id)
SELECT
  CASE i % 8 WHEN 0 THEN 'Giulia' WHEN 1 THEN 'Marco' WHEN 2 THEN 'Sara' WHEN 3 THEN 'Luca' WHEN 4 THEN 'Chiara' WHEN 5 THEN 'Andrea' WHEN 6 THEN 'Elena' ELSE 'Paolo' END,
  CASE i % 7 WHEN 0 THEN 'Rossi' WHEN 1 THEN 'Bianchi' WHEN 2 THEN 'Verdi' WHEN 3 THEN 'Esposito' WHEN 4 THEN 'Romano' WHEN 5 THEN 'Colombo' ELSE 'Ricci' END,
  'utente' || i || '@esempio.it',
  round(1800 + (i * 37 % 2500) + 0.5, 2),
  date('2015-01-01', '+' || (i * 11) || ' days'),
  (i % 4) + 1,
  CASE WHEN i > 4 THEN (i % 4) + 1 ELSE NULL END
FROM n;
INSERT INTO progetti VALUES ('CAS-01','DbCraft desktop',120000,1),('CRM-22','Nuovo CRM',80000,2),('ERP-07','Migrazione ERP',250000,3),('HD-03','Help desk 24/7',40000,4);
INSERT INTO assegnazioni SELECT id, CASE id % 4 WHEN 0 THEN 'CAS-01' WHEN 1 THEN 'CRM-22' WHEN 2 THEN 'ERP-07' ELSE 'HD-03' END, (id * 7) % 160 FROM dipendenti;
