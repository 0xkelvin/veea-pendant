use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, AeadCore, OsRng, Payload},
};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, State},
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, put},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use subtle::ConstantTimeEq;
pub mod inference;

pub struct Store {
    db: Mutex<Connection>,
    cipher: Aes256Gcm,
    token: String,
}
impl Store {
    pub fn open(path: &str, key: &[u8; 32], token: String) -> Result<Arc<Self>, String> {
        if token.len() < 32 {
            return Err("SAGE_TOKEN must be at least 32 characters".into());
        }
        let db = Connection::open(path).map_err(|e| e.to_string())?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS config (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL);").map_err(|e| e.to_string())?;
        let store = Arc::new(Self {
            db: Mutex::new(db),
            cipher: Aes256Gcm::new_from_slice(key).map_err(|_| "Invalid encryption key")?,
            token,
        });
        let stored: Option<Vec<u8>> = store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT data FROM config WHERE id=1", [], |r| r.get(0))
            .optional()
            .map_err(|e| e.to_string())?;
        if let Some(bytes) = stored {
            store
                .decrypt("key-check", &bytes)
                .map_err(|_| "SAGE_DATA_KEY does not unlock this database")?;
        } else {
            let bytes = store
                .encrypt("key-check", b"sage-v1")
                .map_err(|_| "Encryption failed")?;
            store
                .db
                .lock()
                .unwrap()
                .execute("INSERT INTO config VALUES (1, ?1)", params![bytes])
                .map_err(|e| e.to_string())?;
        }
        Ok(store)
    }
    fn encrypt(&self, id: &str, data: &[u8]) -> Result<Vec<u8>, ()> {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let encrypted = self
            .cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: data,
                    aad: id.as_bytes(),
                },
            )
            .map_err(|_| ())?;
        Ok([nonce.to_vec(), encrypted].concat())
    }
    fn decrypt(&self, id: &str, data: &[u8]) -> Result<Vec<u8>, ()> {
        if data.len() < 28 {
            return Err(());
        }
        self.cipher
            .decrypt(
                Nonce::from_slice(&data[..12]),
                Payload {
                    msg: &data[12..],
                    aad: id.as_bytes(),
                },
            )
            .map_err(|_| ())
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Session {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub source: String,
    pub reference: Option<String>,
    pub duration: f64,
    pub capture_warning: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processing: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processing_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topics: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_diagnostics: Option<Value>,
    pub runs: Vec<Run>,
    pub memories: Vec<Memory>,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Run {
    pub model: String,
    pub text: String,
    pub seconds: f64,
    pub segments: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quiet_speech: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_stats: Option<Value>,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Memory {
    pub id: String,
    pub text: String,
    pub evidence: String,
    pub kind: String,
    pub status: String,
}

pub fn validate(s: &Session) -> Result<(), &'static str> {
    if s.id.is_empty()
        || s.id.len() > 100
        || !s.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("Invalid session id");
    }
    if s.title.trim().is_empty() || s.title.len() > 500 || s.created_at.len() > 50 {
        return Err("Invalid session metadata");
    }
    if !["limitless", "limitless_offline", "microphone", "import"].contains(&s.source.as_str()) {
        return Err("Invalid source");
    }
    if !s.duration.is_finite() || s.duration < 0. || s.runs.len() > 20 || s.memories.len() > 100 {
        return Err("Invalid limits");
    }
    if s.runs.iter().any(|r| {
        !r.seconds.is_finite()
            || r.seconds < 0.
            || r.text.len() > 250_000
            || r.segments.len() > 10_000
    }) {
        return Err("Invalid transcript run");
    }
    let reference = s.reference.as_deref().unwrap_or("");
    if reference.len() > 250_000 {
        return Err("Reference too long");
    }
    let mut ids = std::collections::HashSet::new();
    for m in &s.memories {
        if !ids.insert(&m.id)
            || m.id.is_empty()
            || m.id.len() > 100
            || m.text.trim().is_empty()
            || m.text.len() > 4000
        {
            return Err("Invalid memory");
        }
        if !["pending", "accepted", "rejected"].contains(&m.status.as_str()) {
            return Err("Invalid memory status");
        }
        if m.evidence.trim().is_empty() || !reference.contains(&m.evidence) {
            return Err("Every memory needs an exact quote from the reviewed transcript");
        }
    }
    Ok(())
}

type ApiResult<T> = Result<T, ApiError>;
pub struct ApiError(StatusCode, &'static str);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}
fn internal() -> ApiError {
    ApiError(
        StatusCode::INTERNAL_SERVER_ERROR,
        "Storage operation failed",
    )
}

pub fn app(store: Arc<Store>) -> Router {
    let private = Router::new()
        .merge(inference::routes())
        .route("/v1/sessions", get(list))
        .route("/v1/sessions/{id}", put(save).get(read).delete(remove))
        .route_layer(middleware::from_fn_with_state(store.clone(), authorize));
    Router::new()
        .route(
            "/health",
            get(|| async {
                Json(json!({"status":"ok", "version":"0.1.0", "cloudAi":false, "singleUser":true}))
            }),
        )
        .merge(private)
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
        .with_state(store)
}
async fn authorize(State(store): State<Arc<Store>>, req: Request<Body>, next: Next) -> Response {
    let token = req
        .headers()
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .unwrap_or("");
    if !bool::from(token.as_bytes().ct_eq(store.token.as_bytes())) {
        return ApiError(StatusCode::UNAUTHORIZED, "Unauthorized").into_response();
    }
    let mut response = next.run(req).await;
    response
        .headers_mut()
        .insert("cache-control", "no-store".parse().unwrap());
    response
}
async fn save(
    State(store): State<Arc<Store>>,
    Path(id): Path<String>,
    Json(session): Json<Session>,
) -> ApiResult<Json<Value>> {
    if id != session.id {
        return Err(ApiError(StatusCode::BAD_REQUEST, "ID mismatch"));
    }
    validate(&session).map_err(|e| ApiError(StatusCode::BAD_REQUEST, e))?;
    tokio::task::spawn_blocking(move || {
        let bytes = serde_json::to_vec(&session).map_err(|_| internal())?;
        let encrypted = store.encrypt(&id, &bytes).map_err(|_| internal())?;
        store.db.lock().map_err(|_| internal())?.execute("INSERT INTO sessions(id,data) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET data=excluded.data", params![id, encrypted]).map_err(|_| internal())?;
        Ok(Json(json!({"saved":true})))
    }).await.map_err(|_| internal())?
}
async fn read(State(store): State<Arc<Store>>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(move || {
        let encrypted: Option<Vec<u8>> = store
            .db
            .lock()
            .map_err(|_| internal())?
            .query_row("SELECT data FROM sessions WHERE id=?1", params![id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| internal())?;
        let bytes = encrypted.ok_or(ApiError(StatusCode::NOT_FOUND, "Not found"))?;
        let plain = store.decrypt(&id, &bytes).map_err(|_| internal())?;
        Ok(Json(
            serde_json::from_slice(&plain).map_err(|_| internal())?,
        ))
    })
    .await
    .map_err(|_| internal())?
}
async fn list(State(store): State<Arc<Store>>) -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(move || {
        let db = store.db.lock().map_err(|_| internal())?;
        let mut stmt = db
            .prepare("SELECT id FROM sessions ORDER BY id DESC LIMIT 1000")
            .map_err(|_| internal())?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|_| internal())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| internal())?;
        Ok(Json(json!({"ids":ids, "limit":1000})))
    })
    .await
    .map_err(|_| internal())?
}
async fn remove(State(store): State<Arc<Store>>, Path(id): Path<String>) -> ApiResult<StatusCode> {
    tokio::task::spawn_blocking(move || {
        store
            .db
            .lock()
            .map_err(|_| internal())?
            .execute("DELETE FROM sessions WHERE id=?1", params![id])
            .map_err(|_| internal())?;
        Ok(StatusCode::NO_CONTENT)
    })
    .await
    .map_err(|_| internal())?
}
