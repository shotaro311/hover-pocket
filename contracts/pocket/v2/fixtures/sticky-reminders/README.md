# macOS sticky reminder capability v2

`sticky.note.upsert@2` and `sticky.note.get@2` extend the v1 output with a required nullable `reminder`. The descriptor document format remains v1; operation versions are 2. Windows is unavailable and keeps its v1 surface.

- Input omission preserves an existing reminder; input null clears it. A non-null reminder sets a future absolute `scheduledAt` and IANA `timeZone`, resetting acknowledgment. The entire note and reminder persist atomically.
- `scheduledAt` requires RFC3339 with seconds, optional 1–3 fractional digits, and `Z` or a numeric UTC offset. Runtime also validates the time zone and rejects past scheduling. Output normalizes the instant to UTC and retains the display time zone.
- `acknowledgedAt` belongs to the host; input cannot set it. Output null means the reminder is not acknowledged.
- v1 input/output schemas remain unchanged, and v1 writes preserve existing reminders. No migration of existing callers is required.
- Broker permission `sticky.write`, approval, idempotency and readback remain mandatory. v2 upsert reads through v2 get and compares the complete reminder.
- Voice exposes this as the existing `sticky_note_upsert` tool with an optional nullable reminder. Existing calls without the field remain valid. The current dynamic-tool bridge passes optional fields unchanged.

Run `python3 script/verify_sticky_reminder_contracts.py`. The same check runs from the v2 contract verifier. Store, capability, and Voice runtime checks are separate macOS executable verifiers.
