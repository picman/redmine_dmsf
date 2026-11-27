# Revisione indipendente DMSF / ONLYOFFICE

Data: 27 novembre 2026. Commit: `adc69d359ff54394408d889d5a303f76a5453dac`.

Ho individuato e riprodotto **tre problemi aggiuntivi**, non elencati fra D1–D5/D1b
nel rapporto review-3. I difetti precedenti restano aperti: questa verifica non li sostituisce.
Non sono state applicate correzioni al codice applicativo.

L'analisi si concentra sull'integrazione ONLYOFFICE e sui suoi confini con permessi DMSF,
revisioni, recuperi, storage e retention; non costituisce una revisione completa di ogni
funzionalità WebDAV, workflow o ricerca del progetto.

| ID | Priorità proposta | Problema | Verifica |
| --- | --- | --- | --- |
| N1 | P1 | La conversione PDF aggira il controllo dedicato allo storico | Metodo del controller, filtri applicativi e download sorgente reali; convertitore simulato |
| N2 | P1 | Un recupero forgotten di una sessione fill può sostituire la testa del modello PDF | Importazione e ripristino reali; trasporto forgotten simulato |
| N3 | P2 | Un upload che fallisce prima del ritorno lascia byte senza un record blob | Transazione e storage reali, errore di storage iniettato |

## N1 — Permesso sullo storico applicato in modo incoerente

**Riferimenti:** `app/controllers/dmsf_onlyoffice_actions_controller.rb:108`,
`:290`, `:325`; `app/controllers/dmsf_onlyoffice_controller.rb:53`.

Un utente non amministratore ha `view_dmsf_files` e `file_manipulation`, ma non
`view_dmsf_file_revisions`. Il controller dello storico gli nega correttamente l'accesso.
Lo stesso utente può però indicare l'ID di una vecchia revisione approvata a `publish_pdf`.
L'azione cerca fra tutte le revisioni visibili, verifica l'approvazione e avvia la conversione,
senza verificare il permesso sullo storico. Il download firmato destinato al convertitore
controlla soltanto il permesso di lettura del documento.

La sonda ha osservato simultaneamente:

- `history_allowed=false` e `can_write=true`;
- testa corrente 20, conversione autorizzata della revisione 19;
- risposta `accepted` e lettura effettiva dei byte sintetici della revisione 19.

**Impatto:** se il permesso dedicato deve limitare l'accesso ai contenuti precedenti,
la pubblicazione PDF offre un percorso alternativo per leggerli. È una divergenza rispetto
al controllo esplicito implementato nel nuovo controller dello storico.

**Correzione proposta:** verificare il permesso sullo storico quando la sorgente richiesta
non è la testa; ripetere il controllo durante il polling e prima della pubblicazione.
Valutare un token specifico per la conversione, legato all'operazione e alla sua autorizzazione,
senza interrompere i normali download necessari alle sessioni collaborative ancora aperte.

**Nota sul perimetro:** anche il download DMSF classico (`DmsfFilesController#view`, riga 50)
seleziona una revisione tramite ID senza un controllo esplicito equivalente. Questo indica
un'incoerenza più ampia, già presente nel progetto, non una vulnerabilità introdotta
esclusivamente da ONLYOFFICE. Il percorso classico è stato letto, non collaudato qui.
Conviene definire una politica unica per l'accesso ai contenuti storici e applicarla
a tutti i percorsi. Se invece il permesso deve nascondere solo l'elenco dello storico,
questa semantica va resa esplicita e il rilievo va trattato come incoerenza funzionale.

**Regressioni da coprire:** richiesta diretta di vecchia revisione senza permesso;
permesso revocato durante la conversione; conversione della testa ancora consentita
al ruolo previsto; download delle basi di sessioni già aperte.

## N2 — Il recupero forgotten perde la distinzione fra modulo e documento

**Riferimenti:** `app/controllers/dmsf_onlyoffice_admin_controller.rb:66`;
`app/controllers/dmsf_onlyoffice_recovery_controller.rb:30`.

Il callback ordinario conserva i PDF compilati separatamente dal modello. Il ripristino
vieta esplicitamente di sovrascrivere il modello quando `recovery.kind == 'form'`.
L'importazione forgotten assegna però sempre `kind: 'forgotten'`, anche quando la sessione
originale ha `mode: 'fill'`. Il successivo ripristino supera quindi il controllo.

Riproduzione:

1. Creare un modello PDF e registrare una sessione `fill`.
2. Importare come amministratore un forgotten della stessa sessione.
3. Richiedere il ripristino della copia sulla testa attesa del modello.

La sonda ha ottenuto `mode=fill`, `recovery_kind=forgotten`, revisione modello 21 e nuova
testa 22 contenente i dati del modulo compilato. La revisione precedente resta nello storico:
il difetto sostituisce la testa, non cancella fisicamente il vecchio modello.

