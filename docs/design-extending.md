# Estendere gli strumenti di design

Gli strumenti di design e amministrazione (`lib/features/design/`) sono costruiti a strati. Ogni strato ha un solo compito, e aggiungere un DBMS o un tipo di oggetto significa toccarli tutti, sempre nello stesso ordine.

| Strato | Dove | Compito |
|---|---|---|
| Capability | `capabilities.dart` | Cosa sa fare ogni DBMS, in base a famiglia e versione, e perché manca una funzione |
| Modello | `model/` | Definizioni degli oggetti (`*Def`), senza I/O |
| Generatori | `ddl/`, `lib/features/schema/ddl_builder.dart` | Istruzioni dalle definizioni: funzioni pure, senza terminatori |
| Cataloghi | `catalog/` | Lettura delle definizioni dai cataloghi di sistema |
| Sessioni di modifica | `table_design.dart`, `view_design.dart`, `security_design.dart` | Originale e versione modificata; le istruzioni nascono dal diff |
| UI | `ui/` | Fogli, pagine dell'editor, menu del navigator |

## Regole comuni

- **Generatori puri.** Restituiscono `List<String>` senza `;`. Quello che il DBMS non sa fare è un commento `-- … (non supportato)`, che `executableStatements` scarta: l'utente lo vede nell'anteprima.
- **Capability prima della UI.** Menu e campi si abilitano con `DesignCapabilities.of(dialect).has(…)`. Il tooltip spiega il motivo con `reason(…)`. Nel codice UI vanno evitati i test sulla famiglia: le eccezioni, come le etichette dei campi, devono restare locali.
- **Un solo punto di esecuzione.** Ogni script passa da `showDdlScriptDialog`, che gestisce:
  - anteprima, copia, sola lettura e doppia conferma in *Produzione*;
  - le transazioni;
  - `DdlScript.scope`, che dice al navigator e agli editor cosa ricaricare.

  Le password non entrano mai nelle istruzioni: si usano i token di `SecretBag` (vedi `PrincipalDesign.script`).
- **Cache dei cataloghi.** I lettori passano da `DesignCatalog` con chiavi `design:…`, così `schemaChanged` le svuota insieme ai metadati ODBC.

## Aggiungere un DBMS

1. **Riconoscimento.** In `lib/services/sql_dialect.dart` aggiungi il valore di `DbFamily` e la regola in `_detect`.
   - Se il nome ODBC è ambiguo, usa l'id del template del driver.
   - Per un driver nativo vale l'id di `NativeDriver`.
2. **Capability.** In `capabilities.dart` aggiungi un ramo in `_missing` (per i driver nativi l'elenco `_nosql`) e il nome in `_label`.
   - Le soglie di versione si scrivono con `needs(feature, atLeast(x, y), 'x.y')`.
   - Per un DBMS SQL che non deve usare il designer SQL, aggiorna `sqlDesign`.
3. **Generatori.** Aggiungi i casi della famiglia negli switch di:
   - `DdlBuilder`: tipi, identity, collation, vincoli, indici, commenti;
   - `ObjectDdl`: database, schemi, viste, sequenze;
   - `CodeDdl`: trigger e routine;
   - `SecurityDdl.forFamily`, con una sottoclasse in `ddl/security/`;
   - `ExtraDdl`, per gli oggetti specifici.

   Il default deve restare SQL standard oppure "non supportato", mai un'istruzione sbagliata.
4. **Cataloghi.** Crea un lettore delle tabelle in `catalog/<famiglia>.dart` e collegalo in `DesignCatalog.tableExtras`. Poi aggiungi i casi in:
   - `databases.dart`;
   - `views.dart`;
   - `code.dart`;
   - `security.dart`;
   - `extras.dart`.

   Le query alternative (privilegi ridotti, versioni vecchie) si passano a `CatalogQueries.first`, in ordine.
5. **Test golden.** Aggiungi il dialetto a `sqlDialects` in `test/design/helpers.dart`. Da quel momento ogni `expectPerFamily` fallisce con "Aspettative mancanti per: …" finché non scrivi l'SQL atteso. È voluto: nessun generatore resta senza verifica.
6. **Round-trip.**
   - Aggiungi il servizio a `tool/design_db/compose.yml`, con versione fissata.
   - Aggiungi il target a `integration_test/design_db_test.dart`: `DesignTarget` per ODBC, `NativeTarget` per i driver integrati.
   - Documenta tutto in `docs/design-testing.md`.

## Aggiungere un tipo di oggetto

**Oggetto comune a più DBMS** (sequenze, trigger…):

1. Il modello in `model/object_defs.dart`, oppure in un file nuovo.
2. Un `DesignFeature`, con la sua riga nella matrice.
3. I generatori in `ObjectDdl` o `CodeDdl`: create, alter (dal diff tra due definizioni), rename, drop.
4. Il lettore in `catalog/` e il metodo in `DesignCatalog`, con la chiave di cache.
5. Il nodo o la cartella in `lib/ui/navigator/nav_nodes.dart` e le voci in `navigator_panel.dart`. Le voci che creano devono iniziare con "Nuovo…/Nuova…": ⌥⌘N le trova da sole.
6. Il foglio in `ui/object_dialogs.dart`, con `ScriptPreview`, e le azioni in `ui/object_actions.dart`, con lo `SchemaScope` giusto.
7. I test: golden per famiglia, lettore con `ScriptedSession`, widget del foglio, round-trip.

**Oggetto di un solo DBMS** (estensioni, eventi, warehouse…): usa `ExtraKind`.

1. Aggiungi il valore a `ExtraKind` in `model/extra_defs.dart`, indicando etichetta e livello (connessione, schema o tabella).
2. Scrivi la classe che estende `ExtraObjectDef`.
3. Nei generatori, aggiungi i metodi in `ExtraDdl` e i casi di `create` / `alter` / `drop`.
4. Aggiungi il caso in `readExtras`.
5. Lato UI:
   - le voci in `extraFeature` e in `extraIcon`;
   - il foglio in `ui/extra_dialogs.dart`;
   - i casi di `createExtra` / `editExtra` in `ui/extra_objects.dart`.

   Cartelle, menu e aggiornamento del navigator arrivano da soli.

## Nuove versioni dei DBMS

- Aggiorna le soglie in `capabilities.dart` e aggiungi un caso golden con `dialectAt('chiave', 'versione')`.
- Una versione sconosciuta vale come "attuale": le funzioni nuove sono attive.
- Il compose fissa le versioni. Un aggiornamento passa quindi da una modifica esplicita e da un nuovo giro dei round-trip.

## Backlog

- `ALTER DEFAULT PRIVILEGES` (PostgreSQL), grant `FUTURE` (Snowflake), permessi per colonna.
- Partizionamento delle tabelle e tablespace come oggetti.
- Viste indicizzate (SQL Server) e MQT (Db2).
- ERD sullo stesso modello del designer (`TableDesign`) e dialog della tabella dell'ERD su `EditableGrid`.
- Vincoli di esclusione e policy RLS anche nella pagina *Vincoli* dell'editor della tabella (oggi solo nel navigator).
- Pagina *Trigger* nell'editor della tabella (oggi navigator più editor del sorgente).
- Confronto schemi esteso a viste, routine, sequenze e permessi, riusando i lettori dei cataloghi.
- Export delle modifiche come file di migrazione versionati nel progetto Git.
- Redis: rimuovere le singole password di un utente (oggi si aggiungono soltanto).
- BigQuery: verifica su un progetto reale, in particolare la lettura dei permessi per regione.
