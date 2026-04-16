//! Voice mode — STT/TTS integration for Chump.
//!
//! Gated behind the `voice` Cargo feature flag (disabled by default).
//! When enabled, provides:
//! - **STT (Speech-to-Text):** In-process Whisper via `whisper-rs`
//! - **TTS (Text-to-Speech):** macOS `say`, Linux `espeak`, or external API (11Labs, Cartesia)
//!
//! # Architecture
//! ```text
//! Mic → whisper-rs STT → agent.run(text) → TTS → Speaker
//! ```
//!
//! # Requirements
//! - macOS: Microphone permission (System Settings → Privacy & Security → Microphone)
//! - A Whisper model file (e.g. ggml-base.en.bin, ~150MB for base, ~75MB for tiny)
//! - For external TTS: API key in env (e.g. ELEVEN_LABS_API_KEY)
//!
//! # Environment Variables
//! - `CHUMP_VOICE_WHISPER_MODEL` — path to Whisper GGML model file (default: models/ggml-base.en.bin)
//! - `CHUMP_VOICE_TTS_BACKEND` — `system` (default), `elevenlabs`, or `cartesia`
//! - `CHUMP_VOICE_TTS_VOICE` — voice name/ID for the TTS backend
//! - `CHUMP_VOICE_SAMPLE_RATE` — audio sample rate in Hz (default: 16000)
//! - `CHUMP_VOICE_VAD_THRESHOLD` — voice activity detection energy threshold (default: 0.02)

/// Errors specific to voice mode.
#[derive(Debug, thiserror::Error)]
pub enum VoiceError {
    #[error("Whisper model not found at: {0}")]
    ModelNotFound(String),
    #[error("Microphone access denied — grant permission in System Settings")]
    MicrophoneDenied,
    #[error("TTS backend error: {0}")]
    TtsError(String),
    #[error("Audio capture error: {0}")]
    CaptureError(String),
    #[error("Voice feature not compiled — rebuild with: cargo build --features voice")]
    NotCompiled,
}

// ─── STT (Speech-to-Text) ────────────────────────────────────────

/// Speech-to-text transcription using whisper-rs.
///
/// # Usage
/// ```rust,ignore
/// let stt = Stt::new("models/ggml-base.en.bin")?;
/// let text = stt.transcribe(&audio_samples)?;
/// ```
#[cfg(feature = "voice")]
pub mod stt {
    use super::VoiceError;

    pub struct Stt {
        // whisper_ctx will hold the whisper-rs context
        _model_path: String,
    }

    impl Stt {
        /// Create a new STT engine from a Whisper GGML model file.
        pub fn new(model_path: &str) -> Result<Self, VoiceError> {
            if !std::path::Path::new(model_path).exists() {
                return Err(VoiceError::ModelNotFound(model_path.to_string()));
            }
            // TODO: Initialize whisper-rs context
            // let ctx = whisper_rs::WhisperContext::new_with_params(
            //     model_path,
            //     whisper_rs::WhisperContextParameters::default(),
            // ).map_err(|e| VoiceError::CaptureError(e.to_string()))?;
            Ok(Self {
                _model_path: model_path.to_string(),
            })
        }

        /// Transcribe PCM audio samples (f32, 16kHz, mono) to text.
        pub fn transcribe(&self, _samples: &[f32]) -> Result<String, VoiceError> {
            // TODO: Run whisper-rs full inference
            // let mut state = self.ctx.create_state().map_err(...)?;
            // let params = whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 1 });
            // state.full(params, samples).map_err(...)?;
            // let text = (0..state.full_n_segments()?)
            //     .map(|i| state.full_get_segment_text(i).unwrap_or_default())
            //     .collect::<Vec<_>>().join(" ");
            Err(VoiceError::NotCompiled)
        }
    }

    /// Get the default Whisper model path from env or fallback.
    pub fn default_model_path() -> String {
        std::env::var("CHUMP_VOICE_WHISPER_MODEL")
            .unwrap_or_else(|_| "models/ggml-base.en.bin".to_string())
    }
}

// ─── TTS (Text-to-Speech) ────────────────────────────────────────

/// Text-to-speech output using system commands or external APIs.
#[cfg(feature = "voice")]
pub mod tts {
    use super::VoiceError;

