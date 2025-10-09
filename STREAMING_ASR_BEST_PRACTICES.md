# Streaming ASR Best Practices - Conformer-CTC Text Erasure Issue

## Research Request for ChatGPT

**Context**: We're using NVIDIA RIVA ASR with Conformer-CTC streaming model. The transcription shows **text erasure** - partials build up then suddenly reset/backtrack.

**Question for Research**:
> What are the industry best practices for handling streaming ASR results from sliding-window models like Conformer-CTC? Should the client accumulate results server-side, or does the ASR service send cumulative transcripts? How do Google Speech-to-Text, AWS Transcribe, and Azure Speech handle this?

---

## Problem Statement

### Observed Behavior

```
[10:34:02 PM] Partial: "it should be connected again and"
[10:34:03 PM] Partial: "it s"  ← TEXT ERASURE!
[10:34:03 PM] Partial: "it s" (repeated 11 times)
[10:34:05 PM] Partial: "it s and we should be transcribing something"
```

**Issue**: The beginning "it should be connected again" got erased and replaced with "it s".

### Root Cause

**Conformer-CTC Streaming uses a sliding window:**
1. Model processes audio in overlapping windows
2. Each partial result is the "current best hypothesis" for the **current window only**
3. As window slides forward, earlier context can be revised or dropped
4. **Results are NOT cumulative** - each partial replaces the previous one

This is fundamentally different from models like:
- Parakeet RNNT (cumulative)
- Whisper (batch processing, inherently cumulative)
- Traditional RNN-T (maintains full context)

---

## Industry Approaches

### 1. **Google Cloud Speech-to-Text**

**Approach**: Server-side accumulation with `stability` scores

```json
{
  "results": [{
    "alternatives": [{
      "transcript": "how old is the Brooklyn Bridge",  // CUMULATIVE
      "confidence": 0.98745,
      "words": [...]
    }],
    "stability": 0.9,
    "isFinal": false
  }]
}
```

**Key Features:**
- `stability` (0.0-1.0): How likely this partial will stay the same
- Low stability → text may change
- High stability → text is locked in
- **Transcripts are cumulative** - server handles accumulation

**References:**
- https://cloud.google.com/speech-to-text/docs/basics#streaming-responses
- https://cloud.google.com/speech-to-text/docs/async-recognize#speech-async-recognize-python

---

### 2. **AWS Transcribe Streaming**

**Approach**: Cumulative transcripts with `IsPartial` flag

```json
{
  "Transcript": {
    "Results": [{
      "Alternatives": [{
        "Transcript": "how old is the Brooklyn Bridge",  // CUMULATIVE
        "Items": [...]
      }],
      "IsPartial": true
    }]
  }
}
```

**Key Features:**
- Results are **cumulative by default**
- Server maintains full session transcript
- Client just displays whatever arrives
- **No client-side accumulation needed**

**References:**
- https://docs.aws.amazon.com/transcribe/latest/dg/streaming.html
- https://docs.aws.amazon.com/transcribe/latest/dg/how-streaming.html

---

### 3. **Azure Cognitive Services Speech**

**Approach**: Cumulative results with `Reason` field

```json
{
  "RecognitionStatus": "Success",
  "DisplayText": "how old is the Brooklyn Bridge",  // CUMULATIVE
  "Offset": 1300000,
  "Duration": 25700000,
  "ResultId": "...",
  "Reason": "RecognizingSpeech"  // or "RecognizedSpeech" for final
}
```

**Key Features:**
- `RecognizingSpeech` = partial result (cumulative)
- `RecognizedSpeech` = final result (cumulative)
- Server handles accumulation
- Client displays results as-is

**References:**
- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech
- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/get-started-speech-to-text

---

### 4. **AssemblyAI Real-Time Transcription**

**Approach**: Client-side accumulation with word-level diffs

```json
{
  "message_type": "PartialTranscript",
  "text": "hello world",
  "words": [...],
  "created": "2023-01-01T00:00:00.000Z"
}
```

**Key Features:**
- Partials are **NOT cumulative** (like Conformer-CTC!)
- Client must accumulate
- Provides word-level timestamps for accurate merging
- Finals reset the accumulation

**References:**
- https://www.assemblyai.com/docs/walkthroughs#real-time-transcription
- https://github.com/AssemblyAI/assemblyai-python-sdk

**This is similar to our Conformer-CTC behavior!**

---

## NVIDIA RIVA Documentation

### Official Guidance

**From RIVA Streaming ASR docs:**
> "Streaming recognition returns interim results as the audio is being processed. The `is_final` flag indicates when a result is finalized and will not change."

**Key Points:**
- RIVA makes NO guarantee about cumulative transcripts
- Each result is the "current best hypothesis"
- Client is responsible for accumulation if needed

**Quote from RIVA ASR Guide:**
> "For streaming recognition, interim results may be revised as more audio context becomes available. Applications should handle non-monotonic transcript updates."

**Translation**: RIVA can and will revise earlier transcripts!

