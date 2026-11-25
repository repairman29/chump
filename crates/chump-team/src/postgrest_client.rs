//! Minimal native PostgREST HTTP builder backed by `reqwest` 0.12 (`rustls` 0.23).
//!
//! CREDIBLE-1704: Replaces the unmaintained `postgrest = "1.6"` dependency (which
//! pulled `reqwest 0.11` -> `hyper 0.14` -> `rustls 0.21.12` and triggered
//! GHSA-w44r-93j7-qv28, GHSA-c8m5-c952-6cm4, and GHSA-h2v8-394m-p7vv /
//! RUSTSEC-2026-0346 / RUSTSEC-2026-0349) while preserving the exact PostgREST
//! wire protocol (`Accept: application/json`, `Prefer: return=representation`,
//! `Range-Unit: items`, `Range: 0-(n-1)`, `eq.*`/`is.*` filters, and `/rpc/<fn>`).

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, ACCEPT, CONTENT_TYPE};
use reqwest::{Client, Method, Response};

/// Lightweight PostgREST endpoint client sharing a pooled `reqwest::Client`.
#[derive(Clone, Debug)]
pub(crate) struct Postgrest {
    base_url: String,
    headers: HeaderMap,
    client: Client,
}

impl Postgrest {
    /// Construct a PostgREST client targeting `url` (e.g. `https://xyz.supabase.co/rest/v1`).
    pub(crate) fn new(url: impl Into<String>) -> Self {
        let raw = url.into();
        let base_url = raw.trim_end_matches('/').to_string();
        Self {
            base_url,
            headers: HeaderMap::new(),
            client: Client::new(),
        }
    }

    /// Attach a default header (such as `apikey` or `Authorization`) sent on every request.
    pub(crate) fn insert_header(mut self, name: &'static str, value: impl AsRef<str>) -> Self {
        match (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value.as_ref()),
        ) {
            (Ok(name_hdr), Ok(val)) => {
                self.headers.insert(name_hdr, val);
            }
            (Err(err), _) => {
                tracing::warn!(header = name, error = %err, "ignoring invalid PostgREST header name");
            }
            (_, Err(err)) => {
                tracing::warn!(header = name, error = %err, "ignoring invalid PostgREST header value");
            }
        }
        self
    }

    /// Begin a table/view query against `<base_url>/<table>`.
    pub(crate) fn from(&self, table: impl AsRef<str>) -> Builder {
        let url = format!("{}/{}", self.base_url, table.as_ref());
        Builder::new(url, self.headers.clone(), self.client.clone())
    }

    /// Invoke a stored procedure via `POST <base_url>/rpc/<function>`.
    pub(crate) fn rpc(&self, function: impl AsRef<str>, params: impl Into<String>) -> Builder {
        let url = format!("{}/rpc/{}", self.base_url, function.as_ref());
        let mut builder = Builder::new(url, self.headers.clone(), self.client.clone());
        builder.method = Method::POST;
        builder.body = Some(params.into());
        builder
    }
}

/// Fluent PostgREST request builder matching the subset used by `chump-team`.
#[derive(Debug)]
pub(crate) struct Builder {
    url: String,
    method: Method,
    headers: HeaderMap,
    queries: Vec<(String, String)>,
    body: Option<String>,
    client: Client,
}

impl Builder {
    fn new(url: String, mut headers: HeaderMap, client: Client) -> Self {
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        Self {
            url,
            method: Method::GET,
            headers,
            queries: Vec::new(),
            body: None,
            client,
        }
    }

    /// Project columns via `?select=<columns>`.
    pub(crate) fn select(mut self, columns: impl Into<String>) -> Self {
        self.queries.push(("select".to_string(), columns.into()));
        self
    }

    /// Order rows via `?order=<columns>`.
    pub(crate) fn order(mut self, columns: impl Into<String>) -> Self {
        self.queries.push(("order".to_string(), columns.into()));
        self
    }

