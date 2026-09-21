//! Minimal Jellyfin HTTP client: the endpoints the prototype needs.
//!
//! Reference: research/jellyfin-api.md

use anyhow::{Context, Result};
use jelly_ipc::BrowseItem;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

pub const CLIENT_NAME: &str = "Jelly";
pub const CLIENT_VERSION: &str = "0.1.0";
const TIMEOUT: Duration = Duration::from_secs(30);
const MIX_TAG_PREFIX: &str = "mix:";

pub fn mix_label(tag: &str) -> Option<String> {
    tag.strip_prefix(MIX_TAG_PREFIX)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
}

fn mix_tag(label: &str) -> String {
    format!("{MIX_TAG_PREFIX}{}", label.trim())
}

fn api_uuid(id: &str) -> String {
    if id.len() == 32 {
        format!(
            "{}-{}-{}-{}-{}",
            &id[0..8],
            &id[8..12],
            &id[12..16],
            &id[16..20],
            &id[20..32]
        )
    } else {
        id.to_string()
    }
}

fn clone_field(item: &Value, field: &str, default: Value) -> Value {
    item.get(field).cloned().unwrap_or(default)
}

fn metadata_update_body(item: &Value, tags: Vec<String>) -> Value {
    // Mirrors Jellyfin Web's metadata editor DTO. Jellyfin 10.11 rejects
    // smaller tag-only bodies for album metadata updates.
    json!({
        "Id": clone_field(item, "Id", Value::Null),
        "Name": clone_field(item, "Name", json!("")),
        "OriginalTitle": clone_field(item, "OriginalTitle", json!("")),
        "OriginalLanguage": clone_field(item, "OriginalLanguage", json!("")),
        "ForcedSortName": clone_field(item, "ForcedSortName", clone_field(item, "SortName", json!(""))),
        "CommunityRating": clone_field(item, "CommunityRating", Value::Null),
        "CriticRating": clone_field(item, "CriticRating", Value::Null),
        "IndexNumber": clone_field(item, "IndexNumber", Value::Null),
        "AirsBeforeSeasonNumber": clone_field(item, "AirsBeforeSeasonNumber", Value::Null),
        "AirsAfterSeasonNumber": clone_field(item, "AirsAfterSeasonNumber", Value::Null),
        "AirsBeforeEpisodeNumber": clone_field(item, "AirsBeforeEpisodeNumber", Value::Null),
        "ParentIndexNumber": clone_field(item, "ParentIndexNumber", Value::Null),
        "DisplayOrder": clone_field(item, "DisplayOrder", json!("")),
        "Album": clone_field(item, "Album", json!("")),
        "AlbumArtists": clone_field(item, "AlbumArtists", json!([])),
        "ArtistItems": clone_field(item, "ArtistItems", json!([])),
        "SeriesName": clone_field(item, "SeriesName", json!("")),
        "Overview": clone_field(item, "Overview", json!("")),
        "Status": clone_field(item, "Status", json!("")),
        "AirDays": clone_field(item, "AirDays", json!([])),
        "AirTime": clone_field(item, "AirTime", json!("")),
        "Genres": clone_field(item, "Genres", json!([])),
        "Tags": tags,
        "Studios": clone_field(item, "Studios", json!([])),
        "PremiereDate": clone_field(item, "PremiereDate", Value::Null),
        "DateCreated": clone_field(item, "DateCreated", Value::Null),
        "EndDate": clone_field(item, "EndDate", Value::Null),
        "ProductionYear": clone_field(item, "ProductionYear", Value::Null),
        "Height": clone_field(item, "Height", Value::Null),
        "AspectRatio": clone_field(item, "AspectRatio", json!("")),
        "Video3DFormat": clone_field(item, "Video3DFormat", Value::Null),
        "OfficialRating": clone_field(item, "OfficialRating", json!("")),
        "CustomRating": clone_field(item, "CustomRating", json!("")),
        "People": clone_field(item, "People", json!([])),
        "LockData": clone_field(item, "LockData", json!(false)),
        "LockedFields": clone_field(item, "LockedFields", json!([])),
        "ProviderIds": clone_field(item, "ProviderIds", json!({})),
        "PreferredMetadataLanguage": clone_field(item, "PreferredMetadataLanguage", json!("")),
        "PreferredMetadataCountryCode": clone_field(item, "PreferredMetadataCountryCode", json!("")),
        "Taglines": clone_field(item, "Taglines", json!([])),
    })
}

