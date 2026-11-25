# CloudFlow MVP

Native SwiftUI iOS client with an optional Go transfer service. The standalone HTML is a clearly labeled interaction preview; demo share URLs are never sent to a real drive.

## Generate the iOS project

On a Mac with Xcode 15+ and XcodeGen 2.40+:

~~~sh
brew install xcodegen
cd outputs/CloudFlow
xcodegen generate
open CloudFlow.xcodeproj
~~~

Select an iPhone target and build from Xcode. The project minimum is iOS 16. TrollStore does not make an iOS app executable on Windows.

## Build an IPA with GitHub Actions

Use the CloudFlow folder itself as the GitHub repository root so the workflow under .github/workflows is discovered. Push it to GitHub, then run “Build iOS IPA” from Actions, or push a version tag such as v0.1.0. The workflow generates the Xcode project, runs Go service tests, builds the iOS app on a macOS runner with code signing disabled, packages Payload/CloudFlow.app as an unsigned IPA, and publishes it as a downloadable artifact for 14 days. No Apple signing certificate, team, or provisioning profile is configured. Download the IPA from a successful run’s Artifacts section and install it through TrollStore on a compatible device.

## Run the transfer service

The service binds to loopback only. Keep it loopback-bound behind a TLS reverse proxy; do not expose port 8080 directly. Do not place provider cookies or API keys in the mobile app source.

1. Install Go 1.23 or later.
2. Set a random service bearer key with at least 32 characters.
3. Set credentials and destination directories for the providers you use.
4. Run go mod tidy and go test ./... in server/, then run go run .
5. Configure a reverse proxy to forward /api/v1/* to 127.0.0.1:8080 using HTTPS, disable response caching, and limit access to trusted users.

PowerShell environment example (replace values locally; never commit credentials):

~~~powershell
$env:CLOUDFLOW_API_KEY = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$env:NETDISK_QUARK_COOKIE = 'your-quark-cookie'
$env:NETDISK_QUARK_SAVE_DIR = 'your-quark-folder-id'
$env:NETDISK_BAIDU_COOKIE = 'your-baidu-cookie'
$env:NETDISK_BAIDU_SAVE_DIR = '/CloudFlow'
$env:NETDISK_XUNLEI_TOKEN = 'your-xunlei-refresh-token'
$env:NETDISK_XUNLEI_SAVE_DIR = 'your-xunlei-folder-id'
~~~

## Service contract

All requests use Authorization: Bearer <service key> and JSON.

| Method | Path | Request / response |
| --- | --- | --- |
| GET | /api/v1/status | providers object with quark, xunlei, and baidu booleans |
| POST | /api/v1/transfers | Request has id (UUID), url, and code; response has shareURL, code, and title |
| GET | /api/v1/transfers/<UUID> | Fetches a result saved by idempotency key after timeout. A missing result is uncertain, not automatically retried. |

The upstream SDK has a package-global extraction-code slot, so the service serializes transfer calls. This MVP processes a batch sequentially to prevent code crossover. Each input may only reference an HTTPS share URL on one of the three configured provider hosts. Share results are checked against the source provider before they are returned. The local ledger stores results (including share URLs/codes) with owner-only permissions; protect and back it up accordingly.

## Model gateway

The iOS client accepts an OpenAI-compatible HTTPS base URL, lists models at /models, and calls /chat/completions. Keys are kept in iOS Keychain, not task history. The rewrite sends source text with opaque markers replacing recognized share URLs; the app restores original URLs locally, then its link-replacement action swaps only completed items. If a model drops a marker, the app rejects that output. A mobile app cannot hide a provider API key from its device owner; use a private gateway key with narrow quota.

## Verification boundary

The HTML preview opens directly. This Windows host has no Xcode or Swift compiler, so the iOS target cannot be compiled or installed here. No provider credentials were supplied, so live transfers were not attempted. An interrupted provider request can have an uncertain outcome and is not automatically repeated.
