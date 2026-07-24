# 2026-07-12 HoverPocket Google OAuth Review Video Trim

## Summary

- Reviewed `/Users/shotaro/Downloads/画面収録 2026-07-12 12.31.26.mov` for Google OAuth verification use.
- Produced a separate trimmed/redacted candidate at `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-review-trimmed-redacted.mov`.
- Left the original recording unchanged.

## Completed Work

- Confirmed source metadata with `ffprobe`: 83.51s, 3024x1964, H.264, no audio stream.
- Generated review contact sheets under `/tmp/hoverpocket_review/` to inspect scene boundaries.
- Identified unnecessary source sections:
  - Intro with internal workflow / Codex-style notes.
  - Account selection and warning pages that expose account details and are not the core app-scope demonstration.
  - Ending where the browser returns to a general Google page / desktop context.
- Exported a 23.00s trim from the OAuth consent scope screen through HoverPocket Calendar event creation and deletion.
- Applied localized blur to account/profile areas that were not needed for the review content.

## Output

- `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-review-trimmed-redacted.mov`
- Readback: 23.00s, 3024x1964, H.264, 30fps, no audio, 1,735,902 bytes.

## Final English Consent Replacement

- Reviewed the two additional screen recordings in Downloads and selected `画面収録 2026-07-12 12.46.52.mov`, which contains the OAuth consent screen switched to English and both requested Calendar scopes selected.
- Replaced the Japanese consent portion of the earlier redacted edit with the English consent portion, using a short crossfade into the existing HoverPocket settings and Calendar demonstration.
- Normalized both sources to 3024x1928, H.264, 30fps, no audio, and added time-aware localized blur so the Google account identifier remains redacted before and after the consent-page scroll.
- Final output: `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-verification-final.mov`.
- Removed the unrelated browser/article tail after the event deletion result, ending the final video after the delete confirmation closes and before an unrelated article card appears.
- Readback: 20.00s, 3024x1928, H.264, yuv420p, 30fps, no audio, 1,975,712 bytes. SHA256: `60b3dec758c2593429f9ed5b7ee9f6104b0fd6d147ff6d23b96194539930a12b`.
- Verification included full sequential decode, `ffprobe`, full contact-sheet review, targeted frame review before and after the consent-page scroll, and targeted frame review across the replacement boundary.

## Full Intro / No Redaction Re-export

- Rebuilt the final video using only the two video materials remaining in Downloads: `画面収録 2026-07-12 12.31.26.mov` and `画面収録 2026-07-12 12.46.52.mov`.
- Restored the original recording from 0:00 through the OAuth warning flow, replaced only the Japanese consent section with the English consent section, and returned to the original recording for HoverPocket settings plus Calendar create/delete operations.
- Removed all localized blur/mosaic processing as requested. The output therefore preserves account and desktop details visible in the source recordings.
- Extended the ending through the completed event deletion, then stopped before the unrelated article card appears.
- Current final output: `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-verification-final.mov`.
- Readback: 63.90s, 3024x1928, H.264, yuv420p, 30fps, no audio, 6,882,538 bytes. SHA256: `01e8aad300226441c1681f158a9937c6261a666643f86a17c46611166da18049`.
- Verification included warning-free full decode, full contact-sheet review, both replacement boundaries, the restored first frame, English consent and scope selection, the original Calendar workflow, and the post-delete end frame.

## Verification

- `ffprobe -hide_banner -show_entries format=duration,size,bit_rate -show_entries stream=width,height,avg_frame_rate,codec_name`
- Contact-sheet review confirmed the output starts at the OAuth consent screen and retains:
  - HoverPocket app name on the consent screen.
  - Calendar list read scope and event read/write scope on the consent screen.
  - Google Calendar connection state in HoverPocket settings.
  - Calendar event creation.
  - Calendar event deletion confirmation.

## Risk / Follow-up

- The final edit now shows the complete consent screen in English, including the bottom-left `English (United States)` setting and both requested Calendar scopes.
- Neither source recording shows the user clicking the final `Continue` button. The edit transitions from the selected English scopes into HoverPocket's connected state, but Google may still request a retake because its guidance asks for the end-to-end OAuth grant process.
- The local plan also called for showing the AI lane approving and executing a Calendar operation. This recording mainly covers OAuth consent and direct Calendar CRUD; an additional English clip may be needed if Google expects the AI lane scope-use path.

## Google OAuth Verification Submission

- Uploaded `/Users/shotaro/Downloads/HoverPocket-Google-OAuth-verification-final.mov` to the `Uimaru CC` YouTube channel with title `HoverPocket Google OAuth Verification Demo` and unlisted visibility.
- YouTube URL: `https://youtu.be/swDXmcJxJrE`.
- YouTube readback: 1:04 duration, unlisted selected, copyright check completed with no issues, and community-guidelines check completed with no issues. A separate HTTP readback returned `200` and the expected page title.
- Search Console readback for `https://shotaro311.github.io/`: account `shotaro.matsu0311@gmail.com` is shown as a verified owner.
- Changed the Google Auth Platform homepage from the GitHub Pages root to the actual HoverPocket homepage `https://shotaro311.github.io/hover-pocket/`. External readback returned HTTP `200` for both the homepage and `privacy.html`.
- Google Auth's automated branding verification still reported the GitHub Pages homepage as unregistered. Selected the manual-review route (`detected issue is incorrect`) and included the exact Search Console ownership evidence in the submission's additional information.
- Saved an 887-character English scope justification covering both `calendar.events` and `calendar.calendarlist.readonly`, why narrower access is insufficient for event CRUD and CalendarList discovery, and the app's data-use limits.
- Saved the YouTube demo URL and supplemental project/ownership information, completed the verification questionnaire, and submitted the request.
- Final readback in Google Auth Platform Verification Center: `Branding and data access are currently under review.`

## Submission Follow-up

- Monitor `shotaro.matsu0311@gmail.com` for reviewer questions or a request for a new video. The current video does not show the final OAuth `Continue` click, so Google may request an end-to-end retake.
- Created active Codex automation `hoverpocket-oauth` to monitor the mailbox twice daily at 09:00 and 18:00 JST. The automation searches from the submission date, deduplicates previously reported Gmail message/thread IDs, reports new reviewer requests with required actions, and leaves mailbox state unchanged.
- Initial mailbox check found no OAuth verification submission/reviewer email. The only match was the normal Google security notification generated when the account granted HoverPocket access; the monitor explicitly excludes that message type.
