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

- **Pickup prompts / clicks** — a `ProximityPrompt` (the "hold E" bar) or a `ClickDetector`. Tapping a row fires it through the game's own server handler. Uses `fireproximityprompt` / `fireclickdetector` when the executor has them, and falls back to simulating the key hold.
- **Prompt options** — two buttons under the scan row:
  - **Fast (bypass)** — `fireproximityprompt`: ignores distance and the hold. This is what every public script does, and it is detectable: a game can compare `PromptButtonHoldBegan` with `Triggered` and kick anyone whose trigger arrived without a hold (documented on the Roblox devforum, July 2025).
  - **Hold (safe)** — `InputHoldBegin` / `InputHoldEnd`: sends the real hold signal, so that check passes. Needs the prompt in range.
  - **Auto in range** — fires prompts as you come near them, driven by `ProximityPromptService.PromptShown`, which only fires for prompts you can actually reach. 3 second cooldown per prompt. Turn it off in shops.
- **Tools in map** — every `Tool` currently in `workspace`. Three actions per row:
  - tap the name — teleport onto the tool
  - **Take** — press the map's own pickup (prompt, then click, then touch), then watch your Backpack for the result and equip it
  - **Touch** — `firetouchinterest` only, for maps that grant from a `Touched` handler

Every pickup reports what actually happened:

```
Sword -> backpack: Sword        the server gave it to you, now equipped
Coin - Pick up: fired, no new tool in backpack
```

There is deliberately no local clone. A tool copied into your Backpack by the client exists only on your machine: the server does not know it is yours, it cannot be equipped properly, its server Scripts never run, and it disappears on respawn. A local copy would look like it worked and do nothing.

So "item masuk tas dan bisa dipakai" happens when the map's own handler runs — which is what Take does. If the server verifies distance, cooldown, or UserId before granting an item, that check still applies. The utility presses the button; it does not rewrite the handler.

If a map grants tools from a custom `RemoteEvent` instead, no generic pickup can guess its name. Open the Remote tab, scan, and look for names like `GiveTool`, `Buy`, `Claim`, `Pickup`, then fire them with the item name as the argument.

## Notes

- Luau caps a function at 200 local variables. The UI lives in `buildUI()` for that reason; keep new UI code inside it.
- Every feature is isolated: one failing on a game does not stop the rest.
