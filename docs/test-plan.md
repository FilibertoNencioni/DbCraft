# Piano di test completo di DbCraft

Obiettivo: provare **ogni tipo di sorgente dati** supportata (DBMS via ODBC, driver
nativi NoSQL/cloud, storage a oggetti) e su ciascuna **ogni funzionalità dell'app**,
annotando i difetti trovati con passi per riprodurli.

Esecuzione **sequenziale** (nessun agente in parallelo), su macOS arm64, branch
`feat/db-design`.

### Decisioni prese (24/10/2026)

| Tema | Decisione | Effetto |
|---|---|---|
| Difetti | **Solo report**, nessuna correzione durante i test | Le correzioni si pianificano dopo, insieme, sul report |
| Account cloud | **Nessuno** | T14 BigQuery, T15 Snowflake, T16, S03 GCS e S04 → ⏸ non provati; restano MinIO (S01) e Azurite (S02) |
| AI | **Nessuna chiamata reale** | AI-01 ridotto a impostazioni, consenso, chiave nel vault, voci di menu, messaggi senza chiave |
| Installazioni | **Solo Homebrew e Docker** | T09 Oracle, T10 Firebird, T11 Db2, T13 ClickHouse → ⏸ (driver ODBC da installare a mano); T12 DuckDB solo se il driver ODBC è installabile con Homebrew. Per questi DBMS restano i test golden già esistenti |

Il perimetro effettivo è quindi: **SQLite, PostgreSQL, SQL Server (ODBC 18, 17, FreeTDS),
MySQL, MariaDB, MongoDB, Redis, Cassandra, MinIO (S3), Azurite (Azure Blob)**, più le
funzionalità trasversali. Le sezioni sui target ⏸ restano nel piano per un secondo giro.

### Stato (24/10/2026)

Piano **eseguito** per il perimetro effettivo; i difetti trovati sono stati corretti. Differenze rispetto al piano:
- S3 è emulato con **RustFS** (MinIO non pubblica più immagini su Docker Hub).
- L'immagine PostgreSQL con `pldebugger` installa PostgreSQL **17.11** (non 17.2): apt aggiorna il server insieme all'estensione.
- Le suite sono in `integration_test/matrix/` (una per area), i dataset in `tool/test_matrix/seed/`.

