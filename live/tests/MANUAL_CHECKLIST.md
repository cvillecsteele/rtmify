# RTMify Live Manual Packaged-App Checklist

Keep this list small. The browser and Zig integration suites should own normal regressions.

## macOS tray app

1. Launch the tray app.
2. Start the server.
3. Verify the dashboard auto-opens once.
4. Stop the server and verify it does not restart.
5. Force a child crash and verify:
   - the tray shows restarting state
   - the child restarts with backoff
   - the browser is not reopened on restart
   - the crash block lands in `~/.rtmify/log/server.log`
6. Exhaust retries and verify the tray moves to explicit error state.
7. Open `Info` tab and verify:
   - tray app version
   - `rtmify-live` version
   - DB path
   - log path

## final smoke before release

1. Connect a real workbook.
2. Add a real repo.
3. Open Code, Impact, Chain Gaps, MCP & AI, and Info.
4. Confirm the packaged app can be quit cleanly without leaking child processes.
