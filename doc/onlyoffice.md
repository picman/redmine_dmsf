# ONLYOFFICE integration: operation and local validation

This branch targets the plugin's existing Redmine 7 / Rails 8.1 environment. It uses the common ONLYOFFICE Docs 9/10
HTTP APIs (`/command`, `/converter`, `/docbuilder`) with a separate signed request for each service. It does not
require the Developer-only Automation Connector. A live Docs installation is still required to validate editor and
conversion behavior, supported formats and the capabilities available in your installation.

## Install or update

From the Redmine application root, with this branch checked out under `plugins/redmine_dmsf`:

```sh
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=redmine_dmsf
RAILS_ENV=production bundle exec rake assets:precompile
```

Restart Redmine using your normal deployment procedure. The migration creates a local session registry, recovery and
history records, and asynchronous document operation records. It does not delete existing revisions or enable retention.
Use an isolated test database and document storage when exercising deletion and recovery.
Mail delivery and deferred attachment purging use the application's ActiveJob adapter; run its worker when using a queued adapter.

Configure the existing public/internal addresses, JWT and TLS options in **Administration → Plugins → DMSF → Configure**.
The Document Server must reach signed Redmine document/script URLs and callbacks; Redmine must reach the Document
Server's command endpoints and returned files. The administration diagnostics action tests the latter direction and
command authentication. An actual edit/close/save round trip tests the former.

## Settings

| Setting | Initial value | Behavior |
| --- | --- | --- |
| Remove older minor revisions | Off | Enables DMSF minor/patch retention, independent of ONLYOFFICE |
| Recent minor revisions per document | 100 | Retains the latest N minor/patch revisions across all major versions |
| Store a snapshot when saving in the editor | On | Enables the editor Save button's force-save and the snapshot action |
| Snapshots retained per session | 3 | Keeps the latest ordinary working snapshots while a session is open |
| Signed download token lifetime | 86400 seconds | Short-lived document/history URLs; existing bounds of 300 seconds to 7 days |
| Maximum editing session duration | 2592000 seconds | Callback capability, bounded between 300 seconds and 30 days |
| Editor layout | auto | Desktop/mobile selection, with explicit override |
| Template revision IDs | Empty | Administrator-selected DOCX template revisions |
| PDF form field mapping | `{}` | Optional mapping from submitted form keys to issue custom field IDs |

Existing tokens retain their original expiry when the configuration changes. The callback lifetime does not renew an
arbitrarily old browser session: reopen an expired editor. `onRequestRefreshFile` obtains a newly authorized configuration
when ONLYOFFICE requests it; it does not rotate the key on every ordinary save.

### Minor retention

All major revisions remain. A major revision has no nonempty minor or patch component; the implementation handles
numeric versions, `nil` components and DMSF's alphabetic blank sentinel. A patch revision is counted in the minor cap.
The window is per document, not 100 per major release, and applies to browser uploads, WebDAV and editor saves.

Additional protections can leave more than N minors: the current head, bases of active edit/review/comment/form sessions,
conversion/template operations started in the last 24 hours, and assigned, waiting or approved workflow revisions. Locked and deleted files
are skipped. Retention runs after a new revision is committed; a cleanup failure is logged without undoing the saved
revision. A protected overflow is reconsidered by a later save or by the maintenance task.

Browser uploads and WebDAV PUTs keep revision metadata and synchronous byte acquisition in one transaction.
Failed uploads preserve the previous head and retryable temporary attachments; retention only follows a successful
commit. Ordinary revision creation takes the same file row lock as editor publication. Browser uploads reject a
version already present in the visible history and ask the user to refresh.

The ordinary DMSF deletion lifecycle transfers inherited content and source references before removal. Shared blobs are
purged only after a committed destruction and only when no attachment still references them. Physical byte deletion
continues to respect `dmsf_really_delete_files`. History sidecars are removed with their revision; recovery copies are not
part of this policy.

To inspect old documents after enabling retention, run the maintenance task. Its default is a preview:

```sh
RAILS_ENV=production bundle exec rake redmine:dmsf_prune_minor_revisions
RAILS_ENV=production bundle exec rake redmine:dmsf_prune_minor_revisions file_id=123 dry_run=true
RAILS_ENV=production bundle exec rake redmine:dmsf_prune_minor_revisions file_id=123 dry_run=false
```

The task reports candidates and protected exceptions. It is not installed as a scheduled job.

## Collaboration and save semantics

Every editor, reviewer and commenter opening the same retained revision uses the same collaborative key. The key includes
an installation namespace, preventing independent Redmine instances sharing a Document Server from colliding. Viewers have
a separate key so they cannot replace the callback selected for an editing session. Form filling has an individual key.
When a session has completed without publishing a new source revision (for example, a submitted form), reopening uses
a new session generation. Collaborators joining that generation share its key until it closes.

