//! Minimal Jellyfin HTTP client: the endpoints the prototype needs.
//!
//! Reference: research/jellyfin-api.md

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const CLIENT_NAME: &str = "Jelly";
pub const CLIENT_VERSION: &str = "0.1.0";
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
pub struct JellyfinClient {
    base_url: String,
    token: Option<String>,
    user_id: Option<String>,
    device_id: String,
    http: reqwest::Client,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "PascalCase")]
struct AuthRequest {
    username: String,
    pw: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AuthResponse {
    access_token: String,
    user: AuthUser,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AuthUser {
    id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaItem {
    pub id: String,
    pub name: String,
    #[serde(rename = "Type", default)]
    pub item_type: Option<String>,
    #[serde(rename = "AlbumArtist", default)]
    pub album_artist: Option<String>,
    #[serde(rename = "AlbumId", default)]
    pub album_id: Option<String>,
    #[serde(default)]
    pub artists: Option<Vec<String>>,
    #[serde(rename = "RunTimeTicks", default)]
    pub run_time_ticks: Option<i64>,
    #[serde(rename = "ImageTags", default)]
    pub image_tags: Option<ImageTags>,
    #[serde(rename = "MediaSources", default)]
    pub media_sources: Option<Vec<MediaSource>>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "PascalCase")]
pub struct ImageTags {
    #[serde(default)]
    pub primary: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaSource {
    pub container: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ItemsResponse {
    #[serde(rename = "TotalRecordCount", default)]
    pub total: i64,
    #[serde(rename = "Items", default)]
    pub items: Vec<MediaItem>,
}

impl JellyfinClient {
    pub fn new(base_url: &str) -> Self {
        let device_id = format!("jelly-{}", uuid::Uuid::new_v4().simple());
        let http = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .build()
            .expect("reqwest client builds");
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: None,
            user_id: None,
            device_id,
            http,
        }
    }

    pub fn with_token(base_url: &str, token: String, user_id: String, device_id: String) -> Self {
        let mut client = Self::new(base_url);
        client.device_id = device_id;
        client.token = Some(token);
        client.user_id = Some(user_id);
        client
    }

    pub fn is_authenticated(&self) -> bool {
        self.token.is_some() && self.user_id.is_some()
    }

    pub fn user_id(&self) -> Option<&str> {
        self.user_id.as_deref()
    }

    /// `Authorization: MediaBrowser Client=..., Token=...` convention.
    fn auth_header(&self) -> String {
        let mut header = format!(
            "MediaBrowser Client=\"{CLIENT_NAME}\", Device=\"jelly-daemon\", DeviceId=\"{}\", Version=\"{CLIENT_VERSION}\"",
            self.device_id
        );
        if let Some(token) = &self.token {
            header.push_str(&format!(", Token=\"{token}\""));
        }
        header
    }

    pub async fn authenticate(&mut self, username: &str, password: &str) -> Result<String> {
        let url = format!("{}/Users/AuthenticateByName", self.base_url);
        let resp = self
            .http
            .post(&url)
            .header("X-Emby-Authorization", self.auth_header())
            .json(&AuthRequest {
                username: username.to_string(),
                pw: password.to_string(),
            })
            .send()
            .await
            .context("login request failed")?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!("login failed: HTTP {status}");
        }
        let auth: AuthResponse = resp.json().await.context("bad login response")?;
        self.token = Some(auth.access_token.clone());
        self.user_id = Some(auth.user.id.clone());
        Ok(auth.access_token)
    }

    pub async fn get_json<T: for<'de> Deserialize<'de>>(&self, path: &str, query: &[(&str, &str)]) -> Result<T> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self
            .http
            .get(&url)
            .header("Authorization", self.auth_header())
            .query(query)
            .send()
            .await
            .with_context(|| format!("GET {path} failed"))?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!("GET {path}: HTTP {status}");
        }
        Ok(resp.json().await.with_context(|| format!("bad JSON from {path}"))?)
    }

    /// Direct-play URL. Auth rides in the query string because mpv fetches
    /// this URL itself and cannot send our header.
    pub fn stream_url(&self, item_id: &str) -> Option<String> {
        let token = self.token.as_ref()?;
        Some(format!(
            "{}/Audio/{item_id}/stream?static=true&api_key={token}",
            self.base_url
        ))
    }

    pub fn image_url(&self, item: &MediaItem) -> Option<String> {
        item.image_tags
            .as_ref()?
            .primary
            .is_some()
            .then(|| format!("{}/Items/{}/Images/Primary", self.base_url, item.id))
    }

    /// Album artists — the top of the browse tree.
    pub async fn album_artists(&self) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Artists/AlbumArtists",
                &[
                    ("userId", user_id),
                    ("sortBy", "SortName"),
                    ("limit", "100"),
                ],
            )
            .await?;
        Ok(resp.items)
    }

    pub async fn albums_for_artist(&self, artist_id: &str) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("includeItemTypes", "MusicAlbum"),
                    ("albumArtistIds", artist_id),
                    ("recursive", "true"),
                    ("sortBy", "ProductionYear,SortName"),
                    ("fields", "ImageTags,MediaSources"),
                ],
            )
            .await?;
        Ok(resp.items)
    }

    pub async fn tracks_for_album(&self, album_id: &str) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("includeItemTypes", "Audio"),
                    ("parentId", album_id),
                    ("sortBy", "ParentIndexNumber,IndexNumber"),
                    ("fields", "ImageTags,MediaSources,Artists"),
                ],
            )
            .await?;
        Ok(resp.items)
    }

    /// User playlists.
    pub async fn playlists(&self) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("includeItemTypes", "Playlist"),
                    ("sortBy", "SortName"),
                ],
            )
            .await?;
        Ok(resp.items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_header_shape() {
        let client = JellyfinClient::new("http://localhost:8096");
        let header = client.auth_header();
        assert!(header.starts_with("MediaBrowser Client=\"Jelly\""));
        assert!(!header.contains("Token="));
    }

    #[test]
    fn stream_url_requires_token() {
        let client = JellyfinClient::new("http://localhost:8096");
        assert!(client.stream_url("abc").is_none());
        let client = JellyfinClient::with_token(
            "http://localhost:8096",
            "tok".into(),
            "uid".into(),
            "dev".into(),
        );
        assert_eq!(
            client.stream_url("abc").unwrap(),
            "http://localhost:8096/Audio/abc/stream?static=true&api_key=tok"
        );
    }
}
