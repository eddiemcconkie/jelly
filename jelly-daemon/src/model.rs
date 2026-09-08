//! The two-tier playback model (see Plane: "Decision: two-tier playback
//! model"). Pure logic + state, no mpv or tokio — the coordinator owns an
//! instance and mirrors it into the wire snapshot. All transitions return
//! the URL/track to play so the caller can drive the engine.

use jelly_ipc::{ContextSnapshot, RepeatMode, TrackMeta};

/// How far into a song N still counts as "previous song" rather than
/// "restart this one" (seconds).
pub const RESTART_THRESHOLD_SECS: f64 = 5.0;

/// The loaded playback context. Immutable while loaded except for the
/// shuffle permutation; selecting a song replaces the whole struct.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Context {
    pub name: String,
    pub artist: String,
    pub image_url: Option<String>,
    /// Tracks in their ORIGINAL (unshuffled) order.
    pub tracks: Vec<TrackMeta>,
    /// Playback order as indices into `tracks` — the identity permutation
    /// until shuffle is toggled, then a fixed permutation.
    pub order: Vec<usize>,
    /// Position within `order` of the currently playing track.
    pub pos: Option<usize>,
}

impl Context {
    pub fn new(name: impl Into<String>, artist: impl Into<String>, image_url: Option<String>, tracks: Vec<TrackMeta>) -> Self {
        Self {
            name: name.into(),
            artist: artist.into(),
            image_url,
            order: (0..tracks.len()).collect(),
            tracks,
            pos: None,
        }
    }

    /// Track at playback position `pos` (post-shuffle order).
    pub fn track_at(&self, pos: usize) -> Option<&TrackMeta> {
        self.order.get(pos).and_then(|&i| self.tracks.get(i))
    }

    /// The wire view: tracks already permuted, `current_index` in that
    /// same order.
    pub fn snapshot(&self) -> ContextSnapshot {
        ContextSnapshot {
            name: self.name.clone(),
            artist: self.artist.clone(),
            image_url: self.image_url.clone(),
            tracks: self.order.iter().map(|&i| self.tracks[i].clone()).collect(),
            current_index: self.pos,
        }
    }
}

/// Everything playback. The coordinator drives the engine according to
/// what the transition functions here say.
#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackModel {
    pub context: Option<Context>,
    /// The current queue song (the head), if playing from the queue.
    pub head: Option<TrackMeta>,
    /// Waiting queue items, FIFO.
    pub queue: Vec<TrackMeta>,
    /// Context position of the last context song that played — where
    /// continuation resumes (+1) and where N exits a queue song to.
    pub last_context_pos: Option<usize>,
    pub repeat: RepeatMode,
    pub shuffle: bool,
}

/// What to do after a model transition: play this track, or stop.
#[derive(Debug, Clone, PartialEq)]
pub enum Transition {
    Play(TrackMeta),
    Stop,
    /// Stay on the current track (seek/restart handled by the caller).
    Stay,
}

impl PlaybackModel {
    pub fn new() -> Self {
        Self {
            context: None,
            head: None,
            queue: Vec::new(),
            last_context_pos: None,
            repeat: RepeatMode::Off,
            shuffle: false,
        }
    }

    /// Load a new playback context and start at `start_index`. The queue
    /// survives untouched.
    pub fn set_context(
        &mut self,
        name: impl Into<String>,
        artist: impl Into<String>,
        image_url: Option<String>,
        tracks: Vec<TrackMeta>,
        start_index: usize,
    ) -> Transition {
        let start_index = start_index.min(tracks.len().saturating_sub(1));
        let mut ctx = Context::new(name, artist, image_url, tracks);
        ctx.pos = Some(start_index);
        self.context = Some(ctx);
        self.last_context_pos = Some(start_index);
        // Starting a new context takes over from the queue: the head (if
        // any was playing) is dropped back onto the front of the queue.
        if let Some(head) = self.head.take() {
            self.queue.insert(0, head);
        }
        match self.context.as_ref().unwrap().track_at(start_index) {
            Some(t) => Transition::Play(t.clone()),
            None => Transition::Stop,
        }
    }

