use async_std::{future::timeout, io::{self, BufReader}, prelude::*};
use magic_wormhole::{AppConfig, MailboxConnection, Wormhole};
use rand::{rngs::OsRng, Rng};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{borrow::Cow, time::Duration};

const APP_ID: &str = "github.com/shotaro311/hover-pocket/pairing-v1";
const RELAY: &str = "wss://mailbox.mw.leastauthority.com/v1";
const LIMIT: usize = 16_384;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Hello {
    version: u32,
    role: String,
    nonce: String,
    device_id: String,
    device_name: String,
    platform: String,
    group_id: Option<String>,
    folder_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Start {
    role: String,
    code: Option<String>,
    device_id: String,
    device_name: String,
    platform: String,
    group_id: Option<String>,
    folder_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Decision { action: String, approval_id: String }
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Frame { kind: String, approval_id: String, accepted: bool }

fn ensure(ok: bool, reason: &'static str) -> Result<()> {
    if ok { Ok(()) } else { Err(reason.into()) }
}
fn validate_hello(h: &Hello) -> Result<()> {
    ensure(h.version == 1 && (h.role == "invite" || h.role == "join"), "invalid_protocol")?;
    ensure(uuid::Uuid::parse_str(&h.nonce).is_ok(), "invalid_nonce")?;
    let parts: Vec<_> = h.device_id.split('-').collect();
    ensure(parts.len() == 8 && parts.iter().all(|p| p.len() == 7 && p.bytes().all(|b| b.is_ascii_uppercase() || (b'2'..=b'7').contains(&b))), "invalid_device")?;
    ensure(!h.device_name.trim().is_empty() && h.device_name.chars().count() <= 80 && !h.device_name.chars().any(char::is_control), "invalid_name")?;
    ensure(["windows", "macos"].contains(&h.platform.as_str()), "invalid_platform")?;
    ensure(h.group_id.is_some() == h.folder_id.is_some(), "invalid_group")?;
    if let Some(group) = &h.group_id {
        ensure(uuid::Uuid::parse_str(group).is_ok_and(|id| id.to_string() == *group), "invalid_group")?;
        let folder = h.folder_id.as_deref().unwrap_or("");
        ensure(!folder.is_empty() && folder.len() <= 80 && folder.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'), "invalid_folder")?;
    }
    ensure(h.role != "invite" || h.group_id.is_some(), "missing_group")
}
fn validate_pair(local: &Hello, peer: &Hello) -> Result<()> {
    validate_hello(peer)?;
    ensure(local.role != peer.role && local.device_id != peer.device_id, "invalid_peer")?;
    if local.group_id.is_some() && peer.group_id.is_some() {
        ensure(local.group_id == peer.group_id && local.folder_id == peer.folder_id, "different_library")?;
    }
    Ok(())
}
async fn emit(value: Value) -> Result<()> {
    let mut out = io::stdout();
    out.write_all(format!("{}\n", value).as_bytes()).await?;
    out.flush().await?;
    Ok(())
}
async fn input(reader: &mut BufReader<io::Stdin>) -> Result<String> {
    let mut line = String::new();
    ensure(reader.read_line(&mut line).await? != 0 && line.len() <= LIMIT, "input_closed")?;
    Ok(line)
}
async fn receive<T: serde::de::DeserializeOwned>(w: &mut Wormhole) -> Result<T> {
    let bytes = w.receive().await?;
    ensure(bytes.len() <= LIMIT, "message_too_large")?;
    Ok(serde_json::from_slice(&bytes)?)
}
fn relay() -> Result<String> {
    // Only the isolated test runner may override the broker, and only to loopback.
    if let Ok(value) = std::env::var("HOVERPOCKET_PAIRING_TEST_RELAY") {
        ensure(value.starts_with("ws://127.0.0.1:") && value.ends_with("/v1"), "invalid_test_relay")?;
        return Ok(value);
    }
    Ok(RELAY.to_owned())
}
async fn run(reader: &mut BufReader<io::Stdin>, start: Start) -> Result<()> {
    let hello = Hello { version: 1, role: start.role, nonce: uuid::Uuid::new_v4().to_string(), device_id: start.device_id,
        device_name: start.device_name, platform: start.platform, group_id: start.group_id, folder_id: start.folder_id };
    validate_hello(&hello)?;
    let config = AppConfig { id: APP_ID.to_owned().into(), rendezvous_url: Cow::Owned(relay()?), app_version: json!({"version":1}) };
    let mailbox = if hello.role == "invite" {
        let password = format!("{:08}", OsRng.gen_range(0..100_000_000u32));
        MailboxConnection::create_with_password(config, password.parse()?).await?
    } else {
        let code = start.code.ok_or("missing_code")?;
        let (plate, secret) = code.trim().split_once('-').ok_or("invalid_code")?;
        ensure(!plate.is_empty() && plate.len() <= 10 && plate.bytes().all(|b| b.is_ascii_digit()) && secret.len() == 8 && secret.bytes().all(|b| b.is_ascii_digit()), "invalid_code")?;
        MailboxConnection::connect(config, code.trim().parse()?, false).await?
    };
    if hello.role == "invite" { emit(json!({"event":"code", "code":mailbox.code().to_string(), "expiresInSeconds":300})).await?; }
    let mut w = Wormhole::connect(mailbox).await?;
    w.send_json(&hello).await?;
    let peer: Hello = receive(&mut w).await?;
    validate_pair(&hello, &peer)?;
    let (inviter, joiner) = if hello.role == "invite" { (&hello, &peer) } else { (&peer, &hello) };
    let transcript = serde_json::to_vec(&(inviter, joiner))?;
    let approval_id = format!("{:x}", Sha256::digest(&transcript));
    let verifier: &[u8] = w.verifier().as_ref();
    let verification = format!("{:x}", Sha256::digest(verifier))[..8].to_uppercase();
    emit(json!({"event":"peer", "approvalId":approval_id, "verification":verification, "peer":peer,
        "groupId":inviter.group_id, "folderId":inviter.folder_id})).await?;
    let decision: Decision = serde_json::from_str(&input(reader).await?)?;
    if decision.approval_id != approval_id {
        w.send_json(&Frame { kind: "decision".into(), approval_id: approval_id.clone(), accepted: false }).await?;
        return Err("stale_approval".into());
    }
    let accepted = decision.action == if hello.role == "invite" { "approve" } else { "ready" };
    w.send_json(&Frame { kind: "decision".into(), approval_id: approval_id.clone(), accepted }).await?;
    ensure(accepted, "cancelled")?;
    let other: Frame = receive(&mut w).await?;
    ensure(other.kind == "decision" && other.approval_id == approval_id && other.accepted, "peer_declined")?;
    emit(json!({"event":"approved", "approvalId":approval_id, "peer":peer, "groupId":inviter.group_id, "folderId":inviter.folder_id})).await?;
    let apply: Decision = serde_json::from_str(&input(reader).await?)?;
    ensure(apply.approval_id == approval_id, "stale_approval")?;
    w.send_json(&Frame { kind:"applied".into(), approval_id:approval_id.clone(), accepted:apply.action == "applied" }).await?;
    ensure(apply.action == "applied", "setup_failed")?;
    let other: Frame = receive(&mut w).await?;
    ensure(other.kind == "applied" && other.approval_id == approval_id && other.accepted, "peer_setup_failed")?;
    emit(json!({"event":"complete", "approvalId":approval_id})).await?;
    let _ = timeout(Duration::from_secs(3), w.close()).await;
    Ok(())
}
fn main() {
    // Windows threads default to a small stack; the TLS future needs more in debug builds.
    std::thread::Builder::new().stack_size(8 * 1024 * 1024).spawn(session).expect("pairing worker").join().expect("pairing worker stopped");
}
fn session() {
    async_std::task::block_on(async {
        let mut reader = BufReader::new(io::stdin());
        let first = match timeout(Duration::from_secs(10), input(&mut reader)).await {
            Ok(Ok(line)) => line,
            _ => { let _ = emit(json!({"event":"error","reason":"input_closed"})).await; return; }
        };
        let start = match serde_json::from_str::<Start>(&first) {
            Ok(start) => start,
            Err(_) => { let _ = emit(json!({"event":"error","reason":"invalid_request"})).await; return; }
        };
        let result = timeout(Duration::from_secs(300), run(&mut reader, start)).await;
        match result {
            Ok(Ok(())) => {},
            Err(_) => { let _ = emit(json!({"event":"error","reason":"expired"})).await; },
            Ok(Err(error)) => {
                let text = error.to_string();
                let public = ["cancelled","different_library","stale_approval","invalid_peer","peer_declined","setup_failed","peer_setup_failed","invalid_code","invalid_device","invalid_name","invalid_protocol","invalid_platform","invalid_group","invalid_folder","missing_group","missing_code","input_closed"];
                let reason = if public.contains(&text.as_str()) { text.as_str() } else { "connection_failed" };
                // Never log codes, keys, device metadata or raw network errors.
                let _ = emit(json!({"event":"error","reason":reason})).await;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn hello(role: &str) -> Hello { Hello {version:1, role:role.into(), nonce:uuid::Uuid::new_v4().to_string(), device_id:["AAAAAAA";8].join("-"),device_name:"テスト端末".into(),platform:"windows".into(),group_id:Some("11111111-2222-4333-8444-555555555555".into()),folder_id:Some("hoverpocket-test".into())} }
    #[test] fn valid_identity() { assert!(validate_hello(&hello("invite")).is_ok()); }
    #[test] fn deny_unexpected_fields() { assert!(serde_json::from_value::<Decision>(json!({"action":"approve","approvalId":"a","extra":true})).is_err()); }
    #[test] fn reject_wrong_group() { let local=hello("invite");let mut peer=hello("join");peer.device_id=["BBBBBBB";8].join("-");peer.group_id=Some(uuid::Uuid::new_v4().to_string());assert!(validate_pair(&local,&peer).is_err()); }
    #[test] fn reject_self() { assert!(validate_pair(&hello("invite"),&hello("join")).is_err()); }
    #[test] fn reject_paths_and_controls() { let mut h=hello("invite");h.folder_id=Some("../eagle".into());assert!(validate_hello(&h).is_err());h=hello("invite");h.device_name="x\nForged".into();assert!(validate_hello(&h).is_err()); }
}
