use jelly_daemon::jellyfin::JellyfinClient;
use std::process::Command as P;
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let user = P::new("rbw")
        .args(["get", "--field", "username", "jellyfin.mcconkie.dev"])
        .output()?;
    let pw = P::new("rbw")
        .args(["get", "jellyfin.mcconkie.dev"])
        .output()?;
    let user = String::from_utf8(user.stdout)?.trim().to_string();
    let pw = String::from_utf8(pw.stdout)?.trim().to_string();
    let mut c = JellyfinClient::new("https://jellyfin.mcconkie.dev");
    c.authenticate(&user, &pw).await?;
    let uid = c.user_id().unwrap().to_string();

    // `cargo run --bin probe -- mixtime` times the mix-track query with the
    // current field set vs a lean one, to isolate the play-mix latency.
    if std::env::args().any(|a| a == "mixtime") {
        use jelly_daemon::jellyfin::mix_labels;
        use std::collections::HashMap;
        use std::time::Instant;
        let allal = c.all_albums().await?;
        let mut map: HashMap<String, usize> = HashMap::new();
        for a in allal.iter() {
            for t in mix_labels(&a.tags.clone().unwrap_or_default()) {
                *map.entry(t).or_insert(0) += 1;
            }
        }
        let mut tags: Vec<(String, usize)> = map.into_iter().collect();
        tags.sort_by(|a, b| b.1.cmp(&a.1));
        println!("mix tags by album count: {tags:?}");
        for (tag, _) in tags.iter().take(3) {
            let stored = format!("mix:{tag}");
            let t0 = Instant::now();
            let full: jelly_daemon::jellyfin::ItemsResponse = c
                .get_json(
                    "/Items",
                    &[
                        ("userId", uid.as_str()),
                        ("includeItemTypes", "Audio"),
                        ("recursive", "true"),
                        ("tags", stored.as_str()),
                        (
                            "fields",
                            "ImageTags,MediaSources,Artists,ProductionYear,ParentIndexNumber,IndexNumber",
                        ),
                        ("limit", "100000"),
                    ],
                )
                .await?;
            println!(
                "[full] {tag}: {} items in {:?}",
                full.items.len(),
                t0.elapsed()
            );
            let t1 = Instant::now();
            let lean: jelly_daemon::jellyfin::ItemsResponse = c
                .get_json(
                    "/Items",
                    &[
                        ("userId", uid.as_str()),
                        ("includeItemTypes", "Audio"),
                        ("recursive", "true"),
                        ("tags", stored.as_str()),
                        ("fields", "ImageTags,Artists"),
                    ],
                )
                .await?;
            println!(
                "[lean] {tag}: {} items in {:?}",
                lean.items.len(),
                t1.elapsed()
            );
            if let Some(x) = lean.items.first() {
                println!(
                    "  lean sample: {} year={:?} disc={:?} track={:?} dur={:?}",
                    x.name,
                    x.production_year,
                    x.parent_index_number,
                    x.index_number,
                    x.run_time_ticks.map(|v| v as f64 / 1e7)
                );
            }
        }
        return Ok(());
    }

    // `cargo run --bin probe -- mixalbum` times resolving a mix via parallel
    // per-album parentId lookups (the proposed optimization).
    if std::env::args().any(|a| a == "mixalbum") {
        use futures::stream::{self, StreamExt};
        use jelly_daemon::jellyfin::mix_labels;
        use std::collections::HashMap;
        use std::time::Instant;
        let allal = c.all_albums().await?;
        let mut map: HashMap<String, Vec<String>> = HashMap::new();
        for a in allal.iter() {
            for t in mix_labels(&a.tags.clone().unwrap_or_default()) {
                map.entry(t).or_default().push(a.id.clone());
            }
        }
        let mut tags: Vec<(String, Vec<String>)> = map.into_iter().collect();
        tags.sort_by(|a, b| b.1.len().cmp(&a.1.len()));
        for (tag, album_ids) in tags.iter().take(3) {
            let ids = album_ids.clone();
            let n = ids.len();
            let t0 = Instant::now();
            let all = stream::iter(ids)
                .map(|id| {
                    let cc = c.clone();
                    async move { cc.tracks_for_album(&id).await.unwrap_or_default() }
                })
                .buffer_unordered(16)
                .fold(Vec::new(), |mut acc, mut chunk| async move {
                    acc.append(&mut chunk);
                    acc
                })
                .await;
            println!(
                "[album-parallel] {tag}: {n} albums -> {} tracks in {:?}",
                all.len(),
                t0.elapsed()
            );
        }
        return Ok(());
    }

    let albums: jelly_daemon::jellyfin::ItemsResponse = c
        .get_json(
            "/Items",
            &[
                ("userId", uid.as_str()),
                ("includeItemTypes", "MusicAlbum"),
                ("recursive", "true"),
                ("sortBy", "SortName"),
                ("limit", "100"),
            ],
        )
        .await?;
    println!("== {} MusicAlbums (recursive):", albums.total);
    for a in albums.items.iter() {
        println!("  album {} ({}) artist={:?}", a.name, a.id, a.album_artist);
    }
    let pls = c.playlists().await?;
    println!("== playlists:");
    for p in pls.iter() {
        println!("  playlist {} ({})", p.name, p.id);
    }
    if let Some(p) = pls.first() {
        let ts = c.tracks_for_album(&p.id).await?;
        println!("== {} tracks in playlist {}", ts.len(), p.name);
        for t in ts.iter().take(6) {
            println!("  track {} artist={:?}", t.name, t.album_artist);
        }
    }
    for a in albums.items.iter().take(2) {
        let ts = c.tracks_for_album(&a.id).await?;
        println!("== {} tracks on {}:", ts.len(), a.name);
        for t in ts.iter() {
            println!(
                "  track {} artist={:?} dur={:?}",
                t.name,
                t.album_artist,
                t.run_time_ticks.map(|x| x as f64 / 1e7)
            );
        }
    }
    // PROTOTYPE data dump for the widget's MockLibrary.json (throwaway).
    let mut albums_out = Vec::new();
    let base = "https://jellyfin.mcconkie.dev";
    for a in albums.items.iter() {
        let ts = c.tracks_for_album(&a.id).await?;
        albums_out.push(serde_json::json!({
            "id": a.id,
            "title": a.name,
            "artist": a.album_artist.clone().unwrap_or_default(),
            "cover": format!("{base}/Items/{}/Images/Primary?fillWidth=320&quality=90", a.id),
            "tracks": ts.iter().map(|t| serde_json::json!({
                "id": t.id,
                "title": t.name,
                "artist": t.album_artist.clone().unwrap_or_default(),
                "length": t.run_time_ticks.map(|x| (x as f64 / 1e7).round() as i64).unwrap_or(0),
            })).collect::<Vec<_>>(),
        }));
    }
    let mut pls_out = Vec::new();
    for p in pls.iter() {
        let children = c.tracks_for_album(&p.id).await?;
        // PROTOTYPE: inline nested playlists (e.g. a "Playlists" folder that
        // holds real playlists like "Zelda") as items with their tracks.
        let mut items_out = Vec::new();
        for ch in children.iter() {
            let is_playlist = ch.item_type.as_deref() == Some("Playlist");
            let mut item = serde_json::json!({
                "id": ch.id,
                "type": ch.item_type.clone().unwrap_or_default(),
                "title": ch.name,
                "artist": ch.album_artist.clone().unwrap_or_default(),
                "length": ch.run_time_ticks.map(|x| (x as f64 / 1e7).round() as i64).unwrap_or(0),
                "cover": format!("{}/Items/{}/Images/Primary?fillWidth=320&quality=90", "https://jellyfin.mcconkie.dev", ch.id),
            });
            if is_playlist {
                let ts = c.tracks_for_album(&ch.id).await?;
                item["tracks"] = serde_json::json!(ts.iter().map(|t| serde_json::json!({
                    "id": t.id,
                    "type": "Audio",
                    "title": t.name,
                    "artist": t.album_artist.clone().unwrap_or_default(),
                    "album": "",
                    "length": t.run_time_ticks.map(|x| (x as f64 / 1e7).round() as i64).unwrap_or(0),
                })).collect::<Vec<_>>());
            }
            items_out.push(item);
        }
        pls_out.push(serde_json::json!({
            "id": p.id,
            "name": p.name,
            "items": items_out,
        }));
    }
    let out_path = std::env::var("JELLY_MOCK_OUT").unwrap_or_else(|_| {
        "/home/eddie/.config/omarchy/plugins/eddie.jelly/MockLibrary.json".into()
    });
    std::fs::write(
        &out_path,
        serde_json::to_string_pretty(&serde_json::json!({
            "albums": albums_out,
            "playlists": pls_out,
        }))?,
    )?;
    println!("== wrote {}", out_path);
    if let Some(a) = albums.items.first() {
        let tracks = c.tracks_for_album(&a.id).await?;
        println!("== {} tracks on {}", tracks.len(), a.name);
        let mut first_ids = Vec::new();
        for t in tracks.iter().take(5) {
            println!(
                "  track {} ({}) dur={:?}",
                t.name,
                t.id,
                t.run_time_ticks.map(|x| x as f64 / 1e7)
            );
            first_ids.push(t.id.clone());
        }
        println!("IDS={:?}", first_ids);
    }
    Ok(())
}
