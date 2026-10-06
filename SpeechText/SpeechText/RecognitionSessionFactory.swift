// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Speech

// App target only: it names `AppleRecognitionSession`, which needs the Speech framework,
// and the protocol and the cloud sessions it builds stay in the test bundle without it.

/// The one place that knows which tier a configuration selects. Streaming is a
/// composition: `StreamingRecognitionSession` wraps a `BatchRecognitionSession` and
/// hands over to it when the stream fails or returns nothing.
func makeRecognitionSession(configuration: RecordingConfiguration,
                            writer: AudioBufferWriter,
                            recognizer: SFSpeechRecognizer?) -> RecognitionSession {
    switch configuration.provider {
    case .apple:
        return AppleRecognitionSession(recognizer: recognizer, locale: configuration.locale,
                                       contextualStrings: configuration.liveVocabulary)
    case .groq, .elevenlabs, .openai, .local:
        let batch = BatchRecognitionSession(provider: makeBatchTranscriber(configuration: configuration),
                                            writer: writer, language: configuration.cloudLanguage)
        if let streamer = makeStreamingTranscriber(configuration: configuration) {
            // A reconnect makes the same provider again, from the same snapshot of the
            // settings — a dropped stream never comes back as a different engine.
            return StreamingRecognitionSession(provider: streamer, writer: writer,
                                               languages: configuration.languages, fallback: batch,
                                               reconnect: { makeStreamingTranscriber(configuration: configuration) },
                                               meter: configuration.streamMeter)
        }
        return batch
    }
}
