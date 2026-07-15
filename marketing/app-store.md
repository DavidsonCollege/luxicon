# App Store Connect listing copy

Paste-ready. Character limits noted where Apple enforces them.

## Name (30 chars max)
Luxicon

## Subtitle (30 chars max)
Private 1-on-1 transcripts

## Promotional text (170 chars max — editable without review)
Record a 1-on-1, get a speaker-labeled transcript, and keep every word on
your iPhone. No cloud. No accounts. No subscription. Free and open source.

## Description (4000 chars max, plain text)

Luxicon records your 1-on-1 meetings and turns them into speaker-labeled
transcripts — entirely on your iPhone. Audio never leaves the device. There
are no cloud services, no accounts, and no subscription. It is free, open
source, and built for managers who want a faithful record of every sit-down.

WHO SPOKE WHEN
Luxicon doesn't just transcribe — it diarizes. Every transcript is split
into speaker turns, so the record reads like a script: who said what, when,
and for how long, including each person's share of the talk time.

ENROLL YOUR VOICE ONCE
Read aloud for fifteen seconds and Luxicon stores a compact voice
fingerprint (256 numbers — never the audio). From then on, transcripts label
you by name automatically, and in a two-person meeting the other speaker is
labeled with your teammate's name. No manual tagging.

BUILT FOR THE 1-ON-1 CADENCE
Sessions are organized by person, not by date, so the running record of your
working relationship with each teammate stays in one place. Live captions
show what's being heard while you record. If the app is interrupted
mid-meeting, the recording is recovered automatically — a crash never costs
you a conversation.

YOUR VOCABULARY, YOUR WORDS
Add project names, acronyms, and jargon to your personal vocabulary, and
Luxicon grounds transcription in the words you actually use. Teammates'
names are included automatically.

EXPORT ANYWHERE, ESPECIALLY TO AI
Share any transcript as clean markdown or structured JSON — timestamped
speaker turns plus talk-time stats, formatted for the AI assistant of your
choice. Prep for the next check-in, summarize a quarter of conversations, or
draft a review from what was actually said. You choose what leaves the
device, and when.

HANDS-FREE START
"Start a one on one with Josh" works from Siri, the Shortcuts app, or the
Action button — Luxicon opens directly into the record screen.

SEND TRANSCRIPTS TO YOUR MAC
Pair once with the bundled Mac listener and every finished 1-on-1 can land
on your Mac automatically — over your local network, encrypted end to end,
ready for Claude or any MCP-capable assistant to search and summarize. No
cloud in between.

PRIVATE BY ARCHITECTURE
All speech processing runs on the Apple Neural Engine and GPU in your
iPhone. Aside from one-time speech model downloads, Luxicon makes
no network connections unless you turn them on: pair a Mac and it can send
transcripts to that Mac over your own Wi-Fi (encrypted, never the
internet); point it at a vocabulary or people-roster file URL and it will
fetch those files. Otherwise it works in airplane mode. Recordings, transcripts, and voice
fingerprints stay in the app's private on-device storage and your own
iPhone backup.

RECORD RESPONSIBLY
Recording a conversation requires consent — in many places, from everyone in
the room. Luxicon reminds you on every recording screen. Be the kind of
manager who asks first.

Luxicon is open source (MIT) from Davidson College Technology & Innovation:
https://github.com/DavidsonCollege/luxicon

Requires iOS 18 or later. A recent iPhone (A13 or newer) is recommended for
on-device transcription speed.

## Keywords (100 chars max, comma-separated, no spaces needed)
1-on-1,one on one,transcript,diarization,meeting,recorder,private,offline,manager,voice,notes

## Category
Primary: Business · Secondary: Productivity

## Age rating
4+ (no objectionable content)

## App Privacy (nutrition label)
- Data collection: **Data Not Collected** — the app has no analytics, no
  accounts, and no third-party services; the developer receives nothing.
