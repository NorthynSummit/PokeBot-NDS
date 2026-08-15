# Tile Capability Engine

## Purpose

The tile capability engine separates exact raw tile behavior from friendly labels.

A raw behavior code can be exact before its human-friendly meaning is known.

Example:

- `0x0000` may be mapped as safe path
- `0x0002` may be mapped as tall grass
- `0x0001` may be exact but unmapped
- `0x0003` may be exact but unmapped

## Truth Rules

The following are not terrain truth by themselves:

- manual labels
- map names
- battle history
- old sample labels
- random probe labels
- visual guesses

Valid terrain truth comes from:

- exact behavior-code providers
- shared game-profile map data
- controlled validation
- exact seen-tile records

## Capability Evidence

Each exact behavior code should track evidence:

- walkable observed
- blocked observed
- battle observed
- transition observed
- no battle observed yet
- dynamic blockage conflict
- mapped profile label
- unmapped raw code

## Long-Term Goal

The bot should use shared game profiles and map packs so users do not have to rediscover every tile in every game.

Runtime learning should become a local overlay, not the main source of all map truth.
