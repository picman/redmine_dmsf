# Correzioni e verifiche DMSF / ONLYOFFICE

Data: 27 novembre 2026. Base delle modifiche: `c52a6e21`.
Le correzioni sono applicate al checkout del plugin. Il rapporto [precedente](report.md)
e la sua sonda descrivono il comportamento prima delle correzioni e restano evidenze storiche.

## Problemi corretti

| Rilievo | Intervento | Copertura |
| --- | --- | --- |
| D1 / D1b | Upload ordinari racchiusi in una transazione con acquisizione sincrona dei byte; rollback di documenti/revisioni e retention soltanto dopo commit | Upload mancanti e storage in errore; conservazione storico; successo con lettura dei byte; sonde retention |
| D2 | Lock della riga del file prima dell'inserimento di ogni revisione; upload browser e WebDAV leggono la testa sotto lo stesso lock | Due connessioni PostgreSQL reali e `lock_timeout`; suite WebDAV e revisioni |
| D3 | Snapshot tardivi preservano stato e motivo di errore/recupero delle sessioni chiuse | Test di persistenza e sonde late |
| D4 | Aggiornamenti delle operazioni asincrone soltanto se ancora pending, sotto lock; errori tardivi restituiscono il risultato già completato | Risposte remote errate, malformate o prive di URL; sonde concorrenti operation |
| D5 | Provenienza distinta dai metadati di destinazione: riferimento alla revisione PDF/template effettiva | PDF con testa più recente e template di altro contesto/progetto |
| N1 | Permesso sullo storico per conversione PDF e download diretto, ricontrollato nel polling, nel download firmato del convertitore e prima della pubblicazione | Revoca/superamento sorgente; token dell'editor già aperto ancora funzionante |
| N2 | Anche forgotten di sessioni fill o con una submission registrata possono essere salvati soltanto come documento indipendente | Ripristino negato, copia consentita, modello conservato |
| N3 | Registrazione della pulizia blob prima dell'upload; savepoint per errori intercettati dal chiamante | Errore dopo scrittura fisica dei byte, rollback e assenza di blob/oggetti orfani |

Ulteriori correzioni emerse durante il lavoro:

- Il download diretto esclude revisioni cancellate logicamente.
- Il browser rifiuta token allegato mancanti e versioni già presenti, conservando l'allegato temporaneo in caso di fallimento.
- Il PUT WebDAV applica la stessa atomicità fra revisione e byte, anche alla creazione di un documento.
- L'importazione forgotten non riporta sessioni saved/submitted allo stato recovery.
- Gli stub degli hook restituiscono un array, come il metodo reale: prima `nil` causava un errore nel layout delle pagine 403/404 e mascherava il risultato dei test.

Il lock del modello serializza gli inserimenti ordinari; il controllo esplicito dei numeri di
versione è sui percorsi browser modificati. Non è stato introdotto un vincolo univoco globale
sulle versioni e non è stata modificata la strategia WebDAV che riutilizza una revisione quando configurato.

## Ambiente e isolamento

Test eseguiti nel container `redmine-7-0-2-onlyoffice-qa-d45a6bbb-test-redmine-1`:

- Redmine 7, Ruby 4.0.9, Rails 8.1.4, PostgreSQL.
- Copia applicativa `/tmp/dmsf-review-tests`, con il checkout aggiornato in `plugins/redmine_dmsf`.
- Database dedicato `qa_dmsf_fixes_test`; storage `/tmp/dmsf-review-tests-storage`.
- Configurazione Bundler `/tmp/dmsf-review-bundle`, dipendenze del gruppo test installate.
- Migrazioni Redmine e plugin eseguite realmente sul database dedicato.
- Invio email disabilitato e delivery method test nella sola copia temporanea.

La configurazione dell'applicazione servita da `/usr/src/redmine`, il database `redmine`
e i documenti dell'istanza non sono stati modificati. Non è stato eseguito un deploy.
I segreti sono letti dai file montati nel container, senza copiarne i valori nel repository.

## Risultati

**Suite finale: 902 test, 12.389 asserzioni, zero fallimenti, errori e skip.**
Comprende unit, functional, integration, helper e tutte le regressioni aggiunte.
Comandi, output e avvisi sono conservati in [verification.txt](verification.txt).

RuboCop: 85 rilievi su 22 file Ruby interessati; nessuno sulle righe nuove/modificate
e nessuno nei due nuovi file di test. La base dei file già tracciati aveva 90 rilievi.
Il lint complessivo rimane non verde: non sono state aggiunte esclusioni o disabilitate regole.

- Prima suite unit/functional/integration: 881 test, 12.278 asserzioni, nessun fallimento/errore/skip.
- Giro mirato successivo: 55 test, 267 asserzioni, nessun fallimento/errore/skip.
- JavaScript: 17 test superati.
- Sonde review-3 `late_review.rb`: 36 PASS, 0 FAIL; `operation_review.rb`: 38 PASS, 0 FAIL.
- Sonda `retention_review.rb`: 24 PASS e 1 FAIL diagnostico atteso. La vecchia asserzione
  `RET-02 retention ran before the failure` pretendeva che il difetto si verificasse:
  atteso `true`, ottenuto `false`. Le verifiche di integrità dei dati passano.
