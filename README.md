# PokéBot NDS — Navigation Engine Fork

> Experimental Pokémon DS automation/navigation project. This fork is currently focused on HGSS navigation, exact tile behavior reading, scan-lens map understanding, safe map storage, and battle handoff.

## Status

This is not a finished release. The current work is experimental and focused on building a reliable navigation foundation before larger combat, multi-game support, and full map-pack systems are added.

Current internal milestone: **v40.x**

## Long-Term Goal

The long-term goal is to build a Pokémon DS bot that understands maps, movement, tile behavior, encounters, transitions, and battle decisions through structured game profiles and shared map packs, instead of requiring every user to rediscover every map from scratch.

The project is moving toward a Baritone-style navigation system for Pokémon DS games: a bot that can reason about scanned and unscanned directions, exact terrain behavior codes, walkable paths, dynamic blockers, transitions, encounters, and future battle decisions.

## Current Focus

- HGSS navigation engine
- Exact tile behavior-code reading
- Tile capability tracking
- Scan lens coverage reporting
- Safe map storage and archive/reset workflow
- Battle interruption handling without corrupting map data
- Dashboard party/map snapshot recovery
- Future shared map-pack architecture

## Not Done Yet

- Full combat intelligence
- Full B2W2 support
- Complete HGSS map-pack import
- Finished scan-lens visual map overlay
- Finished transition/door/warp intelligence
- Public release packaging

## Legal / Project Notes

This repository does not include ROMs, BIOS files, or copyrighted game data. Users are responsible for using their own legally obtained game files and emulator setup.

This fork is based on the original PokéBot NDS project and is being developed as an experimental navigation-engine branch.

<img src='https://i.imgur.com/lHaYC4z.png' width='600px'>

This repository is dedicated to creating a multi-purpose automated tool for the mainline DS Pokémon games. The bot can perform most monotonous tasks in these games, with all languages supported.

Reported [Issues](https://github.com/wyanido/pokebot-nds/issues) and donations are very appreciated, as making this project widely compatible as the sole developer takes a lot of time and work.

## Getting Started
#### Prerequisites
You'll need to install [node.js](https://nodejs.org/en), and have a recent version of [BizHawk](https://github.com/TASEmulators/BizHawk/releases/latest) or [DeSmuME](https://github.com/TASEmulators/desmume/releases/latest) in order to use this tool. 

#### Installation
**Recommended**: Install [Github Desktop](https://desktop.github.com/) and locally clone this repository to stay up to date with the latest versions of the bot.
_(You can also clone the [dev branch](https://github.com/wyanido/pokebot-nds/tree/dev) to preview upcoming features)_

Alternatively, download [the latest release](https://github.com/wyanido/pokebot-nds/releases/latest) as a .zip archive and extract it anywhere you like.

**Note**: Keep the folder as a whole. **DO NOT** just extract the .lua file.

#### Setup
1. Start the dashboard with `start-dashboard.bat`, or run these commands inside the `dashboard/` folder:
    - `npm i`
    - `npm start`
2. Use the dashboard's Config tab to customise the bot behaviour for your current task. 
3. Open your emulator's Lua Console, and load `pokebot-nds.lua`.
    - **BizHawk**: `Tools > Lua Console`
    - **DeSmuME**: `Tools > Lua Scripting > New Lua Script Window`

The game will then be connected to the dashboard, which you can view info for on the Dashboard tab. The bot will immediately start acting according to your Config, and log any encounters to the dashboard.

## Bot Modes
|  						| DPPt | HGSS | BW | B2W2 | 
|--						| :-: | :-: | :-: | :-: |
| Starter resets 		| ✅ | ✅ | ✅ | ✅ |
| Random encounters		| ✅ | ✅ | ✅ | ✅ |
| Phenomenon encounters		|  |  | ✅ | ✅ |
| Gift resets 			| ✅ | ✅ | ✅ | ✅ |
| Static encounters 	| ✅ | ✅ | ✅ | ✅ |
| Fishing			   	| ✅ | ✅ | ✅ | ✅ |
| Egg hatching			| ✅ | ✅ | ✅ | ✅ |
| Headbutt Trees 		|  | ✅ |  |  |
| Thundurus/Tornadus dex resets 			|  |  | ✅ |  |
| Hidden Grottos 	|  |  |  | ✅ |

#### Additional Features
|  						| DPPt | HGSS | BW | B2W2 | 
|--						| :-: | :-: | :-: | :-: |
| Auto-catching			| ✅ | ✅ | ✅ | ✅ |
| Auto-battling			| ✅ | ✅ | ✅ | ✅ |
| Thief farming			| ✅ | ✅ | ✅ | ✅ |
| Pickup farming		| ✅ | ✅ | ✅ | ✅ |
| Voltorb Flip		|  | ✅ |  |  |

#### Supported Languages
English is the only supported language for Gen 4 (Diamond, Pearl, Platinum, HeartGold & SoulSilver), with minimal support with non-English languages.

All languages are supported for Gen 5 games (Black, White & their sequels).

This is due to the internal structures of the two generations being wildly different. Gen 5's data remains consistent between languages, but Gen 4's data changes depending on the language. While a ROM offset has been applied for non-English ROMs, there will undoubtedly be issues.

## Special Thanks

- The contributors of [BizHawk](https://github.com/TASEmulators/BizHawk) and [DeSmuME](https://github.com/TASEmulators/DeSmuME) for providing a basis to make this project possible
- [40 Cakes](https://github.com/40Cakes) for the [Gen III PokéBot](https://github.com/40Cakes/pokebot-gen3) that originally inspired this project
- [evandixon](https://projectpokemon.org/home/profile/183-evandixon/) for demystifying the [NDS Pokemon format](https://projectpokemon.org/home/docs/gen-5/bw-save-structure-r60)