**References:**
- https://docs.nvidia.com/deeplearning/riva/user-guide/docs/asr/asr-overview.html
- https://docs.nvidia.com/deeplearning/riva/user-guide/docs/tutorials/streaming-asr.html

---

## Model-Specific Behaviors

### Conformer-CTC Streaming

**Architecture**: Convolutional encoder + CTC decoder with sliding windows

**Characteristics:**
- ✅ Ultra-low latency (~40ms frames)
- ✅ Excellent accuracy for short utterances
- ❌ **Non-cumulative results** (sliding window)
- ❌ Limited context retention (typically 2-4 seconds)
- ❌ Can "forget" beginning of long utterances

**Best For:**
- Command & control
- Short-form transcription
- Real-time subtitles (with client accumulation)

**Not Ideal For:**
- Long-form dictation (without accumulation)
- Meeting transcription
- Lecture transcription

---

### Parakeet RNNT (RNN-Transducer)

**Architecture**: RNN encoder-decoder with transducer

**Characteristics:**
- ✅ Cumulative results by design
- ✅ Maintains full context
- ✅ Better for long-form content
- ⚠️  Higher latency (~200-500ms)
- ⚠️  More compute intensive

**Best For:**
- Dictation
- Meeting transcription
- Long-form content

---

### Whisper (Batch)

**Architecture**: Transformer encoder-decoder (batch processing)

**Characteristics:**
- ✅ Highly accurate
- ✅ Naturally cumulative (processes full audio)
- ✅ Handles multiple languages
- ❌ Not true streaming (batch windows)
- ❌ High latency (1-5 seconds)

**Best For:**
- Post-processing
- Offline transcription
- High-accuracy requirements

---

## Best Practice Recommendations

### 1. **Client-Side Accumulation Pattern**

When using non-cumulative models like Conformer-CTC:

```python
class TranscriptAccumulator:
    def __init__(self):
        self.finalized = ""  # All finalized text
        self.current_partial = ""  # Current partial

    def on_partial(self, text):
        """Non-cumulative partial from ASR"""
        self.current_partial = text
        return self.finalized + " " + self.current_partial if self.finalized else self.current_partial

    def on_final(self, text):
        """Final result from ASR"""
        if self.finalized:
            self.finalized += " " + text
        else:
            self.finalized = text
        self.current_partial = ""
        return self.finalized

    def reset(self):
        """Reset for new session"""
        self.finalized = ""
        self.current_partial = ""
```

**Usage:**
```python
accumulator = TranscriptAccumulator()

for result in stream:
    if result.is_final:
        display_text = accumulator.on_final(result.text)
    else:
        display_text = accumulator.on_partial(result.text)

    send_to_ui(display_text)
```

---

### 2. **Server-Side Accumulation Pattern**

Implement in WebSocket bridge (what we just did):

```python
cumulative_finals = ""  # Accumulate all finalized segments
last_partial = ""       # Track current partial

for riva_response in riva_stream:
    transcript = riva_response.alternatives[0].transcript
    is_final = riva_response.is_final

    if is_final:
        # Append to finalized transcript
        cumulative_finals += " " + transcript if cumulative_finals else transcript
        display_text = cumulative_finals
    else:
        # Combine finalized + current partial
        display_text = cumulative_finals + " " + transcript if cumulative_finals else transcript

    send_to_client(display_text, is_final)
```

**Advantages:**
- Single source of truth
- All clients see consistent results
- Simpler client implementation
- Can add features (punctuation fix, profanity filter, etc.)

---

### 3. **Hybrid Approach (Best of Both Worlds)**

Send both **incremental** and **cumulative**:

```json
{
  "type": "partial",
  "text": "hello world",           // Current segment only
  "cumulative": "how are you hello world",  // Full transcript
  "is_final": false,
  "segment_id": 3
}
```

**Client can choose:**
- Use `text` for animations/effects
- Use `cumulative` for display
- Track `segment_id` for deduplication

---

### 4. **Stability Scoring (Advanced)**

Implement confidence-based accumulation:

```python
def should_commit_partial(partial, confidence, stability_threshold=0.85):
    """Commit high-confidence partials to avoid flickering"""
    if confidence > stability_threshold:
        return True  # Lock this text in
    return False
```

**Benefits:**
- Reduce "flickering" in UI
- Lock in high-confidence text early
- Only show uncertain text as partial

---

## VAD Configuration Best Practices

### For Dictation (Long-Form)

```bash
# Allow longer pauses before finalizing
RIVA_VAD_STOP_HISTORY_MS=2000        # 2 seconds silence
RIVA_ENABLE_TWO_PASS_EOU=false       # Don't double-check EOU
RIVA_STOP_HISTORY_EOU_MS=1000        # 1 second confirmation

# Larger context buffer
RIVA_TRANSCRIPT_BUFFER_SIZE=1000     # Keep more context

# Dictation mode: treat finals as partials
RIVA_DICTATION_MODE=true
```

### For Command & Control (Short-Form)

