-- Test matrix dataset for MySQL 8.4 and MariaDB 11.4 (docs/test-plan.md §3.3).
DROP DATABASE IF EXISTS dbcraft;
CREATE DATABASE dbcraft CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dbcraft;
SET SESSION cte_max_recursion_depth = 300000;

CREATE TABLE reparti (id INT PRIMARY KEY, nome VARCHAR(100) NOT NULL UNIQUE, sede VARCHAR(100));
CREATE TABLE dipendenti (
  id INT AUTO_INCREMENT PRIMARY KEY, nome VARCHAR(60) NOT NULL, cognome VARCHAR(60) NOT NULL, email VARCHAR(120),
  stipendio DECIMAL(10,2), assunto_il DATE, reparto_id INT, responsabile_id INT,
  FOREIGN KEY (reparto_id) REFERENCES reparti(id), FOREIGN KEY (responsabile_id) REFERENCES dipendenti(id));
CREATE INDEX ix_dipendenti_cognome ON dipendenti(cognome);
CREATE TABLE progetti (codice VARCHAR(10) PRIMARY KEY, titolo TEXT NOT NULL, budget DOUBLE, reparto_id INT, FOREIGN KEY (reparto_id) REFERENCES reparti(id));
CREATE TABLE assegnazioni (dipendente_id INT, progetto_codice VARCHAR(10), ore INT DEFAULT 0, PRIMARY KEY (dipendente_id, progetto_codice),
  FOREIGN KEY (dipendente_id) REFERENCES dipendenti(id), FOREIGN KEY (progetto_codice) REFERENCES progetti(codice));
CREATE VIEW v_dipendenti_reparto AS SELECT d.id, CONCAT(d.nome, ' ', d.cognome) AS dipendente, r.nome AS reparto, d.stipendio
  FROM dipendenti d LEFT JOIN reparti r ON r.id = d.reparto_id;
INSERT INTO reparti VALUES (1,'Ricerca e Sviluppo','Milano'),(2,'Vendite','Roma'),(3,'Amministrazione','Torino'),(4,'Supporto','Bologna');
INSERT INTO dipendenti(nome, cognome, email, stipendio, assunto_il, reparto_id, responsabile_id)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 500)
SELECT ELT(i % 8 + 1,'Giulia','Marco','Sara','Luca','Chiara','Andrea','Elena','Paolo'),
  ELT(i % 7 + 1,'Rossi','Bianchi','Verdi','Esposito','Romano','Colombo','Ricci'),
  CONCAT('utente', i, '@esempio.it'), ROUND(1800 + (i * 37 % 2500) + 0.5, 2), DATE_ADD('2015-01-01', INTERVAL i * 11 DAY), (i % 4) + 1,
  CASE WHEN i > 4 THEN (i % 4) + 1 END FROM n;
INSERT INTO progetti VALUES ('CAS-01','DbCraft desktop',120000,1),('CRM-22','Nuovo CRM',80000,2),('ERP-07','Migrazione ERP',250000,3),('HD-03','Help desk 24/7',40000,4);
INSERT INTO assegnazioni SELECT id, ELT(id % 4 + 1,'CAS-01','CRM-22','ERP-07','HD-03'), (id * 7) % 160 FROM dipendenti;

CREATE TABLE tipi (
  id INT PRIMARY KEY, i_small SMALLINT, i_big BIGINT, dec_38 DECIMAL(38,10), r FLOAT, dbl DOUBLE, b BOOLEAN,
  d DATE, t TIME, ts DATETIME(3), tz TIMESTAMP NULL, y YEAR, u CHAR(36), j JSON, e ENUM('felice','triste'), st SET('a','b','c'),
  bit8 BIT(8), bin LONGBLOB, testo LONGTEXT, nota VARCHAR(200));
