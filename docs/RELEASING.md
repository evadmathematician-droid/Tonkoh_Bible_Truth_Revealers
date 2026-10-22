# Releasing a new TBTR version

## Every release

1. **Bump the version** in `pubspec.yaml`. Raise the number after the `+`
   by one (for example `version: 3.2.2+30` becomes `3.2.2+31`). Play rejects
   a number it has already seen.
2. **Run the release script** in PowerShell from the project folder:
   ```powershell
   .\tool\release.ps1
   ```
   It builds `dist\tbtr-<version>-<code>.aab` (for Play) and `.apk` (for
   sending directly), then publishes `latest_version_code` to Firebase Remote
   Config.
3. **Upload the `.aab`** in Play Console:
   1. Open Production and click "Create new release".
   2. Upload the `.aab`.
   3. Click Save, then Review, then roll out to 100%.

That's all. Phones with **build 30 or newer** that were installed from Play
ask Play for updates on every start and every return to the app. When the
new build goes live on Play, those phones show Play's full-screen update and
can't use the app until they update.

## Once the release shows "Available on Google Play"

Run:
```powershell
.\tool\release.ps1 -SkipBuild -Enforce
```
This blocks older installs that only read Remote Config:

- builds 25–29;
- 3.2.1 and older (if they have the update check);
- phones that weren't installed from Play.

**Don't run `-Enforce` before Play has the release live.** Users would be
blocked with nothing newer to install.

## One-time setup

The Firebase CLI has to be logged in with the Google account that owns the
TBTR Firebase project (`tonkoh-bible-truth-revea-a7694`):
```powershell
firebase login:add        # sign in with the TBTR owner account
firebase login:use <that-email>
```
Until then, the script still builds the app. It updates
`remoteconfig.template.json` locally and prints the command to publish it.

## How the update check decides

| Installed build | What blocks it |
|---|---|
| 30+ from Play | Google Play has a newer build (automatic), **or** `min_version_code` |
| 25–29 | `force_update = true` and `min_version_code` > installed build |
| ≤ 24 (3.2.1) | `min_required_version` > installed version name |
| Without any update check | Nothing in the app. Only Play's own auto-update. |
