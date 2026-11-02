use std::{net::SocketAddr, path::Path, time::Duration};

use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("could not read {path}: {source}")]
    Read { path: String, source: std::io::Error },
    #[error("invalid config: {0}")]
    Parse(#[from] toml::de::Error),
    #[error("request_timeout_ms must be between 100 and 60000, got {0}")]
    Timeout(u64),
}

#[derive(Debug, Deserialize)]
struct RawConfig {
    listen: SocketAddr,
    database_url_env: String,
    request_timeout_ms: u64,
}

#[derive(Debug)]
pub struct Config {
    pub listen: SocketAddr,
    pub database_url_env: String,
    pub request_timeout: Duration,
}

pub async fn load(path: &Path) -> Result<Config, ConfigError> {
    let text = tokio::fs::read_to_string(path)
        .await
        .map_err(|source| ConfigError::Read { path: path.display().to_string(), source })?;
    let raw: RawConfig = toml::from_str(&text)?;
    if !(100..=60_000).contains(&raw.request_timeout_ms) {
        return Err(ConfigError::Timeout(raw.request_timeout_ms));
    }
    Ok(Config {
        listen: raw.listen,
        database_url_env: raw.database_url_env,
        request_timeout: Duration::from_millis(raw.request_timeout_ms),
    })
}
