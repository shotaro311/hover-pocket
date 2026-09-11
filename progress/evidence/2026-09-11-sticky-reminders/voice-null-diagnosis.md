# Voice verifier null reminder regression

2026-09-11 current debug executable, lldb launch with --verify-voice-foundation.

Observed before secondary executor SIGSEGV:

`NSInvalidArgumentException: +[NSJSONSerialization dataWithJSONObject:options:error:]: Invalid top-level type in JSON write`

Stack: `CapabilityCanonicalJSON.data` -> `OpenAIRealtimeMacOSCapabilityRuntime.upsertStickyNote` -> `executeOnce`.

Cause: new Voice output conversion passed `.null` as the top-level value into the canonical JSON writer. That writer supports JSON containers, not scalar fragments. Objective-C exception escaped the Swift async execution; later WebKit callbacks exposed the invalid executor state seen in the crash reports.

Fix: switch verified reminder output explicitly. Objects pass through canonical object conversion; null maps directly to NSNull. Missing/invalid reminder output throws. Shared canonical JSON behavior is unchanged. Existing Voice regression now also asserts that creating a note without a reminder returns explicit null.

Build and runtime verification after this fix are delegated to the parent agent.
