# ArchonModelsUI

`ArchonModelsUI` provides native SwiftUI surfaces for the same host-registered
`ModelLibrary` used by model App Intents. It includes installed-model library,
discovery, detail, storage, import, and download/update flows.

The views do not create a second database or decide credentials, entitlements,
runtime adapters, or model policy. Register the configured library through
`ModelLibraryIntentRegistry` and inject catalogs/download managers from the
consuming app.

Validate accessibility, file-import security scope, loading states, failure
states, offline behavior, and physical-device layout in a signed host app.
