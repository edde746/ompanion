# Voice and live mode, omp v18.3.1

Evidence: source at tag v18.3.1 (`/tmp/oh-my-pi-18.3.1/packages/coding-agent/src` unless noted; `pi-voice`/`pi-natives` are Rust crates in the same repo).

## 1. What voice surfaces exist

| Surface | Trigger | Audio in / out | Engine & where it runs | Settings | Evidence |
|---|---|---|---|---|---|
| `/live` realtime voice | `/live`, Ctrl+L (`app.live.toggle`) | Host default mic via `AudioCapture(16_000)`. Host default speaker via native `PlaybackStream` inside `LiveWebRtcPeer` (48 kHz Opus). | OpenAI Codex realtime `gpt-live-1-codex` over WebRTC (cloud). Coding work runs as the normal local AgentSession. | `live.voice` (default `sol`, 9 voices). Needs `openai-codex` OAuth. | builtin-control.ts:57-64; tui app-keybindings.ts:244-247; live/controller.ts:176; pi-voice live.rs:3-6,140-151; protocol.ts:1-2; live/settings.ts:8-20; voices.ts:1-18; transport.ts:22,196 |
| Push-to-talk dictation | Hold Space; `app.stt.toggle` (unbound by default) | Host mic `AudioCapture(16_000)` | `modelRoles.dictation`. Local worker streaming: default `local/parakeet-tdt-0.6b-v3` (sherpa-onnx) or Whisper (transformers.js). Or cloud `openai-transcriptions` (buffered WAV). | `stt.enabled`=false, `stt.language`=en, `stt.submitTrigger`=never | tui app-keybindings.ts:240-243; input-controller.ts:691-699; interactive-mode.ts:6952-6981; stt-controller.ts:93,212-228,317-335,379-398,498-505; stt/settings.ts:9-36; local-models.md:10,195-218 |
| Reply vocalization | Automatic when `speech.enabled` | Host speaker (StreamingAudioPlayer → native AudioPlayback) | Local Kokoro via the shared tiny worker (`ttsClient`) | `speech.enabled`=false, `speech.mode` (all / assistant / yield), `speech.voice`, `speech.enhanced` | event-controller.ts:259-270,1265-1286,1500-1505; vocalizer.ts:168-181,446-447; tts/settings.ts:22-78 |
| `tts` tool | The model calls it; registered only when `speechgen.enabled` | Writes a file at `output_path` (local = WAV; cloud = MP3 or WAV) | `modelRoles.speech`: local Kokoro / xAI / DeepInfra | `speechgen.enabled`=false, `tts.localVoice` | tools/tts.ts:175-236; tools/settings.ts:548-552; docs/tools/tts.md |
| `omp say` | CLI one-shot | Plays on host speaker, or writes `--out x.wav` | Local Kokoro only | `--voice --model --file --out` | commands/say.ts:37-38,80-127,142-150 |
| `omp stream` / `/record` | — | — | Terminal-row livestream. **Not voice.** | — | stream.md:1-5 |

Note: docs/tools/tts.md still mentions `providers.tts`. settings.md:406 says that key is retired and replaced by role chains; the code uses `resolveSpeechCandidates` (tools/tts.ts).

## 2. Live mode, end to end

1. **Entry guards.** `/live` is refused while an STT capture is running (interactive-mode.ts:7041-7046), and STT is refused while live is active (6967-6969). The controller replaces the editor with `LiveVisualizer`, suspends the vocalizer and passes `live.voice` (live-command-controller.ts:98-106,111,212).
2. **Connect** (transport.ts:155-181).
   - Native `createOffer` opens the **host speaker** first and throws if there is none (pi-voice live.rs:140,150). It builds an Opus PT111 48 kHz track plus the `oai-events` data channel, with the default RTCConfiguration (live.rs:49-58,142-227).
   - Attestation: DeviceCheck only on darwin-arm64 (attestation.ts:82-96). No attestation header is sent on other hosts.
   - Signaling: `POST https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas` (transport.ts:18; catalog wire/codex.ts:5). Body: `{sdp, session:{model, instructions, audio.output.voice, delegation:{type:"client"}}}` (protocol.ts:13-19; transport.ts:201-239).
   - Auth: bearer token from `withOAuthAccess(authStorage,"openai-codex")`, plus "Codex Desktop" UA/originator headers pinned to client 0.155.1 (transport.ts:79-99,183-199; codex.ts:15).
   - Answer: SDP body plus an `rtc_*` call id from the `Location` header. Then `acceptAnswer` and `waitForOpen`.
   - Sideband: `wss://api.openai.com/v1/live/<id>` with the same headers, up to 5 attempts (transport.ts:73-77,241-254).
