---
name: youtube-batch-video-upload
description: "Upload a folder of video clips to YouTube with consistent, templated metadata (title, description, tags, location) using browser automation. Use when the user wants to bulk-upload footage from an event or trip (e.g. dive clips, event recordings) to their YouTube channel, especially when clip filenames double as subjects and a shared description/tag template applies to the whole batch."
---

# YouTube batch video upload

Upload multiple video files to YouTube Studio through browser automation, applying
a shared metadata template while respecting platform limits and requiring explicit
sign-off before anything goes live.

## Stable Inputs

Collect or confirm before starting:

- The source folder and the list of video files (name, size, shot date).
- Privacy level for the batch (Public / Unlisted / Private) — do not assume Public.
- A title template that can incorporate each file's subject (e.g. its filename).
- A shared description template (event/location/company/date context).
- A shared tag set, plus any per-video subject-specific tag.
- Whether to set a YouTube location/geotag, and what it should be.
- Which browser session holds the destination YouTube account, confirmed by
  channel name shown in YouTube Studio — never assume the first connected
  browser is the right one when more than one is available.

If any of these is missing or ambiguous, ask before uploading anything. Present
the full per-file title/description/tag/privacy plan as a table and get explicit
confirmation before the first file is selected. This is a publish action — treat
it accordingly.

## Known Constraints

- **Browser file-attach size limits.** Automated "attach file to input" tools
  commonly cap combined upload size well below typical video file sizes (single
  digits of MB). Do not attempt to work around this by encoding, chunking, or
  scripting around the tool — it will fail or silently corrupt the upload.
  Instead: drive the YouTube Studio UI up to the "Select files" button, then have
  the user perform that one native-file-picker click and file selection
  themselves (the picker is outside what browser automation can see or drive).
  Automation resumes once the file starts processing, to fill in metadata.
- **Daily upload quota.** YouTube enforces a per-day upload cap per account that
  can be hit mid-batch with no advance warning. Treat a quota-limit message as a
  hard stop, not a retry condition. Do not attempt other accounts, other
  browsers, or repeated retries to route around it.
- **Multiple connected browser sessions.** When browser automation can reach more
  than one browser/device, list them and confirm which one is local/intended
  before navigating — a wrong-browser upload can land on the wrong Google
  account entirely.

## Procedure

1. **Inventory.** List the source folder's video files with size and modified
   date. Flag anything that isn't a video or looks out of place for the batch.
2. **Build the metadata plan.** Draft per-file titles from the template,
   the shared description, shared + per-file tags, geotag, and privacy level.
   Present it as a table and get explicit confirmation before proceeding.
3. **Confirm the browser and account.** Verify which browser session is in use,
   that it matches the user's actual device when more than one is connected, and
   that YouTube Studio shows the expected channel name before uploading anything.
4. **Per video:**
   - Open Create → Upload videos in YouTube Studio.
   - Ask the user to click "Select files" and choose the specific file — name it
     explicitly so there's no ambiguity about which clip goes next.
   - Once the file is attached and processing starts, fill in title,
     description, tags, and location per the confirmed plan.
   - Set visibility per the confirmed plan.
   - Pause and get explicit confirmation before clicking Publish/Save — do not
     chain confirmations across videos; each publish is its own irreversible,
     public action.
   - After publishing, verify the video appears in Content with the expected
     title and visibility.
5. **On quota limit.** Stop immediately. Report exactly which files succeeded and
   which remain. Offer to schedule a reminder (e.g. next day) to resume, rather
   than looping retries.

## Output

A short table: file → status (published / pending / blocked-by-quota) and the
resulting video URL for anything published.

## Stop Conditions

- The daily upload quota is hit (stop and report progress, don't retry).
- The metadata plan is ambiguous or unconfirmed.
- The active browser/account doesn't match the intended destination channel.
- A file selection step can't be completed by the user (don't attempt to bypass
  the native picker).

## Safety Model

- Every Publish click requires the user's explicit, per-video (or explicitly
  per-batch, if they said so) go-ahead — a prior "yes" to the overall plan is not
  a standing approval for each individual publish.
- Never attempt to route around a platform-enforced limit (quota, file size,
  native picker) with a workaround the user hasn't approved.
- Don't store personal file paths, account identifiers, or channel names in this
  public repository — keep those in the conversation/task context, not in this
  skill file.
