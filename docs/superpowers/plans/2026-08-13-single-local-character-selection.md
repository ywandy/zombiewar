# Single and Local Character Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make single-player and every joined local-multiplayer seat explicitly choose any of the ten catalog characters before the selected map starts.

**Architecture:** Both local modes route from map selection into the existing `LocalMultiplayerLobby` 3D scene. A focused `LocalCharacterSelectionState` owns default assignment, source lookup, catalog cycling, and start validation; the lobby owns physical-event routing and visual refresh. `GameSession` stores an explicit descriptor for single-player while `LocalPlayerSpawner` preserves single-player's composite input source.

**Tech Stack:** Godot 4.7.1, typed GDScript, `.tscn` scenes, custom `Resource` catalogs, headless SceneTree validators.

## Global Constraints

- Keep `Main Menu -> Map Selection -> Character Lobby -> Selected Map` in both local modes.
- Single-player auto-creates P1; local multiplayer retains device join for one to four seats.
- Allow duplicate characters; never add an occupancy lock.
- Use `A/D`, `Left/Right`, and gamepad `LB/RB` for each corresponding seat.
- A join event must not also cycle the new seat's default character.
- Only P1 uses `Enter/Start` to begin local multiplayer; single-player accepts either keyboard scheme or any gamepad.
- Preview and spawned player consume the same descriptor `character_id`; unknown IDs block start without fallback.
- Do not change the online protocol, use CUA validation, or touch unrelated `docs/sounds_975 2/` changes.
- Keep Chinese UI text on `assets/fonts/NotoSansSC-UI.ttf` and preserve responsive anchors/containers.

## File Structure

- Create `scripts/menu/local_character_selection_state.gd`: scene-independent selection state.
- Create `tools/validation/validate_single_local_character_selection.gd`: focused mode/input/handoff contract.
- Modify `local_player_join_state.gd`: canonical source-to-seat lookup.
- Modify `local_multiplayer_lobby.gd` and its scene: mode setup, input routing, preview/status refresh.
- Modify `map_selection.gd`: route both local modes through the character lobby.
- Modify `game_session.gd` and `local_player_spawner.gd`: explicit single descriptor with composite input.
- Update validators that encode the old implicit-single and legacy-preview assumptions.

---

### Task 1: Catalog-backed selection state

**Files:**
- Create: `scripts/menu/local_character_selection_state.gd`
- Modify: `scripts/menu/local_player_join_state.gd`
- Modify: `tools/validation/validate_local_join_state.gd`
- Create: `tools/validation/validate_single_local_character_selection.gd`

**Interfaces:**
- Consumes: `CharacterCatalog.default_id()`, `has_id(id)`, and `next_id(id, step)`.
- Produces: `LocalPlayerJoinState.find_player_index(source_kind: int, device_id: int = -1) -> int`.
- Produces: `initialize_single()`, `try_join()`, `step_player()`, `selection_error()`, and `players` on `LocalCharacterSelectionState`.

- [ ] **Step 1: Write the failing state assertions**

Use the real character catalog:

```gdscript
var selection = LocalCharacterSelectionStateScript.new(catalog)
selection.initialize_single()
_expect(selection.players.size() == 1, "single creates exactly P1", failures)
_expect(selection.players[0].character_id == catalog.default_id(), "single gets default character", failures)

selection.clear()
_expect(selection.try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD) == 0, "WASD joins P1", failures)
_expect(selection.try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS) == 1, "arrows join P2", failures)
selection.step_player(0, 1)
_expect(selection.players[0].character_id != catalog.default_id(), "P1 cycles", failures)
_expect(selection.players[1].character_id == catalog.default_id(), "P2 remains unchanged", failures)
selection.players[1].character_id = selection.players[0].character_id
_expect(selection.selection_error() == "", "duplicate choices are valid", failures)
selection.players[1].character_id = &"missing_character"
_expect(selection.selection_error() != "", "unknown character blocks start", failures)
```

- [ ] **Step 2: Run RED**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_single_local_character_selection.gd
```

Expected: FAIL because the state script does not exist.

- [ ] **Step 3: Implement canonical source lookup**

```gdscript
func find_player_index(source_kind: int, device_id: int = -1) -> int:
	for index in range(players.size()):
		var player = players[index]
		if player.source_kind == source_kind and (
			source_kind != LocalPlayerDescriptorScript.SourceKind.GAMEPAD
			or player.gamepad_device_id == device_id
		):
			return index
	return -1
