# Quickjell

A thin omarchy-shell plugin over an always-on Rust daemon that plays music from a self-hosted Jellyfin server. This is the glossary for the shared language between the daemon, the quickshell UI, and Jellyfin.

## Language

### Playback

**Track**:
A single audio item in Jellyfin, identified by its Jellyfin item id.
_Avoid_: Song, item, audio

**Queue**:
The ephemeral, ordered list of tracks the daemon will play. Owned by the daemon, discarded on stop; edits to it are never written back to Jellyfin.
_Avoid_: Playlist (see below), play order

**Playlist**:
A named, ordered track list stored canonically in Jellyfin. Its order is maintained by the daemon's release sort (see below), never by manual drag-reorder.
_Avoid_: Collection, list

**Play Next**:
Insert a track immediately after the currently playing one in the Queue. Distinct from enqueueing.
_Avoid_: Queue up (ambiguous)

**Release Sort**:
The canonical ordering rule for playlists: by album release date, newest first; within the same album, by disc number then track number, ascending.

**Playback Snapshot**:
The single complete description of playback state (status, queue, position, volume, shuffle, repeat, auth) pushed to clients.
_Avoid_: State blob, status

### Library

**View**:
A typed window over the library the daemon serves to the UI: all artists, one artist, one album, playlists, one playlist, recent.
_Avoid_: Page, endpoint, section

**Library Revision**:
A monotonically increasing counter bumped whenever the daemon's library snapshot is rebuilt; clients compare revisions to detect staleness.
_Avoid_: Cache version, etag

**Pin**:
A user request that the daemon keep a durable local copy of an album, track, or playlist. Pinned content is never evicted; it is the opposite of the rolling cache.
_Avoid_: Download (reserved for the transfer itself), favorite, save

### Auth

**Auth Status**:
One of authenticated, needs-unlock (rbw agent locked), or failed. The daemon never prompts; unlock is the user's action.
_Avoid_: Login state, session