- Network use: speech model downloads (Hugging Face, and Apple's system
  speech asset on iOS 26+ — no user data), plus three opt-in,
  user-configured connections: Mac sync on the local network, and
  vocabulary / people-roster fetches from user-supplied https URLs.
- Microphone: used to record meetings the user explicitly starts; audio is
  processed and stored on-device only.

## Support URL
https://github.com/DavidsonCollege/luxicon

## Privacy Policy URL
https://github.com/DavidsonCollege/luxicon/blob/main/docs/privacy-policy.md

## Copyright
© 2026 Davidson College

## TestFlight — Beta App Description (4000 chars max)

Luxicon turns your 1-on-1 meetings into speaker-labeled transcripts, entirely
on your iPhone. Put the phone on the table, record the conversation, and get
a script-style transcript of who said what, when, and for how long — with
talk-time stats for each person. Nothing is uploaded anywhere: transcription,
speaker separation, and voice matching all run on the device, and the app
works in airplane mode after a one-time model download.

Enroll your voice once (about fifteen seconds of reading aloud) and every
transcript labels you by name; in a two-person meeting, the other speaker is
automatically labeled with your teammate's name. Sessions are organized by
person, so each working relationship keeps a running record. Add project
names and jargon to your vocabulary and Luxicon grounds transcription in the
words you actually use. Live captions preview what's being heard while you
record, and an interrupted recording is recovered automatically on next
launch — a crash never loses a conversation.

When you need the transcript elsewhere, share it as clean markdown or
structured JSON — formatted for pasting into the AI assistant of your choice
for meeting summaries, check-in prep, or review drafting. You can also start
hands-free: "Start a one on one with Josh" works from Siri, Shortcuts, or
the Action button.

