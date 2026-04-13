//! Server-side Web Push (VAPID) delivery for PWA subscribers (universal power P2.1).
//! Subscriptions live in `chump_push_subscriptions`; private key via **`CHUMP_VAPID_PRIVATE_KEY_FILE`**.

use std::io::Cursor;

use anyhow::Result;
use rusqlite::params;
use web_push::{
    ContentEncoding, HyperWebPushClient, PartialVapidSignatureBuilder, SubscriptionInfo,
    VapidSignatureBuilder, WebPushClient, WebPushMessageBuilder, WebPushError,
};

fn vapid_pem_bytes() -> Option<Vec<u8>> {
    let path = std::env::var("CHUMP_VAPID_PRIVATE_KEY_FILE")
        .ok()?
        .trim()
        .to_string();
    if path.is_empty() {
        return None;
    }
    std::fs::read(&path).ok()
}

/// `CHUMP_WEB_PUSH_AUTONOMY=1` and a readable VAPID PEM file.
pub fn autonomy_push_enabled() -> bool {
    let on = std::env::var("CHUMP_WEB_PUSH_AUTONOMY")
        .map(|s| {
            let t = s.trim();
            t == "1" || t.eq_ignore_ascii_case("true") || t.eq_ignore_ascii_case("yes")
        })
        .unwrap_or(false);
    on && vapid_pem_bytes().is_some()
}

fn normalize_b64_key(s: &str) -> String {
    s.trim().trim_end_matches('=').to_string()
}

fn delete_subscription(endpoint: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    let _ = conn.execute(
        "DELETE FROM chump_push_subscriptions WHERE endpoint = ?1",
        params![endpoint],
    )?;
    Ok(())
}

fn subscription_rows() -> Result<Vec<(String, String, String)>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT endpoint, COALESCE(p256dh, ''), COALESCE(auth, '') FROM chump_push_subscriptions",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Broadcast a small JSON payload `{"title","body"}` to all stored subscriptions (decrypted by the service worker).
/// Returns `(succeeded, failed)`. Skips silently when no PEM or no rows. Removes expired subscriptions on 404/410-style errors.
pub async fn broadcast_json_notification(title: &str, body: &str) -> (usize, usize) {
    let Some(pem) = vapid_pem_bytes() else {
        tracing::debug!("web push: no CHUMP_VAPID_PRIVATE_KEY_FILE; skip broadcast");
        return (0, 0);
    };

    let rows = match subscription_rows() {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("web push: list subscriptions: {}", e);
            return (0, 0);
        }
    };
    if rows.is_empty() {
        return (0, 0);
    }

    let partial: PartialVapidSignatureBuilder = match VapidSignatureBuilder::from_pem_no_sub(Cursor::new(&pem)) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("web push: VAPID PEM parse failed: {}", e);
            return (0, 0);
        }
    };

    let payload = serde_json::json!({ "title": title, "body": body }).to_string();
    let payload_bytes = payload.as_bytes();
    if payload_bytes.len() > 3500 {
        tracing::warn!("web push: payload too large; truncating title/body");
    }
    let payload_bytes = &payload_bytes[..payload_bytes.len().min(3500)];

    let client = HyperWebPushClient::new();
    let mut ok = 0usize;
    let mut fail = 0usize;

    for (endpoint, p256dh_raw, auth_raw) in rows {
        if endpoint.is_empty() {
            continue;
        }
        let p256dh = normalize_b64_key(&p256dh_raw);
        let auth = normalize_b64_key(&auth_raw);
        if p256dh.is_empty() || auth.is_empty() {
            tracing::debug!("web push: skip endpoint with missing keys");
            fail += 1;
            continue;
        }

        let sub = SubscriptionInfo::new(&endpoint, &p256dh, &auth);
        let mut sig_b = partial.clone().add_sub_info(&sub);
        if let Ok(s) = std::env::var("CHUMP_VAPID_SUBJECT") {
            let t = s.trim();
            if !t.is_empty() {
                sig_b.add_claim("sub", t);
            }
        }
        let sig = match sig_b.build() {
            Ok(s) => s,
            Err(e) => {
                tracing::debug!("web push: vapid build for endpoint: {}", e);
                fail += 1;
                continue;
            }
        };

        let mut builder = WebPushMessageBuilder::new(&sub);
        builder.set_payload(ContentEncoding::Aes128Gcm, payload_bytes);
        builder.set_vapid_signature(sig);
        let msg = match builder.build() {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!("web push: build message: {}", e);
                fail += 1;
                continue;
            }
        };

        match client.send(msg).await {
            Ok(()) => ok += 1,
            Err(e) => {
                let drop = matches!(
                    &e,
                    WebPushError::EndpointNotFound(_) | WebPushError::EndpointNotValid(_)
                );
                if drop {
                    let _ = delete_subscription(&endpoint);
                    tracing::info!("web push: removed stale subscription (endpoint prefix)");
                } else {
                    tracing::debug!("web push: send error: {}", e);
                }
                fail += 1;
            }
        }
    }

    (ok, fail)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_b64_key_strips_padding() {
        assert_eq!(normalize_b64_key("abc="), "abc");
        assert_eq!(normalize_b64_key("  xyz  "), "xyz");
    }
}
