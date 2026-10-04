use sage_backend::{Store, app};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token =
        std::env::var("SAGE_TOKEN").map_err(|_| "Set SAGE_TOKEN (at least 32 characters)")?;
    let key = hex::decode(
        std::env::var("SAGE_DATA_KEY").map_err(|_| "Set SAGE_DATA_KEY (64 hex characters)")?,
    )?;
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "SAGE_DATA_KEY must encode 32 bytes")?;
    let path = std::env::var("SAGE_DB").unwrap_or_else(|_| "data/sage.sqlite".into());
    if let Some(parent) = std::path::Path::new(&path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)?;
    }
    let store = Store::open(&path, &key, token)?;
    sage_backend::inference::start_worker(store.clone())?;
    let addr = std::env::var("SAGE_BIND").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("Sage single-user backend listening on {addr}; cloud AI disabled");
    axum::serve(listener, app(store))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
