#!/usr/bin/env python3
"""Build the fictional demo library used for the Mac app's marketing screenshots.

    scripts/mac-demo-fixture/generate.py <out dir>

Reads demo-library.json (next to this script) and writes, inside <out dir> only:

  lib/            a ~/Luxicon-style library folder: one export envelope per
                  session, in the shape TranscriptExport.json produces (iPhone
                  files without provenance; Mac files with "source": "mac" and
                  the session's id), plus a fake .sync-token
  store/          a scratch store: store.json matching Store.Persisted, with
                  the Mac-recorded sessions as ready SessionRecords
  captions.txt    text for the recording window's -simulateCaptions hook

lib/ and store/ are deleted and recreated on every run, so a recording left
behind by a screenshot run is never recovered into the next one. Point the
Debug app at them with -libraryPath <out>/lib -storePath <out>/store.
Everything in demo-library.json is invented; never put real data in it.
"""
import json
import shutil
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
# Foundation's reference date: Store.Persisted encodes dates as seconds since it.
REFERENCE = datetime(2001, 1, 1, tzinfo=timezone.utc)
WORDS_PER_SECOND = 2.6
GAP = 0.6


def refuse_real_locations(out: Path) -> None:
    home = Path.home().resolve()
    if out == home:
        sys.exit(f"refusing to write to {out}: pass a scratch directory")
    for place in (home / "Luxicon", home / "Library/Application Support/Luxicon"):
        if out == place or place in out.parents:
            sys.exit(f"refusing to write to {out}: it is inside the real library {place}")


def timed_turns(raw, speaker_ids):
    turns, t = [], 1.2
    for i, (name, text) in enumerate(raw):
        length = round(max(1.5, len(text.split()) / WORDS_PER_SECOND + 0.4), 2)
        turns.append({
            "id": i,
            "speakerId": speaker_ids[name],
            "speakerName": name,
            "start": round(t, 2),
            "end": round(t + length, 2),
            "text": text,
            "confidence": 0.94,
        })
        t += length + GAP
    return turns, round(t + 1.5, 1)


def speaker_stats(turns):
    total = sum(t["end"] - t["start"] for t in turns)
    stats = []
    for sid in sorted({t["speakerId"] for t in turns}):
        mine = [t for t in turns if t["speakerId"] == sid]
        time = sum(t["end"] - t["start"] for t in mine)
        stats.append({
            "speakerId": sid,
            "speakerName": mine[0]["speakerName"],
            "speakingTime": round(time, 2),
            "talkShare": round(time / total, 4) if total else 0,
            "turnCount": len(mine),
            "longestTurn": round(max(t["end"] - t["start"] for t in mine), 2),
        })
    return stats


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def reference_seconds(dt: datetime) -> float:
    return (dt - REFERENCE).total_seconds()


def library_filename(person: str, date: datetime, session_id: str) -> str:
    # LuxiconSync.sessionFilename: "<person> <UTC yyyy-mm-dd> <first 8 of id>.json"
    day = date.astimezone(timezone.utc).strftime("%Y-%m-%d")
    return f"{person} {day} {session_id[:8]}.json"


def envelope(transcript, summary, session_id=None, source=None) -> str:
    body = {"kind": "one-on-one", "schemaVersion": 1, "transcript": transcript}
    if summary:
        body["summary"] = summary
    if session_id:
        body["sessionId"] = session_id
        body["source"] = source
    return json.dumps(body, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1]).expanduser().resolve()
    refuse_real_locations(out)
    demo = json.loads((HERE / "demo-library.json").read_text())
    zone = ZoneInfo(demo["timeZone"])
    me = demo["myName"]
    people = {p["name"]: p for p in demo["people"]}

    lib, store = out / "lib", out / "store"
    for d in (lib, store):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)

    records = []
    for s in demo["sessions"]:
        sid = str(uuid.UUID(s["id"])).upper()
        name = s["person"]
        date = datetime.fromisoformat(s["date"]).replace(tzinfo=zone)
        # The person who speaks first is diarization speaker 0.
        order = list(dict.fromkeys(n for n, _ in s["turns"]))
        turns, duration = timed_turns(s["turns"], {n: i for i, n in enumerate(order)})
        title = f"1-on-1 with {name}"
        generated = date + timedelta(seconds=duration + 75)
        is_mac = s["source"] == "mac"
        transcript = {
            "title": title,
            "date": iso(date),
            "duration": duration,
            "turns": turns,
            "speakers": speaker_stats(turns),
        }
        summary = {"overview": s["summary"], "generatedAt": iso(generated)} if s.get("summary") else None
        filename = library_filename(name, date, sid)
        (lib / filename).write_text(envelope(
            transcript, summary, sid if is_mac else None, "mac" if is_mac else None))
        if is_mac:
            record = {
                "id": sid,
                "personId": people[name]["id"],
                "title": title,
                "date": reference_seconds(date),
                "duration": duration,
                "status": "ready",
                "transcript": {**transcript, "date": reference_seconds(date)},
                "libraryFileName": filename,
            }
            if summary:
                record["summary"] = {"overview": s["summary"], "generatedAt": reference_seconds(generated)}
            if s.get("listLabel"):
                record["listLabel"] = s["listLabel"]
            records.append((s.get("featured", False), date, record))
        print(f"{'mac   ' if is_mac else 'iphone'} {filename}  ({duration:.0f} s, {len(turns)} turns)")

    # Featured first (scripts/mac-screenshots.sh reads sessions.0), then newest first.
    records.sort(key=lambda r: (not r[0], -r[1].timestamp()))
    persisted = {
        "people": [{"id": p["id"], "name": p["name"], "context": p["context"]} for p in demo["people"]],
        "sessions": [r[2] for r in records],
        "myName": me,
        "myContext": demo["myContext"],
        "vocabularyEntries": [
            {"term": v["term"], "soundsLike": v.get("soundsLike", []),
             **({"category": v["category"]} if "category" in v else {}),
             **({"notes": v["notes"]} if "notes" in v else {})}
            for v in demo["vocabulary"]
        ],
        "aiSummariesEnabled": True,
        "summaryEngine": "appleIntelligence",
        "autoSummarize": True,
        "autoPushToMac": False,
    }
    (store / "store.json").write_text(json.dumps(persisted, indent=2))
    # A visibly fake pairing token, so Settings never shows a real one.
    (lib / ".sync-token").write_text("DEMO-TOKEN-NOT-A-REAL-KEY\n")
    (out / "captions.txt").write_text(demo["captions"] + "\n")
    featured = records[0][2]
    print(f"store: {len(persisted['people'])} people, {len(records)} Mac sessions; "
          f"featured session {featured['id']} (person {featured['personId']})")


if __name__ == "__main__":
    main()
