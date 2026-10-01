# Kalanoro Together

Online co-op mod for **Kalanoro** (UE 5.6): one player hosts their game, the others join and play together in the
host's world. Comes with **Kalanoro Fix**, the graphics options and bug fixes the game is missing.
Unofficial fan mod, built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).

**Version 0.1 alpha** — expect bugs. Please report them in [Issues](https://github.com/pixl27/kalanoro-together/issues).

### [⬇ Download the latest release](https://github.com/pixl27/kalanoro-together/releases/latest)

## Install (every player)

Requirements: Windows 10/11 and Kalanoro. All players need the same game build and the same mod version.

1. Download `KalanoroTogether-v0.1-alpha.zip` from the [releases page](https://github.com/pixl27/kalanoro-together/releases/latest).
2. Close the game, then unzip it anywhere inside the game folder (the folder that contains `Kalanoro.exe`).
   Unzipped somewhere else, the installer asks for the game folder.
3. Right-click `Install-KalanoroCoop.ps1` → **Run with PowerShell**. Run it as administrator to also add the
   firewall rule; otherwise accept the Windows Firewall prompt the first time you host.
   If Windows refuses to run the script, open PowerShell in that folder and run
   `powershell -ExecutionPolicy Bypass -File Install-KalanoroCoop.ps1`.
4. Optional: `Kalanoro\Binaries\Win64\ue4ss\Mods\KalanoroCoop\config.ini` (`PlayerName` = the name shown above
   your character, default your Windows user name; keys) and graphics options in
   `Kalanoro\Binaries\Win64\ue4ss\Mods\KalanoroFix\config.ini`.

The installer adds UE4SS (the mod loader) if the game doesn't have it yet, installs both mods and keeps your
`config.ini` files when you update. It also disables the game's Steam API (`steam_api64.dll` is renamed):
Unreal's Steam socket layer otherwise blocks direct connections. `Uninstall-KalanoroCoop.ps1` restores it and
removes everything the installer added.

## Play

| Key | Action |
|-----|--------|
| F5  | Host: load your save first, then press F5 (the level reloads as an online session). Your IP is shown and copied to the clipboard: send it to your friends. |
| F6  | Join: copy the host's IP, then press F6 (with no IP on the clipboard it joins the last address used) |
| F7  | Leave the session |
| F8  | Teleport next to your partner |
| Middle mouse | Ping: marks the enemy in front of you, or your position, for everyone |
| F11 | Unstuck: close a stuck menu and give the controls back |

Console (F10 or `~`): `coop host`, `coop join <ip[:port]>`, `coop leave`, `coop status`, `coop tp`, `coop ping`.

A client that loses the connection reconnects by itself (up to 6 tries). Sessions work with more than two players.

**Playing over the internet:** the host must accept UDP port 7777. Either forward UDP 7777 on the host's
router and join the host's public IP, or put everyone on the same virtual LAN (ZeroTier, Tailscale,
Radmin VPN) and join the host's VPN IP.

### A friend can't join?

If the Windows Firewall prompt was closed without allowing the game, Windows adds rules that **block** it, and a
block rule wins over the installer's allow rule. In an administrator PowerShell on the host:

```powershell
Get-NetFirewallApplicationFilter | Where-Object Program -like '*kalanoro-win64-shipping*' | Get-NetFirewallRule | Where-Object Action -eq 'Block' | Remove-NetFirewallRule
```

then run the installer again as administrator.

## What is shared

- **Characters:** movement, abilities (dash, glide, climb, hair swing), attacks and hit reactions. Each player
  has a colour; name tags show each teammate's health, and their distance when they are far (the tag stays
  readable from afar, so it also shows where they are). A reminder with the teleport key appears when a
  teammate has been far away for a while.
- **Story progress:** clients play the session with the host's progress (quests, story, unlocked areas,
  village). A client's own save file is never written during a session, and their own progress is back as
  soon as they leave (`FollowHostProgress = false` in config.ini keeps your own progress instead).
- **Talking:** when a teammate talks to a character, the others are told.
- **World:** collected gems, broken crates and walls, levers, doors, bridges, platforms, generators, chests,
  lockers — what one player does happens in everyone's world. Players who join late get the current state.
- **Moving platforms and traps** follow the host's timing, so a platform or a spike trap is at the same point
  for everyone. Push/pull blocks, pull platforms and weapons lying around follow the player moving them.
- **Combat:** enemies live on the host and hunt the nearest standing player; everyone's hits count; enemy
  health scales with the number of players (+60% per extra player); enemy shots are visible to everyone.