    /// TTS backend selection.
    #[derive(Debug, Clone)]
    pub enum TtsBackend {
        /// macOS `say` or Linux `espeak` — no API key needed.
        System,
        /// ElevenLabs API — requires ELEVEN_LABS_API_KEY.
        ElevenLabs { api_key: String, voice_id: String },
        /// Cartesia API — requires CARTESIA_API_KEY.
        Cartesia { api_key: String, voice_id: String },
    }

    impl TtsBackend {
        /// Build TTS backend from environment variables.
        pub fn from_env() -> Self {
            match std::env::var("CHUMP_VOICE_TTS_BACKEND")
                .unwrap_or_else(|_| "system".to_string())
                .to_lowercase()
                .as_str()
            {
                "elevenlabs" | "11labs" => {
                    let api_key = std::env::var("ELEVEN_LABS_API_KEY")
                        .unwrap_or_default();
                    let voice_id = std::env::var("CHUMP_VOICE_TTS_VOICE")
                        .unwrap_or_else(|_| "EXAVITQu4vr4xnSDxMaL".to_string()); // Rachel
                    TtsBackend::ElevenLabs { api_key, voice_id }
                }
                "cartesia" => {
                    let api_key = std::env::var("CARTESIA_API_KEY")
                        .unwrap_or_default();
                    let voice_id = std::env::var("CHUMP_VOICE_TTS_VOICE")
                        .unwrap_or_default();
                    TtsBackend::Cartesia { api_key, voice_id }
                }
                _ => TtsBackend::System,
            }
        }

        /// Speak the given text.
        pub async fn speak(&self, text: &str) -> Result<(), VoiceError> {
            match self {
                TtsBackend::System => speak_system(text),
                TtsBackend::ElevenLabs { .. } => {
                    // TODO: POST to https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
                    Err(VoiceError::TtsError("ElevenLabs not yet implemented".into()))
                }
                TtsBackend::Cartesia { .. } => {
                    Err(VoiceError::TtsError("Cartesia not yet implemented".into()))
                }
            }
        }
    }

    /// Use macOS `say` or Linux `espeak` for TTS.
    fn speak_system(text: &str) -> Result<(), VoiceError> {
        let cmd = if cfg!(target_os = "macos") {
            "say"
        } else {
            "espeak"
        };

        let voice = std::env::var("CHUMP_VOICE_TTS_VOICE").ok();
        let mut command = std::process::Command::new(cmd);

        if cfg!(target_os = "macos") {
            if let Some(ref v) = voice {
                command.args(["-v", v]);
            }
        } else if let Some(ref v) = voice {
            command.args(["-v", v]);
        }

        command.arg(text);

        let status = command
            .status()
            .map_err(|e| VoiceError::TtsError(format!("{cmd} failed: {e}")))?;

        if status.success() {
            Ok(())
        } else {
            Err(VoiceError::TtsError(format!(
                "{cmd} exited with code {}",
                status.code().unwrap_or(-1)
            )))
        }
    }
}

// ─── Fallback when feature is disabled ───────────────────────────

#[cfg(not(feature = "voice"))]
pub fn voice_not_available() -> VoiceError {
    VoiceError::NotCompiled
}

// ─── Audio Capture (future: cpal or coreaudio) ──────────────────

#[cfg(feature = "voice")]
pub mod capture {
    use super::VoiceError;

    /// Configuration for audio capture.
    pub struct CaptureConfig {
        pub sample_rate: u32,
        pub vad_threshold: f32,
    }

    impl Default for CaptureConfig {
        fn default() -> Self {
            Self {
                sample_rate: std::env::var("CHUMP_VOICE_SAMPLE_RATE")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(16000),
                vad_threshold: std::env::var("CHUMP_VOICE_VAD_THRESHOLD")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0.02),
            }
        }
    }

    /// Record audio from the default input device until silence is detected.
    ///
    /// Returns PCM f32 samples at the configured sample rate.
    pub fn record_until_silence(_config: &CaptureConfig) -> Result<Vec<f32>, VoiceError> {
        // TODO: Use cpal or coreaudio-rs to capture from default input
        // 1. Open default input device
        // 2. Set up VAD (voice activity detection) with energy-based thresholding
        // 3. Record while energy > vad_threshold
        // 4. Stop after sustained silence (e.g., 1.5s below threshold)
        // 5. Return accumulated samples
        Err(VoiceError::CaptureError(
            "Audio capture not yet implemented — needs cpal or coreaudio-rs".into(),
        ))
    }
}