3. **Capture and turn-taking.**
   - Mic frames go through an echo gate: dropped while output RMS > 0.015 unless input ≥ max(0.04, 0.65 × output) (barge-in) (controller.ts:22-24,360-372). Surviving frames go to `pushAudio` and native Opus in 20 ms frames (live.rs:50-53).
   - Turn detection happens **on the server**. The client only consumes `input_transcript.added`, `output_transcript.added` and `turn.done` (controller.ts:268-293).
   - Mute calls `setMuted` on the peer (controller.ts:202-216).
   - Phases: connecting / listening / working / speaking / muted / error (tui live-visualizer.ts:9).
4. **Delegation.**
   - A server `delegation.created` event becomes `session.sendCustomMessage({customType:"live-delegation", display:true, attribution:"agent"}, {triggerTurn:true})` (controller.ts:296-315; tui chat/messages.ts:35-36). That starts a normal agent turn.
   - Progress: each assistant `message_end` with `stopReason:"toolUse"` is sent back as text chunks of ≤500 bytes via `delegation.context.append` on channel `commentary` (controller.ts:317-334; protocol.ts:4-5).
   - Final: a terminal `agent_end` sends the last assistant text wrapped in the "Agent Final Message" template (controller.ts:336-355). The live model then speaks it (live-instructions.md:9-15).
5. **Output.** Remote Opus is decoded natively and played on the **host speaker**. JS only receives RMS levels; `output_audio.delta` is ignored (pi-natives live.rs:3-6,102-106; pi-voice live.rs:596-677; controller.ts:273).
6. **Transcripts.** User text goes to the visualizer. Assistant text is shown as a transient UI assistant component (live-command-controller.ts:118-133,148-194).
7. **Stop.** `session.close` is sent over the sideband, then the peer and playback are closed (controller.ts:219-262; live.rs:354-374).

## 3. What is reachable over RPC, and what needs the companion

| Capability | Over RPC (`--mode rpc-ui`) | With the companion | Evidence |
|---|---|---|---|
| Start/stop `/live` | ✗. `/live` has only `handleTui`. RPC `prompt` runs builtins through `executeAcpBuiltinSlashCommand`, which calls only `handle`. `/live` is not advertised to RPC clients. | Only by re-implementing it, and it would still use the host's mic and speaker. Useless for a phone. | builtin-control.ts:57-64; rpc-mode.ts:1148; acp-builtins.ts:66-67; available-commands.ts:46-47 |
| Push-to-talk STT | ✗ (STTController exists only inside InteractiveMode) | ✓ Host-engine transcription of audio the app supplies: `sttClient.transcribe/startStream`, or `new STTController(customCapture, deps)` from `@oh-my-pi/pi-coding-agent/stt`; `transcribeAudio` from `@oh-my-pi/pi-ai/transcription` | interactive-mode.ts:6966-6981; stt/index.ts:1-8; asr-client.ts:151,180,397; stt-controller.ts:82-96 |
| Reply vocalization | ✗ (only the TUI event-controller feeds the vocalizer) | Not needed: the phone can do it from RPC `message_update` / `message_end` / `agent_end` | event-controller.ts:1265-1286; rpc.md:519-564 |
| Host side effect | warning: The `ask` tool speaks on the **host** speaker when `speech.enabled` is on, even in RPC mode | — | tools/ask.ts:922-923; vocalizer.ts:168-181 |
| `tts` tool | ✓ Normal tool events (details include path and bytes); needs `speechgen.enabled` | — | docs/tools/tts.md |
| Host TTS on demand | ✗ | ✓ `pi.pi.ttsTool.execute(id,{text,output_path},undefined,ctx)` | src/index.ts:75; tools/index.ts:158; tools/tts.ts:175-236; ExtensionContext fields types.ts:431-447 |
| One-shots | `omp say "…" --out f.wav`; `omp setup speech --json/--check` (non-TTY installs the configured models); `omp models --kind stt\|tts`; `omp tiny-models download`. Run via SSH exec or RPC `bash`. | — | say.ts:38,84-111; setup-cli.ts:62-66,239-300; local-models.md:25; rpc-types.ts:75 |
| Codex OAuth (needed for live) | ✓ RPC `login`, with `open_url` UI frames | — | rpc-types.ts:93-94; rpc-mode.ts:1655 |
| stt / speech / live settings | ✗ There is no setter command | — | rpc-types.ts:24-94. Edit config.yml over SFTP, or pass a per-launch `--config` overlay (launch-help.ts:49-50). |

