# Piano: tutti i database di PostgreSQL in una connessione

Branch `feat/pg-all-databases`. In PostgreSQL una sessione è legata a un
database e psqlODBC non espone i cataloghi: oggi il navigatore mostra solo il
database della connessione. L'interfaccia è già pronta per più database
(`CatalogNode`, selettore del database nell'editor SQL, `tab.catalog`,
`useCatalog()`, metadati con il catalogo come parametro): manca il motore.

**Idea:** per PostgreSQL `DbConnection` tiene una coppia di sessioni (query e
metadati) per database, aperte su richiesta; "cambiare database" vuol dire
usare le sessioni di quel database invece di `setCurrentCatalog`.

Decisioni dell'utente (2026-10-28):
- "Mostra tutti i database" sempre attivo di default, anche sulle connessioni
  esistenti.
- In commit manuale Commit/Rollback agiscono su tutti i database.
- Verifica reale sul container `postgres-18` (utente `sa`).

## Fase 1: sessioni per database (`lib/state/db_connection.dart`)
- Sessioni per database aperte su richiesta, con la stringa della connessione
  e il database sostituito (driver, DSN con `DATABASE=`, stringa).
- `useCatalog(db)` passa alle sessioni di quel database; le nuove sessioni
  ricevono auto-commit, sola lettura e query di inizializzazione.
- Commit/Rollback su tutti i database con modifiche in sospeso; contatore
  totale.
- `disconnect()` chiude tutto; `openSession(catalog:)`.

## Fase 2: metadati
- `supportsCatalogs` vero e `catalogs()` da `pg_database` (`datallowconn`);
  `template1` nella cartella "Sistema".
- `MetadataService` e `DesignCatalog` instradano le letture sulla sessione
  metadati del database richiesto; le query di server (ruoli, database) restano
  sulla sessione iniziale.

## Fase 3: chi usa direttamente le sessioni
- `dc.main!` / `dc.meta!` (conteggio righe, view editor, code editor, vincoli,
  dati tabella, query builder, DDL) usano la sessione del database
  dell'oggetto.
- `openSession()` (export, import, confronti, debugger, prestazioni) riceve il
  database.

## Fase 4: interfaccia
- Navigatore con i database (il predefinito segnato), editor SQL con il
  selettore del database.
- Eliminazione di un database: chiudere prima le sue sessioni; elenco
  aggiornato dopo creazione ed eliminazione.
- Finestra di connessione PostgreSQL: interruttore "Mostra tutti i database",
  "Database" diventa "Database iniziale".

## Fase 5: test e documentazione
- Test unitari con sessioni finte (`sessionOpener`); prova reale con più
  database; README e DESIGN.md.

## Limiti
- Due sessioni ODBC per database aperto, chiuse alla disconnessione.
- Niente query tra database diversi (limite di PostgreSQL).
- Solo PostgreSQL vero e proprio, non Redshift/CockroachDB.

## Stato (2026-10-28)
Fasi 1–5 completate, non committate. Router: `lib/drivers/database_router_session.dart`;
`DbConnection.mainFor` / `metaFor` / `closeDatabase`, `openSession(catalog:)`;
gli script DDL senza catalogo usano quello dello scope; "Estensioni" sotto ogni
database. Test: `test/pg_databases_test.dart` (unitari),
`integration_test/pg_databases_test.dart` (container di `tool/design_db`).
Matrice pg: core e objects verdi; i difetti di design (DES-03b, DES-10, DES-11,
DES-12, DES-12b) sono identici su `main`, quindi preesistenti.

Limite noto: la scheda "Utenti e ruoli" a livello di connessione legge i
permessi sugli oggetti del solo database iniziale (la pagina Permessi della
tabella usa il suo database).
