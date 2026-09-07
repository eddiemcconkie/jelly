use jelly_daemon::jellyfin::JellyfinClient;
use std::process::Command as P;
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let user = P::new("rbw").args(["get","--field","username","jellyfin.mcconkie.dev"]).output()?;
    let pw = P::new("rbw").args(["get","jellyfin.mcconkie.dev"]).output()?;
    let user = String::from_utf8(user.stdout)?.trim().to_string();
    let pw = String::from_utf8(pw.stdout)?.trim().to_string();
    let mut c = JellyfinClient::new("https://jellyfin.mcconkie.dev");
    c.authenticate(&user, &pw).await?;
    let uid = c.user_id().unwrap().to_string();
    let albums: jelly_daemon::jellyfin::ItemsResponse = c
        .get_json("/Items", &[
            ("userId", uid.as_str()),
            ("includeItemTypes", "MusicAlbum"),
            ("recursive", "true"),
            ("sortBy", "SortName"),
            ("limit", "100"),
        ]).await?;
    println!("== {} MusicAlbums (recursive):", albums.total);
    for a in albums.items.iter() { println!("  album {} ({}) artist={:?}", a.name, a.id, a.album_artist); }
    let pls = c.playlists().await?;
    println!("== playlists:");
    for p in pls.iter() { println!("  playlist {} ({})", p.name, p.id); }
    if let Some(p) = pls.first() {
        let ts = c.tracks_for_album(&p.id).await?;
        println!("== {} tracks in playlist {}", ts.len(), p.name);
        for t in ts.iter().take(6) { println!("  track {} artist={:?}", t.name, t.album_artist); }
    }
    for a in albums.items.iter().take(2) {
        let ts = c.tracks_for_album(&a.id).await?;
        println!("== {} tracks on {}:", ts.len(), a.name);
        for t in ts.iter() { println!("  track {} artist={:?} dur={:?}", t.name, t.album_artist, t.run_time_ticks.map(|x| x as f64/1e7)); }
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
            "cover": format!("{base}/Items/{}/Images/Primary", a.id),
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
                "cover": format!("{}/Items/{}/Images/Primary", "https://jellyfin.mcconkie.dev", ch.id),
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
    let out_path = std::env::var("JELLY_MOCK_OUT")
        .unwrap_or_else(|_| "/home/eddie/.config/omarchy/plugins/eddie.jelly/MockLibrary.json".into());
    std::fs::write(&out_path, serde_json::to_string_pretty(&serde_json::json!({
        "albums": albums_out,
        "playlists": pls_out,
    }))?)?;
    println!("== wrote {}", out_path);
    if let Some(a) = albums.items.first() {
        let tracks = c.tracks_for_album(&a.id).await?;
        println!("== {} tracks on {}", tracks.len(), a.name);
        let mut first_ids = Vec::new();
        for t in tracks.iter().take(5) {
            println!("  track {} ({}) dur={:?}", t.name, t.id, t.run_time_ticks.map(|x| x as f64/1e7));
            first_ids.push(t.id.clone());
        }
        println!("IDS={:?}", first_ids);
    }
    Ok(())
}