Registration retains authenticated participant membership separately from the server's current presence list. Callback
`users` for final/forced saves identifies the last editor and is not treated as a complete author list or as an ACL.
The callback URL's signed user and mode are rechecked before publication. A user with file manipulation can use all
applicable modes; additional roles can grant only review, commenting or form filling. Review mode requests tracked changes.

| Event | DMSF result |
| --- | --- |
| Editor state reports changes sent | Browser status only; no claim of DMSF persistence |
| Force-save request accepted | Pending until the callback's bytes have been acquired |
| Status 6 ordinary save | Recovery snapshot, no normal revision |
| Status 2 final save | One normal revision for the collaborative key, plus available history artifacts |
| Repeated status 2 | Same revision, with no duplicate notification/publication |
| Source superseded, locked or permission revoked | Durable recovery copy; current head remains intact |
| Status 3 or 7 with a file URL | Returned bytes retained for recovery |
| Acquisition failure | Error response; transient failures use HTTP 503 to allow server retries |
| Form submission or final form-filling save | Separate form recovery, never an overwrite of the template |

Local byte acquisition precedes a successful acknowledgement. A server that delivers no downloadable content cannot
be recovered by the callback alone. Ordinary snapshots are bounded and removed after a successful final publication;
exceptional recoveries are kept. Late force-saves cannot change a session from saved back to active or consume its final
idempotency key. File/session locks and expected-head checks serialize concurrent publication and restoration.

In strict co-editing mode, a server snapshot can only include changes already sent to ONLYOFFICE. It cannot capture
unsent browser edits. The UI distinguishes these states and exposes the approval link only after a confirmed final
revision. Existing DMSF approval assignment, authorization and locking remain in use; the snapshot action does not approve.

## History, differences and restoration

The native editor history panel lists retained DMSF revisions. Newly captured final saves preserve the signed `history`
metadata, `serverVersion`, changes archive and exact predecessor reference. The native highlighted changes are supplied
only when both the archive and its original predecessor are still available. Old revisions or pruned predecessors fall
back to complete snapshots; the implementation never labels changes against a different predecessor.

The comparison picker can select retained word-processing revisions from the current document or search other accessible
documents in the same project. It uses `onRequestSelectDocument` and `setRequestedDocument` for compare/combine/insert-text.
Availability depends on the format supported by Docs. Comparison is distinct from the history changes archive.

Restoration creates a new version using the selected content and advances the current version number. It requires both
history access and file manipulation, and fails if the head changed after the user selected a version. Download tokens
for historical content and change archives recheck the dedicated history permission on every request.

The editor's API history identifiers use immutable revision IDs. The DMSF version label is shown in the revision picker.
If a Document Server puts history metadata outside its signed callback token, that unsigned metadata is not trusted;
snapshot viewing still works and the document can be compared explicitly.

## Recovery and forgotten files

The editor links to the document recovery page. Administrators also have **Administration → ONLYOFFICE Docs**, including
copies from documents whose author lost access or whose source was deleted. Copies can be downloaded or explicitly
published as a new revision or independent document, with current permissions and head checks. Imported final audit
records no longer retain an extra payload attachment, allowing ordinary revision retention to release storage.

The forgotten inventory is intersected with locally registered session keys. Keys from other Redmine installations or
unknown documents are not exposed or imported. A source filename/type is recorded with the session so removal of an old
base revision does not prevent recovery. Recovery deduplicates by session, kind and SHA-256 content digest.

Recoveries from form-filling sessions, including forgotten files and sessions with a recorded form submission, can
only be saved as independent documents. They cannot replace the template. Late snapshots preserve the error/recovery
state and diagnostic reason of a closed session; importing forgotten bytes does not reopen a saved or submitted session.

Recovering a forgotten file does **not** delete it from ONLYOFFICE. The separate deletion action requires a local receipt,
an intact stored payload, an inactive editing session, and a fresh download matching that receipt. If the remote contents
changed, recover again first. The command protocol has no compare-and-delete primitive: perform cleanup only when users
have closed the affected document. Forgotten storage is an additional recovery path, not a guarantee after every crash
or failure. Docs 10 documents recovery at orderly shutdown; unexpected crashes can still lose unsaved state.

Recovery and history downloads are authenticated, returned as attachments and marked `no-store`. URLs supplied by the
editor or server can only be downloaded from configured Document Server origins; redirects retain this restriction and
Redmine's attachment-size limit applies.

## Document workflows

**Save copy** creates an independent document in a permitted folder of the same project. Rename changes the current
filename/title under a head check and then uses the `meta` command to update collaborators. A propagation failure is
reported without silently undoing a successful storage rename.

