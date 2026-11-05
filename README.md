# roblox-utility

Client-side utility for Roblox. Executor required.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/malhidayah/roblox-utility/main/roblox-utility.lua"))()
```

Toggle UI: `RightShift`. Drag the header to move it. The window sizes itself to the viewport, so it works on phones and desktop.

## Tabs

| Tab | What it does |
|---|---|
| **Main** | Fly, Noclip, Player ESP, Freecam (character stays still), Fullbright, Lock walk speed, Infinite jump, Click teleport, walk/fly speed sliders, network panel, executor capability line |
| **Player** | Teleport to or bring a player by username, display name or UserId; search; auto-refreshing list |
| **World** | Filter parts, ESP items, TP to nearest, pull all, tap-to-grab, scan part names, waypoints, **pickup prompts / click detectors**, **tools in map** (TP + Touch) |
| **Avatar** | Copy another player's outfit, character scale 0.1x - 20x |
| **Emote** | 90+ emotes with search and categories, plus any custom animation id |
| **Remote** | Scan RemoteEvents/Functions, fire with arguments, copy path, spy on what the game fires |

## What other players can see

Roblox replicates only physics state, local animations, chat and remote calls from a client. Property writes never leave your machine.

| Reaches other players | Stays on your screen |
|---|---|
| Fly, speed, teleport, noclip | Invisible |
| Emotes, custom animations | Character size |
| Pickup prompts / click detectors (through the game's own server handler) | Outfit copy |
| | Fullbright, ESP |

If the game enables Server Authority, the server owns physics and client movement is rejected. The Main tab's network panel shows `owner=` and `authority=` so you can tell.

## Picking things up

The World tab lists the map's own interaction points, nearest first:

- **Pickup prompts / clicks** — a `ProximityPrompt` (the "hold E" bar) or a `ClickDetector`. Tapping a row fires it through the game's own server handler, so the item arrives for real and other players see it. Uses `fireproximityprompt` / `fireclickdetector` when the executor has them, and falls back to simulating the key hold.
- **Tools in map** — every `Tool` currently in `workspace`. Tap to teleport onto it, or **Touch** to call `firetouchinterest` so a `Touched` handler runs without moving you.

None of this bypasses the game's own checks. If the server verifies distance, cooldown, or UserId before granting an item, that check still applies — the utility presses the button, it does not rewrite the handler.

## Notes

- Luau caps a function at 200 local variables. The UI lives in `buildUI()` for that reason; keep new UI code inside it.
- Every feature is isolated: one failing on a game does not stop the rest.