    /// Advance: queue head first, then context order (+1 / wrap).
    pub fn next(&mut self) -> Transition {
        if !self.queue.is_empty() {
            let head = self.queue.remove(0);
            self.head = Some(head.clone());
            return Transition::Play(head);
        }
        let Some(ctx) = self.context.as_mut() else {
            return Transition::Stop;
        };
        // Leaving the queue (if we were in it) for the context.
        self.head = None;
        let next_pos = match ctx.pos {
            Some(p) => p + 1,
            // Fresh context that was loaded paused/stopped: start at top.
            None => 0,
        };
        let next_pos = if next_pos >= ctx.order.len() {
            match self.repeat {
                RepeatMode::All => 0,
                _ => return Transition::Stop,
            }
        } else {
            next_pos
        };
        ctx.pos = Some(next_pos);
        self.last_context_pos = Some(next_pos);
        match ctx.track_at(next_pos) {
            Some(t) => Transition::Play(t.clone()),
            None => Transition::Stop,
        }
    }

    /// Backward navigation. `position_secs` is the current playback
    /// position for the 5s rule.
    pub fn prev(&mut self, position_secs: f64) -> Transition {
        if position_secs > RESTART_THRESHOLD_SECS {
            return Transition::Stay;
        }
        // Playing from the queue: exit to the last-played context song
        // (exhausted queue songs are gone; going back leaves the queue).
        // With no context to fall back to, restart the queue song.
        if self.head.is_some() {
            let Some(ctx) = self.context.as_mut() else {
                return Transition::Play(self.head.clone().unwrap());
            };
            self.head = None;
            if let Some(p) = self.last_context_pos {
                ctx.pos = Some(p);
                match ctx.track_at(p) {
                    Some(t) => return Transition::Play(t.clone()),
                    None => return Transition::Stop,
                }
            }
            return Transition::Stop;
        }
        let Some(ctx) = self.context.as_mut() else {
            return Transition::Stop;
        };
        let Some(p) = ctx.pos else {
            return Transition::Stay;
        };
        if p > 0 {
            ctx.pos = Some(p - 1);
            self.last_context_pos = Some(p - 1);
            match ctx.track_at(p - 1) {
                Some(t) => Transition::Play(t.clone()),
                None => Transition::Stop,
            }
        } else if self.repeat == RepeatMode::All {
            // Wrap to the last context track before giving up.
            let last = ctx.order.len().saturating_sub(1);
            ctx.pos = Some(last);
            self.last_context_pos = Some(last);
            match ctx.track_at(last) {
                Some(t) => Transition::Play(t.clone()),
                None => Transition::Stop,
            }
        } else {
            // First context track, repeat off: restart the current song.
            self.last_context_pos = Some(0);
            Transition::Stay
        }
    }

    /// Called when the current track ends naturally (EOF). Same decision
    /// tree as `next`, except repeat-one owns the transition natively in
    /// the engine (loop-file), so we never see EOF in that mode.
    pub fn track_ended(&mut self) -> Transition {
        self.next()
    }

    /// Toggle shuffle: a fixed permutation of the context order only.
    /// The current track keeps playing — `pos` is remapped to wherever it
    /// sits in the new order.
    pub fn set_shuffle(&mut self, on: bool) {
        self.shuffle = on;
        let Some(ctx) = self.context.as_mut() else { return };
        if on {
            let playing_track_idx = ctx.pos.and_then(|p| ctx.order.get(p).copied());
            ctx.order = shuffle_order(ctx.tracks.len(), &[0xBA, 0xDC, 0x0F, 0xEE, 0xBA, 0xBE]);
            // Keep the current track current.
            if let Some(t) = playing_track_idx {
                ctx.pos = Some(ctx.order.iter().position(|&i| i == t).unwrap_or(0));
            }
        } else {
            let playing_track_idx = ctx.pos.and_then(|p| ctx.order.get(p).copied());
            ctx.order = (0..ctx.tracks.len()).collect();
            if let Some(t) = playing_track_idx {
                ctx.pos = Some(t);
            }
        }
    }

    /// Append to the tail of the queue.
    pub fn enqueue(&mut self, items: Vec<TrackMeta>) {
        self.queue.extend(items);
    }

    /// Insert at the head of the queue (play next). When the head slot is
    /// occupied, insert ahead of it (it plays before the current head).
    pub fn play_next(&mut self, item: TrackMeta) {
        self.queue.insert(0, item);
    }

    /// Jump to waiting item `index`, consuming everything before it.
    pub fn jump(&mut self, index: usize) -> Option<TrackMeta> {
        if index >= self.queue.len() {
            return None;
        }
        let item = self.queue.drain(0..=index).last().unwrap();
        self.head = Some(item.clone());
        Some(item)
    }

    /// Remove waiting item `index`. The head is unreachable by cursor so
    /// needs no protection here.
    pub fn remove(&mut self, index: usize) -> Option<TrackMeta> {
        if index >= self.queue.len() {
            return None;
        }
        Some(self.queue.remove(index))
    }

