-- Test matrix dataset for SQL Server 2022 (docs/test-plan.md §3.3). Run with sqlcmd -I.
USE master;
IF DB_ID('dbcraft') IS NOT NULL BEGIN ALTER DATABASE dbcraft SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE dbcraft; END;
CREATE DATABASE dbcraft COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO
USE dbcraft;
GO
CREATE TABLE reparti (id INT PRIMARY KEY, nome NVARCHAR(100) NOT NULL UNIQUE, sede NVARCHAR(100));
CREATE TABLE dipendenti (
  id INT IDENTITY(1,1) PRIMARY KEY, nome NVARCHAR(60) NOT NULL, cognome NVARCHAR(60) NOT NULL, email NVARCHAR(120),
  stipendio DECIMAL(10,2), assunto_il DATE, reparto_id INT REFERENCES reparti(id), responsabile_id INT REFERENCES dipendenti(id));
CREATE INDEX ix_dipendenti_cognome ON dipendenti(cognome);
CREATE TABLE progetti (codice VARCHAR(10) PRIMARY KEY, titolo NVARCHAR(MAX) NOT NULL, budget FLOAT, reparto_id INT REFERENCES reparti(id));
CREATE TABLE assegnazioni (dipendente_id INT REFERENCES dipendenti(id), progetto_codice VARCHAR(10) REFERENCES progetti(codice),
  ore INT DEFAULT 0, PRIMARY KEY (dipendente_id, progetto_codice));
GO
CREATE VIEW v_dipendenti_reparto AS SELECT d.id, d.nome + ' ' + d.cognome AS dipendente, r.nome AS reparto, d.stipendio
  FROM dipendenti d LEFT JOIN reparti r ON r.id = d.reparto_id;
GO
INSERT INTO reparti VALUES (1,N'Ricerca e Sviluppo',N'Milano'),(2,N'Vendite',N'Roma'),(3,N'Amministrazione',N'Torino'),(4,N'Supporto',N'Bologna');
WITH n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 500)
INSERT INTO dipendenti(nome, cognome, email, stipendio, assunto_il, reparto_id, responsabile_id)
SELECT CHOOSE(i % 8 + 1,'Giulia','Marco','Sara','Luca','Chiara','Andrea','Elena','Paolo'),
  CHOOSE(i % 7 + 1,'Rossi','Bianchi','Verdi','Esposito','Romano','Colombo','Ricci'),
  CONCAT('utente', i, '@esempio.it'), ROUND(1800 + (i * 37 % 2500) + 0.5, 2), DATEADD(day, i * 11, '2015-01-01'), (i % 4) + 1,
  CASE WHEN i > 4 THEN (i % 4) + 1 END FROM n OPTION (MAXRECURSION 0);
INSERT INTO progetti VALUES ('CAS-01',N'DbCraft desktop',120000,1),('CRM-22',N'Nuovo CRM',80000,2),('ERP-07',N'Migrazione ERP',250000,3),('HD-03',N'Help desk 24/7',40000,4);
INSERT INTO assegnazioni SELECT id, CHOOSE(id % 4 + 1,'CAS-01','CRM-22','ERP-07','HD-03'), (id * 7) % 160 FROM dipendenti;

CREATE TABLE tipi (
  id INT PRIMARY KEY, i_small SMALLINT, i_big BIGINT, dec_38 DECIMAL(38,10), r REAL, dbl FLOAT, b BIT,
  d DATE, t TIME(3), ts DATETIME2(3), tz DATETIMEOFFSET(3), sdt SMALLDATETIME, u UNIQUEIDENTIFIER, j NVARCHAR(MAX), x XML,
  m MONEY, g GEOGRAPHY, hid HIERARCHYID, sv SQL_VARIANT, bin VARBINARY(MAX), testo NVARCHAR(MAX), nota NVARCHAR(200));
