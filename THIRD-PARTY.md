# Third-party components

## Fonts

The three font families bundled in `Resources/Fonts/` are used under the
[SIL Open Font License 1.1](https://openfontlicense.org). Each family's licence text sits next
to the font file.

| Family | Copyright | Licence file |
| --- | --- | --- |
| [Manrope](https://github.com/googlefonts/manrope) | Copyright 2018 The Manrope Project Authors | `Resources/Fonts/Manrope-OFL.txt` |
| [Instrument Serif](https://github.com/Instrument/instrument-serif) | Copyright 2022 The Instrument Serif Project Authors | `Resources/Fonts/InstrumentSerif-OFL.txt` |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | Copyright 2020 The JetBrains Mono Project Authors | `Resources/Fonts/JetBrainsMono-OFL.txt` |

## Services

- **[LRCLIB](https://lrclib.net)** — free, open lyrics database, no account or key needed. Aura
  sends only the track title, artist, album and duration of the song you are playing.
- **Spotify oEmbed** (`open.spotify.com/oembed`) — used to find album artwork when the desktop
  app doesn't supply a URL. Aura sends only the track ID.
- **Spotify's image CDN** (`i.scdn.co`) — the album cover itself is downloaded from the URL the
  desktop app or oEmbed gives, and cached locally.

Aura has no analytics, no telemetry and no accounts.