pub fn mix_labels(tags: &[String]) -> Vec<String> {
    let mut labels = std::collections::BTreeMap::new();
    for label in tags.iter().filter_map(|t| mix_label(t)) {
        labels.entry(label.to_lowercase()).or_insert(label);
    }
    labels.into_values().collect()
}

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
    #[serde(rename = "Tags", default)]
    pub tags: Option<Vec<String>>,
    #[serde(rename = "ProductionYear", default)]
    pub production_year: Option<i32>,
    #[serde(rename = "ParentIndexNumber", default)]
    pub parent_index_number: Option<i32>,
    #[serde(rename = "IndexNumber", default)]
    pub index_number: Option<i32>,
    #[serde(rename = "UserData", default)]
    user_data: Option<UserData>,
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

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "PascalCase")]
struct UserData {
    is_favorite: Option<bool>,
    #[serde(default)]
    rating: Option<f64>,
}

/// Body of `POST /Users/{uid}/Items/{id}/UserData` (10.11 semantics:
/// every present field is applied, absent fields are untouched — so
/// `rating` is only ever `Some` here; clearing goes via the Rating
/// DELETE route instead).
#[derive(Debug, Serialize, Default)]
#[serde(rename_all = "PascalCase")]
struct UpdateUserItemData {
    #[serde(skip_serializing_if = "Option::is_none")]
    rating: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    is_favorite: Option<bool>,
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

    /// Credentials for the session websocket, once authenticated.
    pub fn session(&self, server_url: &str) -> Option<crate::session::Session> {
        let token = self.token.as_ref()?;
        let user_id = self.user_id.as_ref()?;
        Some(crate::session::Session {
            ws_url: crate::session::ws_url(server_url, token),
            user_id: user_id.clone(),
        })
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

    pub async fn get_json<T: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<T> {
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
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("GET {path}: HTTP {status}: {body}");
        }
        Ok(resp
            .json()
            .await
            .with_context(|| format!("bad JSON from {path}"))?)
    }