Per rieseguire una suite (la finestra dell'app deve restare visibile, lo schermo non deve andare in stop):

```sh
docker compose -f tool/test_matrix/compose.yml up -d --wait          # pg (+ pldebugger), s3, azurite
docker compose -f tool/design_db/compose.yml up -d --wait mysql mariadb mssql mongo redis cassandra
flutter test integration_test/matrix/<suite>_test.dart -d macos \
  --dart-define=TARGET=<sqlite|pg|mysql|mariadb|mssql|mongo|redis|cassandra|s3|azure|app|cross> \
  --dart-define=REPO=$PWD --dart-define=SHOT_DIR=$PWD/build/matrix/<suite>
```
Suite: `driver_install`, `core`, `conn`, `objects`, `design`, `security`, `pro`, `nosql`, `storage`, `appwide`, `cross`.
Screenshot e risultati in `build/matrix/<suite>/<target>/` (`results.jsonl` + PNG); matrice degli esiti con `python3 -I tool/test_matrix/summary.py build/matrix`.

---

## 1. Vincoli dell'ambiente rilevati

| Voce | Stato attuale | Impatto sul piano |
|---|---|---|
| Docker | 29.9, **7,6 GB di RAM**, 8 CPU, arm64 | I server non stanno tutti insieme in memoria: vanno avviati **a blocchi** (§5) |
| Disco | ~313 GB liberi | Nessun problema (immagini da scaricare ~10 GB) |
| Driver ODBC registrati | Solo `ODBC Driver 17/18 for SQL Server` | `psqlodbc` e `mariadb-connector-odbc` vanno installati (lo si fa **dall'app**, così si prova anche l'installer) |
| Librerie presenti non registrate | `libsqlite3odbc.dylib`, `libtdsodbc.so` (FreeTDS) | Utilizzabili indicando il percorso della libreria |
| Oracle / Firebird / Db2 ODBC | Non installati | Installazione manuale (Instant Client 23 arm64, Firebird ODBC, IBM clidriver `macarm64`). Firebird ODBC su arm64 è **incerto** |
| Db2 server | Immagine solo x86, privilegiata, ~3 GB | Gira in emulazione Rosetta: **best effort**, può non partire |
| GCS e BigQuery | Endpoint fissi nel codice (`storage.googleapis.com`, `bigquery.googleapis.com`) | Nessun emulatore utilizzabile senza modifiche: serve un **account Google Cloud reale** |
| S3 / Azure Blob | — | Emulabili in locale: **MinIO** e **Azurite** (immagine già presente) |
| Debugger PL/pgSQL | `postgres:17.2` non ha `pldbgapi` | Serve un'immagine derivata con `postgresql-17-pldebugger` |
| AI | — | Serve una chiave API Anthropic (costo per chiamata) |
| CLI cloud | `az` presente; `aws`, `gcloud` assenti | Le credenziali "CLI" si provano solo per Azure, salvo installazione |
| Kerberos, Entra ID, Okta, SAML, IAM | Nessun IdP locale | Verificata solo la stringa di connessione generata, salvo account reali |

---

## 2. Sorgenti dati da provare

### Livello A — locali, driver disponibili o installabili dall'app

| ID | Sorgente | Versione | Come | Driver |
|---|---|---|---|---|
| T01 | SQLite | 3.x | file locale (`sample/demo.db` + DB di test) | `libsqlite3odbc.dylib` |
| T02 | PostgreSQL | 17.2 | compose `pg` (+ variante `pg-debug`) | `PostgreSQL Unicode` (installato dall'app) |
| T03 | SQL Server | 2022 CU16 | compose `mssql` | `ODBC Driver 18` (+ prova con 17 e FreeTDS) |
| T04 | MySQL | 8.4.3 | compose `mysql` | MariaDB Connector/ODBC ≥ 3.1.11 |
| T05 | MariaDB | 11.4.4 | compose `mariadb` | MariaDB Connector/ODBC |
| T06 | MongoDB | 8.0.4 | compose `mongo` | nativo |
| T07 | Redis | 7.4.1 | compose `redis` | nativo |
| T08 | Cassandra | 5.0.2 | compose `cassandra` | nativo |

### Livello B — locali, driver da installare a mano

| ID | Sorgente | Come | Driver |
|---|---|---|---|
| T09 | Oracle Free | 23.5 (compose `oracle`) | Oracle Instant Client 23 Basic + ODBC (arm64), registrato in `odbcinst.ini` |
| T10 | Firebird | 5.0.1 (compose `firebird`) | Firebird ODBC driver (se disponibile per arm64, altrimenti **N/D**) |
| T11 | Db2 | 11.5.9 (profilo `db2`) | IBM Data Server Driver `macarm64_odbc_cli` — **best effort** |
| T12 | DuckDB (generico ODBC) | file locale | DuckDB ODBC driver per macOS |
| T13 | ClickHouse (generico ODBC) | container `clickhouse/clickhouse-server` | `clickhouse-odbc` (compilato o binario) — opzionale |

### Livello C — servizi cloud (richiedono account)

| ID | Sorgente | Requisito |
|---|---|---|
| T14 | Google BigQuery (nativo) | Progetto GCP con sandbox gratuita + service account JSON |
| T15 | Snowflake (ODBC) | Account di prova 30 giorni + driver ODBC Snowflake |
| T16 | Redshift / Athena / Databricks / Trino / Atlas SQL / Access / Cassandra ODBC / BigQuery ODBC | Solo se l'utente ha account e driver: altrimenti si verifica il **template** (stringa generata) e il riconoscimento del dialetto |

### Storage a oggetti (pannello Storage)

| ID | Sorgente | Come |
|---|---|---|
| S01 | Amazon S3 | **MinIO** in Docker (endpoint personalizzato, path-style) |
| S02 | Azure Blob Storage | **Azurite** in Docker (shared key, SAS, connection string) |
| S03 | Google Cloud Storage | Bucket reale (stesso progetto di T14) |
| S04 | AWS S3 / Cloudflare R2 reali | Opzionale, se ci sono credenziali |

---

## 3. Preparazione

### 3.1 Workspace isolato
- `DBCRAFT_WORKSPACE=$SCRATCH/ws` per non toccare connessioni, vault e cronologia reali.
- Snapshot iniziale di `flutter test` (baseline): ogni test che fallisce già prima è annotato e non conta come regressione.

### 3.2 Infrastruttura aggiuntiva (in `tool/test_matrix/`, non nel compose di design)
- `compose.yml` con: `minio`, `azurite`, `pg-debug` (Dockerfile `FROM postgres:17.2` + `postgresql-17-pldebugger`, `shared_preload_libraries=plugin_debugger,pg_stat_statements`), `clickhouse` (opzionale).
- Repository Git remoto: repository *bare* locale (`git init --bare`) per pull/push.
- Utente DSN di prova in `~/.odbc.ini` per il modo **DSN** (rimosso alla fine).

### 3.3 Dataset di test identico per ogni DBMS SQL (`tool/test_matrix/seed/<target>.sql`)
- **Schema relazionale** (catena di FK reparti → dipendenti → progetti → assegnazioni, auto-riferimento, PK composta, tabella **senza PK**, tabella con PK solo `UNIQUE`).
- **Tabella dei tipi** con tutte le famiglie del DBMS: interi (min/max), `DECIMAL(38,10)`, float/real, `MONEY`, boolean/bit, date/time/timestamp/timestamptz/interval, uuid, json/jsonb, xml, array, enum, geometry, BLOB/bytea/varbinary (0 byte, 1 KB, 5 MB), CLOB/TEXT (1 MB), stringhe Unicode (accenti, CJK, emoji, RTL), stringhe con `'`, `"`, `\`, a capo, tab, `NULL` e stringa vuota.
- **Nomi difficili**: tabella e colonne con spazi, maiuscole/minuscole, parole riservate (`order`, `select`), Unicode, punto nel nome.
- **Tabella grande**: 200.000 righe (paginazione, scroll, export in streaming, confronto dati).
- Vista, vista materializzata (dove esiste), sequenza, trigger, procedura con parametri IN/OUT, funzione, procedura che restituisce **più result set** e che stampa messaggi (`PRINT`/`RAISE NOTICE`/`DBMS_OUTPUT`/`SIGNAL`).
- Oggetti specifici (estensione, enum, dominio, policy RLS, sinonimo, package, evento…) dove previsti.
- **Schema grande**: 1.000 tabelle in uno schema separato (prestazioni del navigator e dell'autocompletamento).
- NoSQL: database/collezioni Mongo con documenti annidati, array, ObjectId, Date, Decimal128, Binary; Redis con tutti i tipi (string, hash, list, set, zset, stream, JSON se presente, chiavi con TTL, 100k chiavi); Cassandra con keyspace, tipi collezione/UDT/tuple, chiavi di partizione e clustering, 100k righe.

### 3.4 Installazioni
1. Dall'app: *Database › Driver ODBC installati… › Installa*: PostgreSQL e MariaDB (prova dell'installer, §F-CON-13).
2. A mano: Oracle Instant Client + ODBC, Firebird ODBC, IBM clidriver, DuckDB ODBC.
3. Immagini: `postgres:17.2`, `mysql:8.4.3`, `mariadb:11.4.4`, `gvenzl/oracle-free:23.5-slim`, `firebirdsql/firebird:5.0.1`, `minio/minio`, eventualmente `db2` e `clickhouse`.

---

## 4. Metodo di esecuzione

Non potendo cliccare sull'app, le prove passano da quattro livelli, tutti eseguiti da me:

| Livello | Strumento | Cosa produce |
|---|---|---|
| L0 Baseline | `flutter test` | Stato dei test unitari/golden prima di iniziare |
| L1 Round-trip design | `integration_test/design_db_test.dart` con `DESIGN_TARGETS=<tutti i target disponibili>` | Verifica DDL su server reali (già esistente: oggi provato solo su SQLite, SQL Server, Mongo, Cassandra, Redis) |
| L2 Matrice end-to-end | **Nuova suite** `integration_test/matrix_test.dart` parametrizzata con `--dart-define=TARGET=…` che avvia l'app reale, si connette e percorre la checklist del §6 **tramite l'interfaccia** (tap, digitazione, drag, scorciatoie) | Esito per caso di test in un file JSON + screenshot per ogni passo |
| L3 Verifica lato server | `docker exec … psql/sqlcmd/mysql/sqlplus/mongosh/redis-cli/cqlsh`, `curl` per i link firmati | Conferma indipendente che quanto fatto nell'app è avvenuto davvero sul server |

Regole:
- Ogni screenshot viene guardato (non solo generato): problemi di layout, testo tagliato, stati disabilitati sbagliati, tema scuro.
- La finestra dell'app deve restare visibile durante i test di integrazione (macOS sospende il rendering se coperta).
- Dove l'interfaccia nativa non è pilotabile (barra dei menu macOS, dialoghi di sistema per i file) si usa la scorciatoia o la callback equivalente e lo si annota.
- Prima di ogni blocco si riparte da un workspace pulito e da un seed ricaricato.

---

## 5. Ordine di esecuzione (blocchi per la memoria di Docker)

| Fase | Server attivi | Target |
|---|---|---|
| 0 | nessuno | L0 baseline, preparazione, installazione driver (PG e MariaDB dall'app), scrittura harness e seed |
| 1 | — | T01 SQLite (target di riferimento: tutta la checklist, serve a stabilizzare la suite) |
| 2 | pg, pg-debug, mysql, mariadb, minio, azurite, redis | T02, T04, T05, T07, S01, S02 + Git + vault |
| 3 | mssql | T03 (ODBC 18, poi 17 e FreeTDS) |
| 4 | mongo, cassandra | T06, T08 |
| 5 | — | T12 DuckDB, solo se il driver è disponibile via Homebrew |
| 6 | a coppie (pg+mysql, pg+mssql, mysql+mssql, SQLite+tutti) | Funzionalità **tra DBMS**: confronto schemi/migrazione, confronto dati, export SQL → import in altro DBMS |
| 7 | — | Funzionalità indipendenti dal DBMS ancora aperte, regressione finale, report |
| — | (rimandati) | T09 Oracle, T10 Firebird, T11 Db2, T13 ClickHouse, T14–T16 cloud, S03–S04: non eseguiti per le decisioni prese |

---

## 6. Catalogo dei casi di test

Ogni caso ha un ID; nel report l'esito è per coppia *(caso, target)*: ✅ ok, ❌ difetto, ⚠️ funziona con limiti, ➖ non applicabile (con motivo), ⏸ non eseguito (con motivo).

### CON — Connessioni e driver
| ID | Caso | Esito atteso |
|---|---|---|
| CON-01 | Nuova connessione in modalità **Driver ODBC** con il template del DBMS (host, porta, database) | Stringa generata corretta, connessione riuscita, dialetto e versione riconosciuti |
| CON-02 | Modalità **DSN** | Il DSN compare nell'elenco, connessione riuscita |
| CON-03 | Modalità **stringa di connessione** libera | Connessione riuscita |
| CON-04 | Test connessione: ok / password errata / host irraggiungibile / porta chiusa / driver mancante / database inesistente | Messaggi chiari, nessun blocco della UI, timeout ragionevole |
| CON-05 | Parametri extra del driver (es. `TrustServerCertificate`, `sslmode`) | Passati nella stringa |
| CON-06 | Password salvata nel vault vs richiesta al login; annulla sulla richiesta | Comportamento coerente, nessuna password in `connections.json` |
| CON-07 | Tipo **Produzione**: badge, conferma prima di modificare dati, **doppia conferma** per il DDL | Conferme presenti, annullando non succede nulla |
| CON-08 | **Sola lettura**: azioni di modifica e design disabilitate; UPDATE scritto a mano | Bloccato o rifiutato dal server, messaggio chiaro |
| CON-09 | **Commit manuale**: contatore istruzioni pendenti, Commit, Rollback, disconnessione con transazione aperta | Conteggio esatto, verificato lato server (L3) |
| CON-10 | Catalogo di default e **bootstrap query** | Applicati a ogni connessione e riconnessione |
| CON-11 | Cartelle di connessioni: crea, sposta, rinomina, elimina | Persistenti dopo riavvio |
| CON-12 | Riconnetti, Disconnetti tutto, Informazioni connessione | Corretti |
| CON-13 | **Driver Manager**: elenco driver e DSN; **installazione** PostgreSQL e MariaDB via Homebrew con log in tempo reale | Driver registrati in `odbcinst.ini` e usabili subito |
| CON-14 | Connessioni simultanee a più DBMS, cambio della connessione attiva | Sessioni indipendenti, nessuna interferenza |
| CON-15 | **Caduta del server** durante una query e da inattivi (`docker stop`/`pause`), poi ripartenza | Errore chiaro, riconnessione possibile, app non bloccata |
| CON-16 | Driver nativi: campi specifici (Mongo URI e `mongodb+srv`, meccanismi SCRAM; Redis ACL, database, RESP2/3, TLS; Cassandra consistency, paging) | Connessione riuscita con ogni variante provabile in locale |
| CON-17 | Metodi di autenticazione enterprise (Kerberos, Entra ID ×6, SSO, Okta, AWS IAM, OAuth, coppia di chiavi) | Stringa/parametri generati corretti per ogni template; prova reale solo con account |

### NAV — Database Navigator
| ID | Caso | Esito atteso |
|---|---|---|
| NAV-01 | Albero completo: catalogo → schema → Tabelle/Viste/Altri/Procedure/Sequenze → Colonne/Chiavi/CHECK/FK/Riferimenti/Indici/Trigger | Tutti gli oggetti del seed presenti, nessuno doppio |
| NAV-02 | Cartelle **Sicurezza** e degli oggetti specifici del DBMS | Presenti solo dove previsto |
| NAV-03 | Filtro | Corretto, anche su nomi Unicode e con spazi |
| NAV-04 | F5 e aggiornamento automatico dopo ogni modifica di design; **i nodi aperti restano aperti** | Sì |
| NAV-05 | Menu contestuale di **ogni tipo di nodo**: voci abilitate/disabilitate secondo la capability, con il motivo | Coerente con `capabilities.dart` |
| NAV-06 | ⌥⌘N crea l'oggetto giusto nel contesto selezionato | Sì |
| NAV-07 | Schema da 1.000 tabelle | Apertura fluida, nessun blocco della UI |

### SQL — Editor SQL
| ID | Caso | Esito atteso |
|---|---|---|
| SQL-01 | Evidenziazione della sintassi del dialetto, numeri di riga | Corretti (incluso CQL, shell Mongo, comandi Redis) |
| SQL-02 | Autocompletamento: keyword, funzioni, tabelle, colonne, colonne via **alias**, nomi con quoting, schema grande | Suggerimenti pertinenti e veloci |
| SQL-03 | Trova/sostituisci, commenta, formatta, maiuscolo/minuscolo | Corretti, formattazione che non rompe lo SQL |
| SQL-04 | Esegui istruzione sotto il cursore / selezione / in nuova scheda | Corretto |
| SQL-05 | Esegui **script** (⌥X/F5) con statistiche; errore a metà: continua/ferma | Comportamento come scelto, statistiche esatte |
| SQL-06 | Delimitatori: riga vuota, blocchi procedurali (`$$`, `BEGIN…END`, `GO`, `DELIMITER`, `/` Oracle) | Istruzioni divise correttamente |
| SQL-07 | **Parametri** `:nome` e `?` con dialogo | Valori e tipi passati correttamente |
| SQL-08 | **Annullamento** di una query lunga (`pg_sleep`, `WAITFOR DELAY`, `SLEEP()`, `DBMS_SESSION.SLEEP`) | Interrotta lato server (verifica L3), UI subito libera |
| SQL-09 | **Output del server** (PRINT / NOTICE / DBMS_OUTPUT) | Mostrato nel pannello |
| SQL-10 | **Più result set** dalla stessa istruzione/procedura | Tutti visibili |
| SQL-11 | **Piano di esecuzione** testuale e **piano visuale** (⌘⌥E): costi, stime vs reali, avvisi | Presenti per ogni DBMS che li supporta, messaggio chiaro altrove |
| SQL-12 | Errori: sintassi con riga/colonna, oggetto inesistente, violazione vincolo | Messaggio del server leggibile, cursore sulla riga |
| SQL-13 | Log di esecuzione e **Query Manager** (ricerca, filtro errori, riapri nell'editor) | Tutte le istruzioni registrate, nessuna password |
| SQL-14 | Script: salvataggio automatico, pannello *Script*, rinomina, elimina, apri file, salva come | Persistenti dopo riavvio |
| SQL-15 | **Crea vista dalla query** | Apre il designer della vista con la definizione |
| SQL-16 | NoSQL: shell Mongo (`find`, `aggregate`, `insertOne`, `updateMany`, `deleteOne`, `countDocuments`…), comandi Redis, CQL, **sottoinsieme SQL** (`SELECT * FROM … WHERE … ORDER BY … LIMIT`) | Risultati in griglia, errori chiari per la sintassi non supportata |
| SQL-17 | Generazione SQL dal navigator: SELECT, INSERT, UPDATE, DELETE, DDL, CALL, TRUNCATE, DROP, conteggio righe | SQL valido ed eseguibile per il dialetto |

### GRD — Griglia risultati e modifica dati
| ID | Caso | Esito atteso |
|---|---|---|
| GRD-01 | Paginazione (fetch size) e caricamento allo scroll sulla tabella da 200k righe | Fluido, nessuna riga persa o duplicata |
| GRD-02 | Ordinamento, ricerca, vista **record**, selezione multipla | Corretti |
| GRD-03 | Copia: semplice, con intestazioni, CSV, JSON, Markdown, SQL; incolla | Formati corretti, Unicode e NULL preservati |
| GRD-04 | **Rendering di ogni tipo** della tabella dei tipi (precisione DECIMAL, date e fusi, binari, JSON, Unicode, testo NULL configurato) | Nessuna perdita di precisione né eccezione |
| GRD-05 | Modifica in linea, editor valori (testo/JSON/hex, carica/salva file), imposta NULL | Salvataggio verificato lato server |
| GRD-06 | Aggiungi, duplica, elimina righe; **anteprima SQL**; salvataggio transazionale | UPDATE/INSERT/DELETE parametrici sulla PK |
| GRD-07 | Tabella senza PK (chiave virtuale), PK composta, nomi difficili | Modifiche corrette o rifiuto motivato |
| GRD-08 | Errore al salvataggio (violazione vincolo) | Rollback dell'intero salvataggio, messaggio chiaro, modifiche ancora in sospeso |
| GRD-09 | Vista **Grafico**: barre, linee, aree, torta, dispersione, aggregazioni, esportazione PNG | Grafici corretti, PNG valido |
| GRD-10 | Valori enormi (testo 1 MB, BLOB 5 MB) | Nessun blocco, editor valori utilizzabile |

### OBJ — Editor oggetti
| ID | Caso | Esito atteso |
|---|---|---|
| OBJ-01 | Tabella: Proprietà, Dati (filtro WHERE / ORDER BY, "filtra per valore"), Colonne, Vincoli e chiavi, Indici, DDL, Diagramma ER, Permessi | Ogni pagina coerente col catalogo (L3) |
| OBJ-02 | Vista: pagina **Definizione** e verifica della query | Corretta |
| OBJ-03 | Procedure, funzioni, trigger, package: sorgente letto dal catalogo | Sorgente completo e fedele |
| OBJ-04 | DDL ricostruito eseguito su un DB vuoto | Ricrea l'oggetto identico |

### DES — Design dello schema (secondo la capability di ciascun DBMS)
| ID | Caso | Esito atteso |
|---|---|---|
| DES-01 | Nuovo database, rinomina, elimina | Dove supportato; altrove voce disabilitata col motivo |
| DES-02 | Nuovo schema, elimina | Idem |
| DES-03 | Nuova tabella dal designer con ogni tipo, default, identity/autoincrement, commenti | Riletta uguale (nessuna differenza nella pagina *Modifiche*) |
| DES-04 | Modifica tabella: aggiungi/rinomina/elimina colonna, cambia tipo e nullabilità, **annulla/ripeti**, pagina *Modifiche* dal vivo, ⌘S | Script corretto, eseguito; su SQLite **ricostruzione** della tabella con dati preservati |
| DES-05 | Duplica struttura | Copia identica |
| DES-06 | Vincoli: PK, UNIQUE, CHECK, FK (regole ON DELETE/UPDATE, MATCH, DEFERRABLE), disabilita/abilita, aggiungi senza validare, rinomina | Secondo capability |
| DES-07 | **Verifica preventiva dei dati** (orfani, duplicati, NULL) con "Apri le righe" | Righe trovate esatte |
| DES-08 | Indici: DESC, INCLUDE, filtro, metodo, rinomina, ricostruisci, disattiva, online | Secondo capability |
| DES-09 | Viste e viste materializzate (crea, modifica, refresh, elimina) | Corrette |
| DES-10 | Sequenze, trigger, procedure, funzioni: crea, modifica, elimina | Corrette, errori di compilazione mostrati |
| DES-11 | Rinomina, Elimina (DROP), Svuota (TRUNCATE) dal navigator | Corretti, con conferma |
| DES-12 | **Anteprima dello script**: copia, apri nell'editor; errore a metà script → rollback dove il DDL è transazionale, stato parziale riportato altrove | Corretto |
| DES-13 | Guardie: Produzione (doppia conferma), sola lettura (disabilitato), vista semplificata (nascosto), commit manuale (CREATE/DROP DATABASE in sessione separata) | Corretto |
| DES-14 | **Oggetti specifici**: PG estensioni, enum, domini, policy RLS, vincoli di esclusione; SQL Server/Oracle sinonimi; Oracle package (specifica, corpo, errori); MySQL/MariaDB eventi; Firebird domini; Snowflake warehouse, stage, formati | Crea, rileggi, modifica, elimina |
| DES-15 | **ERD in modifica**: nuova tabella, colonne, relazione trascinando, eliminazioni, script DDL rivisto ed eseguito; disposizione automatica, zoom, esportazione PNG | Corretto |
| DES-16 | NoSQL: Mongo (database, collezioni capped e time series, validatori, indici TTL/parziali/nascosti, viste con pipeline); Cassandra (keyspace, tabelle partizione/clustering, indici SAI, tipi, viste materializzate); BigQuery (dataset, tabelle partizionate e in cluster) | Crea, rileggi, modifica, elimina |

### SEC — Utenti, ruoli e permessi
| ID | Caso | Esito atteso |
|---|---|---|
| SEC-01 | Scheda *Utenti e ruoli*: utenti, ruoli, login con attributi e appartenenze | Coerente col catalogo |
| SEC-02 | Crea utente con password, ruolo, appartenenza, permessi sugli oggetti (matrice), privilegi di sistema | Verificato lato server: il nuovo utente si connette e ha esattamente quei permessi |
| SEC-03 | **La password non compare** in cronologia, script copiato, script aperto nell'editor, log | Mai |
| SEC-04 | Revoca, rimozione dal ruolo, eliminazione | Corrette |
| SEC-05 | Pagina *Permessi* di una tabella | Coerente |
| SEC-06 | Redis ACL, ruoli Mongo, ruoli Cassandra, IAM BigQuery | Corretti |

### XFR — Trasferimento dati
| ID | Caso | Esito atteso |
|---|---|---|
| XFR-01 | Export in CSV, TSV, JSON, XML, HTML, Markdown, SQL INSERT, testo; su file e appunti | File validi (parsati da `python -I`), Unicode, NULL e binari corretti |
| XFR-02 | Export in streaming della tabella da 200k righe | Numero righe esatto, memoria stabile |
| XFR-03 | **Import CSV** con mappatura colonne, intestazioni, separatori, tipi, righe errate | Righe importate verificate lato server, errori riportati |
| XFR-04 | Export SQL INSERT da un DBMS e esecuzione su un altro | Dati identici |

### PRO — Funzionalità avanzate
| ID | Caso | Esito atteso |
|---|---|---|
| QB-01 | **Query builder**: trascina tabelle, join automatici dalle FK e trascinando colonna→colonna, alias, aggregati, ordinamento, filtri, HAVING, DISTINCT, limite | SQL generato valido per il dialetto, risultati uguali a quelli di una query scritta a mano |
| CMP-01 | **Confronto schemi** stesso DBMS (due schemi/database) | Differenze esatte |
| CMP-02 | **Migrazione tra DBMS** (SQLite→PG, PG→MySQL, MySQL→SQL Server, SQL Server→PG, MariaDB→SQLite) | Script eseguito, nuovo confronto senza differenze (salvo mappature di tipo dichiarate) |
| DCM-01 | **Confronto dati** (merge/hash join) con script di sincronizzazione, anche tra DBMS | Dopo la sincronizzazione nessuna differenza |
| MOCK-01 | **Dati di test**: ogni generatore (nomi, email, codice fiscale, IBAN, P.IVA, FK reali, sequenze, modelli…), 10k righe | Righe valide, vincoli rispettati |
| DBG-01 | **Debugger PL/pgSQL**: breakpoint, step into/over, stack, variabili modificabili, parametri, rollback finale; messaggio su server senza `pldbgapi` | Corretto |
| PERF-01 | **Dashboard** (PG, SQL Server, MySQL, MariaDB, Oracle): KPI con sparkline, sessioni attive, **termina/annulla** sessione, albero dei blocchi (scenario di lock creato apposta), query più costose, tabelle più grandi, indici inutilizzati | Dati coerenti con L3; altri DBMS: messaggio chiaro |
| AI-01 | Spiega query e oggetti, **Correggi con AI** su un errore, genera SQL/CQL/Mongo/Redis, chat per connessione; consenso prima dell'invio, contesto dello schema opzionale, chiave nel vault | Funziona; nessun dato inviato senza consenso |
| SIMPLE-01 | **Vista semplificata**: filtri a chip, solo tabelle e viste, strumenti sviluppatore nascosti | Corretto |

### CLD — Pannello Storage (S01–S04)
| ID | Caso | Esito atteso |
|---|---|---|
| CLD-01 | Aggiungi account con ogni tipo di credenziale provabile (S3: chiavi + endpoint, profilo `~/.aws`, assume role se possibile; Azure: shared key, SAS, connection string, Azure CLI; GCS: service account, ADC) | Account valido, bucket/container elencati |
| CLD-02 | Crea/naviga cartelle, prefissi annidati, nomi Unicode e con spazi | Corretto |
| CLD-03 | Carica e scarica (file piccoli, 1 GB **multipart**, molti file) con avanzamento e annullamento | Hash identico (L3) |
| CLD-04 | Rinomina, elimina (anche cartelle intere) | Corretto |
| CLD-05 | **Link di condivisione** (presigned / SAS / signed URL) con scadenza | Scaricabile con `curl`, scaduto dopo la scadenza |
| CLD-06 | Apri un `.sql` nell'editor SQL; **import CSV** dallo storage in una tabella | Corretto |
| CLD-07 | Errori: credenziali errate, bucket inesistente, permessi negati | Messaggi chiari |

### APP — Funzionalità trasversali
| ID | Caso | Esito atteso |
|---|---|---|
| VLT-01 | **Vault**: master password, schermata di sblocco all'avvio, password errata, blocco ⌘⇧L, blocco per inattività, cambio/rimozione master password | Corretto, `connections.json` senza segreti |
| GIT-01 | **Git**: inizializza, collega remoto (bare locale), stato, diff, commit, pull/push/sincronizza, cronologia, conflitto | Corretto |
| GIT-02 | Vault e file personali esclusi; **controllo anti-segreti** blocca un commit con una password | Corretto |
| PRF-01 | Preferenze: tema chiaro/scuro/sistema, font, fetch size, testo NULL, autocompletamento, delimitatore, libreria ODBC personalizzata, AI | Applicate subito e dopo riavvio |
| UI-01 | Schede: successiva/precedente, chiudi, chiudi tutte, chiusura con modifiche non salvate | Avviso prima di perdere modifiche |
| UI-02 | Ogni scorciatoia elencata in *Aiuto › Scorciatoie* funziona | Sì |
| UI-03 | Persistenza dopo riavvio: connessioni, cartelle, preferenze, cronologia, script, account cloud | Sì |
| UI-04 | Tema scuro su tutte le schermate principali (screenshot) | Nessun contrasto illeggibile |
| UI-05 | Barra laterale: sezioni Navigator, Script, Storage, Git; nascondi/mostra | Corretto |

### ROB — Robustezza
| ID | Caso | Esito atteso |
|---|---|---|
| ROB-01 | Due schede che eseguono query lunghe in parallelo sulla stessa connessione; export durante una query | Nessun blocco né risultato mescolato |
| ROB-02 | Fetch di 1 milione di righe e annullamento | Memoria contenuta, UI reattiva |
| ROB-03 | Identificatori difficili in **tutte** le funzioni (designer, modifica dati, export, confronti, query builder) | Quoting corretto ovunque |
| ROB-04 | Rete interrotta durante upload cloud / export / salvataggio dati | Errore chiaro, nessuno stato incoerente |

---

## 7. Matrice target × aree

Legenda: ● completo · ◐ parziale (secondo capability) · ○ solo messaggio "non supportato" da verificare · — non applicabile

| Area | SQLite | PG | SQL Server | MySQL | MariaDB | Oracle | Firebird | Db2 | DuckDB/ClickHouse | Mongo | Redis | Cassandra | BigQuery | Snowflake |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CON | ● | ● | ● (+FreeTDS) | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| NAV | ● | ● | ● | ● | ● | ● | ● | ● | ◐ | ● | ● | ● | ● | ● |
| SQL | ● | ● | ● | ● | ● | ● | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ● |
| GRD (modifica) | ● | ● | ● | ● | ● | ● | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ● |
| OBJ | ● | ● | ● | ● | ● | ● | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ● |
| DES | ◐ | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ○ | ◐ | ○ | ◐ | ◐ | ◐ |
| SEC | ○ | ● | ● | ● | ● | ● | ● | ◐ | ○ | ● | ◐ | ● | ◐ | ● |
| XFR | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| QB / CMP / DCM / MOCK | ● | ● | ● | ● | ● | ● | ● | ● | ◐ | ○ | ○ | ○ | ◐ | ● |
| DBG | ○ | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| PERF | ○ | ● | ● | ● | ● | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| AI | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |

La verifica ○ conta: l'app deve mostrare un motivo comprensibile, non un errore del driver.

---

## 8. Gestione dei difetti

- Ogni difetto va registrato con: ID, gravità (**bloccante / alta / media / bassa / estetica**), target, caso di test, passi minimi per riprodurlo, atteso vs ottenuto, screenshot, log o query L3.
- Un difetto trovato su un target viene **ricontrollato sugli altri** per capire se è comune.
- I casi automatizzati della suite L2 restano nel repository come regressione.

## 9. Criteri di chiusura

- Tutti i casi del Livello A eseguiti su tutti i target A; Livello B e C eseguiti dove l'ambiente lo consente, con i ⏸ motivati.
- Nessun difetto bloccante o alto aperto senza una decisione esplicita.
- Report finale: matrice esiti caso × target, elenco difetti, cosa non è stato provato e perché, confronto con le "Limitazioni note" del README (da aggiornare).

## 10. Fuori perimetro e rischi

- **Windows e Linux** non vengono provati (solo macOS).
- Funzioni non supportate per scelta (README): tunnel SSH, Redis Cluster, GSSAPI per Mongo, copie S3 > 5 GB — verificato solo che il messaggio sia chiaro.
- Rischi: Db2 e SQL Server in emulazione possono essere lenti o instabili; il driver Firebird ODBC per arm64 potrebbe non esistere; i test cloud reali hanno costi (minimi) e richiedono credenziali; la chiave AI ha un costo per chiamata.