- **Bosses:** every player sees the boss's health bar and attacks; the health of Raneny, Maraji and Rapeto
  scales with the number of players (Fara's phases are fixed hit counts).
- **Abilities:** hair shots, elemental shots, electric pulses, stuns and dashes on enemies count for everyone,
  and the shots are visible to the other players.
- **Down, not out:** at 0 HP you go down instead of dying. Stand next to a downed teammate for 2.5 s to
  revive them (they come back with half health). If nobody is left standing, or you bleed out (60 s), the
  normal death screen appears; the host's "Restart level" brings everyone back.
- **Loot:** gems placed in levels reward every player; crates and enemies drop loot for each player.
- **Cutscenes:** walking into a cutscene trigger plays it for everyone near it.
- **Levels:** the host leads — level exits, the pause menu's "back to the bus" and "Restart level" move the
  whole group. (`ClientsCanChangeLevel = true` lets a client's level exit move everyone too.)
- The game never pauses during a session (the pause menu still opens).

## Graphics and fixes (KalanoroFix)

| Setting | Default | |
|---|---|---|
| `VSync` | true | The game ships with VSync off and no frame cap (GPU at 100%). |
| `FrameRateLimit` | 0 | FPS cap, 0 = none. |
| `HDR`, `HDRNits` | false, 1000 | HDR output on HDR displays (Windows HDR on, fullscreen). |
| `AntiAliasing` | Game | `Game` keeps the game's FXAA; `TSR` = Unreal's temporal upscaler; `TAA`, `FXAA`, `Off`. |
| `ResolutionScale` | 100 | Render resolution in %, upscaled — use with `AntiAliasing = TSR`. |
| `MotionBlur` | true | |
| `PerformanceMode` | false | Low quality + TSR from 67% + no motion blur, for weak GPUs. |

DLSS and frame generation are not possible: the game is not built with NVIDIA's DLSS/Streamline plugins, and
DLSS needs an RTX card. TSR upscaling is the built-in equivalent that works on every GPU.

Bug fixes (each can be turned off in the config):
- **Settings menu with a mouse:** the arrows of Screen mode / Quality / Language only appeared with keyboard or
  gamepad focus, so these options could not be changed with a mouse. They are now always shown.
- **Blank, stuck Quality option:** when the engine reports a "custom" quality the option shows nothing and its
  arrows do nothing; it is snapped to the nearest Low/Medium/High/Epic level.
- **Missing mouse cursor in menus** (inventory…) with keyboard and mouse.
- **Controls stop responding:** press **F11** to close a stuck menu, unpause and restore game input.

## Known limitations

- Village building and the music (rhythm) game are single-player activities: they run for the player using
  them and are not shared.
- A weapon thrown by a client lands where the host's physics puts it.
- Platforms moved by one player's ability (pull platforms) follow that player with a short delay.

## Installation en français

1. Télécharge `KalanoroTogether-v0.1-alpha.zip` depuis la [page des versions](https://github.com/pixl27/kalanoro-together/releases/latest).
2. Ferme le jeu et dézippe-le dans le dossier du jeu (celui qui contient `Kalanoro.exe`).
3. Clic droit sur `Install-KalanoroCoop.ps1` → **Exécuter avec PowerShell** (en administrateur pour ajouter
   aussi la règle du pare-feu). Chaque joueur fait la même chose.
4. En jeu : **F5** héberger (ton IP est copiée, envoie-la à tes amis), **F6** rejoindre (copie l'IP de l'hôte
   avant), **F7** quitter, **F8** se téléporter près de son partenaire, **clic molette** pour pinger.
   Par internet, l'hôte doit ouvrir le port UDP 7777, ou utilisez un VPN (ZeroTier, Tailscale, Radmin VPN).

## Build from source

`./build_dist.sh <version>` (Git Bash) builds `dist/KalanoroTogether-<version>.zip`. It needs the UE4SS
experimental build v3.0.1-1152-ge3ba1016 ([UE4SS releases](https://github.com/UE4SS-RE/RE-UE4SS/releases))
extracted in `tools/UE4SS_v3.0.1-1152-ge3ba1016/` (`dwmapi.dll` and the `ue4ss` folder).

Sources: `src/KalanoroCoop` and `src/KalanoroFix` (UE4SS Lua mods), `dist-src` (installer and uninstaller).

## License

MIT for this mod (see `LICENSE`). UE4SS is MIT-licensed too; its license ships in `files/ue4ss/LICENSE`.
Kalanoro and its assets belong to their developers; this project contains none of the game's files.
