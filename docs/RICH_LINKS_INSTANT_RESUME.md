# Rich link previews + instant resume (build 29)

Branch `feature/rich-links-instant-resume`, version 3.2.2+29.

## Part 1: WhatsApp-style link previews

Link previews from an earlier build already existed (`lib/links/`), so
this work repairs and finishes that system. It does not add a second one.

### What was broken

TikTok links showed a plain "TikTok video" card. TikTok's oEmbed endpoint
no longer returns a title or thumbnail. The service now tries these
sources in order:

1. **Video page data**: `__UNIVERSAL_DATA_FOR_REHYDRATION__` →
   `webapp.video-detail.itemInfo.itemStruct`. This gives the caption, the
   author, the vertical cover with its real size, and the duration.
   TikTok rate-limits this page per IP, so it sometimes fails.
2. **oEmbed**, used only if it returns both a thumbnail and a real title.
3. **Crawler Open Graph tags** (`facebookexternalhit` user agent). These
   reliably give the cover and "TikTok · Author".
4. **Basic card** with the site and the link.

Facebook and Instagram pages are also fetched with the crawler user agent
first.

### What the user sees

- **Composer** (chat and Audio screen): 400 ms after a link is typed or
  pasted, a shimmer skeleton appears, then a compact card with:
  - thumbnail;
  - bold title (2 lines);
  - site icon and name;
  - ✕ to remove the card.

  Deleting the link removes the card.
- **Sent card**:
  - Full-width thumbnail. Its height is reserved before the image loads,
    so lists don't jump. YouTube shows 16:9. Vertical TikTok covers are
    cropped to at most 260 dp.
  - ▶ button for videos and a duration badge when the duration is known.
  - Site favicon and name, bold title, and a 3-line description with
    "more"/"less".
  - Author and a short link (`youtube.com/watch?v=…`).
  - The user's text above the card.
- **Tapping**:
  - YouTube plays inside the app (official iframe player) with an "Open in
    YouTube" button. The app's own audio player pauses first.
  - TikTok, Facebook and other sites open in their app if it's installed,
    otherwise in the browser.
- **Older messages that only contain a link** (chat bubbles and Audio
  feed text posts): the preview is fetched once on this phone, without
  re-hosting the thumbnail and without writing anything to anyone's data.
  It is then cached.
- **Shares from other apps** (share screen → chat, Audio screen and the
  admin approval card) use the same service and card.

### Data

The preview is stored inside the message / post as
`link: {type: "link", url, title, description, author, siteName,
thumbnailUrl, thumbWidth, thumbHeight, videoId, sharedText, isVideo,
durationSeconds?, iconUrl?}`.

- **Old app versions** ignore `link` and show the text, which always still
  contains the URL. The new fields are optional, so older stored previews
  still read.
- **Expiring thumbnails** (TikTok, Facebook, Instagram CDNs) are re-hosted
  to Cloudinary when sending. YouTube thumbnails are permanent and are not
  copied.
- **Videos are never downloaded.**
- **Local cache**: `LinkPreviewCache` keeps the 300 most recent previews in
  SharedPreferences, keyed by URL.
- **Limits**: 8 s per request; at most 1 MB of HTML is read.

## Part 2: Instant start and resume

### Cause (measured on the Samsung SM-A175F, release build 28)

There were two separate problems:

1. **The app was killed in the background, so every "resume" was a cold
   start.** After Home, Android's low-memory killer reclaimed `com.tbtrapp`
   about 3.7 s later. At the time it used 244 MB RSS plus 171 MB of swap,
   at oom_adj 700. Home → Settings → back was therefore a full cold start:
   6.4 s.
2. **The cold start itself waited on Dart gates, not native code.** Process
   start → Dart `main` took about 0.3 s, and `main` → first frame took
   0.26–0.57 s. After that:
   - The force-update gate showed a logo and spinner until its first
     decision.
   - The auth gate showed a spinner until the profile loaded.
   - The feed then appeared 1.6–1.8 s later, because chat sync, contact
     sync (phone number normalisation on the UI thread), the profile photo
     warm-up and the alias refresh all competed with it at startup.

The Activity was not recreated, and no gate waited for the network after
the earlier fix (build 28). The flow did restart, but only because the
process had been killed.

### Fixes

- **Force-update gate** shows the app at once. It only covers the app when
  a policy blocks this version (decided from the saved policy within
  milliseconds; the network re-check runs in the background).
- **AuthGate** opens immediately from the cached profile.
- **Local feed** starts loading in `main()`, before `runApp`.
- **Router** is built once per host, so a rebuild can't send the user back
  to the start.
- **Startup work after the first frame**, staggered:
  - photo warm-up: 0.6 s;
  - chat sync: 1.5 s;
  - contact sync: 3 s, with numbers normalised in a background isolate;
  - alias refresh: 4 s.
- **Memory**: the image cache is capped at 48 MB / 300 images and cleared
  when the app goes to the background. A smaller process is much less
  likely to be killed.
- **Native splash**: centred app logo on white (`launch_background.xml`),
  plus the Android 12+ splash theme (`values-v31`, `values-night-v31`), so
  there is no white or black flash before Flutter draws.