```

Make `try_join()` reuse it before appending.

- [ ] **Step 4: Implement selection state**

The `RefCounted` accepts a catalog, wraps a `LocalPlayerJoinState`, assigns `default_id()` immediately after a successful join, cycles only valid indexes, and reports exact errors for no catalog, no players, offline seats, and unknown IDs. `initialize_single()` clears seats, creates logical P1, and assigns the default ID.

- [ ] **Step 5: Run GREEN**

Run the new validator and `validate_local_join_state.gd`; both must print `PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/menu/local_character_selection_state.gd scripts/menu/local_character_selection_state.gd.uid scripts/menu/local_player_join_state.gd tools/validation/validate_local_join_state.gd tools/validation/validate_single_local_character_selection.gd
git diff --cached --check
git commit -m "feat(menu): add local character selection state"
```

### Task 2: Explicit single-player handoff

**Files:**
- Modify: `scripts/gameplay/game_session.gd`
- Modify: `scripts/gameplay/local_player_spawner.gd`
- Modify: `tools/validation/validate_content_session_routing.gd`
- Modify: `tools/validation/validate_local_player_spawning.gd`

**Interfaces:**
- Produces: `GameSessionState.configure_single(player = null) -> void`.
- Guarantees: configured single sessions hold exactly one descriptor; omitted `player` creates a default descriptor for direct-scene/test compatibility.
- Preserves: `single_player_input` remains P1's combat input source.

- [ ] **Step 1: Change tests to require explicit single P1**

```gdscript
session.configure_single()
_expect(session.local_players.size() == 1, "single stores P1 descriptor", failures)
_expect(session.local_players[0].character_id == characters.default_id(), "direct single uses default", failures)
var selected = LocalPlayerDescriptorScript.new()
selected.character_id = &"female_medic"
session.configure_single(selected)
_expect(session.local_players[0].character_id == &"female_medic", "single preserves selection", failures)
```

Extend spawning validation so selected `female_medic` is applied while the injected composite input is retained.

- [ ] **Step 2: Run RED**

Run `validate_content_session_routing.gd` and `validate_local_player_spawning.gd`. Expected: FAIL because single configuration clears descriptors and spawning substitutes `null`.

- [ ] **Step 3: Implement session contract**

```gdscript
func configure_single(player = null) -> void:
	mode = Mode.SINGLE
	var resolved = player
	if resolved == null:
		resolved = LocalPlayerDescriptorScript.new()
		resolved.character_id = ContentCatalogsScript.characters().default_id()
	local_players = [resolved]
	map_id = ContentCatalogsScript.maps().default_id()
	last_error = ""
```

Keep `clear()` as a true reset: empty `local_players` after resetting mode/map fields.

- [ ] **Step 4: Preserve composite input in the spawner**

Use `session.local_players` in all configured modes. For single mode set `input_source = single_player_input`; only local/online descriptors call `create_input_source()` or use `is_local` sharing.

- [ ] **Step 5: Run GREEN and commit**

Both validators must pass, then commit only the four files with:

```bash
git commit -m "feat(gameplay): carry single-player character choice"
```

### Task 3: Unified map-to-lobby routing

**Files:**
- Modify: `scripts/menu/map_selection.gd`
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Modify: `scenes/menu/LocalMultiplayerLobby.tscn`
- Modify: `tools/validation/validate_map_selection_scene.gd`
- Modify: `tools/validation/validate_local_multiplayer_menu_scenes.gd`
- Modify: `tools/validation/validate_single_local_character_selection.gd`

**Interfaces:**
- Produces: `is_single_mode: bool`, `selection_state: LocalCharacterSelectionState`, and `_configure_mode()`.

- [ ] **Step 1: Add failing route/mode tests**

Assert map confirmation always targets `LocalMultiplayerLobby.tscn`. Instantiate the lobby with each `map_selection_mode`; single must auto-create P1 and hide P2-P4, local must start with zero seats and show all four.

- [ ] **Step 2: Run RED**

Run `validate_map_selection_scene.gd` and the new unified validator. Expected: FAIL because single bypasses the lobby.

- [ ] **Step 3: Route both modes to the lobby**

After `GameSession.select_map_scene(scene_path)`, always call `change_scene_to_file(LOCAL_LOBBY_PATH)`. Do not configure the gameplay session until character confirmation.

- [ ] **Step 4: Configure lobby mode before `_sync_slots()`**

```gdscript
is_single_mode = GameSession.map_selection_mode == GameSessionState.Mode.SINGLE
if is_single_mode:
	selection_state.initialize_single()
	title.text = "选择角色"
	join_hint.text = "A / D 或 ← / → 或 LB / RB 选择角色"
else:
	title.text = "本地多人 · 加入并选择角色"