    /// Bound row count via `Range-Unit: items` and `Range: 0-(count-1)`.
    pub(crate) fn limit(mut self, count: usize) -> Self {
        self.headers.insert(
            HeaderName::from_static("range-unit"),
            HeaderValue::from_static("items"),
        );
        let upper = count.saturating_sub(1);
        if let Ok(range_val) = HeaderValue::from_str(&format!("0-{upper}")) {
            self.headers
                .insert(HeaderName::from_static("range"), range_val);
        }
        self
    }

    /// Filter equality via `?<column>=eq.<value>`.
    pub(crate) fn eq(mut self, column: impl Into<String>, value: impl AsRef<str>) -> Self {
        self.queries
            .push((column.into(), format!("eq.{}", value.as_ref())));
        self
    }

    /// Filter `IS` (`null`, `true`, `false`) via `?<column>=is.<value>`.
    pub(crate) fn is(mut self, column: impl Into<String>, value: impl AsRef<str>) -> Self {
        self.queries
            .push((column.into(), format!("is.{}", value.as_ref())));
        self
    }

    /// Insert JSON row(s) via `POST` with `Prefer: return=representation`.
    pub(crate) fn insert(mut self, body: impl Into<String>) -> Self {
        self.method = Method::POST;
        self.headers.insert(
            HeaderName::from_static("prefer"),
            HeaderValue::from_static("return=representation"),
        );
        self.body = Some(body.into());
        self
    }

    /// Update matching rows via `PATCH` with `Prefer: return=representation`.
    pub(crate) fn update(mut self, body: impl Into<String>) -> Self {
        self.method = Method::PATCH;
        self.headers.insert(
            HeaderName::from_static("prefer"),
            HeaderValue::from_static("return=representation"),
        );
        self.body = Some(body.into());
        self
    }

    /// Send the built HTTP request.
    pub(crate) async fn execute(mut self) -> std::result::Result<Response, reqwest::Error> {
        if !matches!(self.method, Method::GET | Method::HEAD) {
            self.headers
                .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        }
        let mut req = self
            .client
            .request(self.method, &self.url)
            .headers(self.headers)
            .query(&self.queries);
        if let Some(body) = self.body {
            req = req.body(body);
        }
        req.send().await
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        ChumpTeam, ChumpTeamConfig, ClaimResult, Effort, GapFilter, GapPatch, GapStatus, Priority,
    };
    use mockito::Matcher;
    use uuid::Uuid;

    fn test_client(server_url: String) -> ChumpTeam {
        ChumpTeam::new(ChumpTeamConfig {
            url: server_url,
            api_key: "anon-test-key".to_string(),
            user_jwt: Some("user-jwt-token".to_string()),
            active_team_slug: Some("dogfood".to_string()),
        })
    }

    #[tokio::test]
    async fn ping_sends_auth_and_range_headers() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("GET", "/rest/v1/teams")
            .match_header("apikey", "anon-test-key")
            .match_header("authorization", "Bearer user-jwt-token")
            .match_header("accept", "application/json")
            .match_header("range-unit", "items")
            .match_header("range", "0-0")
            .match_query(Matcher::UrlEncoded("select".into(), "id".into()))
            .with_status(200)
            .with_body(r#"[{"id":"00000000-0000-0000-0000-000000000001"}]"#)
            .create_async()
            .await;

        let client = test_client(server.url());
        client.ping().await.unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn reserve_list_and_update_gap_wire_protocol() {
        let mut server = mockito::Server::new_async().await;
        let team_id = Uuid::nil();
        let user_id = Uuid::nil();
        let row_json = r#"[{
            "id": "CREDIBLE-TEST",
            "team_id": "00000000-0000-0000-0000-000000000000",
            "domain": "CREDIBLE",
            "title": "wire check",
            "description": null,
            "priority": "P1",
            "effort": "s",
            "status": "open",
            "acceptance_criteria": null,
            "created_by_user_id": "00000000-0000-0000-0000-000000000000",
            "created_at": "2026-11-25T00:00:00Z",
            "updated_at": "2026-11-25T00:00:00Z",
            "closed_pr": null,
            "notes": null
        }]"#;

        let insert_mock = server
            .mock("POST", "/rest/v1/shared_gaps")
            .match_header("prefer", "return=representation")
            .match_header("content-type", "application/json")
            .with_status(201)
            .with_body(row_json)
            .create_async()
            .await;