    /// Move waiting item `index` by `delta` slots, clamped.
    pub fn move_item(&mut self, index: usize, delta: i32) -> bool {
        let target = index as i32 + delta;
        if index >= self.queue.len() || target < 0 || target >= self.queue.len() as i32 || delta == 0 {
            return false;
        }
        let item = self.queue.remove(index);
        self.queue.insert(target as usize, item);
        true
    }

    /// The track the engine should consider "current": queue head when
    /// playing from the queue, else the context track at `pos`.
    pub fn current(&self) -> Option<TrackMeta> {
        if let Some(h) = &self.head {
            return Some(h.clone());
        }
        self.context
            .as_ref()
            .and_then(|c| c.pos)
            .and_then(|p| c_track(self, p).cloned())
    }

    /// The wire snapshot for the model-owned fields.
    pub fn snapshot_parts(&self) -> (Option<ContextSnapshot>, Option<TrackMeta>, Vec<TrackMeta>) {
        (
            self.context.as_ref().map(Context::snapshot),
            self.head.clone(),
            self.queue.clone(),
        )
    }
}

fn c_track(m: &PlaybackModel, pos: usize) -> Option<&TrackMeta> {
    m.context.as_ref().and_then(|c| c.track_at(pos))
}

/// Deterministic Fisher-Yates over `n` items from a fixed seed — keeps the
/// permutation stable per toggle and unit-testable. Swap in a real RNG
/// source at the call site if this ever matters.
fn shuffle_order(n: usize, seed: &[u8]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..n).collect();
    // xorshift-ish from the seed bytes.
    let mut s = seed.iter().fold(0x2545F4914F6CDD1Du64, |acc, b| {
        (acc ^ u64::from(*b)).wrapping_mul(0x100000001B3)
    });
    if n > 1 {
        for i in (1..n).rev() {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            let j = (s as usize) % (i + 1);
            order.swap(i, j);
        }
    }
    order
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str) -> TrackMeta {
        TrackMeta {
            id: id.into(),
            name: format!("song-{id}"),
            artist: "a".into(),
            album: "al".into(),
            duration_secs: Some(10.0),
            image_url: None,
            stream_url: format!("url://{id}"),
        }
    }

    fn ctx(tracks: &[&str]) -> Context {
        Context::new("Album", "Artist", None, tracks.iter().map(|t| track(t)).collect())
    }

    fn model(tracks: &[&str], start: usize) -> (PlaybackModel, Vec<TrackMeta>) {
        let mut m = PlaybackModel::new();
        m.set_context("Album", "Artist", None, tracks.iter().map(|t| track(t)).collect(), start);
        let seq = vec![track(tracks[start])];
        (m, seq)
    }

    #[test]
    fn set_context_plays_start_index_and_keeps_queue() {
        let mut m = PlaybackModel::new();
        m.play_next(track("q1"));
        let t = m.set_context("Album", "A", None, vec![track("1"), track("2")], 1);
        assert_eq!(t, Transition::Play(track("2")));
        assert_eq!(m.context.as_ref().unwrap().pos, Some(1));
        // The queued song was pushed back in front of the queue.
        assert_eq!(m.queue, vec![track("q1")]);
        assert_eq!(m.head, None);
    }

    #[test]
    fn next_walks_context_then_stops() {
        let (mut m, _) = model(&["1", "2", "3"], 0);
        assert_eq!(m.next(), Transition::Play(track("2")));
        assert_eq!(m.next(), Transition::Play(track("3")));
        assert_eq!(m.next(), Transition::Stop);
    }

    #[test]
    fn next_wraps_only_with_repeat_all() {
        let (mut m, _) = model(&["1", "2"], 1);
        m.repeat = RepeatMode::All;
        assert_eq!(m.next(), Transition::Play(track("1")));
    }

    #[test]
    fn queue_consumed_before_context() {
        let (mut m, _) = model(&["1", "2"], 0);
        m.enqueue(vec![track("q1"), track("q2")]);
        assert_eq!(m.next(), Transition::Play(track("q1")));
        assert_eq!(m.next(), Transition::Play(track("q2")));
        // Queue exhausted: continuation resumes at last-played + 1.
        assert_eq!(m.next(), Transition::Play(track("2")));
    }

    #[test]
    fn queue_head_plays_without_context_then_stops() {
        let mut m = PlaybackModel::new();
        m.enqueue(vec![track("q1"), track("q2")]);
        assert_eq!(m.next(), Transition::Play(track("q1")));
        assert_eq!(m.next(), Transition::Play(track("q2")));
        assert_eq!(m.next(), Transition::Stop);
    }

    #[test]
    fn prev_restarts_deep_into_song() {
        let (mut m, _) = model(&["1", "2"], 1);
        assert_eq!(m.prev(9.0), Transition::Stay);
    }

    #[test]
    fn prev_steps_back_within_5s() {
        let (mut m, _) = model(&["1", "2"], 1);
        assert_eq!(m.prev(2.0), Transition::Play(track("1")));
    }

    #[test]
    fn prev_on_first_track_restarts_or_wraps() {
        let (mut m, _) = model(&["1", "2"], 0);
        assert_eq!(m.prev(2.0), Transition::Stay);
        m.repeat = RepeatMode::All;
        assert_eq!(m.prev(2.0), Transition::Play(track("2")));
    }

    #[test]
    fn prev_exits_queue_song_to_last_context_track() {
        let (mut m, _) = model(&["1", "2", "3"], 1);
        m.enqueue(vec![track("q1")]);
        assert_eq!(m.next(), Transition::Play(track("q1")));
        // N on a queue song: back to the last-played context song (track 2).
        assert_eq!(m.prev(2.0), Transition::Play(track("2")));
        // Queue song was consumed by the exit.
        assert_eq!(m.queue, vec![]);
        assert_eq!(m.head, None);
        // From there, N continues walking the context backwards.
        assert_eq!(m.prev(2.0), Transition::Play(track("1")));
    }

    #[test]
    fn prev_on_queue_song_without_context_restarts() {
        let mut m = PlaybackModel::new();
        m.enqueue(vec![track("q1")]);
        assert_eq!(m.next(), Transition::Play(track("q1")));
        // No context to fall back to: restart the queue song.
        assert_eq!(m.prev(2.0), Transition::Play(track("q1")));
    }

    #[test]
    fn shuffle_keeps_current_and_round_trips() {
        let (mut m, _) = model(&["1", "2", "3", "4", "5", "6", "7"], 2);
        m.set_shuffle(true);
        let c = m.context.as_ref().unwrap();
        // Permuted order is still a permutation.
        let mut sorted = c.order.clone();
        sorted.sort();
        assert_eq!(sorted, (0..7).collect::<Vec<_>>());
        // The current track (start index 2 → third track) stays current.
        assert_eq!(c.track_at(c.pos.unwrap()).map(|t| t.id.as_str()), Some("3"));
        m.set_shuffle(false);
        let c = m.context.as_ref().unwrap();
        assert_eq!(c.order, (0..7).collect::<Vec<_>>());
        assert_eq!(c.pos, Some(2));
    }

    #[test]
    fn shuffle_continuation_walks_new_order() {
        let (mut m, _) = model(&["1", "2", "3"], 0);
        m.set_shuffle(true);
        m.repeat = RepeatMode::All;
        let mut seen = vec![];
        for _ in 0..3 {
            if let Transition::Play(t) = m.next() {
                seen.push(t.id);
            }
        }
        seen.sort();
        assert_eq!(seen, vec!["1", "2", "3"]);
    }

    #[test]
    fn jump_consumes_earlier_waiting_items() {
        let (mut m, _) = model(&["1"], 0);
        m.enqueue(vec![track("q1"), track("q2"), track("q3")]);
        let jumped = m.jump(1).unwrap();
        assert_eq!(jumped, track("q2"));
        assert_eq!(m.queue, vec![track("q3")]);
        assert_eq!(m.jump(5), None);
    }

    #[test]
    fn remove_and_move_are_clamped() {
        let (mut m, _) = model(&["1"], 0);
        m.enqueue(vec![track("q1"), track("q2"), track("q3")]);
        assert!(m.move_item(2, 1) == false); // clamped at the tail
        assert!(m.move_item(0, -1) == false); // clamped at the head
        assert!(m.move_item(2, -1));
        assert_eq!(m.queue.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec!["q1", "q3", "q2"]);
        assert_eq!(m.remove(1).unwrap(), track("q3"));
        assert_eq!(m.remove(5), None);
    }

    #[test]
    fn enqueue_appends_to_tail() {
        let (mut m, _) = model(&["1"], 0);
        m.enqueue(vec![track("q1")]);
        m.enqueue(vec![track("q2"), track("q3")]);
        assert_eq!(
            m.queue.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
            vec!["q1", "q2", "q3"]
        );
    }
}
