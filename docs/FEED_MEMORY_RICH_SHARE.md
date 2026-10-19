# Instant Audio screen with position memory + rich link sharing

Branch: `feature/feed-memory-rich-share`. It starts from `fix/settings-admin`,
which already contains the phone/contacts/chat, KGP-warning and
Settings/Admin work. Version **3.2.2+27**.

| Commit | |
|---|---|
| `619415e` | Part 1: Audio screen opens instantly where I stopped (+ link-preview module) |
| `db4c490` | Part 2: rich link cards in private chats |
| `1c155d8` | Part 3: share screen with "Audio Screen" on top, via admin approval; Direct Share |
| `d8bd691` | feed-open benchmark, build number 27 |

Packages added:

- `scrollable_positioned_list` 0.3.8: jump to a saved post reliably.
- `youtube_player_iframe` 6.0.2: the official YouTube embed. It brings `webview_flutter`, whose Android plugin is already Built-in-Kotlin, so there is **no new KGP warning**.

## Part 1 — Audio screen

**Why it showed a long spinner.** The spinner wasn't the feed. The app-wide
force-update gate covered every screen until a network check of Remote Config
finished, which could take up to ~10 s on each cold start, even though the
last policy was saved on the phone. It now decides **at once** from the saved
policy and confirms over the network in the background. A phone that must
update is still blocked, offline too.

**Why it jumped to the top.** The list started at its first item (the oldest
post) and nothing was saved.

**Now:**

- **Local-first feed** (`LocalFeedStore` v2, an additive upgrade, so the existing cache is kept).
  - Every approved post is stored with everything needed to draw it, including link previews (`linkJson`).
  - The provider starts with the app, so the screen opens from memory/disk on its first frame.
  - The network brings only changes:
    - new posts via `orderByChild('timestamp').startAfter(newest stored − 6 h)` (the 6 h window catches phones with a slow clock; duplicates are harmless);
    - edits and deletions via child events;
    - reactions one item at a time.
  
    Bursts are written to the phone in one batch. Images keep using `cached_network_image`'s disk cache, and audio/video downloads are unchanged.
- **App bar:** a small **Offline** or **Updating…** chip; it never blocks the screen.
- **Reading position:**
  - The list is drawn newest-at-the-bottom with `ScrollablePositionedList`.
  - The post at the bottom of the view and its offset are saved per account (while scrolling, on leaving the screen, and when the app goes to the background), then restored exactly. If that post was deleted, it opens at the nearest older one.
  - New posts arriving while you read further up don't move your place.
  - If you left at the newest post, or on a fresh install, it opens at the newest.
  - Image, video and link tiles reserve their size before loading, so the position doesn't drift.
- **New posts since your last visit:** a "**N new messages**" divider sits above the first one, and the existing down-arrow button shows the count. Tapping it goes to the newest. Posts that are on screen count as read.
- **Older posts:** all stored posts are read in one indexed query (600 posts in under 30 ms on a PC) and the list builds rows lazily, so no separate page loading is needed.

**Open times:**

| | Before | After |
|---|---|---|
| Cold start → Audio screen | spinner until Remote Config answered: up to ~10 s online on slow networks, the full 8–10 s timeout offline | no network wait; the feed appears as soon as the phone's copy is read |
| Reading the feed for the first frame (600 posts, PC, real SQLite) | (already local) | 18–28 ms |
| Coming back to the Audio screen in the same session | list rebuilt at the top | from memory, at the saved post |

I couldn't measure on your phone. The app logs it: run `flutter logs` and open
the app to see `[FeedOpen] N posts visible after X ms (from the phone)`.

## Part 2 — rich link previews

- **Detection** (`lib/links/link_preview.dart`): YouTube watch / youtu.be / Shorts / embed / live / mobile / music links, TikTok (including `vm.`/`vt.tiktok.com` and `tiktok.com/t/` short links, which are followed to the real URL), Facebook, Instagram, X and any website.
- **Metadata** (`lib/links/link_preview_service.dart`):
  - YouTube: oEmbed (title, channel) plus the video's thumbnail (`maxresdefault` when it exists, otherwise `hqdefault`).
  - TikTok: oEmbed (caption, author, thumbnail).
  - Other sites: Open Graph tags, fetched with a normal phone browser User-Agent.
  - If anything fails, the result is still a card with the link and the site name, never raw text.
- **Expiring thumbnails** (TikTok and most sites) are downloaded once and re-uploaded to Cloudinary (folder `link_previews`), and the post stores the Cloudinary URL. **Videos are never downloaded.**
- **The preview is saved inside the post or message** under `link` (`url`, `title`, `description`, `author`, `siteName`, `thumbnailUrl`, `thumbWidth`, `thumbHeight`, `videoId`, `sharedText`). Receivers draw it instantly, also offline from the local stores (feed v2, chats v5, both additive).
- **The card** has a large thumbnail with a play button for videos, the site icon and name, title, description, author and link.
  - Tapping a YouTube card plays it **inside the app** with the official embed, with an **Open in YouTube** button.
  - TikTok and others open in their app if it's installed, otherwise in the browser.
