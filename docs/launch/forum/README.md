# Forum media

Short posts ready to paste:

- [omxcode](../kit/modular-forum/omxcode.md) — attach `docs/img/forum/omxcode.gif`.
- [omxconsole](../kit/modular-forum/omxconsole.md) — attach `docs/img/forum/omxconsole.gif`.

The cover pages use the same media. Setup instructions and platform limits live in the repository README.

## Actual app sources

- `robot-data.png`: frame at 12.7 s from `docs/img/clip-robots-15s.mp4`, goal 61’s real Linux recording.
- `agent-dashboard.png`: the native AgentChat’s recorded dashboard, from `docs/img/agents/dashboard.png`.
- `console-find.png`, `console-models.png`, `console-keys.png`: captured again on 2026-11-07 from the real GTK console and Mojo consoled. A throwaway copy of the earlier real Hub-download test registry was used; the model was stopped before taking the pictures, and the Keys picture shows prefixes only. Search results came from the MAX catalog and Hub. No fixture server.
- The omxcode GIF takes five seconds from the robot recording at its recorded speed, five from the existing AG-UI film, and holds the console search screenshot for three. The AG-UI film is labelled as a scripted demo; its original recording was slowed for readability.
- The omxconsole GIF is a nine-second slideshow of the three actual console screenshots. It is not a measurement of download or model-start time.

Rebuild the GIFs and still posters with ffmpeg installed:

```bash
python scripts/forum_media.py
```

There are no generated/fake app screens, invented performance figures or full API keys in these assets. Post the GIF as an attachment in the forum editor, then paste the short text. Nothing posts to the forum automatically.