- **`StartupTrace`** prints a `[Startup] +N ms` timeline in logcat.

### Times (Samsung SM-A175F, Android 16, release)

| Scenario | Before (build 28) | After (build 29) |
|---|---|---|
| Cold start, process start → feed on screen | 3.9–4.8 s to the first frame, plus 1.6–1.8 s for the feed | **0.98 / 1.30 / 1.38 s** |
| Dart `main` → feed content | ~2.3 s | 0.90–1.18 s (feed appears in the first frame) |
| Home → wait 60 s → back | process killed after ~3.7 s → cold start | same process, **26 ms**, no restart |
| Home → Settings (20 s) → YouTube (15 s) → back | 6.4 s (cold, the process had been killed) | **HOT, 395 ms**, same process, no Dart restart |
| PSS in the background | 244 MB RSS + 171 MB swap | ~200 MB |

These times meet the targets: warm resume < 0.5 s, and cold start < 2 s
on the Samsung.

The phone was locked with a PIN during the after-measurements, and I did
not unlock it, so `am start -W` couldn't report TotalTime for cold starts
(the lock screen covers the window). The cold times above come from
logcat timestamps instead: `Start proc` → the `feedContent` mark, which
fires after the first frame that already contains the feed.

The itel wasn't connected, so it couldn't be measured. The Samsung's cold
start (1.0–1.4 s) leaves headroom under the itel's 3 s target.

## Part 3: Tests and builds

- `flutter analyze`: no issues.
- `flutter test`: 287 passed, 7 skipped. Five of the skipped tests are the
  opt-in live-network checks in `test/live_link_preview_test.dart`; run
  them with `LIVE_LINKS=1`.
- New tests:
  - `test/link_preview_parsing_test.dart`:
    - TikTok page data and crawler OG tags, parsed from saved pages in
      `test/fixtures/`;
    - favicon and og:video;
    - database round trip, including old maps without the new fields;
    - cache hits and the 300-entry limit, and that failed fetches aren't
      cached;
    - fallback card, vertical thumbnail cap with duration badge, and the
      "more" toggle.
  - `test/startup_gate_test.dart`: the first frame shows the app without
    waiting for a policy, and a resume keeps the same screen (no splash,
    no reset).
  - The existing `test/link_preview_test.dart` covers URL detection, oEmbed
    and OG parsing, and the offline fallback.

### Builds

Status when this report was written: the build-29 arm64 APK was built and
installed on the Samsung (all the after-times above come from it). The
split-per-abi and AAB release builds were still running in a detached
process, logging to `release_build.log`. Until they finish, the files
below are still the build-28 ones (dated 19 Oct, 22:27–22:36).

- Split APKs: `build/app/outputs/flutter-apk/`
  - `app-arm64-v8a-release.apk`: for the **Samsung** (arm64-v8a, confirmed
    with adb).
  - `app-armeabi-v7a-release.apk`: for the **itel**. Most itel phones are
    32-bit ARM. It wasn't connected, so check with
    `adb shell getprop ro.product.cpu.abi`; if it says `arm64-v8a`, use the
    arm64 APK.
  - `app-x86_64-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

**Signing: these builds are signed with the debug key, not the Play
key.** `android/key.properties` (and the upload keystore it points to)
isn't on this PC, so Gradle falls back to the debug signing config.

- Debug certificate SHA-256 (from `apksigner verify --print-certs`):
  `18ef50495ad7626dd3a6082940de96cfe81f7b62be8a7368cde51d3f8bc688c5`.
- Play Console rejects an AAB signed this way, and the APKs can't install
  over the Play version (signature mismatch).

To make Play-signed builds, put `key.properties` and the keystore back in
`android/` and run:

```
flutter build apk --release --split-per-abi
flutter build appbundle --release
```

The signing setup and package name were not changed.

## Test checklist (on a phone)

1. **YouTube link in a chat**: paste `https://youtu.be/dQw4w9WgXcQ`. A
   shimmer, then the card appears. Send it: the card shows a 16:9
   thumbnail with ▶. Tap it: the video plays in the app, and the Audio
   player pauses if it was playing. "Open in YouTube" works.
2. **TikTok link**: paste one from the TikTok app (`vm.tiktok.com/...`). The
   card shows the vertical cover (at most about a third of the screen
   tall), the author and the caption. Tap it: the TikTok app opens.
3. **Facebook or news link**: a card with the image, title and favicon
   appears. ✕ removes it before sending. Deleting the link from the text
   also removes it.
4. **Old messages**: open a chat with links sent by an older version. The
   cards appear a moment later, and instantly the next time.
5. **Share from YouTube or TikTok into the app** (share screen → Audio
   screen): the card is shown, and the admin approval card shows the same
   preview.
6. **Warm resume**: open the app, press Home, open Settings and another
   app, then come back. You land on the same screen and scroll position,
   with no splash, immediately.
7. **Cold start**: swipe the app away and open it. You see the logo on
   white (no white or black flash), then the Audio feed in about a second,
   with no spinner screens.
8. **Offline cold start**: turn on airplane mode, then swipe away and open
   the app. It is just as fast and shows the saved feed and chats; links
   show a basic card.
