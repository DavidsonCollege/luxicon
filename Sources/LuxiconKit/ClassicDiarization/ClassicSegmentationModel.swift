// Copyright 2025 Ivan Digital
// Licensed under the Apache License, Version 2.0. You may obtain a copy of
// the License at http://www.apache.org/licenses/LICENSE-2.0 (full text in
// THIRD-PARTY-NOTICES.md). Distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND.
//
// Vendored from soniqo/speech-swift @ e403d0b (Apache-2.0)
// Sources: Sources/SpeechVAD/Segmentation.swift, Sources/SpeechVAD/WeightLoading.swift,
//          and SegmentationConfig from Sources/SpeechVAD/Configuration.swift
// Modified by Luxicon: types renamed with a `Classic` prefix; the three sources
// combined into one file; SegmentationConfig made internal; MLXCommon's
// WeightLoadingError replaced by ClassicDiarizationError (MLXCommon is not a
// public product of speech-swift). Logic unchanged.

import Foundation
import MLX
import MLXNN

/// PyanNet segmentation model: SincNet → BiLSTM → Linear → Classifier.
///
/// Produces per-frame powerset class probabilities for up to 3 speakers.
/// Output classes (7): non-speech, spk1, spk2, spk3, spk1+2, spk1+3, spk2+3
///
/// Weight keys at model level:
/// ```
/// sincnet.{conv, norm, wav_norm}.*
/// lstm_fwd.layers.{i}.{Wx, Wh, bias}
/// lstm_bwd.layers.{i}.{Wx, Wh, bias}
/// linear.{0,1}.{weight, bias}
/// classifier.{weight, bias}
/// ```
class ClassicSegmentationModel: Module {
    let config: ClassicSegmentationConfig

    let sincnet: ClassicSincNet

    /// Forward and backward LSTM stacks (at top level for weight loading)
    @ModuleInfo(key: "lstm_fwd") var lstmFwd: ClassicLSTMStack
    @ModuleInfo(key: "lstm_bwd") var lstmBwd: ClassicLSTMStack

    let linear: [Linear]
    let classifier: Linear

    init(config: ClassicSegmentationConfig = .default) {
        self.config = config

        self.sincnet = ClassicSincNet(config: config)

        // Build LSTM stacks
        let sincnetOutputDim = config.sincnetFilters.last!  // 60
        var fwdLayers = [ClassicLSTMLayer]()
        var bwdLayers = [ClassicLSTMLayer]()
        for i in 0 ..< config.lstmNumLayers {
            let inSize = (i == 0) ? sincnetOutputDim : config.lstmHiddenSize * 2
            fwdLayers.append(ClassicLSTMLayer(inputSize: inSize, hiddenSize: config.lstmHiddenSize))
            bwdLayers.append(ClassicLSTMLayer(inputSize: inSize, hiddenSize: config.lstmHiddenSize))
        }

        // Linear layers with LeakyReLU
        let lstmOutputDim = config.lstmHiddenSize * 2  // 256 (bidirectional)
        var layers = [Linear]()
        for i in 0 ..< config.linearNumLayers {
            let inDim = (i == 0) ? lstmOutputDim : config.linearHiddenSize
            layers.append(Linear(inDim, config.linearHiddenSize))
        }
        self.linear = layers

        self.classifier = Linear(config.linearHiddenSize, config.numClasses)

        // Set @ModuleInfo properties after all stored properties
        self._lstmFwd.wrappedValue = ClassicLSTMStack(layers: fwdLayers)
        self._lstmBwd.wrappedValue = ClassicLSTMStack(layers: bwdLayers)
    }

    /// Run segmentation on audio.
    /// - Parameter waveform: `[batch, 1, samples]` (mono, 16kHz)
    /// - Returns: `[batch, num_frames, num_classes]` class probabilities
    func callAsFunction(_ waveform: MLXArray) -> MLXArray {
        // ClassicSincNet: [B, 1, T] → [B, 60, ~293]
        var x = sincnet(waveform)

        // Transpose for LSTM: [B, 60, L] → [B, L, 60]
        x = x.transposed(0, 2, 1)

        // BiLSTM: [B, L, 60] → [B, L, 256]
        x = classicRunBiLSTM(x, fwd: lstmFwd, bwd: lstmBwd)

        // Linear layers with LeakyReLU
        for layer in linear {
            x = layer(x)
            x = classicLeakyRelu(x)
        }

        // Classifier + softmax: [B, L, 7]
        x = classifier(x)
        x = softmax(x, axis: -1)

        return x
    }

    /// Extract speech probability from powerset output.
    ///
    /// Classes: [non-speech, spk1, spk2, spk3, spk1+2, spk1+3, spk2+3]
    /// Speech probability = 1 - P(non-speech).
    ///
    /// - Parameter posteriors: `[batch, frames, 7]`
    /// - Returns: `[batch, frames]` speech probability per frame
    static func speechProbability(from posteriors: MLXArray) -> MLXArray {
        let nonSpeech = posteriors[0..., 0..., 0]
        return 1.0 - nonSpeech
    }
}

/// Weight loading for the PyanNet segmentation model.
///
/// Loads from safetensors files produced by `scripts/convert_pyannote.py`.
/// The conversion script pre-computes sinc filters and transposes Conv1d weights,
/// so loading is a straightforward parameter tree update.
enum ClassicSegmentationWeightLoader {

    /// Load weights from a directory containing model.safetensors.
    static func loadWeights(
        model: ClassicSegmentationModel,
        from directory: URL
    ) throws {
        let weightsURL = directory.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw ClassicDiarizationError.noWeightsFound(directory)
        }

        let weights = try MLX.loadArrays(url: weightsURL)

        // The conversion script produces keys matching our module structure directly.
        // Use ModuleParameters.unflattened to build the nested parameter tree.
        let parameters = ModuleParameters.unflattened(weights)

        // Apply to model
        try model.update(parameters: parameters, verify: .noUnusedKeys)

        // Evaluate all parameters to ensure they're materialized
        MLX.eval(model.parameters())
    }
}

/// Model configuration for pyannote PyanNet segmentation.
struct ClassicSegmentationConfig: Sendable {
    /// Audio sample rate in Hz
    let sampleRate: Int

    /// SincNet filter counts per layer
    let sincnetFilters: [Int]
    /// SincNet kernel sizes per layer
    let sincnetKernelSizes: [Int]
    /// SincNet strides per layer
    let sincnetStrides: [Int]
    /// SincNet max-pool kernel sizes per layer
    let sincnetPoolSizes: [Int]

    /// LSTM hidden size (per direction; output is 2x for bidirectional)
    let lstmHiddenSize: Int
    /// Number of LSTM layers
    let lstmNumLayers: Int

    /// Linear layer hidden size
    let linearHiddenSize: Int
    /// Number of linear layers (before classifier)
    let linearNumLayers: Int

    /// Number of output classes (powerset)
    let numClasses: Int

    /// Default configuration for pyannote/segmentation-3.0
    static let `default` = ClassicSegmentationConfig(
        sampleRate: 16000,
        sincnetFilters: [80, 60, 60],
        sincnetKernelSizes: [251, 5, 5],
        sincnetStrides: [10, 1, 1],
        sincnetPoolSizes: [3, 3, 3],
        lstmHiddenSize: 128,
        lstmNumLayers: 4,
        linearHiddenSize: 128,
        linearNumLayers: 2,
        numClasses: 7
    )
}
