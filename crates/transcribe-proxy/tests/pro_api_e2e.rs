mod common;

use std::time::Duration;

use common::{start_server, test_audio_stream_with_rate};
use futures_util::StreamExt;
use owhisper_client::{AnarlogAdapter, FinalizeHandle, ListenClient};
use owhisper_interface::ListenParams;
use owhisper_interface::stream::StreamResponse;
use transcribe_proxy::{AnarlogRoutingConfig, Env, SttProxyConfig};

fn required_key(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} must be set"))
}

fn pro_env() -> Env {
    let mut env = Env::default();
    env.stt.deepgram_api_key = Some(required_key("DEEPGRAM_API_KEY"));
    env.stt.assemblyai_api_key = Some(required_key("ASSEMBLYAI_API_KEY"));
    env.stt.soniox_api_key = Some(required_key("SONIOX_API_KEY"));
    env.stt.gladia_api_key = Some(required_key("GLADIA_API_KEY"));
    env.stt.elevenlabs_api_key = Some(required_key("ELEVENLABS_API_KEY"));
    env
}

fn supabase_env() -> anlg_api_env::SupabaseEnv {
    anlg_api_env::SupabaseEnv {
        supabase_url: String::new(),
        supabase_anon_key: String::new(),
        supabase_service_role_key: String::new(),
    }
}

async fn assert_live_transcription(addr: std::net::SocketAddr) {
    let sample_rate = 16_000;
    let client = ListenClient::builder()
        .adapter::<AnarlogAdapter>()
        .api_base(format!("http://{addr}"))
        .params(ListenParams {
            model: Some("cloud".to_string()),
            languages: vec![anlg_language::ISO639::En.into()],
            sample_rate,
            ..Default::default()
        })
        .build_single()
        .await
        .expect("Pro live client should be configured");

    let (stream, handle) = client
        .from_realtime_audio(test_audio_stream_with_rate(sample_rate))
        .await
        .expect("Pro live transcription should connect");
    futures_util::pin_mut!(stream);

    let saw_transcript = tokio::time::timeout(Duration::from_secs(45), async {
        while let Some(result) = stream.next().await {
            let response = result.expect("Pro live transcription should not fail");
            if let StreamResponse::TranscriptResponse { channel, .. } = response
                && channel
                    .alternatives
                    .first()
                    .is_some_and(|alternative| !alternative.transcript.trim().is_empty())
            {
                return true;
            }
        }
        false
    })
    .await
    .expect("Pro live transcription timed out");

    handle.finalize().await;
    assert!(saw_transcript, "Pro live transcription should return text");
}

async fn assert_batch_transcription(addr: std::net::SocketAddr) {
    let audio = tokio::fs::read(anlg_data::english_1::AUDIO_PATH)
        .await
        .expect("test audio should be readable");
    let response = reqwest::Client::new()
        .post(format!(
            "http://{addr}/listen?provider=anarlog&model=cloud&language=en"
        ))
        .header("content-type", "audio/wav")
        .body(audio)
        .send()
        .await
        .expect("Pro batch transcription request should complete");

    let status = response.status();
    let body = response
        .text()
        .await
        .expect("Pro batch transcription response should be readable");
    assert!(
        status.is_success(),
        "Pro batch transcription failed with {status}: {body}"
    );

    let response: owhisper_interface::batch::Response =
        serde_json::from_str(&body).expect("Pro batch response should be valid");
    let transcript = response
        .results
        .channels
        .first()
        .and_then(|channel| channel.alternatives.first())
        .map(|alternative| alternative.transcript.trim())
        .unwrap_or_default();
    assert!(
        !transcript.is_empty(),
        "Pro batch transcription should return text"
    );
}

#[ignore]
#[tokio::test]
async fn pro_transcription_api_supports_live_and_batch() {
    let _ = tracing_subscriber::fmt::try_init();

    let env = pro_env();
    let config = SttProxyConfig::new(&env, &supabase_env())
        .with_anarlog_routing(AnarlogRoutingConfig::default());
    let addr = start_server(config).await;

    assert_live_transcription(addr).await;
    assert_batch_transcription(addr).await;
}
