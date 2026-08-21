# Voice input spike

## Decision

Do not ship voice input yet. The safe first implementation target is macOS 26+
using Apple's `SpeechAnalyzer` + `SpeechTranscriber` and `AVAudioEngine`; keep
the current macOS 13+ app unchanged until the offline/privacy gate passes.

Evidence from Apple's current documentation:

- `SpeechAnalyzer` and `SpeechTranscriber` were introduced on macOS 26.
- `SpeechTranscriber` exposes availability, supported locales, installed
  locales, and an async results stream.
- `SpeechAnalyzer` exposes audio-format negotiation, preparation, streaming
  analysis, finalization, and cancellation.
- Speech assets are managed through the Speech framework's `AssetInventory`.

Primary references:

- <https://developer.apple.com/documentation/speech/speechanalyzer>
- <https://developer.apple.com/documentation/speech/speechtranscriber>
- <https://developer.apple.com/documentation/speech/assetinventory>

## Proposed MVP boundary

```text
explicit hotkey press
  -> visible recording state
  -> AVAudioEngine capture
  -> SpeechTranscriber for ru-RU/en-US
  -> final text preview
  -> explicit insertion into the focused non-secure field
```

Requirements:

- opt-in microphone permission; no background recording;
- secure/password fields are denied before capture and insertion;
- no transcript, audio, or selected text in logs/history by default;
- no automatic fallback to a network recognizer;
- cancellation always stops capture and discards volatile content;
- language chosen explicitly first; auto-language can be a later experiment.

## Acceptance gate

Measure on the owner's Mac for both Russian and English:

| Check | Pass condition |
|---|---|
| Offline proof | Works with outbound network denied after required assets are installed |
| Locale support | `ru-RU` and `en-US` are reported supported and available |
| Accuracy | WER measured on a fixed, owner-approved corpus; threshold chosen before release |
| Responsiveness | Cold start, first partial, final result, and cancellation latency recorded |
| Footprint | Installed asset size and peak RAM recorded |
| Safety | Password fields, app-profile denial, cancellation, and transcript-free logs tested |

## Compatibility choice still needed

For macOS 13–15, legacy `SFSpeechRecognizer` may depend on server processing and
must not be used until that behavior is separately verified. A bundled third-party
offline engine would increase app/model size and creates a license/update surface.
Therefore the recommended first release is a guarded macOS 26+ feature, not an
unverified fallback.

No microphone entitlement, model download, runtime code, or dependency was added
in this spike.
