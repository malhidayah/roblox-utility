# roblox-utility

Client-side utility for Roblox. Executor required.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/malhidayah/roblox-utility/main/roblox-utility.lua"))()
```

Toggle UI: `RightShift`. Drag the header to move it. The window sizes itself to the viewport, so it works on phones and desktop.

## Tabs

| Tab | What it does |
|---|---|
| **Main** | Fly, Noclip, Player ESP, Freecam (character stays still), Fullbright, Lock walk speed, Infinite jump, Click teleport, walk/fly speed sliders, network panel |
| **Player** | Teleport to or bring a player by username, display name or UserId; search; auto-refreshing list |
| **World** | Filter parts, ESP items, TP to nearest, pull all, tap-to-grab, scan part names, waypoints, **pickup prompts / click detectors**, **tools in map** |
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

## Notes

- Luau caps a function at 200 local variables. The UI lives in `buildUI()` for that reason; keep new UI code inside it.
- Every feature is isolated: one failing on a game does not stop the rest.
