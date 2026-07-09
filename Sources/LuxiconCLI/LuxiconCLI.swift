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
              --enroll Name=voice.wav   enroll a known voice (repeatable)
              --out <dir>               write transcript.md + transcript.json here
              --title <title>           meeting title (default: file name)
              --vocab "a, b, c"         names/terms to ground transcription in
              --vocab-file terms.json   vocabulary JSON ({"terms":[{"term":...,"soundsLike":[...]}]})
              --engine parakeet|qwen3   ASR engine (qwen3 supports --vocab context injection)
            """)
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
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--enroll":
                let spec = args[i + 1]
                guard let eq = spec.firstIndex(of: "=") else {
                    throw ValidationError("--enroll expects Name=file.wav, got '\(spec)'")
                }
                enrollSpecs.append((String(spec[..<eq]), String(spec[spec.index(after: eq)...])))
                i += 2
            case "--out": outDir = args[i + 1]; i += 2
            case "--title": title = args[i + 1]; i += 2
            case "--vocab":
                vocabulary += args[i + 1].split(separator: ",").map {
                    VocabularyEntry(term: $0.trimmingCharacters(in: .whitespaces))
                }
                i += 2
            case "--vocab-file":
                let data = try Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
                vocabulary += try VocabularyJSON.parse(data)
                i += 2
            case "--engine":
                guard let parsed = ASREngine(rawValue: args[i + 1]) else {
                    throw ValidationError("--engine expects parakeet or qwen3")
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
            enrollments: enrollments
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