- La vecchia sonda del lock assumeva che un inserimento potesse completare durante il lock:
  sostituita, per la verifica corretta, dal nuovo test PostgreSQL con connessioni indipendenti.

Il lancio indiscriminato di `rails test plugins/redmine_dmsf/test` carica anche
`field_format_test.rb`, un supporto di test che richiede l'helper Rails già caricato.
Per questo banco il comando riproducibile elenca le quattro directory effettive dei test.

Dopo le sonde review-3 un giro esteso ha prodotto tre falsi fallimenti: le loro righe
ONLYOFFICE restavano nel database, mentre le fixture reinizializzavano i documenti DMSF.
Verificata la presenza di 7 sessioni, 1 conflict e 9 operazioni sintetiche residue,
il database dedicato è stato reinizializzato e la suite ripetuta con lo stesso seed `5612`.
Non sono stati disabilitati test o indebolite asserzioni per risolvere questi fallimenti.

## Ripetizione nel banco locale

Gli script [setup_tests.sh](setup_tests.sh) e [run_tests.sh](run_tests.sh) sono specifici
per questo container e questa copia temporanea. Il setup **reinizializza lo schema del solo
`qa_dmsf_fixes_test`**, con controllo sul nome. Eseguirlo senza altre suite attive su quel DB.
Non usarlo come script di configurazione dell'istanza servita.

Prerequisiti: copia completa di Redmine in `/tmp/dmsf-review-tests` senza gli archivi runtime
`files`, `tmp`, `log` e `.bundle`, plugin aggiornato nella copia e gemme test disponibili
con `BUNDLE_APP_CONFIG=/tmp/dmsf-review-bundle`. Lo schema precompilato dell'immagine viene
accantonato nella copia: inizializzazione tramite migrazioni effettive evita il conflitto
fra tabelle del plugin già presenti e metadata di migrazione mancanti.

Dal checkout del plugin, per ripetere nel banco già predisposto:

```powershell
$qaContainer = 'redmine-7-0-2-onlyoffice-qa-d45a6bbb-test-redmine-1'
docker cp app "${qaContainer}:/tmp/dmsf-review-tests/plugins/redmine_dmsf/"
docker cp lib "${qaContainer}:/tmp/dmsf-review-tests/plugins/redmine_dmsf/"
docker cp test "${qaContainer}:/tmp/dmsf-review-tests/plugins/redmine_dmsf/"
docker cp doc/review-independent-2026-11-27/setup_tests.sh "${qaContainer}:/tmp/setup_dmsf_tests.sh"
docker cp doc/review-independent-2026-11-27/run_tests.sh "${qaContainer}:/tmp/run_dmsf_tests.sh"
docker exec $qaContainer sh /tmp/setup_dmsf_tests.sh
docker exec $qaContainer sh /tmp/run_dmsf_tests.sh rails test plugins/redmine_dmsf/test/unit plugins/redmine_dmsf/test/functional plugins/redmine_dmsf/test/integration plugins/redmine_dmsf/test/helpers --seed 5612
node --test --test-isolation=none test/javascript/dmsf_onlyoffice_test.js
```

`run_tests.sh` controlla nome database e radice storage prima di eseguire il comando.
Eseguire le sonde esterne su un altro database dedicato oppure reinizializzare questo prima
di tornare ai test Rails: le sonde non ripuliscono tutte le proprie tabelle.

## Limiti della verifica

- Le richieste a convertitore, builder e forgotten sono simulate nei test: queste esecuzioni
  non certificano il contenuto prodotto dal Document Server reale.
- Restano da eseguire iframe reale, coediting con due browser, `info` su una sessione
  reale chiusa e recupero di un forgotten effettivamente presente sul Document Server.
- LibreOffice non è installato nel container: i test preesistenti sulle anteprime Office
  ritornano senza asserzioni. Lo zero skip del runner non equivale a copertura di quelle anteprime.
- Il runner segnala anche test preesistenti privi di asserzioni (mailer e helper di route).
- Il test di lock concorrente è specifico PostgreSQL; sugli altri adapter segnala esplicitamente skip.
- Il lint completo dei file interessati ha segnalazioni preesistenti; non viene dichiarato verde.
  Non sono state aggiunte esclusioni per nasconderle.

## Messaggi di commit proposti

Nessuno staging, commit, push o pull eseguito.

Breve:

```text
fix(onlyoffice): correggi upload, recuperi e accesso allo storico
```

Medio:

```text
fix(onlyoffice): rendi atomici i salvataggi e proteggi lo storico

- serializza le revisioni e conserva i dati quando l'upload fallisce
- verifica i permessi dello storico e isola i moduli recuperati
- preserva risultati completati e provenienza di PDF e template
- aggiungi regressioni e documenta i test nel banco Docker isolato
```
