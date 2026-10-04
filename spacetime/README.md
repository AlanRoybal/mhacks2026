# bounty-live: the SpacetimeDB module

Every job someone is working on is a session here. The worker's location pings, the on-site clock, the geofence, "left the site", signal loss, proof progress and the job's live phase are all decided in this module's reducers (`src/index.ts`). The backend reads sessions back to verify proof (time on site) and to drive both people's Live Activities. See [docs/API.md › Live sessions](../docs/API.md#live-sessions).

| Table | What it holds |
|---|---|
| `job_session` | One row per started job: phase, the current on-site stretch, banked on-site time, last ping, counters, proof progress. Private. |
| `session_event` | The session's history: `arrived`, `left`, `signal_lost`, `progress`, `phase`. Private. |
| `config` | The identity allowed to write (the backend). |
| `signal_check` | Schedules `check_signals` every 30 s, which pauses the clock for phones that stopped pinging. |

| Reducer | Called by the backend when |
|---|---|
| `claim_backend` | First use. Makes the caller the only writer. |
| `open_session` | The worker taps Start and the backend accepts their location. |
| `ping` | The worker's phone reports a location (about every 30 s). |
| `record_progress` | Proof is captured in the app. |
| `set_phase` | The job moves on: submitted, in review, paid, refunded, withdrawn. |

## Publishing to Maincloud

The backend reads private tables, so the database must be **published by the backend's own identity**, the same one whose token goes in `SPACETIME_TOKEN`. Use a separate CLI config so your own `spacetime login` stays as it is.

1. Log in to Maincloud once (opens a browser):

   ```bash
   spacetime login
   ```

2. Make an identity for the backend and save its token:

   ```bash
   curl -s -X POST https://maincloud.spacetimedb.com/v1/identity | jq -r .token > backend-token
   ```

3. Publish as that identity, from this folder:

   ```bash
   npm install
   spacetime --config-path ./backend.toml login --token "$(cat backend-token)"
   spacetime --config-path ./backend.toml publish --server maincloud bounty-live
   ```

4. Point the backend at it (`backend/.env`, or the deployed stack's environment):

   ```
   LIVE_PROVIDER=spacetime
   SPACETIME_URL=https://maincloud.spacetimedb.com
   SPACETIME_DB=bounty-live
   SPACETIME_TOKEN=<contents of backend-token>
   ```

The backend calls `claim_backend` on its first write. Keep `backend-token` and `backend.toml` out of git.

## Local

```bash
spacetime start
spacetime --config-path ./backend.toml publish --server local bounty-live
```

Then set `SPACETIME_URL=http://127.0.0.1:3000`. Without SpacetimeDB, `LIVE_PROVIDER=memory` (the default) runs the same rules in the backend process; keep `backend/src/live/live.ts` in step with `src/index.ts`.