- **Where cards appear:** the Audio screen (link posts and text posts with links), private chats, the Admin approval panel, and the share screen.
- **Typing or pasting a link** in the feed composer or a chat shows a small preview above the input; it can be removed before sending.
- **Older app versions:** chat messages and feed text posts keep the URL in their text, so old versions show plain text. Approved link posts have an empty `audioUrl`, which old versions skip.

## Part 3 — sharing into T.B.T.R

- **The share screen shows,** top to bottom: the rich preview card, an "Add a message…" box, the pinned **📢 Audio Screen (Post to everyone)** item with the app icon, then your chats and contacts. Any combination can be selected.
- **Audio Screen shares always go to the Admin approval queue** (`sermons/pending`) and never appear in the feed before approval:
  - media as before;
  - links as a `LINK` post carrying the full preview;
  - plain text as `TEXT`.
  
  You get the confirmation "Sent to Admin for approval ✓".
- **Contacts** receive a private message with the card.
- **Admin approval panel:** link items show the full card (thumbnail, title, description, link, site). Approve and Reject work as before. Approving a `TEXT` item publishes it as a normal feed text post.
- **Android Direct Share:** a "**T.B.T.R – Audio Screen**" sharing shortcut is published at app start. Choosing it from Android's share sheet opens the share screen with Audio Screen already selected. Android decides whether and where the shortcut appears; it usually needs the app to have been opened once since installing.
- Sharing works with the app closed, in the background or open. If you're not signed in yet, the share is kept until sign-in finishes (as before).

## Tests

- `test/link_preview_test.dart`:
  - link detection (YouTube long, short, Shorts, embed, live; TikTok short links; other sites);
  - oEmbed and Open Graph parsing;
  - redirect following and thumbnail re-hosting (mock HTTP);
  - the offline fallback card;
  - Firebase/SQLite round trips;
  - old-version text.
- `test/feed_memory_test.dart`:
  - open position (first install, at newest, middle, new posts since, deleted post);
  - the unread divider (including your own posts);
  - the feed store v1 → v2 migration;
  - the open benchmark.
- `test/incoming_share_test.dart`: the Direct Share target.
- `test/local_chat_store_test.dart`: the chat store upgrade to v5.

`flutter analyze`: no issues. `flutter test`: all pass (see build section).

## Build

| Step | Result |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | all pass (259, plus 2 opt-in preview renders skipped) |
| `flutter build apk --release --split-per-abi` | **OK.** `app-arm64-v8a-release.apk` 37.9 MB, armeabi-v7a 31.0 MB, x86_64 43.2 MB |
| `flutter build appbundle --release` | **OK.** `app-release.aab` 85.2 MB |
| KGP warning | **none** in the full output (`docs/build_logs/feed_release_build.txt`) |

The builds ran as a separate process with Android Studio still open, after
`gradlew --stop` each time.

**Signing:** `android/key.properties` is still missing and there is no keystore
in the project, so both are signed with the **debug key**. The APK installs on
your phone; if the Play version is installed, uninstall it first (that
deletes its local chats). Play will **reject** this AAB. Restore
`android/key.properties` and run `flutter build appbundle --release` again
before uploading.

- Phone APK: `E:\APACHE\TonkohApp\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`
- AAB: `E:\APACHE\TonkohApp\build\app\outputs\bundle\release\app-release.aab`

## Phone test checklist (SM-A175F)

1. Open the app → the Audio screen appears straight away, with no long spinner.
2. Scroll to a post in the middle, open another screen, come back → same place. Close the app completely and reopen it → same place.
3. Post something from another phone → a "1 new message" divider and a badge on the down arrow. The arrow jumps to the newest post.
4. Turn off the internet and reopen the app → the Audio screen opens straight away, with its images; the app bar shows "Offline".
5. In YouTube: Share → T.B.T.R (or the "T.B.T.R – Audio Screen" shortcut at the top of the share sheet) → "📢 Audio Screen" is at the top, with the video card → add a caption → Send → "Sent to Admin for approval ✓".
6. ☰ → Admin (2222) → Review uploaded audio → the item shows thumbnail, title, description and link → Approve → it appears in the Audio screen as a card → tap it → it plays inside the app; "Open in YouTube" works.
7. TikTok: the same steps, with thumbnail and caption; tapping opens TikTok.
8. Share a YouTube link to a contact → they see the card in the chat (older app versions see the link as text).
9. Paste a link in a chat and in the feed composer → the preview appears above the input before sending, and × removes it.
10. Discussions, chats, calls, contacts, Settings, Admin (approve/reject of normal uploads), Bible Facts, Feedback and notifications work as before.
