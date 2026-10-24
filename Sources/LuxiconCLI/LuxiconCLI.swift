import Foundation
import LuxiconKit
import AudioCommon
import SpeechVAD

/// Development harness: process a recording from the command line.
///
///   luxicon-cli meeting.wav [--enroll Name=voice.wav ...] [--out dir] [--title "Weekly 1:1"]
@main
struct LuxiconCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty, !["-h", "--help"].contains(args[0]) else {
            print("""
            usage: luxicon-cli <audio-file> [options]
                   luxicon-cli push <file.json> --token <pairing token>
                   luxicon-cli captions <audio-file> --seconds <n>
                   luxicon-cli summarize <transcript.json> [--context "Name=text"]
                                         [--context-file "Name=path"]
                                         [--chunk-chars <n>] [--second-pass]
              --enroll Name=voice.wav   enroll a known voice (repeatable)
              --out <dir>               write transcript.md + transcript.json here
              --title <title>           meeting title (default: file name)
              --vocab "a, b, c"         names/terms to ground transcription in
              --vocab-file terms.json   vocabulary JSON ({"terms":[{"term":...,"soundsLike":[...]}]})
              --engine parakeet|appleSpeech|cohere
                                        ASR engine (Parakeet TDT, Apple SpeechTranscriber, or
                                        Cohere Transcribe — ~1.6 GB download, ~4 GB memory)
              --save-diarization f.json write the diarization result (A/B: share turns across runs)
              --load-diarization f.json reuse a saved diarization instead of diarizing
              --diarizer classic|v2     diarization pipeline (default classic; v2 is opt-in, validation only)
              --cluster-threshold <f>   v2 clustering threshold (default 0.4; lower = fewer merges)
              --diarize-only            stop after diarization (needs --save-diarization)
              --turn-log f.jsonl        write one {start,end,speakerId,text} JSON line per turn
            """)
            return
        }

        // Subcommand: run the on-device summarizer over an exported transcript
        // JSON (or a raw MeetingTranscript) with optional participant context.
        // Verifies real model output on the Mac without round-tripping a phone.
        //   luxicon-cli summarize <transcript.json> [--context "Name=text"]
        //                                           [--context-file "Name=path"]
        if args[0] == "summarize" {
            guard args.count >= 2 else {
                throw ValidationError("usage: luxicon-cli summarize <transcript.json> "
                    + "[--context \"Name=text\" ...] [--context-file \"Name=path\" ...]")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            struct Envelope: Decodable { let transcript: MeetingTranscript }
            let transcript: MeetingTranscript
            if let env = try? decoder.decode(Envelope.self, from: data) {
                transcript = env.transcript
            } else {
                transcript = try decoder.decode(MeetingTranscript.self, from: data)
            }

            func nameEq(_ spec: String) throws -> (String, String) {
                guard let eq = spec.firstIndex(of: "=") else {
                    throw ValidationError("expected Name=value, got '\(spec)'")
                }
                return (String(spec[..<eq]), String(spec[spec.index(after: eq)...]))
            }
            var context: [SummaryParticipant] = []
            var secondPass = false
            var chunkChars: Int?
            var j = 2
            while j < args.count {
                if args[j] == "--second-pass" { secondPass = true; j += 1; continue }
                guard args.indices.contains(j + 1) else {
                    throw ValidationError("\(args[j]) expects a value")
                }
                switch args[j] {
                case "--context":
                    let (n, c) = try nameEq(args[j + 1])
                    context.append(SummaryParticipant(name: n, context: c))
                case "--context-file":
                    let (n, p) = try nameEq(args[j + 1])
                    let text = try String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8)
                    context.append(SummaryParticipant(name: n, context: text))
                case "--chunk-chars":
                    // Debug override of the per-pass budget, to exercise split
                    // summarization on short transcripts.
                    guard let n = Int(args[j + 1]), n > 0 else {
                        throw ValidationError("--chunk-chars expects a positive integer")
                    }
                    chunkChars = n
                default: throw ValidationError("unknown option \(args[j])")
                }
                j += 2
            }

            guard AppleIntelligence.status == .available else {
                throw ValidationError("Apple Intelligence is not available here "
                    + "(\(AppleIntelligence.status)) — summarization needs macOS 26+ "
                    + "with Apple Intelligence on")
            }
            print("Using the Apple Intelligence system model…")
            let summarizer = try await MeetingSummarizer.load(
                transcriptCharBudget: chunkChars
            ) { p, stage in
                print(String(format: "  [%3.0f%%] %@", p * 100, stage))
            }
            let isEmpty = MeetingSummarizer.isEmpty(transcript)
            print("Transcript: \(transcript.turns.count) turns, "
                + "empty=\(isEmpty), context=\(context.count) participant(s)\n")
            let result = try await summarizer.summarize(transcript, context: context)
            print("=== LIST LABEL (\(result.headline.count) chars) ===")
            print(result.headline)
            if secondPass {
                let refined = try await summarizer.refineLabel(
                    headline: result.headline, overview: result.overview)
                print("\n=== REFINED LABEL (\(refined.count) chars) ===")
                print(refined)
            }
            print("\n=== OVERVIEW ===")
            print(result.overview)
            return
        }

        // Subcommand: feed the first N seconds through the live-caption
        // engine in 100 ms chunks and print the final committed text.
        //   luxicon-cli captions <audio> --seconds <n>
        if args[0] == "captions" {
            guard args.count >= 4, args[2] == "--seconds", let seconds = Double(args[3]), seconds > 0 else {
                throw ValidationError("usage: luxicon-cli captions <audio-file> --seconds <n>")
            }
            let sr = MeetingPipeline.sampleRate
            let audio = try AudioFileLoader.load(url: URL(fileURLWithPath: args[1]), targetSampleRate: sr)
            let samples = Array(audio.prefix(Int(seconds * Double(sr))))
            let engine = try await LiveTranscriptionEngine.load()
            try engine.startSession()
            var committed = ""
            let chunk = sr / 10
            var lo = 0
            while lo < samples.count {
                let hi = min(lo + chunk, samples.count)
                if let delta = engine.push(Array(samples[lo..<hi]))?.committedDelta { committed += delta }
                lo = hi
            }
            if let delta = engine.finish()?.committedDelta { committed += delta }
            print(committed.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        // Subcommand: push an exported JSON to a LAN listener (tests the
        // same code path the iPhone app uses).
        if args[0] == "push" {
            guard args.count >= 2 else { throw ValidationError("usage: luxicon-cli push <file.json> --token <token>") }
            let file = URL(fileURLWithPath: args[1])
            guard let ti = args.firstIndex(of: "--token"), args.indices.contains(ti + 1) else {
                throw ValidationError("push requires --token <pairing token>")
            }
            let payload = try Data(contentsOf: file)
            var host: String? = nil
            if let hi = args.firstIndex(of: "--host"), args.indices.contains(hi + 1) { host = args[hi + 1] }
            print(host.map { "Connecting to \($0)…" } ?? "Discovering listener via Bonjour…")
            try await LuxiconSync.push(
                filename: file.lastPathComponent, payload: payload, token: args[ti + 1], host: host)
            print("Pushed \(file.lastPathComponent) (\(payload.count) bytes)")
            return
        }

        let audioPath = args.removeFirst()
        var enrollSpecs: [(String, String)] = []
        var outDir: String?
        var title: String?
        var vocabulary: [VocabularyEntry] = []
        var engine: ASREngine = .parakeet
        var saveDiarization: String?
        var loadDiarization: String?
        var diarizeOnly = false
        var diarizerName = "classic"
        var clusterThreshold: Float?
        var turnLogPath: String?

        func value(after flag: String, at i: Int) throws -> String {
            guard args.indices.contains(i + 1) else {
                throw ValidationError("\(flag) expects a value")
            }
            return args[i + 1]
        }

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--enroll":
                let spec = try value(after: "--enroll", at: i)
                guard let eq = spec.firstIndex(of: "=") else {
                    throw ValidationError("--enroll expects Name=file.wav, got '\(spec)'")
                }
                enrollSpecs.append((String(spec[..<eq]), String(spec[spec.index(after: eq)...])))
                i += 2
            case "--out": outDir = try value(after: "--out", at: i); i += 2
            case "--title": title = try value(after: "--title", at: i); i += 2
            case "--vocab":
                vocabulary += try value(after: "--vocab", at: i).split(separator: ",").map {
                    VocabularyEntry(term: $0.trimmingCharacters(in: .whitespaces))
                }
                i += 2
            case "--vocab-file":
                let path = try value(after: "--vocab-file", at: i)
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                vocabulary += try VocabularyJSON.parse(data)
                i += 2
            case "--engine":
                guard let parsed = ASREngine(rawValue: try value(after: "--engine", at: i)) else {
                    throw ValidationError("--engine expects parakeet, appleSpeech or cohere")
                }
                engine = parsed
                i += 2
            case "--save-diarization": saveDiarization = try value(after: args[i], at: i); i += 2
            case "--load-diarization": loadDiarization = try value(after: args[i], at: i); i += 2
            case "--turn-log": turnLogPath = try value(after: args[i], at: i); i += 2
            case "--diarize-only": diarizeOnly = true; i += 1
            case "--diarizer": diarizerName = try value(after: args[i], at: i); i += 2
            case "--cluster-threshold":
                let raw = try value(after: args[i], at: i)
                guard let f = Float(raw) else { throw ValidationError("--cluster-threshold expects a number, got '\(raw)'") }
                clusterThreshold = f; i += 2
            default: throw ValidationError("unknown option \(args[i])")
            }
        }

        guard let diarization = DiarizationMethod(cliValue: diarizerName, threshold: clusterThreshold) else {
            throw ValidationError("--diarizer expects classic or v2")
        }
        let sr = MeetingPipeline.sampleRate
        if diarizeOnly {
            guard let saveDiarization else { throw ValidationError("--diarize-only needs --save-diarization") }
            let diarizer = try await MeetingPipeline.loadDiarizer(method: diarization)
            let audio = try AudioFileLoader.load(url: URL(fileURLWithPath: audioPath), targetSampleRate: sr)
            let t0 = Date()
            let result = MeetingPipeline.diarizeOnly(diarizer, audio: audio)
            let elapsed = Date().timeIntervalSince(t0)
            try JSONEncoder().encode(DiarizationFile(result)).write(to: URL(fileURLWithPath: saveDiarization))
            print(String(format: "Diarized %d segments, %d speakers in %.1fs",
                         result.segments.count, result.numSpeakers, elapsed))
            return
        }
        var precomputed = try loadDiarization.map {
            try JSONDecoder().decode(DiarizationFile.self, from: Data(contentsOf: URL(fileURLWithPath: $0))).result
        }

        print("Loading models (downloads on first run, engine: \(engine.rawValue))...")
        let pipeline = try await MeetingPipeline.load(engine: engine, diarization: diarization) { p, stage in
            print(String(format: "  [%3.0f%%] %@", p * 100, stage))
        }

        var enrollments: [VoiceEnrollment] = []
        for (name, path) in enrollSpecs {
            let voice = try AudioFileLoader.load(url: URL(fileURLWithPath: path), targetSampleRate: sr)
            enrollments.append(VoiceEnrollment(name: name, embedding: pipeline.embedVoice(audio: voice)))
            print("Enrolled \(name) from \(path)")
        }

        let url = URL(fileURLWithPath: audioPath)
        let audio = try AudioFileLoader.load(url: url, targetSampleRate: sr)
        print("Loaded \(audioPath): \(TranscriptExport.timestamp(Double(audio.count) / Double(sr)))")

        // A full run that also saves the diarization diarizes up front (same
        // diarize + cap path as `process`), saves it, and hands it back in.
        if let saveDiarization, precomputed == nil {
            let result = MeetingPipeline.diarizeOnly(pipeline.diarizer, audio: audio)
            try JSONEncoder().encode(DiarizationFile(result)).write(to: URL(fileURLWithPath: saveDiarization))
            print("Saved diarization: \(result.segments.count) segments, \(result.numSpeakers) speakers")
            precomputed = result
        }
        var turnRecords: [TurnRecord] = []
        let start = Date()
        let transcript = try pipeline.process(
            audio: audio,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            date: Date(),
            enrollments: enrollments,
            vocabulary: vocabulary,
            progress: { p, stage in
                print(String(format: "  [%3.0f%%] %@", p * 100, stage))
            },
            precomputedDiarization: precomputed,
            onTurn: { turnRecords.append($0) }
        )
        let elapsed = Date().timeIntervalSince(start)
        if let turnLogPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let lines = try turnRecords.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: turnLogPath), atomically: true, encoding: .utf8)
        }
        let rtf = elapsed / max(transcript.duration, 0.001)
        print(String(format: "Processed in %.1fs (%.2fx real-time)\n", elapsed, rtf))

        let markdown = TranscriptExport.markdown(transcript)
        print(markdown)

        if let outDir {
            let dir = URL(fileURLWithPath: outDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try markdown.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try TranscriptExport.json(transcript).write(to: dir.appendingPathComponent("transcript.json"))
            print("Wrote \(outDir)/transcript.md and transcript.json")
        }
    }

    struct ValidationError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
