# Media upload diagnosis

Branch `feature/multi-upload-chat-attachments`. Findings from reading the
code before any change.

## Where things are

| Piece | File |
|---|---|
| Audio screen upload button | `lib/screens/audio_screen.dart` → `showUploadPickMenu` |
| Picker + "Add a description" sheet + upload loop | `lib/screens/audio/upload_sheet.dart` |
| Upload backend | Cloudinary unsigned upload (`lib/cloudinary/cloudinary_upload.dart`, Dio multipart, streamed from a file path) |
| Feed items | `sermons/pending/{id}`, then admin approval (`admin_audio_approval_screen.dart`), then `sermons/approved/{id}` |
| Chat attachments | `lib/screens/chat/private_chat_screen.dart` → `_pickImageVideo` → `_uploadAttachment` |
| Chat image bubble | `lib/screens/chat/message_bubbles.dart` → `ImageMessageBubble` |

## Audio screen: picking 2+ files "closes and returns with nothing"

What the code already does right: `allowMultiple: true`, and `withData`
only on web (native uses file paths). Neither `.single` nor `.first` is
used, so those are not the cause. The real causes:

1. **Images go through the gallery app, not the file picker.**
   `file_picker` 9.2.3 sends `FileType.image` to
   `ACTION_PICK` + `MediaStore.Images`, the phone's own gallery app. Many OEM
   galleries, XOS's included, ignore `EXTRA_ALLOW_MULTIPLE` there, or return
   the selection in a non-standard way. `file_picker` then finds no URIs.
   - The result is either an empty list ("No file selected.").
   - Or an `unknown_activity` error, shown only as the vague "Couldn't open
     the file picker" message.

   Audio and video use the system document picker (`ACTION_OPEN_DOCUMENT`),
   which handles multi-select properly.
2. **Long silent wait after "Select".** Before returning anything to Dart,
   `file_picker` copies **every** picked file into the app's cache. Several
   large audio or video files take many seconds. Nothing shows during the
   copy (`onFileLoading` isn't used), so it looks as if the picker closed and
   nothing happened.
3. **The app can be killed while the picker is open.** The app is in the
   background while the system picker is showing. On a 3–4 GB XOS phone, the
   memory killer can end it there, and then the result is delivered to a
   process that no longer exists. Nothing comes back.
4. **The upload is tied to a bottom sheet.**
   - Swiping the sheet away, or pressing back, during the upload leaves the
     loop running with no UI.
   - A failed file's error text is dropped (`onError: (_) {}`).
   - A failed file only says "will retry on Submit".
5. **Uploads go to the approval queue.** Uploaded items go to
   `sermons/pending` and only appear in the feed after an admin approves
   them, so "nothing appeared" can also be just this. This is existing
   policy and is kept, but the app now says so ("waiting for approval").
6. **There's no batch concept.** One shared description goes on every file,
   with no numbering or order. Approval also gives each item its own
   approval timestamp, so parts approved separately end up scattered in the
   feed.

## Private chat: image sends at once and spins for a long time

1. **No preview step.** `_pickImageVideo` calls `ImagePicker().pickMedia()`
   (one item) and passes it straight to `_uploadAttachment`. Picking *is*
   sending: no review, no crop, no caption, no way to cancel.
2. **The full-size original is uploaded.** No resize, no compression: a
   12 MP camera photo is 3–6 MB, which takes minutes on a weak 3G/EDGE
   connection.
3. **The message only exists after the upload finishes.** The chat shows a
   global spinner (`_isUploadingAttachment`) and nothing in the list. The
   bubble only appears once Cloudinary answers.
4. **No timeout.** `Dio()` is created with no connect, send or receive
   timeouts. On a dead or stalled connection, the request (and the spinner)
   never ends.
5. **No retry.** A failure shows one SnackBar and the picked photo is lost.

## Fix plan

- **Audio screen:**
  - `FileType.custom` with audio, video and image extensions: always the
    system document picker, so multi-select works for every type, mixed
    freely.
  - A "Preparing files…" indicator while `file_picker` copies.
  - The 20-file limit.
  - A review screen (numbered, reorderable, removable, add more, one title
    and one description).
  - Uploads run in an app-wide service with at most 2 at a time, per-file
    progress, a notification, and retry.
  - Images compressed to 1600 px / JPEG 80.
  - `batchId` / `partNumber` / `totalParts`.
  - Admins get "Approve all parts", so a batch lands together in order.
- **Private chat:**
  - Gallery multi-pick (up to 10) or camera, then a WhatsApp-style preview
    with crop and rotate, Standard / HD quality, per-image captions, and a
    discard confirmation.
  - On Send, local bubbles appear at once with progress.
  - Compression runs natively off the UI thread; the upload has a 60 s
    timeout.
  - Failures show "Tap to retry".
  - Several images show as a grid, opening a swipeable zoomable viewer with
    Save.
  - Receivers see a small blurred Cloudinary thumbnail first.