INSERT INTO tipi VALUES
 (1, -32768, -9223372036854775808, -1234567890123456789012345678.0123456789, -1.5e-38, 3.141592653589793, 1,
  '2024-02-29', '23:59:59', '2024-02-29 23:59:59.123', '2024-02-29 23:59:59', 2024, '0b5f6c1e-7d4a-4c3e-9b1a-2f6e8d9c0a11',
  '{"a":[1,2,{"b":null}],"è":"ü"}', 'felice', 'a,c', b'10101010', UNHEX('00FF10AB'), 'normale', 'minimo'),
 (2, 32767, 9223372036854775807, 1234567890123456789012345678.0123456789, 3.4e38, -0.0, 0,
  '1000-01-01', '00:00:00', '1970-01-01 00:00:01', '1970-01-01 00:00:01', 1901, NULL, '[]', 'triste', '', b'0',
  '', 'accenti àèéìòù — CJK 漢字 — emoji 😀👍🏽 — RTL שלום', 'massimo'),
 (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'tutto NULL'),
 (4, 0, 0, 0, 0, 0, 0, '2000-01-01', '12:00:00', '2000-01-01 12:00:00', '2000-01-01 12:00:00', 2000, '', '""', 'felice', 'b', b'1', UNHEX('00'), '', 'stringhe vuote'),
 (5, 1, 1, 0.0000000001, 1e-10, 1e10, 1, '9999-12-31', '838:59:59', '9999-12-31 23:59:59', '2038-01-19 03:14:07', 2155, 'x', '{}', 'felice', 'a', b'1',
  REPEAT(CHAR(0), 5242880), CONCAT('apice '' doppio " backslash \\ tab', CHAR(9), 'fine', CHAR(10), 'a capo'), 'speciali e blob 5MB'),
 (6, 2, 2, 2, 2, 2, 1, '2024-01-01', '01:02:03', '2024-01-01 01:02:03', '2024-01-01 01:02:03', 2024, 'y', '{}', 'triste', 'c', b'1', UNHEX('01'),
  REPEAT('ab', 524288), 'testo 1MB');

CREATE TABLE `Tabella Strana` (`Id` INT PRIMARY KEY, `order` TEXT, `select` INT, `colonna con spazi` TEXT,
  `MaiuscoleMinuscole` TEXT, `città` TEXT, `punto.nel.nome` TEXT);
INSERT INTO `Tabella Strana` VALUES (1,'primo',10,'a b','Mm','Città di Castello','p.1'),(2,'secondo',20,'c d','mM','Forlì','p.2');
CREATE TABLE senza_pk (codice VARCHAR(10), valore INT);
INSERT INTO senza_pk VALUES ('a',1),('b',2),('b',2),('c',NULL);
CREATE TABLE solo_unique (codice VARCHAR(10) NOT NULL UNIQUE, valore INT);
INSERT INTO solo_unique VALUES ('x',1),('y',2);
CREATE TABLE grande (id INT PRIMARY KEY, gruppo INT, testo VARCHAR(50), importo DECIMAL(12,2), creato DATETIME);
INSERT INTO grande WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 200000)
  SELECT i, i % 100, CONCAT('riga ', i), ROUND(((i * 7919) % 100000) / 100.0, 2), DATE_ADD('2020-01-01', INTERVAL (i % 1500) DAY) FROM n;
CREATE INDEX ix_grande_gruppo ON grande(gruppo);
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, tabella VARCHAR(50), azione VARCHAR(100), quando TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
CREATE TRIGGER trg_progetti_upd AFTER UPDATE ON progetti FOR EACH ROW INSERT INTO audit(tabella, azione) VALUES ('progetti', CONCAT('update ', NEW.codice));
CREATE TABLE con_check (id INT PRIMARY KEY, eta INT CHECK (eta BETWEEN 0 AND 150), stato VARCHAR(1) CHECK (stato IN ('A','B')));
INSERT INTO con_check VALUES (1, 30, 'A'), (2, 99, 'B');
CREATE VIEW v_progetti_ore AS SELECT p.codice, p.titolo, SUM(a.ore) AS ore FROM progetti p JOIN assegnazioni a ON a.progetto_codice = p.codice GROUP BY p.codice, p.titolo;
DELIMITER $$
CREATE PROCEDURE due_risultati() BEGIN SELECT 1 AS a; SELECT 2 AS b; END $$
CREATE FUNCTION calcola_bonus(p_id INT, p_perc DECIMAL(5,2)) RETURNS DECIMAL(12,2) READS SQL DATA
BEGIN
  DECLARE s DECIMAL(12,2);
  SELECT stipendio INTO s FROM dipendenti WHERE id = p_id;
  RETURN s * p_perc / 100;
END $$
CREATE PROCEDURE aumenta(IN p_reparto INT, IN p_perc DECIMAL(5,2))
BEGIN
  UPDATE dipendenti SET stipendio = stipendio * (1 + p_perc / 100) WHERE reparto_id = p_reparto;
END $$
DELIMITER ;
