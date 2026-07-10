import Foundation
import Qwen3Chat

/// Why Apple Intelligence can (or can't) run on this device — in terms the
/// UI can turn into user-actionable copy. Availability-neutral so views and
/// error paths never need FoundationModels imports or OS gates.
public enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// OS predates the FoundationModels framework (needs iOS 26 / macOS 26).
    case osTooOld
    /// Hardware can never run Apple Intelligence (pre-iPhone 15 Pro class).
    case deviceNotEligible
    /// Eligible device, but Apple Intelligence is off in system Settings.
    case notEnabled
    /// Enabled, but the OS is still downloading the model.
    case modelNotReady
}

/// Errors a summarization backend can surface beyond transport failures.
public enum SummaryBackendError: Error, Equatable {
    /// The backend's content safety system refused the transcript
    /// (Apple Intelligence guardrails).
    case declined
    /// The backend has no app-managed model directory (OS-owned weights).
    case noModelDirectory
    /// Apple Intelligence can't run here; the status says why.
    case unavailable(AppleIntelligenceStatus)
}

/// Namespace for querying Apple Intelligence without constructing a chat.
public enum AppleIntelligence {
    /// Current availability, safe to call on any OS version.
    public static var status: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return .osTooOld }
        return AppleIntelligenceChat.status
        #else
        return .osTooOld
        #endif
        }
}

#if canImport(FoundationModels)
import FoundationModels

/// `SummaryChat` over the OS-managed Apple Intelligence on-device model.
/// No download and no cache directory — the OS owns the weights; the app's
/// only job is checking availability and staying inside the context window.
@available(iOS 26.0, macOS 26.0, *)
public final class AppleIntelligenceChat: SummaryChat {
    private let model: SystemLanguageModel

    public init() throws {
        // Relaxed guardrails: summarizing the user's own recorded
        // conversation is exactly the content-transformation case the
        // permissive mode exists for. Refusals can still happen and are
        // surfaced as `.declined`.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else {
            throw SummaryBackendError.unavailable(Self.status)
        }
        self.model = model
    }

    static var status: AppleIntelligenceStatus {
        switch SystemLanguageModel(guardrails: .permissiveContentTransformations).availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    /// The model's context window in tokens (8,192 on OS 27, 4,096 before).
    public var contextTokens: Int { model.contextSize }

    public func generate(messages: [ChatMessage], sampling: ChatSamplingConfig) async throws -> String {
        let instructions = messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system }
            .map(\.content).joined(separator: "\n\n")
        // Fresh session per request: summarization is an isolated task, and
        // carried-over history would only eat the small context window.
        let session = LanguageModelSession(
            model: model,
            instructions: instructions.isEmpty ? nil : instructions)
        let options = GenerationOptions(
            temperature: Double(sampling.temperature),
            maximumResponseTokens: sampling.maxTokens)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { throw SummaryBackendError.declined }
            throw error
        }
    }
}
#endif
