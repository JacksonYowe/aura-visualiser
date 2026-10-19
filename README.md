# Aura

A real-time music visualiser for macOS that paints the screen with whatever Spotify is playing —
built from that song's own album cover, with the lyrics on top.

Native Swift and Metal. No Spotify account, no API keys, no accounts of any kind.

---

## What it does

**Eight visual modes**, all drawn from the current album cover and its colours — Halo, Kaleido,
Liquid, Tunnel, Mosaic, Stardust, Scope and Skyline. Keys `1`–`8` switch between them.

**Lyrics in six styles** — Bubbles, Karaoke, Neon, Cinema, Embers and Stickers. Timed lyrics come
from [LRCLIB](https://lrclib.net), a free open database. `T` changes style, `L` turns them off.

Lyric files only say when each *line* starts, so Aura has two ways to show them:

- **Line by line** (default) — the whole line appears as the singer starts it.
- **Word by word** (experimental) — each word appears as it's sung. Aura paces the words by
  syllables at that song's own singing speed, listens for whether someone is actually singing
  right now, and learns whether a song's lyric file runs early or late so the next play is closer.
  `[` and `]` nudge the timing for the current song; it's remembered.

**Ring pulses** that shoot out of the cover (Halo) or ripple through it (Mosaic):

- **Genre presets**, or let Aura listen for about ten seconds and detect the genre itself — techno,
  drum & bass, hip-hop, rock, pop, chill or acoustic. Each one fires on the drum hits that genre is
  built on.
- **How often** — a slider from one ring per bar, through every two beats and every beat (these
  three lock to the song's tempo), up to every drum hit and then some.
- **Expert page** — build up to four of your own triggers, each with a frequency range (808s, kick,
  bass, snare, vocals, cymbals, the whole song, or your own Hz), how loud it has to be, how sudden
  the jump has to be, and a live meter showing both.
- **Consistency** — once a sound has fired a few times at the same place in the beat, Aura
  remembers what it sounds like and fires on it every time it comes back, even when it gets
  quieter in a breakdown.

## Why it feels in time

Sound reaches your ears later than the app sees it, and the gap depends on your output device.
Aura works out when each sample of audio will actually be heard and draws every frame for that
exact moment.

- **Headphones** delay sound a lot — AirPods by about 170 ms — so Aura sees each beat long before
  you hear it and has plenty of time to prepare.
- **Built-in speakers** only delay by about 27 ms, which isn't enough. With **Look-ahead** on,
  Aura mutes Spotify's own output and plays the same audio itself 60 ms later, giving the visuals
  a head start. You can't hear a 60 ms delay in music. It turns itself off on Bluetooth, and never
  touches a device that has a microphone on it (so AirPods never drop to call quality).

Against a synthetic song with known beat times, flashes land within a couple of milliseconds of
the kick, with no missed or extra beats.

---

## Requirements

- macOS 15 or newer, Apple silicon
- Spotify's desktop app (not the web player)
- To build: Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)

## Build and install

```sh
./build.sh
```

That generates the Xcode project, builds a release binary, copies it to `/Applications/Aura.app`,
signs it and launches it. `./build.sh --no-open` skips the launch. If the Xcode you want isn't the
one `xcode-select` points at, set `XCODE_PATH=/Applications/Xcode-beta.app`.

The script signs with a local Apple Development certificate when it finds one, and falls back to
ad-hoc signing. The certificate isn't required — it just means macOS remembers the permissions
below instead of asking again after every rebuild.

### Permissions

On first launch macOS will ask for two things, and Aura shows a banner linking straight to the
right Privacy & Security page if either is missing:

- **Audio recording** — to read Spotify's audio stream through a Core Audio process tap. Nothing
  is ever recorded or written to disk.
- **Apple Events (Spotify)** — to ask Spotify what's playing and to run the playback controls.

## What leaves your machine

Three things, all anonymous, none of them tied to an account:

- The title, artist, album and duration of the current song, sent to [LRCLIB](https://lrclib.net)
  to look up lyrics.
- The track ID, sent to Spotify's public oEmbed endpoint, but only when the desktop app doesn't
  supply an artwork URL itself.
- A request for the album cover image, to Spotify's own image CDN — the same picture the Spotify
  app is already showing.

Kept on your machine: lyrics and artwork are cached under `~/Library/Caches/`; a status log at
`~/Library/Logs/Aura/aura.log` (reset on every launch, capped at 512 KB) records track names so
you can see what Aura saw; and the lyric timing Aura learns or you nudge is remembered per song
in the app's preferences, as a list of Spotify track IDs that stops growing at about 400 songs.
Delete that list any time with `defaults delete app.aura.Aura`.

There is no telemetry, no analytics and no account.

---

## Keyboard

| Key | Does |
| --- | --- |
| `1`–`8` | Pick a visual mode |
| `L` | Lyrics on / off |
| `T` | Next lyric style |
| `[` `]` | Lyrics earlier / later for this song |
| `\` | Back to automatic lyric timing |
| `F` | Full screen |
| `Space` | Play / pause |
| `←` `→` | Previous / next visual mode |
| `⌘←` `⌘→` | Previous / next track |
| `H` | Hide / show the controls |
| `A` | Cycle auto-change (off, each song, timed) |

Settings live behind the slider icon: sensitivity, audio source, sync offset, lyric style and
timing, and everything about the rings.

## How it works inside

- **Audio** — a Core Audio process tap on Spotify, mixed to stereo into a lock-free ring buffer.
  Each buffer is stamped with the host time at which it will be heard, which is what every
  visual lines up against.
- **Analysis** — vDSP FFTs at three window sizes, a 64-band log spectrum, onset detection on a
  256-sample hop, and an autocorrelation tempo tracker with a phase-locked beat grid.
- **Rings** — per-trigger band detectors judge loudness against that song's own quiet-to-loud range
  and sharpness against its own biggest jumps, so the same settings suit a ballad and a club track.
  Each sound that fires is remembered as a 16-band shape plus its position in the beat.
- **Rendering** — Metal shaders compiled at launch from `Resources/Shaders/*.msl`, on a dedicated
  render thread driven by `CAMetalDisplayLink`, each frame drawn for its own presentation time.
  Resolution adapts to keep GPU time inside the frame budget.
- **Lyrics** — drawn as GPU instances from a glyph atlas, one per word, with per-style motion and
  particles.

### Self-tests

The binary runs its own checks with no permissions and no audio device, against a synthetic song
with known beats, lyrics and vocals:

```sh
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --latency-test        # beat timing
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --tempo-test          # tempo, 72–180 BPM
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --rings-test          # ring pulses
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --ring-consistency    # repeated hits
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --ring-frequency      # the How often slider
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --lyrics-timing-test  # word timing
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --voice-test          # singing detection
Aura.app/Contents/MacOS/Aura --snapshot /tmp/out --hud                 # renders UI previews
```

`kill -USR1 <pid>` saves the current frame to `~/Library/Logs/Aura/capture.png`.

## Known limits

- Spotify only, and only the desktop app.
- Lyrics depend on LRCLIB having the song, and on its timings being right. Word-by-word mode is
  a guess refined by listening, not real per-word data.
- Genre detection uses macOS's on-device sound classifier plus rhythm, so it reads the
  instrumentation rather than the label. It can be wrong; you can always pick the genre yourself.
- Very fast music is sometimes counted in half-time (an 87 BPM reading of a 174 BPM track), which
  is a legitimate way to hear it but makes the tempo-locked ring settings fire half as often.

## Licence

MIT — see [LICENSE](LICENSE). Bundled fonts and the services Aura talks to are listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