    async fn post_json<B: Serialize + ?Sized>(&self, path: &str, body: &B) -> Result<()> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self
            .http
            .post(&url)
            .header("Authorization", self.auth_header())
            .json(body)
            .send()
            .await
            .with_context(|| format!("POST {path} failed"))?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("POST {path}: HTTP {status}: {body}");
        }
        Ok(())
    }

    async fn delete_json(&self, path: &str) -> Result<()> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self
            .http
            .delete(&url)
            .header("Authorization", self.auth_header())
            .send()
            .await
            .with_context(|| format!("DELETE {path} failed"))?;
        if !resp.status().is_success() {
            anyhow::bail!("DELETE {path}: HTTP {}", resp.status());
        }
        Ok(())
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

    /// Toggle the favorite flag on one item; returns the NEW state.
    /// Reads the current flag from the item, then POSTs (add) or DELETEs.
    pub async fn toggle_favorite(&self, item_id: &str) -> Result<bool> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let item: MediaItem = self
            .get_json(&format!("/Users/{user_id}/Items/{item_id}"), &[])
            .await?;
        let fav = item.user_data.and_then(|u| u.is_favorite).unwrap_or(false);
        let url = format!("{}/Users/{user_id}/FavoriteItems/{item_id}", self.base_url);
        let req = if fav {
            self.http.delete(&url)
        } else {
            self.http.post(&url)
        };
        let resp = req
            .header("Authorization", self.auth_header())
            .send()
            .await
            .with_context(|| format!("favorite toggle failed for {item_id}"))?;
        if !resp.status().is_success() {
            anyhow::bail!("favorite toggle: HTTP {}", resp.status());
        }
        Ok(!fav)
    }

    /// All favorited songs for the user (ids only, enough for heart icons).
    pub async fn favorite_ids(&self) -> Result<Vec<String>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("filters", "IsFavorite"),
                    ("includeItemTypes", "Audio"),
                    ("recursive", "true"),
                    ("fields", "MediaSources,Artists"),
                    ("limit", "1000"),
                ],
            )
            .await?;
        Ok(resp.items.into_iter().map(|i| i.id).collect())
    }

    /// Persist a track tier: one UserData write sets rating + favorite
    /// flag (Favorite hearts the item, every other tier unhearts it).
    /// Unrated uses DELETE Rating — the update DTO can set ratings but
    /// never clear them, while DELETE maps likes=null to rating=null.
    pub async fn set_tier(&self, item_id: &str, tier: jelly_ipc::Tier) -> Result<()> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let path = format!("/Users/{user_id}/Items/{item_id}/UserData");
        match tier.rating() {
            Some(rating) => {
                self.post_json(
                    &path,
                    &UpdateUserItemData {
                        rating: Some(rating),
                        is_favorite: Some(tier == jelly_ipc::Tier::Favorite),
                    },
                )
                .await
            }
            None => {
                self.post_json(
                    &path,
                    &UpdateUserItemData {
                        rating: None,
                        is_favorite: Some(false),
                    },
                )
                .await?;
                self.delete_json(&format!("/Users/{user_id}/Items/{item_id}/Rating"))
                    .await
            }
        }
    }

    /// Every rated audio item as (id, tier) — the tier map seed. Unrated
    /// items are absent; a personal library's scores are a small subset.
    pub async fn tier_map(&self) -> Result<std::collections::BTreeMap<String, jelly_ipc::Tier>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                &format!("/Users/{user_id}/Items"),
                &[
                    ("includeItemTypes", "Audio"),
                    ("recursive", "true"),
                    ("enableUserData", "true"),
                    ("limit", "100000"),
                ],
            )
            .await?;
        Ok(resp
            .items
            .iter()
            .filter_map(|i| {
                let rating = i.user_data.as_ref()?.rating?;
                Some((i.id.clone(), jelly_ipc::Tier::from_rating(Some(rating))))
            })
            .collect())
    }

    pub fn image_url(&self, item: &MediaItem) -> Option<String> {
        item.image_tags.as_ref()?.primary.is_some().then(|| {
            format!(
                "{}/Items/{}/Images/Primary?fillWidth=320&quality=90",
                self.base_url, item.id
            )
        })
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

    /// Every album in the library: one request, no artist bridge.
    pub async fn all_albums(&self) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("includeItemTypes", "MusicAlbum"),
                    ("recursive", "true"),
                    ("sortBy", "SortName"),
                    ("fields", "ImageTags,ChildCount,Tags"),
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

    /// Set one album tag/mix. Jellyfin propagates album tag changes to
    /// child tracks; LockedFields prevents future refreshes clobbering it.
    pub async fn set_album_mix_tag(
        &self,
        album_id: &str,
        label: &str,
        present: Option<bool>,
    ) -> Result<Vec<String>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let wanted = mix_tag(label);
        let mut resp: Value = self
            .get_json(
                &format!("/Users/{user_id}/Items"),
                &[
                    ("ids", album_id),
                    (
                        "fields",
                        "ProviderIds,Genres,Studios,Overview,SortName,ProductionYear,PremiereDate,DateCreated,People,Tags",
                    ),
                ],
            )
            .await?;
        let items = resp
            .get_mut("Items")
            .and_then(Value::as_array_mut)
            .context("album response missing Items")?;
        let album = items
            .iter()
            .find(|album| album.get("Id").and_then(Value::as_str) == Some(album_id))
            .with_context(|| format!("album {album_id} not found"))?;
        let mut tags: Vec<String> = album
            .get("Tags")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|tag| tag.as_str().map(ToString::to_string))
            .collect();
        let existing = tags.iter().position(|t| t.eq_ignore_ascii_case(&wanted));
        let should_exist = present.unwrap_or(existing.is_none());
        match (existing, should_exist) {
            (Some(pos), false) => {
                tags.remove(pos);
            }
            (None, true) => tags.push(wanted),
            _ => {}
        }
        tags.sort_by_key(|t| t.to_lowercase());
        let body = metadata_update_body(album, tags.clone());
        self.post_json(&format!("/Items/{}", api_uuid(album_id)), &body)
            .await?;
        Ok(mix_labels(&tags))
    }

    /// Full track list for a mix tag. Sorting is album release year desc,
    /// then disc, then track; contexts remain unfiltered by score.
    pub async fn tracks_for_tag(&self, tag: &str) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let stored_tag = mix_tag(tag);
        let resp: ItemsResponse = self
            .get_json(
                "/Items",
                &[
                    ("userId", user_id),
                    ("includeItemTypes", "Audio"),
                    ("recursive", "true"),
                    ("tags", &stored_tag),
                    ("fields", "ImageTags,MediaSources,Artists,ProductionYear,ParentIndexNumber,IndexNumber"),
                    ("limit", "100000"),
                ],
            )
            .await?;
        let mut items = resp.items;
        items.sort_by(|a, b| {
            b.production_year
                .unwrap_or_default()
                .cmp(&a.production_year.unwrap_or_default())
                .then(
                    a.parent_index_number
                        .unwrap_or_default()
                        .cmp(&b.parent_index_number.unwrap_or_default()),
                )
                .then(
                    a.index_number
                        .unwrap_or_default()
                        .cmp(&b.index_number.unwrap_or_default()),
                )
                .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(items)
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
                    ("recursive", "true"),
                    ("sortBy", "SortName"),
                ],
            )
            .await?;
        Ok(resp.items)
    }

    /// Items of one playlist. NOTE: playlists are NOT browsable with the
    /// parentId trick used for albums — they need their own endpoint.
    pub async fn playlist_tracks(&self, playlist_id: &str) -> Result<Vec<MediaItem>> {
        let user_id = self.user_id.as_deref().context("not authenticated")?;
        let path = format!("/Playlists/{playlist_id}/Items");
        let resp: ItemsResponse = self
            .get_json(
                &path,
                &[
                    ("userId", user_id),
                    ("fields", "ImageTags,MediaSources,Artists"),
                ],
            )
            .await?;
        Ok(resp.items)
    }
}