```

Keep `join_state` as an alias to `selection_state.join_state` for existing validator compatibility. Hide P2-P4 marker/status roots only in single mode.

- [ ] **Step 5: Return to map selection**

Export `map_selection_scene_path = "res://scenes/menu/MapSelection.tscn"`. Returning clears transient seats but preserves `map_selection_mode`; do not call `GameSession.clear()`.

- [ ] **Step 6: Run GREEN and commit**

The two focused validators plus `validate_local_multiplayer_menu_scenes.gd` must pass. Commit with:

```bash
git commit -m "feat(menu): route local modes through character lobby"
```

### Task 4: Concurrent device-isolated selection controls

**Files:**
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Modify: `tools/validation/validate_single_local_character_selection.gd`
- Modify: `tools/validation/validate_local_disconnect_contract.gd`

**Interfaces:**
- Produces: `_step_character(player_index: int, step: int) -> bool` and `_start_selected_game() -> bool`.

- [ ] **Step 1: Add failing physical-event tests**

Drive `_handle_key()`/`_handle_joypad_button()` using real events. Assert first `A` joins WASD without cycling, second `A` cycles only P1, first `Right` joins arrows without cycling, key echo is ignored, an unassigned gamepad cannot mutate keyboard seats, two assigned gamepads change only their own seats, and duplicates remain allowed. Assert only P1 can start local mode while any device can confirm single mode.

- [ ] **Step 2: Run RED**

Run the unified validator. Expected: FAIL on join-consumption and routing assertions.

- [ ] **Step 3: Implement keyboard routing**

Ignore releases/echo first. In local mode resolve the keyboard source: if unassigned, join and return; if assigned, only its left/right selection keys cycle its seat. `Enter` starts only when P1 is a keyboard seat. In single mode skip seat lookup and accept both keyboard schemes.

- [ ] **Step 4: Implement gamepad routing**

Resolve by `event.device`. In local mode unassigned `A` joins and returns; assigned `LB/RB` cycles that seat; only seat 0 uses `Start/B`; assigned `A` does nothing. In single mode any gamepad uses `LB/RB`, `A/Start`, and `B`.

- [ ] **Step 5: Validate before transition**

On success:

```gdscript
if is_single_mode:
	GameSession.configure_single(selection_state.players[0])
else:
	GameSession.configure_local(selection_state.players)
get_tree().change_scene_to_file(GameSession.selected_game_scene_path(game_scene_path))
```

On validation error, update the bottom status text and remain in the lobby.

- [ ] **Step 6: Run GREEN and commit**

Run unified-selection and disconnect validators. Commit with:

```bash
git commit -m "feat(menu): add concurrent local character controls"
```

### Task 5: Character-aware lobby presentation

**Files:**
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Modify: `scripts/menu/lobby_player_preview.gd`
- Modify: `scenes/menu/LocalMultiplayerLobby.tscn`
- Modify: `tools/validation/validate_lobby_player_preview.gd`
- Modify: `tools/validation/validate_single_local_character_selection.gd`

**Interfaces:**
- `_sync_slot_preview()` resolves each descriptor ID and calls `set_character_definition()` plus `set_accent_color()`.
- `_character_status_text()` shows P number, source, definition display name, control hint, and offline state.

- [ ] **Step 1: Add failing presentation tests**

After join and cycle, assert preview model scene matches the descriptor's `CharacterDefinition.model_scene`, light/label match its accent, and status contains its `display_name`. In single mode require P2-P4 world/status roots hidden.

- [ ] **Step 2: Run RED**

Run preview and unified validators. Expected: FAIL because joined previews use the legacy fallback and status omits the selected definition.

- [ ] **Step 3: Bind preview to definition**

```gdscript
var definition = ContentCatalogsScript.characters().get_by_id(descriptor.character_id)
preview.set_character_definition(definition)
preview.set_accent_color(definition.accent_color if definition != null else Color.WHITE)
preview.set_player_index(index)
preview.set_online(descriptor.online)
```

Do not store a second selected ID on the preview.

- [ ] **Step 4: Render source-specific status**

Use two lines such as `P1 · 键盘 WASD · 男·突击手` and `A / D 选择`; arrows show `← / →`, gamepads show `LB / RB`. Append `设备离线` and dim without discarding the accent.

- [ ] **Step 5: Update legacy preview assertions**

The standalone scene may retain its editor fallback, but lobby assertions require the catalog-selected generated GLB. Preserve looped `Idle_Gun`, no combat nodes/colliders, accent propagation, and offline dimming checks.

- [ ] **Step 6: Run GREEN and commit**

Run both focused validators and commit with:

```bash
git commit -m "feat(menu): preview selected local characters"
```

### Task 6: Regression and visual handoff

**Files:**
- Modify: `docs/assets/player-characters/production-status.md`

- [ ] **Step 1: Run import/parse gate**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0 without scene/script parse or import errors.

- [ ] **Step 2: Run complete focused regression**

Run these headless validators individually and require `PASS`: `validate_single_local_character_selection`, `validate_local_join_state`, `validate_local_disconnect_contract`, `validate_local_input_contracts`, `validate_local_multiplayer_menu_scenes`, `validate_map_selection_scene`, `validate_game_map_selection_routing`, `validate_content_session_routing`, `validate_local_player_spawning`, `validate_lobby_player_preview`, `validate_character_catalog`, `validate_generated_character_models`, `validate_character_model_switching`, `validate_character_stats_apply`, and `validate_ui_font_coverage`.

- [ ] **Step 3: Check patch hygiene**

Run `git diff --check` and `git status --short`. Unrelated sound-translation changes must remain untouched/unstaged.

- [ ] **Step 4: Record validation and commit documentation**

Update production status with three-mode `character_id` support, the shared local lobby, duplicate-choice rule, and exact passing validations. Retain the note that Blender kit-attachment visual QA is unfinished. Commit only this status update with `docs(menu): record local character selection validation`.

- [ ] **Step 5: Request human captures**

Request: (1) single lobby with a non-default selection, (2) four joined local seats with at least three different characters, and (3) one offline local seat. Analyse framing, overlaps, stale models, accent readability, and the known floating-kit defect before declaring visual completion.
