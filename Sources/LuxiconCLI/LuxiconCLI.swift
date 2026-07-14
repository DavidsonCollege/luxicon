import Foundation
import LuxiconKit
import AudioCommon

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
                   luxicon-cli summarize <transcript.json> [--backend qwen35|gemma4|apple]
                                         [--context "Name=text"] [--context-file "Name=path"]
                                         [--chunk-chars <n>] [--second-pass]
              --enroll Name=voice.wav   enroll a known voice (repeatable)
              --out <dir>               write transcript.md + transcript.json here
              --title <title>           meeting title (default: file name)
              --vocab "a, b, c"         names/terms to ground transcription in
              --vocab-file terms.json   vocabulary JSON ({"terms":[{"term":...,"soundsLike":[...]}]})
              --engine parakeet         ASR engine (Parakeet TDT, CoreML)
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
            var modelId: String?
            var modelDir: String?
            var chunkChars: Int?
            var backend: MeetingSummarizer.Backend = .qwen35
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
                case "--model": modelId = args[j + 1]
                case "--model-dir": modelDir = args[j + 1]  // local dir with int4/ inside
                case "--chunk-chars":
                    // Debug override of the per-pass budget, to exercise split
                    // summarization on short transcripts.
                    guard let n = Int(args[j + 1]), n > 0 else {
                        throw ValidationError("--chunk-chars expects a positive integer")
                    }
                    chunkChars = n
                case "--backend":
                    guard let b = MeetingSummarizer.Backend(rawValue: args[j + 1]) else {
                        throw ValidationError("--backend expects qwen35, gemma4, or apple")
                    }
                    backend = b
                default: throw ValidationError("unknown option \(args[j])")
                }
                j += 2
            }

            if backend == .appleIntelligence, AppleIntelligence.status != .available {
                throw ValidationError("Apple Intelligence is not available here "
                    + "(\(AppleIntelligence.status)) — needs macOS 26+ with Apple Intelligence on")
            }
            print(backend == .appleIntelligence
                ? "Using the Apple Intelligence system model…"
                : "Loading summarizer model (downloads on first run)…")
            let summarizer = try await MeetingSummarizer.load(
                backend: backend,
                modelId: modelId,
                cacheDir: modelDir.map { URL(fileURLWithPath: $0) },
                offlineMode: modelDir != nil,
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
                    throw ValidationError("--engine expects parakeet")
                }
                engine = parsed
                i += 2
            default: throw ValidationError("unknown option \(args[i])")
            }
        }

        let sr = MeetingPipeline.sampleRate
        print("Loading models (downloads on first run, engine: \(engine.rawValue))...")
        let pipeline = try await MeetingPipeline.load(engine: engine) { p, stage in
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

        let start = Date()
        let transcript = try pipeline.process(
            audio: audio,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            date: Date(),
            enrollments: enrollments,
            vocabulary: vocabulary
        ) { p, stage in
            print(String(format: "  [%3.0f%%] %@", p * 100, stage))
        }
        let elapsed = Date().timeIntervalSince(start)
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