/// Jellyfin item → wire browse item.
pub fn browse_item_from(item: &MediaItem, image_url: Option<String>) -> BrowseItem {
    BrowseItem {
        id: item.id.clone(),
        name: item.name.clone(),
        item_type: item.item_type.clone().unwrap_or_default(),
        detail: item
            .album_artist
            .clone()
            .or_else(|| item.artists.as_ref().and_then(|a| a.first().cloned()))
            .unwrap_or_default(),
        duration_secs: item.run_time_ticks.map(|t| t as f64 / 10_000_000.0),
        image_url,
        tags: mix_labels(&item.tags.clone().unwrap_or_default()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_data_body_omits_absent_fields() {
        // 10.11 applies exactly the fields present in the DTO.
        let b = UpdateUserItemData {
            rating: None,
            is_favorite: Some(false),
        };
        assert_eq!(
            serde_json::to_string(&b).unwrap(),
            r#"{"IsFavorite":false}"#
        );
        let b = UpdateUserItemData {
            rating: Some(8.0),
            is_favorite: Some(false),
        };
        assert_eq!(
            serde_json::to_string(&b).unwrap(),
            r#"{"Rating":8.0,"IsFavorite":false}"#
        );
    }

    #[test]
    fn mix_labels_strip_prefix_and_dedupe_case_insensitively() {
        let labels = mix_labels(&[
            "mix:Nintendo".into(),
            "genre:Game".into(),
            "mix:nintendo".into(),
            "mix:Driving".into(),
        ]);
        assert_eq!(labels, vec!["Driving".to_string(), "Nintendo".to_string()]);
    }

    #[test]
    fn media_item_reads_rating_from_user_data() {
        let item: MediaItem = serde_json::from_str(
            r#"{"Id":"x","Name":"T","UserData":{"IsFavorite":false,"Rating":9.0}}"#,
        )
        .unwrap();
        assert_eq!(item.user_data.unwrap().rating, Some(9.0));
        let item: MediaItem =
            serde_json::from_str(r#"{"Id":"x","Name":"T","UserData":{"Rating":null}}"#).unwrap();
        assert_eq!(item.user_data.unwrap().rating, None);
    }

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