INSERT INTO tipi VALUES
 (1, -32768, -9223372036854775808, -1234567890123456789012345678.0123456789, -1.5e-38, 3.141592653589793, 1,
  '2024-02-29', '23:59:59.123', '2024-02-29 23:59:59.123', '2024-02-29 23:59:59.123 +01:00', '2024-02-29 23:59', '0B5F6C1E-7D4A-4C3E-9B1A-2F6E8D9C0A11',
  N'{"a":[1,2,{"b":null}],"è":"ü"}', N'<r a="1"><c>ü</c></r>', -1234.5678, geography::Point(45.46, 9.19, 4326), '/1/2/', CAST(42 AS SQL_VARIANT), 0x00FF10AB, N'normale', N'minimo'),
 (2, 32767, 9223372036854775807, 1234567890123456789012345678.0123456789, 3.4e38, -0.0, 0,
  '0001-01-01', '00:00:00', '0001-01-01 00:00:00', '0001-01-01 00:00:00 +00:00', '1900-01-01', NULL, N'[]', NULL, 0, NULL, '/', CAST(N'testo' AS SQL_VARIANT),
  0x, N'accenti àèéìòù — CJK 漢字 — emoji 😀👍🏽 — RTL שלום', N'massimo'),
 (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, N'tutto NULL'),
 (4, 0, 0, 0, 0, 0, 0, '2000-01-01', '12:00:00', '2000-01-01 12:00:00', '2000-01-01 12:00:00 +00:00', '2000-01-01', '00000000-0000-0000-0000-000000000000',
  N'', N'<a/>', 0, NULL, NULL, NULL, 0x00, N'', N'stringhe vuote'),
 (5, 1, 1, 0.0000000001, 1e-10, 1e10, 1, '9999-12-31', '12:34:56', '9999-12-31 23:59:59.999', '9999-12-31 23:59:59 +14:00', '2079-06-06', NEWID(),
  N'{}', N'<a/>', 1, NULL, NULL, NULL, CAST(REPLICATE(CAST(0x00 AS VARBINARY(MAX)), 5242880) AS VARBINARY(MAX)),
  N'apice '' doppio " backslash \ tab' + CHAR(9) + N'fine' + CHAR(10) + N'a capo', N'speciali e blob 5MB'),
 (6, 2, 2, 2, 2, 2, 1, '2024-01-01', '01:02:03', '2024-01-01 01:02:03', '2024-01-01 01:02:03 +00:00', '2024-01-01', NEWID(), N'{}', N'<a/>', 2, NULL, NULL, NULL,
  0x01, REPLICATE(CAST(N'ab' AS NVARCHAR(MAX)), 524288), N'testo 1MB');

CREATE TABLE [Tabella Strana] ([Id] INT PRIMARY KEY, [order] NVARCHAR(50), [select] INT, [colonna con spazi] NVARCHAR(50),
  [MaiuscoleMinuscole] NVARCHAR(50), [città] NVARCHAR(50), [punto.nel.nome] NVARCHAR(50));
INSERT INTO [Tabella Strana] VALUES (1,N'primo',10,N'a b',N'Mm',N'Città di Castello',N'p.1'),(2,N'secondo',20,N'c d',N'mM',N'Forlì',N'p.2');
CREATE TABLE senza_pk (codice NVARCHAR(10), valore INT);
INSERT INTO senza_pk VALUES (N'a',1),(N'b',2),(N'b',2),(N'c',NULL);
CREATE TABLE solo_unique (codice NVARCHAR(10) NOT NULL UNIQUE, valore INT);
INSERT INTO solo_unique VALUES (N'x',1),(N'y',2);
CREATE TABLE grande (id INT PRIMARY KEY, gruppo INT, testo NVARCHAR(50), importo DECIMAL(12,2), creato DATETIME2);
WITH n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 200000)
INSERT INTO grande SELECT i, i % 100, CONCAT(N'riga ', i), ROUND(((i * 7919) % 100000) / 100.0, 2), DATEADD(day, i % 1500, '2020-01-01') FROM n OPTION (MAXRECURSION 0);
CREATE INDEX ix_grande_gruppo ON grande(gruppo);
CREATE TABLE audit (id INT IDENTITY PRIMARY KEY, tabella NVARCHAR(50), azione NVARCHAR(100), quando DATETIME2 DEFAULT SYSDATETIME());
GO
CREATE TRIGGER trg_progetti_upd ON progetti AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO audit(tabella, azione) SELECT N'progetti', N'update ' + codice FROM inserted;
END;
GO
CREATE TABLE con_check (id INT PRIMARY KEY, eta INT CHECK (eta BETWEEN 0 AND 150), stato NVARCHAR(1) CHECK (stato IN (N'A',N'B')));
INSERT INTO con_check VALUES (1, 30, N'A'), (2, 99, N'B');
GO
CREATE VIEW v_progetti_ore AS SELECT p.codice, p.titolo, SUM(a.ore) AS ore FROM progetti p JOIN assegnazioni a ON a.progetto_codice = p.codice GROUP BY p.codice, p.titolo;
GO
CREATE SEQUENCE seq_fatture START WITH 1000 INCREMENT BY 10;
GO
CREATE FUNCTION calcola_bonus(@p_id INT, @p_perc DECIMAL(5,2)) RETURNS DECIMAL(12,2) AS
BEGIN
  DECLARE @s DECIMAL(12,2);
  SELECT @s = stipendio FROM dipendenti WHERE id = @p_id;
  RETURN @s * @p_perc / 100;
END;
GO
CREATE PROCEDURE aumenta @p_reparto INT, @p_perc DECIMAL(5,2) AS
BEGIN
  UPDATE dipendenti SET stipendio = stipendio * (1 + @p_perc / 100) WHERE reparto_id = @p_reparto;
  PRINT 'aumento applicato';
END;
GO
CREATE SCHEMA molte;
GO
DECLARE @i INT = 1, @sql NVARCHAR(200);
WHILE @i <= 1000 BEGIN
  SET @sql = N'CREATE TABLE molte.t_' + RIGHT('000' + CAST(@i AS VARCHAR(4)), 4) + N' (id INT PRIMARY KEY, v NVARCHAR(50))';
  EXEC(@sql);
  SET @i += 1;
END;
GO