**What the companion can import in compiled or npm builds.**
- Only explicit or prefixed exports of agent, ai, coding-agent, natives, tui and utils are bundled; root `./*` catch-alls are skipped (legacy-pi-virtual-module.ts:17-24,100-101,141).
- ✓ Available:
  - `@oh-my-pi/pi-coding-agent/stt`, `/stt/*`, `/tools/*`, `/modes/controllers/*` (package.json:417-420,457-464,485-488).
  - `@oh-my-pi/pi-natives` (AudioCapture, AudioPlayback, LiveWebRtcPeer).
  - The `@oh-my-pi/pi-ai` root (`withOAuthAccess`, through the shim's `export *` at legacy-pi-ai-shim.ts:132), plus `/speech` and `/transcription` (ai package.json:57-68).
- ✗ Not available:
  - `tts/*` and `live/*`: their only export route is the `./*` catch-all (package.json:53-56).
  - `@oh-my-pi/pi-catalog`: not in the bundled list, so the companion must hardcode the Codex constants.

## 4. How audio bytes move between host and app

| Channel | Direction | Binary-safe? | Use | Evidence |
|---|---|---|---|---|
| SFTP | both | ✓ | WAV files from the `tts` tool, the companion or `omp say --out`; phone WAVs for host STT | — |
| RPC `extension_ui_request` strings (`setStatus` / `notify` / `setWidget` lines) | host → app | base64 | File paths, request ids, small clips | rpc-mode.ts:884-921. 1 MiB per line; protocol v2 `rpc_chunk` reassembles up to 64 MiB (rpc-frame.ts:6-8; rpc.md:55). |
| RPC `prompt` carrying `/<ext-cmd> <b64>` | app → host | base64 | Streaming PCM chunks into the companion (extension commands run even while streaming) | rpc-types.ts:29 |
| Host-URI `write` | host → app | string content | Companion writes to an app-registered writable scheme. [INFERENCE: needs access to the URL router from an extension] | rpc-types.ts:597-605; rpc.md:774-777 |
| SSH `direct-tcpip` to a loopback socket opened by the companion | both | ✓ | Low-latency PCM streaming [INFERENCE design]. Default sshd_config has `#AllowTcpForwarding yes`; Windows has no streamlocal forwarding. | Win32-OpenSSH sshd_config; MS Learn |

## 5. What a phone GUI must do instead

1. **Dictation.**
   - On-device STT (platform recognizers or on-device Whisper/sherpa-onnx [INFERENCE]). Put the text into the composer, then send RPC `prompt` (or `steer` / `follow_up` while streaming).
   - Reproduce the `stt.submitTrigger` semantics client-side (stt-controller.ts:498-505).
   - Optional host engine: record a 16 kHz mono WAV, upload it over SFTP, then send the companion command `/omp-app-stt <path> <reqId>`. The companion resolves `modelRoles.dictation` and returns the text via `ctx.ui.setEditorText` (an RPC `set_editor_text` frame, rpc-mode.ts:953) or via `setStatus`.
2. **Reply TTS.**
   - On-device TTS driven by RPC events, mirroring `speech.mode`:
     - `assistant`: speak `text_delta`.
     - `all`: also speak `thinking_delta`.
     - `yield`: speak the final assistant message.
   - Clear on a new user message or abort (event-controller.ts:992,1265-1286,1500-1505).
   - Host voices: the companion's `ttsTool.execute` writes a WAV, and the app downloads it over SFTP. Split per sentence for latency.
   - Force `speech.enabled: false` through a `--config` overlay for RPC sessions, so the ask tool doesn't talk on the host.
3. **Live, tiered.**
   - (a) **No companion (recommended first):** "pseudo-live" loop: on-device VAD + STT → `prompt` / `steer`; on-device TTS; barge-in stops TTS and optionally sends `abort`.
   - (b) **Codex parity (experimental):**
     - The phone runs the WebRTC peer (Opus / 48 kHz plus an `oai-events` data channel) and exchanges media directly with OpenAI.
     - The companion runs the signaling POST, the sideband WebSocket and the delegation loop. That is essentially LiveSessionController without the audio parts: `pi.on('message_end' | 'agent_end')` (types.ts:1288-1294) and `pi.sendMessage` with live-delegation (types.ts:1453-1456).
     - Transcripts and phase go to the phone as setStatus/setWidget frames; SDP, mute and stop come back as extension commands.
     - The OAuth token never leaves the host.
     - Risks: private endpoint, "Codex Desktop" impersonation, a pinned client version, no attestation, and unverified server acceptance of a mobile SDP [INFERENCE].
   - (c) A public realtime API on the phone, with a `delegate` function mapped to RPC `prompt` and completion taken from `agent_end` [INFERENCE].
4. **Rendering.** Render `customType: "live-delegation"` messages found in sessions created with the TUI (tui chat/messages.ts:35-36).
5. **Desktop with local omp.** A companion could rebuild /live on the same machine from pi-natives + withOAuthAccess. Alternatively, it could construct the exported `LiveCommandController` with a fake context, which is brittle [INFERENCE].

**Verdict.**
- Host `/live` through the GUI: **not feasible**. It is TUI-only, bound to host audio devices, and has no PCM tap.
- Phone push-to-talk and reply TTS: **feasible**, with no companion required.
- Host speech engines: **feasible** with the companion plus SFTP.
- Full-duplex Codex-live parity: **only as an app-side rebuild** (phone WebRTC + companion proxy). Feasible but fragile; ship it behind a flag.
