# DBEngineKit

Runs local PostgreSQL, MySQL and Redis servers as per-user **launchd agents**, using
binaries from Homebrew (`/opt/homebrew/opt/<formula>`). Laradeck's Databases page is built on it.

- Service list: `~/Library/Application Support/Laradeck/Databases/Data/services.json` (file lock + backup copy)
- One data folder per service: `…/Databases/Engines/<engine>/<uuid>/` (database files in `data/`, launchd plist and log beside it)
- Start: `launchctl bootstrap gui/<uid> <plist>`; stop: `launchctl bootout gui/<uid>/<label>`
- launchd owns the server: it keeps running when Laradeck quits and restarts after a crash (`KeepAlive.SuccessfulExit = false`).
  Jobs don't survive logout, so Laradeck starts services marked autostart when it launches.
- Defaults: PostgreSQL user `postgres`, MySQL user `root`, both with an empty password, on 127.0.0.1.

```sh
swift test                                        # unit tests
DBENGINE_E2E=1 swift test --filter EndToEnd       # real servers from installed Homebrew formulae
```
