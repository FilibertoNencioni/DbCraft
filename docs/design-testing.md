# Test degli strumenti di design

Gli strumenti di design e amministrazione (creazione e modifica di database, tabelle, vincoli, viste, utenti…) si verificano su tre livelli.

| Livello | Dove | Cosa verifica | Quando |
|---|---|---|---|
| Golden SQL | `test/design/*_test.dart` | Le istruzioni esatte generate per **ogni** DBMS supportato | Sempre (`flutter test`) |
| Widget | `test/design/*_test.dart` | Finestre, editor, esecuzione degli script (con sessioni finte) | Sempre (`flutter test`) |
| Round-trip | `integration_test/design_db_test.dart` | Su server reali: crea → rileggi dal catalogo → **diff vuoto** → modifica → elimina | A mano, prima di chiudere una fase |

## Test unitari e golden

`test/design/helpers.dart` mette a disposizione:

- **`sqlDialects`**: un dialetto per ogni DBMS SQL supportato (PostgreSQL, SQL Server, MySQL, MariaDB, Oracle, Db2, SQLite, Firebird, Snowflake), con una versione recente del server. `dialectAt(key, version)` restituisce lo stesso dialetto con un'altra versione, per provare le soglie di versione.
- **`expectPerFamily(build, {chiave: atteso})`**: confronta l'output con l'atteso per ogni dialetto e **fallisce se ne manca uno**. Così, quando si aggiunge un DBMS, bisogna scriverne le aspettative.
- **`ScriptedSession`**: una sessione finta che risponde alle istruzioni tramite espressioni regolari (`on(pattern, Rows(...))`, oppure un'eccezione). Registra ogni chiamata in `log`: istruzioni, auto-commit, commit e rollback.
- **`scriptedConnection(session)`**: una `DbConnection` connessa sulla sessione finta, che scrive la cronologia in una lista.

```sh
flutter test test/design
```

## Round-trip su server reali

### 1. Server

I server sono in `tool/design_db/compose.yml`, con versioni fissate. Le porte sono spostate rispetto a quelle standard per non scontrarsi con eventuali server locali.

| Target | Immagine | Porta | Utente / password | Database |
|---|---|---|---|---|
| `pg` | postgres:17.2 | 55432 | dbcraft / DbCraft_Test1 | dbcraft |
| `mssql` | mssql/server:2022 CU16 | 51433 | sa / DbCraft_Test1 | dbcraft |
| `mysql` | mysql:8.4.3 | 53306 | dbcraft / DbCraft_Test1 | dbcraft |
| `mariadb` | mariadb:11.4.4 | 53307 | dbcraft / DbCraft_Test1 | dbcraft |
| `oracle` | gvenzl/oracle-free:23.5-slim | 51521 | dbcraft / DbCraft_Test1 | FREEPDB1 |
| `firebird` | firebirdsql/firebird:5.0.1 | 53050 | dbcraft / DbCraft_Test1 | dbcraft.fdb |
| `db2` (profilo `db2`) | db2_community/db2:11.5.9.0 | 55000 | db2inst1 / DbCraft_Test1 | dbcraft |

```sh
tool/design_db/up.sh                 # avvia e attende che siano pronti
tool/design_db/up.sh --profile db2   # anche Db2 (solo x86, ~3 GB, avvio lento)
tool/design_db/down.sh               # ferma e cancella i dati
```

Un solo server: `docker compose -f tool/design_db/compose.yml up -d --wait pg`.

Su Apple Silicon, SQL Server e Db2 girano in emulazione (Rosetta di Docker Desktop).

### 2. Driver ODBC

| Target | Driver | Installazione |
|---|---|---|
| sqlite, pg, mssql, mysql, mariadb | `SQLite3`, `PostgreSQL Unicode`, `ODBC Driver 18 for SQL Server`, `MariaDB ODBC Driver` | DbCraft: Database ▸ Driver ODBC installati… ▸ Installa |
| oracle | `Oracle 23 ODBC driver` | Oracle Instant Client Basic + ODBC; registrare la libreria `libsqora` in `odbcinst.ini` |
| firebird | `Firebird/InterBase(r) driver` | Firebird ODBC driver; registrare la libreria in `odbcinst.ini` |
| db2 | `IBM DB2 ODBC DRIVER` | IBM Data Server Driver (clidriver); registrare `libdb2.dylib` in `odbcinst.ini` |

MySQL 8.4 usa `caching_sha2_password`: serve MariaDB Connector/ODBC 3.1.11 o successivo. In alternativa si può usare il driver MySQL Connector/ODBC, passando la stringa con `DESIGN_MYSQL`.

### 3. Esecuzione

```sh
flutter test integration_test/design_db_test.dart -d macos \
  --dart-define=DESIGN_TARGETS=sqlite,pg,mssql,mysql,mariadb,oracle,firebird
```

- **Target di default.** Senza `DESIGN_TARGETS` gira solo `sqlite`, su un file temporaneo e senza bisogno di server. Il driver SQLite ODBC si cerca in `/opt/homebrew/lib/libsqlite3odbc.dylib`; un percorso diverso si passa con `--dart-define=SQLITE_ODBC=…`.
- **Connessioni.** Le stringhe di connessione predefinite corrispondono al compose. Per cambiarne una si usa `--dart-define=DESIGN_<TARGET>='Driver=…;…'` (per esempio `DESIGN_ORACLE`).
- **Snowflake.** Gira solo con `DESIGN_SNOWFLAKE`, una stringa di connessione a un account di prova.
- **Oggetti temporanei.** Ogni test crea oggetti con il prefisso `dbc_` e li elimina alla fine, anche quando fallisce.
- **Oggetti specifici.** Il round-trip "DBMS specific objects" prova sinonimi (SQL Server, Oracle), domini (PostgreSQL, Firebird), tipi enumerati (PostgreSQL) ed eventi (MySQL, MariaDB): li crea, li rilegge, li modifica e verifica che la rilettura non produca altre modifiche. Estensioni, policy, vincoli di esclusione, package e oggetti Snowflake sono coperti dai test unitari.
- **Sicurezza.** Il round-trip di utenti e ruoli crea un ruolo, un utente (su SQL Server anche il login) con un permesso e l'appartenenza al ruolo, li rilegge, cambia permessi e ruoli e li elimina. Serve un utente amministratore: con privilegi minori il test fallisce alla creazione. Le password passano per `runScript`, come nel foglio dello script: mai nella cronologia.

### Come si scrive un round-trip

1. Definisci l'oggetto atteso con il modello (`TableDef`, …).
2. Crealo con il builder del dialetto (`DdlBuilder(dc.dialect)`) ed eseguilo con `run(dc, statements)`.
3. Rileggilo dal catalogo (`readBack`) e verifica che `differences(dc, atteso, letto)` sia vuoto.
4. Per ogni modifica supportata dalla capability: applica il diff, rileggi e verifica di nuovo che il diff sia vuoto.
5. Elimina l'oggetto in un `finally`.

## Checklist manuale per fase

Nell'app (`flutter run -d macos`), contro i container:

- crea, modifica, rinomina ed elimina gli oggetti della fase su ogni DBMS disponibile;
- connessione di **produzione**: viene chiesta la doppia conferma;
- connessione in **sola lettura**: le azioni sono disabilitate;
- **commit manuale**: il contatore delle istruzioni in sospeso è corretto, e CREATE/DROP DATABASE vanno in una sessione separata;
- **vista semplificata**: gli strumenti di design sono nascosti;
- **utenti e ruoli**: dopo aver creato un utente con password, la password non compare né nella cronologia delle query né nello script copiato o aperto nell'editor;
- dopo ogni modifica il navigator si aggiorna da solo e i nodi aperti restano aperti.