```bash
# Quick finalization for responsive commands
RIVA_VAD_STOP_HISTORY_MS=500         # 500ms silence
RIVA_ENABLE_TWO_PASS_EOU=true        # Confirm EOU quickly
RIVA_STOP_HISTORY_EOU_MS=200         # 200ms confirmation

# Smaller buffer (faster response)
RIVA_TRANSCRIPT_BUFFER_SIZE=500

# Normal mode: finals are finals
RIVA_DICTATION_MODE=false
```

---

## Comparison Table

| Approach | Pros | Cons | Used By |
|----------|------|------|---------|
| **Server-side accumulation** | Simple client, consistent results, centralized logic | Server state management, scaling complexity | Google, AWS, Azure |
| **Client-side accumulation** | Stateless server, flexible client UX | Each client must implement correctly, inconsistent results | AssemblyAI, some open-source |
| **Hybrid (send both)** | Maximum flexibility, best UX | More bandwidth, more complex protocol | Rev.ai, some enterprise solutions |
| **No accumulation** | Simplest implementation, lowest latency | Poor UX for long-form, text erasure issues | Basic Conformer-CTC (our original issue) |

---

## Research Questions for ChatGPT

1. **How do commercial ASR services handle non-cumulative streaming models?**
   - Do they accumulate server-side or client-side?
   - What's the industry standard?

2. **What are the tradeoffs between server-side vs client-side accumulation?**
   - Scalability implications?
   - UX implications?
   - Latency implications?

3. **How do you handle "flickering" text in streaming ASR UIs?**
   - Stability scores?
   - Debouncing?
   - Progressive commitment?

4. **What's the best practice for handling VAD (Voice Activity Detection) in streaming ASR?**
   - How long should pauses be before finalization?
   - Should dictation mode exist?
   - How do you balance responsiveness vs context retention?

5. **Are there academic papers on streaming ASR UX patterns?**
   - Human factors research?
   - Cognitive load studies?
   - Best practices for real-time transcript display?

6. **How do browser-based real-time transcription apps (like Otter.ai, Descript) handle this?**
   - Client-side or server-side accumulation?
   - WebSocket protocol design?

---

## Our Implementation Decision

**We chose: Server-side accumulation in WebSocket bridge**

**Rationale:**
1. Conformer-CTC sends non-cumulative results (confirmed by testing)
2. All major cloud providers (Google, AWS, Azure) do server-side accumulation
3. Simpler client implementation (just display what arrives)
4. Single source of truth
5. Easier to add features (profanity filter, custom vocabulary, etc.)

**Trade-offs:**
- Server must maintain per-connection state (acceptable with current scale)
- More complex WebSocket bridge (mitigated by clear separation of concerns)

**Code Location:**
- `/opt/riva/nvidia-parakeet-ver-6/src/asr/riva_websocket_bridge.py` lines 623-682

---

## Testing Checklist

### ✅ Validation Tests

1. **Short utterances** (< 2 seconds):
   - Should work perfectly without accumulation
   - Quick finalization

2. **Long utterances** (> 5 seconds):
   - Partials should build progressively
   - No text erasure
   - Finals should be cumulative

3. **Rapid speech** (no pauses):
   - Should maintain context
   - No backtracking

4. **Multiple sentences with pauses**:
   - Each sentence should finalize
   - Next sentence should continue (not replace)

5. **Silence handling**:
   - Long pauses should finalize but NOT reset cumulative transcript
   - Should wait VAD timeout before finalizing

---

## References & Further Reading

### NVIDIA RIVA
- [RIVA ASR Overview](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/asr/asr-overview.html)
- [Streaming ASR Tutorial](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/tutorials/streaming-asr.html)
- [Conformer-CTC Model Card](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/riva/models/speechtotext_en_us_conformer)

### Industry Standards
- [Google Speech-to-Text Streaming](https://cloud.google.com/speech-to-text/docs/basics#streaming-responses)
- [AWS Transcribe Streaming](https://docs.aws.amazon.com/transcribe/latest/dg/streaming.html)
- [Azure Speech Services](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech)
- [AssemblyAI Real-Time](https://www.assemblyai.com/docs/walkthroughs#real-time-transcription)

### Academic Papers
- [Streaming End-to-End Speech Recognition](https://arxiv.org/abs/1811.02707)
- [Conformer: Convolution-augmented Transformer](https://arxiv.org/abs/2005.08100)
- [RNN-T for Streaming ASR](https://arxiv.org/abs/1211.3711)

### Open Source Examples
- [Mozilla DeepSpeech Streaming](https://github.com/mozilla/DeepSpeech)
- [Kaldi Streaming ASR](https://github.com/kaldi-asr/kaldi)
- [Vosk Streaming](https://github.com/alphacep/vosk-api)

---

## Summary

**The industry standard is server-side accumulation.** All major cloud providers (Google, AWS, Azure) send cumulative transcripts to clients. Only some open-source and specialized systems expect client-side accumulation.

**Our fix aligns with industry best practices** by implementing server-side accumulation in the WebSocket bridge, matching the behavior of Google Speech-to-Text, AWS Transcribe, and Azure Speech Services.

**Test the fix at:** https://3.16.124.227:8444/demo.html
