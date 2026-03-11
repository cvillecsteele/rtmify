# Windows Manual Smoke Checklist

Use this checklist on a clean Windows machine or VM.

## Bundle check

1. Unzip the portable bundle.
2. Verify both files exist:
   - `RTMify Live.exe`
   - `rtmify-live.exe`

## Basic startup

3. Launch `RTMify Live.exe`.
4. Verify the tray icon appears.
5. Click `Start Server`.
6. Verify the dashboard opens automatically.
7. Verify `http://localhost:8000/api/status` is reachable.

## Data paths

8. Verify the DB exists at:
   - `%LOCALAPPDATA%\RTMify Live\graph.db`
9. Verify the log exists at:
   - `%LOCALAPPDATA%\RTMify Live\logs\server.log`

## Stop / restart

10. Use the tray menu to stop the server.
11. Verify the dashboard is no longer reachable.
12. Start the server again from the tray.
13. Verify the dashboard opens again and the same DB/log paths are reused.

## Failure path

14. Temporarily rename `rtmify-live.exe`.
15. Launch `RTMify Live.exe`.
16. Click `Start Server`.
17. Verify the tray reports a specific missing-binary error.
18. Restore `rtmify-live.exe`.

## Done

19. Quit the tray app.
