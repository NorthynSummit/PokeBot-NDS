# Baritone-Lite Navigation Plan

## Purpose

Baritone-lite is the navigation brain for PokéBot NDS. It should help the bot understand where it is, what has been scanned, where useful unknown map data exists, and how to move toward that data safely.

## Core Loop

1. Observe current position and exact tile behavior
2. Load known map graph
3. Evaluate scanned and unscanned directions
4. Choose a useful frontier target
5. Travel using known safe graph edges
6. Probe unknown direction
7. Classify result
8. Save only trusted map facts
9. Recover/replan after battle, stuck state, or interrupted travel

## Result Types

- clean walkable movement
- confirmed blocked movement
- battle interruption
- transition/map change
- untrusted movement
- dynamic or conditional blockage
- wrong-tile result
- no-write diagnostic result

## Core Rule

The bot should never write a permanent map fact unless the result is trusted.

Battles should not become blocked edges. Untrusted movement should not become clean walkable edges. Dynamic blockers should not become permanent walls.