        let list_mock = server
            .mock("GET", "/rest/v1/shared_gaps")
            .match_query(Matcher::AllOf(vec![
                Matcher::UrlEncoded("select".into(), "*".into()),
                Matcher::UrlEncoded("status".into(), "eq.open".into()),
            ]))
            .with_status(200)
            .with_body(row_json)
            .create_async()
            .await;

        let patch_mock = server
            .mock("PATCH", "/rest/v1/shared_gaps")
            .match_header("prefer", "return=representation")
            .match_query(Matcher::UrlEncoded("id".into(), "eq.CREDIBLE-TEST".into()))
            .with_status(200)
            .with_body(row_json)
            .create_async()
            .await;

        let client = test_client(server.url());
        let created = client
            .reserve_gap(
                "CREDIBLE-TEST",
                team_id,
                "CREDIBLE",
                "wire check",
                Priority::P1,
                Effort::S,
                user_id,
            )
            .await
            .unwrap();
        assert_eq!(created.id, "CREDIBLE-TEST");

        let listed = client
            .list_gaps(GapFilter {
                status: Some(GapStatus::Open),
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);

        let updated = client
            .update_gap(
                "CREDIBLE-TEST",
                GapPatch {
                    notes: Some("ok".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(updated.id, "CREDIBLE-TEST");

        insert_mock.assert_async().await;
        list_mock.assert_async().await;
        patch_mock.assert_async().await;
    }

    #[tokio::test]
    async fn try_claim_gap_maps_23505_conflict_to_lost() {
        let mut server = mockito::Server::new_async().await;
        let team_id = Uuid::nil();
        let user_id = Uuid::nil();

        // First probe sees no active claim; insert hits 23505 unique race; second probe returns winner.
        let empty_probe = server
            .mock("GET", "/rest/v1/shared_claims")
            .match_query(Matcher::AllOf(vec![
                Matcher::UrlEncoded("select".into(), "*".into()),
                Matcher::UrlEncoded("gap_id".into(), "eq.CREDIBLE-RACE".into()),
                Matcher::UrlEncoded("released_at".into(), "is.null".into()),
            ]))
            .with_status(200)
            .with_body("[]")
            .expect(1)
            .create_async()
            .await;

        let conflict_insert = server
            .mock("POST", "/rest/v1/shared_claims")
            .with_status(409)
            .with_body(
                r#"{"code":"23505","message":"duplicate key value violates unique constraint"}"#,
            )
            .create_async()
            .await;

        let winner_probe = server
            .mock("GET", "/rest/v1/shared_claims")
            .match_query(Matcher::AllOf(vec![
                Matcher::UrlEncoded("select".into(), "*".into()),
                Matcher::UrlEncoded("gap_id".into(), "eq.CREDIBLE-RACE".into()),
                Matcher::UrlEncoded("released_at".into(), "is.null".into()),
            ]))
            .with_status(200)
            .with_body(
                r#"[{
                    "id": "00000000-0000-0000-0000-000000000042",
                    "gap_id": "CREDIBLE-RACE",
                    "team_id": "00000000-0000-0000-0000-000000000000",
                    "operator_user_id": "00000000-0000-0000-0000-000000000000",
                    "worker_machine": "peer-node",
                    "session_id": "sess-peer",
                    "claimed_at": "2026-11-25T00:00:00Z",
                    "expires_at": "2026-11-25T01:00:00Z",
                    "released_at": null,
                    "release_reason": null
                }]"#,
            )
            .expect(1)
            .create_async()
            .await;

        let client = test_client(server.url());
        let outcome = client
            .try_claim_gap(
                "CREDIBLE-RACE",
                team_id,
                user_id,
                "local-node",
                "sess-me",
                60,
            )
            .await
            .unwrap();
        match outcome {
            ClaimResult::Lost { held_by } => assert_eq!(held_by.worker_machine, "peer-node"),
            ClaimResult::Won(_) => panic!("expected Lost on 23505 conflict"),
        }

        empty_probe.assert_async().await;
        conflict_insert.assert_async().await;
        winner_probe.assert_async().await;
    }
}