This is an early beta from Davidson College Technology & Innovation, free
and open source (https://github.com/DavidsonCollege/luxicon). Recording a
conversation requires consent — please tell the other person before you
record.

## TestFlight — What to Test (per-build notes, 4000 chars max)

### Build 11

New since build 10 — a transcription engine choice, and summaries that read
the whole meeting:

(1) Engine picker (iOS 26 only): My Voice → Transcription now offers
Automatic, Apple, and Luxicon. Record or re-transcribe the same meeting on
Apple and on Luxicon and compare transcript quality and speed. Automatic
should behave like Apple on this phone.
(2) Long-meeting summaries: summaries are now built from every part of a
long meeting instead of trimming the middle. Summarize a 45-minute-plus
recording and confirm topics from the middle of the conversation appear.
(3) Summaries run on Apple Intelligence only: the old downloaded summary
model is gone and its disk space is reclaimed automatically. If you used
summaries on an earlier build, confirm enabling them no longer offers a
download and existing summaries still display.

### Build 10

New since build 9 — people sync and a giving screen:

(1) People-roster URL sync: in the People list, point the app at a people
JSON file (same format as Export People) and confirm the roster stays in
sync on app open — names and context update, nobody is ever removed, and
the file's "me" entry lands in About You. While sync is on, context fields
should be read-only in the app.
(2) Context previews: long context on a person is now a height-capped
preview — tap it to read and edit the full text on its own screen.
(3) Giving screen: the Davidson College credit at the bottom of the root
screen opens a giving page; its links should open in Safari, not in the app.

### Build 9

New since build 8 — summaries are grounded in the transcript, plus a one-line
label in the sessions list:

(1) Session labels: in a person's Sessions list, each summarized session now
shows a short one-line topic label under the date. Generate (or regenerate) a
summary and confirm the label appears, fits on one line, and describes the
topics — with no "SUMMARY:" text or markdown leaking into it.
(2) Grounded summaries: the summary must reflect only what was actually said.
If you have background context set for yourself or the other person (Context
field on their page), confirm the summary does NOT repeat that background as if
it were discussed — record a short session about an unrelated topic and check
the summary sticks to it.
(3) Empty and short recordings: a recording with no speech should show "No
conversation recorded"; a very short one (a few sentences, like a mic test)
should show "Too short to summarize" — both immediately, without running the
summarizer model.
(4) Existing sessions keep their old summary/label until you tap Regenerate
Summary — regenerate one old session and confirm the label updates.

### Build 8

New since build 7 — a quick way to get the Mac listener onto your Mac:

(1) In My Voice → Mac sync, tap "Send installer link to your Mac" (the first row
of the section). The system share sheet should open with a link to the listener
installer. AirDrop it to your Mac (or send it via Messages/Mail) and confirm the
Mac opens the Releases page where LuxiconListener.pkg can be downloaded.
(2) Confirm the rest of the Mac sync section is unchanged: the pairing-token
field, optional Mac address, and "Push automatically after each 1-on-1" toggle
all still work as before.

### Build 7

New since build 6 — please exercise the new "off the record" control:

(1) Off the record basics: while recording, tap "Go off the record" (below Stop
& Transcribe). The screen switches to a dark "This stays between you and
<name>" state, the system microphone indicator (the orange dot) turns off, and
the timer freezes. Tap "Resume recording" to continue. Anything said while off
the record must NOT appear in the final transcript, and the elapsed time must
pick up where it left off (the off-the-record stretch isn't counted). Try going
off the record more than once in one session.
(2) Off the record vs. interruptions: go off the record, then take a phone call
or trigger Siri. When the call ends, recording must STAY paused — it must not
silently resume on its own. Only the Resume button brings it back.
(3) Lock screen / Live Activity: with a recording off the record, check that the
Lock Screen and Dynamic Island show the paused "Off the record" state instead of
a running timer, and that on resume the timer reflects real recording time (it
does not jump forward by the length of the off-the-record gap).
(4) Save/discard around it: after an off-the-record stretch, Stop & Transcribe
and Discard should both behave normally, and the transcript should contain the
on-the-record audio from before and after the gap.

### Build 6

New since build 5 — please exercise:

(1) Mac sync end-to-end: install the Mac listener (one double-click — grab
LuxiconListener.pkg from the repo's Releases page), pair with the token, and
push a session. Every session row now shows its sync state, and the session
screen has a Mac Sync section with the exact error and a Retry button when a
push fails. Try pushing with the Mac asleep: it should fail with a clear
message within ~10 seconds, never hang, and retry when you reopen the app.
(2) Interruptions: take a phone call mid-recording — the record screen shows
a paused banner and keeps recording after the call. Everything said after
the call must be in the transcript.
(3) Per-person context: add a couple of sentences about a teammate on their
page (and about yourself in My Voice), then Regenerate Summary on a session
— the summary should read as better-informed, and headlines are now short
topic lists without names.
(4) People sync/import: point My Voice → People sync at a people JSON file
(or use Import People) — syncing adds and updates people but never removes
anyone.
(5) First-run basics still matter: deny the mic permission and try to record
(should show a friendly Settings pointer, not crash); decline Local Network
on the first push and check the error explains where to fix it.

### Build 5 and earlier

To test: (1) Add a person, then enroll your voice under My Voice (~15
seconds of reading aloud) so transcripts label speakers by name. (2) Record
a short conversation — the FIRST transcription downloads ~700 MB of speech
models, so be on Wi-Fi and keep the app open for that one. After that it
works fully offline. (3) Check the transcript: speaker labels, talk-time
split, and the share button (markdown export). (4) Add a project name or
acronym under My Voice → Vocabulary and see whether it transcribes correctly
in the next recording. (5) Try "Hey Siri, start a one on one with [name] in
Luxicon."

Known limits: needs a recent iPhone (iOS 18+); transcription pauses if you
leave the app and resumes when you return (on some iOS 26 devices it
continues in the background with progress shown as a Live Activity). Always
tell the other person you're recording.

## TestFlight — Beta App Review notes
No account or sign-in exists. To exercise the app fully: add a person,
record a short spoken conversation (any two voices, or one voice reading
two parts), wait for on-device processing, and open the transcript. First
transcription downloads ~700 MB of ML models from Hugging Face; no user
data is transmitted.
