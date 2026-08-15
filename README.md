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
