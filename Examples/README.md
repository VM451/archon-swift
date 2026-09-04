# Examples

`ArchonExampleApp` is a buildable SwiftUI host composition for macOS, iOS, and
visionOS 27. It wires the real model lifecycle surfaces together:

```bash
swift run archon-example-app
```

The example provides installed-model browsing, Hugging Face discovery, the
collection and metadata filters, device-fit recommendations, model detail
actions (download, pause, resume, retry, redownload, delete, and select),
resumable download actions, revision checks and updates, storage cleanup, model
library App Intents registration, and a real Apple Foundation Model chat
surface. It intentionally leaves credentials,
entitlements, privacy usage descriptions, and custom-model text-generation
adapters to the consuming application.

The executable is a SwiftPM example host, not a signed Xcode `.app` project.
Use it to verify package composition; deployment and live UI acceptance still
require an Apple application target with the host's entitlements and runtime
configuration.
