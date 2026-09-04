# Handle background model transfers

Use the foreground `ModelDownloadManager` for an in-process transfer. Use
`ModelBackgroundTransferCoordinator` when the operating system may relaunch the
application to finish a download.

## Required setup

1. Choose a stable URLSession background identifier owned by the consuming app.
2. Persist `ModelBackgroundDownloadRecord` values in an app-owned location.
3. Recreate the coordinator with the same identifier after relaunch.
4. Rehydrate the original `ModelDownloadRequest` from the host's model catalog.
5. Call `reconnect()` and consume transfer events.
6. Send the staged artifact through the normal library validation and atomic
   installation path.

The background coordinator moves bytes; it does not decide whether an artifact
is runnable or licensed.

## Security requirements

- Never persist raw bearer tokens or credential-bearing headers in transfer
  records.
- Rehydrate authorization from the host's secure credential service.
- Treat resume data as opaque and protect it with the configured secure store.
- Revalidate URL, variant identity, size, checksum, resources, and manifest
  before installation.
- Reconcile missing URLSession tasks to a resumable failed state.

See the [model lifecycle reference](../reference/model-lifecycle.md) and the
[model contract](../reference/model-contract.md).