**Publish approved revision as PDF** converts an immutable, approved source revision through `/converter`, then saves a
new DMSF file whose provenance records the source revision. Unapproved/live content is not published as an approved PDF.
Historical PDF sources and direct DMSF revision downloads require the history permission. PDF operations recheck it
during polling, source download and publication; an editor already open on its base revision retains its normal token
semantics. Soft-deleted revisions cannot be fetched by the direct DMSF revision download route.
Async operations have durable IDs and can resume polling without duplicating the final file.
Transient service failures retain that operation ID. Terminal service failures are marked failed; unfinished operations
expire after 24 hours and no longer protect a source revision from retention.
Late errors cannot replace an already completed result.

**New from template** uses administrator-selected DOCX revision IDs. Template permissions are rechecked. Add tagged block
content controls using `project.id`, `project.name`, `author.name`, `date`, `issue.id`, `issue.subject`, `issue.description`
or `issue.cf.ID`. Selecting an issue copies only fields visible to the user and places the generated document in the
issue's DMSF folder. Generation is one-time: later manual text changes are not overwritten by field synchronization.
The new revision records the selected template as its source while destination metadata follows the current context.
The signed builder script contains only fixed code and JSON-encoded values; users cannot submit arbitrary scripts.

**PDF forms** preserve submitted PDFs and `formsdataurl` JSON. Configure a mapping such as `{"customer":12}`. On the recovery
page, select an issue, review the old and submitted values, then apply the explicit import. Redmine issue and custom-field
edit permissions are rechecked and optimistic locking prevents overwriting a concurrent issue change. The import creates
an issue journal. Saving the filled PDF as a separate document is explicit.

**Mentions and action links** resolve active, authorized project members. The editor receives opaque member identifiers
instead of exposing their real email addresses. Sending a mention requires the user's confirmation in the editor; normal
Redmine mail delivery handles the notification. Action links reopen the document at the supplied comment/bookmark.

## Local validation checklist

Apply migrations to a test Redmine database and build plugin assets before running the plugin tests. From the Redmine root:

```sh
RAILS_ENV=test bundle exec rake redmine:plugins:migrate NAME=redmine_dmsf
RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_dmsf
node --test plugins/redmine_dmsf/test/javascript/dmsf_onlyoffice_test.js
```

The new Rails tests cover retention, inherited attachments and rollback, callback signatures and modes, session/draft
deduplication, conflicts, revoked permissions, forms, history authorization, restoration, document operations and forgotten
recovery. The JavaScript tests exercise editor event wiring and server-confirmed save state without a live Document Server.

For end-to-end testing on your Docs 9/10 installations:

1. Open one DOCX with two different Redmine users. Confirm live co-editing and the same document key. Save repeatedly while
   both remain connected: recovery snapshots should appear, with no normal revision per click. Close both: one final
   revision should appear, with both users' content. Replay its callback: no additional revision.
2. While a session is open, upload a newer DMSF revision. Close the editor: confirm that the newer head remains and that the
   old session's content can be recovered. Repeat after a lock or role revocation.
3. Enable retention with a small test limit. Create mixed major/minor/patch revisions and a branched inherited attachment.
   Check all majors, latest minors, workflow exceptions, open session bases and retained file bytes. Preview the task before
   a real cleanup. Test the production limit of 100 only after these cases pass.
4. Inspect history before/after pruning, compare two retained word documents and restore an older version. Trigger a
   concurrent new revision immediately before restoration; it must fail without overwriting either file.
5. Interrupt callback delivery, recover an available forgotten file, verify the local download, and perform the separate
   cleanup only after closing its session. Unknown server keys must remain untouched.
6. Test reviewer/commenter roles, filled PDF isolation, form import preview and issue concurrency. Check templates with
   quotes/newlines in fields, async PDF/template retries, inaccessible destinations and editor reconnection/mobile layout.

### Verification in the implementation workspace

Ruby and a host Redmine application were unavailable in the implementation workspace. The Ruby/Rails suite and a live
ONLYOFFICE round trip therefore require execution locally; they are not represented as having passed. JavaScript,
translation consistency, route/action linkage and whitespace can be checked independently.

## API references

- [Callback handler](https://api.onlyoffice.com/docs/docs-api/usage-api/callback-handler/)
- [Document history](https://api.onlyoffice.com/docs/docs-api/get-started/how-it-works/document-history/)
- [Command service](https://api.onlyoffice.com/docs/docs-api/additional-api/command-service/)
- [Data retention](https://api.onlyoffice.com/docs/docs-api/get-started/how-it-works/data-retention/)
- [Conversion request](https://api.onlyoffice.com/docs/docs-api/additional-api/conversion-api/request/)
- [Document Builder](https://api.onlyoffice.com/docs/docs-api/additional-api/document-builder-api/)
- [Tagged field filling example](https://api.onlyoffice.com/docs/office-api/samples/document-editor/auto-filling-fields-from-json/)