**Impatto:** l'azione di recupero può trasformare un modello riutilizzabile in un modulo
già compilato, rendendo i dati inseriti parte del documento che sarà riaperto dagli utenti.
Richiede l'importazione amministrativa e un successivo ripristino autorizzato;
non è un'escalation di privilegi del solo compilatore.

**Correzione proposta:** preservare separatamente origine del recupero e natura del contenuto.
Come protezione minima, vietare il ripristino sul modello anche quando la sessione associata
è `fill`, indipendentemente dal valore `kind`. Per moduli inviati da sessioni `edit`, usare
anche l'informazione di invio già registrata. Conservare la possibilità di salvarli come
documento separato e i controlli della cancellazione forgotten.

**Regressioni da coprire:** forgotten da sessione fill, forgotten da sessione con invio modulo
già registrato, copia separata consentita, recupero di un normale documento ancora consentito.

## N3 — Pulizia del blob registrata troppo tardi

**Riferimento:** `app/services/dmsf_onlyoffice_blob.rb:57`.

`upload!` registra il callback di rollback soltanto dopo il ritorno di
`ActiveStorage::Blob.create_and_upload!`. Se il servizio scrive byte e poi solleva un errore,
la transazione elimina il record blob, ma il callback che dovrebbe eliminare i byte non è
mai stato registrato.

La sonda usa il vero DiskService in una directory temporanea. Un adattatore di prova
lascia eseguire la scrittura e solleva `IOError` prima che l'upload ritorni. Dopo il rollback:
`blob_row_exists=false`, `orphan_bytes_exist=true`. È una simulazione deterministica della
finestra di errore, non una prova di guasto fisico del disco o di un particolare backend remoto.

**Impatto:** errori e retry possono accumulare oggetti non raggiungibili tramite il database.
I test esistenti coprono il rollback successivo a un upload riuscito, non l'eccezione durante
`create_and_upload!`.

**Correzione proposta:** ottenere identità e chiave del blob e registrare la pulizia prima
della scrittura esterna; in alternativa prevedere una gestione dell'errore che conservi
la chiave necessaria a cancellare l'oggetto. Mantenere il controllo che impedisce di rimuovere
un oggetto ancora posseduto da un record, e i casi di transazione esterna/nidificata già coperti.

**Regressioni da coprire:** errore dopo scrittura parziale/completa, rollback esterno dopo
upload riuscito, commit riuscito e indisponibilità del servizio anche durante la pulizia.

## Evidenze e limiti

- [Sonda ripetibile](probe.rb) e [output osservato](evidence.txt).
- Banco esistente `qa_r3`, storage temporaneo dedicato, modifiche applicative racchiuse
  in una transazione annullata. Conteggi di documenti, revisioni, sessioni e operazioni
  invariati dopo il rollback. Il database dell'istanza non è stato usato.
- Nessuna email consegnata, nessuna modifica alla configurazione del Document Server,
  nessuna chiamata al convertitore o al servizio forgotten reali.
- Controller invocati direttamente, eseguendo i filtri di autorizzazione pertinenti:
  non è un collaudo HTTP completo di login, middleware o CSRF. I rendering sono sostituiti
  da raccolta dei risultati. I controlli sui permessi non sono simulati.
- Corrispondenza SHA-256 verificata per i quattro file principali delle riproduzioni
  fra checkout e container in esecuzione.
- Suite JavaScript esistente: **17 test passati, 0 falliti**.
- Suite Rails completa, browser reale e verifiche residue del passaggio: non eseguiti.
  I contenuti delle sonde sono marcatori sintetici; non dimostrano validità o fedeltà di PDF/DOCX.

La sonda richiede Rails già avviato tramite runner sul database `qa_r3` e rifiuta un nome
database diverso. Nel laboratorio esistente è stata copiata in
`/tmp/qa_review3/independent_review.rb` ed eseguita con:

```text
docker exec redmine-7-0-2-onlyoffice-qa-d45a6bbb-test-redmine-1 sh /tmp/qa_review3/run_r3.sh independent_review.rb 45
```

Il wrapper storico usa una pipeline con `tail`: il solo exit code non garantisce il successo.
Verificare tutte le righe `PROBE`, il rollback e il marcatore finale `PROBE COMPLETE`.
Gli ID cambiano fra esecuzioni perché il rollback non ripristina le sequenze PostgreSQL.

Ho escluso dalla lista dei difetti il riuso della chiave dopo una chiusura senza modifiche:
è una scelta esplicitamente coperta da
`test_collaborators_and_an_unchanged_reconnect_share_the_live_generation`.
Il protocollo descrive `status=4` come chiusura senza modifiche
([documentazione ONLYOFFICE](https://api.onlyoffice.com/docs/docs-api/usage-api/callback-handler/));
questo, da solo, non dimostra che il riuso della chiave sia errato.

L'ordine operativo resta: correggere prima D1/D2 già riprodotti dalla review-3;
affrontare N1/N2 insieme ai controlli di autorizzazione e isolamento dei recuperi;
completare N3 e aggiungere le regressioni mirate prima del collaudo completo.
