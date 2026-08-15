# Roadmap

## Current Milestone: v40.x Navigation Foundation

The v40 line focuses on turning the old exploration system into a Baritone-lite navigation engine.

### v40 Goals

- Exact HGSS tile behavior reading
- Tile capability engine
- Scan lens coverage model
- Clean map archive/reset workflow
- Safer blocked/dynamic obstacle handling
- Better local vs global frontier planning
- Dashboard map intelligence panel
- Party snapshot persistence
- Battle interruption handling without false blocked edges

## Near-Term Priorities

### 1. Tile Capability Engine

Separate raw behavior-code truth from friendly labels.

Examples:

- `0x0000` = mapped safe path
- `0x0002` = mapped tall grass
- `0x0001` = exact unmapped code
- `0x0003` = exact unmapped code

The bot should use observed capabilities, but it should not invent friendly labels without profile data or controlled validation.

### 2. Scan Lens

The scan lens should show what the bot knows and does not know:

- walkable scanned directions
- blocked scanned directions
- transitions
- inferred reverse directions
- possible holes
- unscanned frontier directions

### 3. Shared Map Packs

Long-term, users should not have to relearn every map. The project should support shared per-game map packs plus a local overlay.

Shared map pack:

- canonical map structure
- collision/permission data
- terrain/behavior data
- transitions and warps

Local overlay:

- user-specific observations
- dynamic blockers
- route-learning notes
- runtime battle/encounter data

### 4. Combat System

Combat is a future major system. It should eventually become its own intelligence layer, not just simple flee/fight behavior.

Future combat goals:

- matchup-aware decisions
- move evaluation
- party health/status awareness
- target rules
- safe leveling
- PvE planning
- possible PvP analysis later

## Long-Term Vision

Build a Pokémon DS automation system that can understand maps, movement, terrain, encounters, transitions, and battles at a level beyond simple scripts.

The final goal is not just automation. The goal is a map-aware, game-aware assistant that can navigate and make decisions more intelligently than repetitive manual play.
