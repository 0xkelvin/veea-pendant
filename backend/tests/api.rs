use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use sage_backend::{Store, app};
use serde_json::{Value, json};
use tower::ServiceExt;
const TOKEN: &str = "test-token-with-at-least-32-characters";
fn sample() -> Value {
    json!({"id":"sample-1","title":"Mixed speech", "createdAt":"2026-10-04T00:00:00Z", "source":"import", "reference":"Mình chưa gửi firmware.", "duration":12.0, "captureWarning":null, "runs":[], "memories":[{"id":"m1","text":"Chưa gửi firmware", "evidence":"chưa gửi firmware", "kind":"observation","status":"pending"}]})
}
fn req(method: &str, path: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {TOKEN}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}
#[tokio::test]
async fn auth_roundtrip_validation_deletion_and_encryption() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db.sqlite");
    let store = Store::open(path.to_str().unwrap(), &[7; 32], TOKEN.into()).unwrap();
    let router = app(store);
    let unauth = router
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/sessions")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unauth.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        router
            .clone()
            .oneshot(req("PUT", "/v1/sessions/sample-1", sample()))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let response = router
        .clone()
        .oneshot(req("GET", "/v1/sessions/sample-1", Value::Null))
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    let body = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(serde_json::from_slice::<Value>(&body).unwrap(), sample());
    let db = rusqlite::Connection::open(&path).unwrap();
    let blob: Vec<u8> = db
        .query_row("SELECT data FROM sessions", [], |r| r.get(0))
        .unwrap();
    assert!(!blob.windows(b"firmware".len()).any(|w| w == b"firmware"));
    assert!(Store::open(path.to_str().unwrap(), &[8; 32], TOKEN.into()).is_err());
    let mut invalid = sample();
    invalid["reference"] = json!("Mình đã gửi firmware.");
    assert_eq!(
        router
            .clone()
            .oneshot(req("PUT", "/v1/sessions/sample-1", invalid))
            .await
            .unwrap()
            .status(),
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        router
            .clone()
            .oneshot(req("DELETE", "/v1/sessions/sample-1", Value::Null))
            .await
            .unwrap()
            .status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        router
            .oneshot(req("GET", "/v1/sessions/sample-1", Value::Null))
            .await
            .unwrap()
            .status(),
        StatusCode::NOT_FOUND
    );
}
