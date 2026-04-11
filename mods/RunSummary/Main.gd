extends Node

# Run Summary — Pure autoload, no script overrides
# Shows a post-run modal with stats after death or returning to shelter.
# Persists last 10 runs to disk. Hooks Cash/XP mods if present.

var gameData = preload("res://Resources/GameData.tres")

# ─── Run State Machine ───

enum RunState { IDLE, IN_RUN, RUN_ENDED }
var _run_state: int = RunState.IDLE

# ─── Snapshot (captured at run start) ───

var _snap_xp_total: int = 0
var _snap_health: float = 100.0
var _snap_energy: float = 100.0
var _snap_hydration: float = 100.0
var _snap_mental: float = 100.0
var _snap_inv_value: float = 0.0
var _snap_inv_count: int = 0
var _snap_time_real: int = 0
var _snap_time_game: float = 0.0
var _snap_map: String = ""
var _snap_zone: String = ""

# ─── Accumulators (incremented during run) ───

var _acc_kills: int = 0
var _acc_cash_earned: int = 0
var _acc_cash_spent: int = 0
var _acc_conditions: Array = []
var _acc_damage_taken: float = 0.0
var _acc_last_health: float = 100.0
var _acc_energy_used: float = 0.0
var _acc_last_energy: float = 100.0
var _acc_energy_restored: float = 0.0
var _acc_hydration_used: float = 0.0
var _acc_last_hydration: float = 100.0
var _acc_hydration_restored: float = 0.0
var _acc_mental_lost: float = 0.0
var _acc_last_mental: float = 100.0
var _acc_mental_restored: float = 0.0
var _acc_items_picked: int = 0
var _acc_last_inv_count: int = 0
var _inv_snapshot_ready: bool = false
var _acc_peak_xp: int = 0
var _acc_last_xp: int = 0
var _acc_boss_kills: int = 0

# ─── Kill Attribution ───

const GRENADE_WINDOW_MS: int = 6000  # 6s covers 3s fuse + travel + buffer
var _last_grenade_time: int = 0
var _prev_grenade1: bool = false
var _prev_grenade2: bool = false

# ─── Scene Tracking ───

var _interface = null
var _last_scene: String = ""
var _was_dead: bool = false
var _was_shelter: bool = true
var _scene_ready: bool = false

# ─── UI ───

var _canvas_layer: CanvasLayer = null
var _overlay: ColorRect = null
var _modal_visible: bool = false
var _history_visible: bool = false
var _last_summary: Dictionary = {}
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED

# ─── Config ───

var cfg_auto_show: bool = true
var cfg_reopen_key: int = KEY_F6

# ─── MCM ───

var _mcm_helpers = null
const MCM_FILE_PATH = "user://MCM/RunSummary"
const MCM_MOD_ID = "RunSummary"
const LOCAL_CFG_PATH = "user://RunSummaryConfig.cfg"
const HISTORY_PATH = "user://RunSummaryHistory.cfg"
const REOPEN_ACTION = "run_summary_reopen"

# ─── Condition names for display ───

const CONDITIONS = {
    "bleeding": "Bleeding", "fracture": "Fracture", "burn": "Burn",
    "frostbite": "Frostbite", "insanity": "Insanity", "rupture": "Rupture",
    "headshot": "Headshot", "starvation": "Starvation",
    "dehydration": "Dehydration", "poisoning": "Poisoning"
}

# ─── Initialization ───

func _ready():
    process_mode = Node.PROCESS_MODE_ALWAYS
    Engine.set_meta("RunSummaryMain", self)
    _mcm_helpers = _try_load_mcm()
    if _mcm_helpers:
        _register_mcm()
    else:
        _load_local_config()
    _register_hotkey(cfg_reopen_key)
    _hook_other_mods()
    # Load most recent run from history so hotkey works before first run
    var history = _load_history()
    if history.size() > 0:
        _last_summary = history[0]

func _hook_other_mods():
    var cash_mod = Engine.get_meta("CashMain", null)
    if cash_mod:
        if cash_mod.has_signal("cash_sold"):
            cash_mod.cash_sold.connect(_on_cash_sold)
        if cash_mod.has_signal("cash_bought"):
            cash_mod.cash_bought.connect(_on_cash_bought)
        if cash_mod.has_signal("cash_picked_up"):
            cash_mod.cash_picked_up.connect(_on_cash_picked_up)
        print("[RunSummary] Hooked into Cash System signals")

func _on_cash_sold(amount: int, _items: Array):
    if _run_state == RunState.IN_RUN:
        _acc_cash_earned += amount

func _on_cash_bought(amount: int, _items: Array):
    if _run_state == RunState.IN_RUN:
        _acc_cash_spent += amount

func _on_cash_picked_up(amount: int):
    if _run_state == RunState.IN_RUN:
        _acc_cash_earned += amount

# ─── Main Loop ───

func _process(_delta):
    # Enforce game state every frame while modal is open
    # (game scripts may reset freeze/mouse_mode during scene transitions)
    if _modal_visible:
        if Input.mouse_mode != Input.MOUSE_MODE_CONFINED:
            Input.mouse_mode = Input.MOUSE_MODE_CONFINED
        if "freeze" in gameData and not gameData.freeze:
            gameData.freeze = true

    _update_interface()
    if _interface == null:
        return

    match _run_state:
        RunState.IDLE:
            _check_run_start()
        RunState.IN_RUN:
            _track_run()
            _check_run_end()
        RunState.RUN_ENDED:
            pass

func _update_interface():
    var scene = get_tree().current_scene
    if scene == null:
        _scene_ready = false
        return

    if scene.name != _last_scene:
        _last_scene = scene.name
        _interface = null
        _scene_ready = false

    if _interface == null:
        var core_ui = scene.get_node_or_null("Core/UI")
        if core_ui:
            for child in core_ui.get_children():
                if child.get("containerGrid") != null:
                    _interface = child
                    _scene_ready = true
                    break

# ─── Run Lifecycle ───

func _check_run_start():
    if !_scene_ready:
        return
    var scene = get_tree().current_scene
    if scene == null:
        return

    var is_map = scene.name == "Map" or "mapName" in scene
    var in_shelter = gameData.shelter if "shelter" in gameData else false

    if is_map and !in_shelter and !gameData.isDead:
        _start_run(scene)

func _start_run(scene):
    _run_state = RunState.IN_RUN
    _snap_xp_total = _get_xp_total()
    _snap_health = gameData.health
    _snap_energy = gameData.energy
    _snap_hydration = gameData.hydration
    _snap_mental = gameData.mental if "mental" in gameData else 100.0
    _snap_time_real = Time.get_ticks_msec()
    _snap_time_game = _get_sim_time()
    _snap_map = scene.mapName if "mapName" in scene else "Unknown"
    _snap_zone = gameData.zone if "zone" in gameData else ""
    _snap_inv_value = _get_inv_value()
    _snap_inv_count = _get_inv_count()

    _acc_kills = 0
    _acc_boss_kills = 0
    _acc_last_xp = _snap_xp_total
    _last_grenade_time = 0
    _prev_grenade1 = gameData.grenade1 if "grenade1" in gameData else false
    _prev_grenade2 = gameData.grenade2 if "grenade2" in gameData else false
    _acc_cash_earned = 0
    _acc_cash_spent = 0
    _acc_conditions = []
    _acc_damage_taken = 0.0
    _acc_last_health = gameData.health
    _acc_energy_used = 0.0
    _acc_last_energy = gameData.energy
    _acc_energy_restored = 0.0
    _acc_hydration_used = 0.0
    _acc_last_hydration = gameData.hydration
    _acc_hydration_restored = 0.0
    _acc_mental_lost = 0.0
    _acc_last_mental = gameData.mental if "mental" in gameData else 100.0
    _acc_mental_restored = 0.0
    _acc_items_picked = 0
    _acc_last_inv_count = _snap_inv_count
    _inv_snapshot_ready = _snap_inv_count > 0
    _acc_peak_xp = _snap_xp_total

    _was_dead = false
    _was_shelter = false

    print("[RunSummary] Run started on %s" % _snap_map)

func _track_run():
    # ─── Kill detection (frame-by-frame XP monitoring) ───
    var current_xp = _get_xp_total()
    if current_xp > _acc_peak_xp:
        _acc_peak_xp = current_xp

    # Detect grenade throws (grenade1/grenade2 transition true → false)
    var g1 = gameData.grenade1 if "grenade1" in gameData else false
    var g2 = gameData.grenade2 if "grenade2" in gameData else false
    if (_prev_grenade1 and !g1) or (_prev_grenade2 and !g2):
        _last_grenade_time = Time.get_ticks_msec()
    _prev_grenade1 = g1
    _prev_grenade2 = g2

    # Check for XP increase → attribute kill
    var xp_delta_frame = current_xp - _acc_last_xp
    if xp_delta_frame > 0:
        var is_player_kill = false

        # Gun kill: player is actively firing
        if gameData.isFiring:
            is_player_kill = true
        # Grenade kill: player recently threw a grenade
        elif _last_grenade_time > 0 and (Time.get_ticks_msec() - _last_grenade_time) <= GRENADE_WINDOW_MS:
            is_player_kill = true

        if is_player_kill:
            if xp_delta_frame >= 100:
                _acc_boss_kills += 1
                _acc_kills += 1
            else:
                _acc_kills += xp_delta_frame / 25
    _acc_last_xp = current_xp

    # Track damage taken (accumulate decreases, ignore healing)
    var current_hp = gameData.health
    if current_hp < _acc_last_health:
        _acc_damage_taken += _acc_last_health - current_hp
    _acc_last_health = current_hp

    # Track energy (accumulate drain and restoration separately)
    var current_energy = gameData.energy
    if current_energy < _acc_last_energy:
        _acc_energy_used += _acc_last_energy - current_energy
    elif current_energy > _acc_last_energy:
        _acc_energy_restored += current_energy - _acc_last_energy
    _acc_last_energy = current_energy

    # Track hydration (accumulate drain and restoration separately)
    var current_hydration = gameData.hydration
    if current_hydration < _acc_last_hydration:
        _acc_hydration_used += _acc_last_hydration - current_hydration
    elif current_hydration > _acc_last_hydration:
        _acc_hydration_restored += current_hydration - _acc_last_hydration
    _acc_last_hydration = current_hydration

    # Track mental (accumulate loss and recovery separately)
    if "mental" in gameData:
        var current_mental = gameData.mental
        if current_mental < _acc_last_mental:
            _acc_mental_lost += _acc_last_mental - current_mental
        elif current_mental > _acc_last_mental:
            _acc_mental_restored += current_mental - _acc_last_mental
        _acc_last_mental = current_mental

    # Track conditions
    for key in CONDITIONS:
        if key in gameData and gameData.get(key) and key not in _acc_conditions:
            _acc_conditions.append(key)

    # Track items picked up (count actual Item nodes, not all grid children)
    var inv_count = _get_inv_count()
    if !_inv_snapshot_ready and inv_count > 0:
        _snap_inv_count = inv_count
        _acc_last_inv_count = inv_count
        _snap_inv_value = _get_inv_value()
        _inv_snapshot_ready = true
    elif _inv_snapshot_ready and inv_count > _acc_last_inv_count:
        _acc_items_picked += inv_count - _acc_last_inv_count
    if inv_count > 0:
        _acc_last_inv_count = inv_count

func _check_run_end():
    # Death
    if gameData.isDead and !_was_dead:
        _was_dead = true
        _end_run(true)
        return

    # Returned to shelter
    var in_shelter = gameData.shelter if "shelter" in gameData else false
    if in_shelter and !_was_shelter:
        _was_shelter = true
        _end_run(false)
        return

func _end_run(died: bool):
    _run_state = RunState.RUN_ENDED

    var elapsed_ms = Time.get_ticks_msec() - _snap_time_real
    var xp_delta = _acc_peak_xp - _snap_xp_total

    var summary = {
        "outcome": "DEATH" if died else "EXTRACTED",
        "map": _snap_map,
        "zone": _snap_zone,
        "duration_sec": int(elapsed_ms / 1000),
        "xp_gained": xp_delta,
        "kills": _acc_kills,
        "boss_kills": _acc_boss_kills,
        "damage_taken": int(_acc_damage_taken),
        "items_picked": _acc_items_picked,
        "value_gained": int(_get_inv_value() - _snap_inv_value) if !died else 0,
        "energy_used": int(round(_acc_energy_used)),
        "energy_restored": int(round(_acc_energy_restored)),
        "hydration_used": int(round(_acc_hydration_used)),
        "hydration_restored": int(round(_acc_hydration_restored)),
        "mental_lost": int(round(_acc_mental_lost)),
        "mental_restored": int(round(_acc_mental_restored)),
        "conditions": _acc_conditions.duplicate(),
        "cash_earned": _acc_cash_earned,
        "cash_spent": _acc_cash_spent,
        "timestamp": Time.get_datetime_string_from_system(),
    }

    _last_summary = summary
    _save_to_history(summary)

    print("[RunSummary] Run ended — %s on %s (%ds)" % [summary.outcome, summary.map, summary.duration_sec])

    if cfg_auto_show:
        # Delay to let death screen / shelter load finish
        get_tree().create_timer(1.5).timeout.connect(_show_summary_modal)

# ─── Helpers ───

func _get_xp_total() -> int:
    # Prefer XP mod's own tracker (separate from gameData)
    var xp_mod = Engine.get_meta("XPMain", null)
    if xp_mod and "xpTotal" in xp_mod:
        return xp_mod.xpTotal
    if "xpTotal" in gameData:
        return gameData.xpTotal
    return 0

func _get_inv_value() -> float:
    if _interface and "currentInventoryValue" in _interface:
        return _interface.currentInventoryValue
    return 0.0

func _get_inv_count() -> int:
    if _interface and _interface.get("inventoryGrid"):
        var count = 0
        for child in _interface.inventoryGrid.get_children():
            if child.get("slotData") != null:
                count += 1
        return count
    return 0

func _get_sim_time() -> float:
    var sim = get_node_or_null("/root/Simulation")
    if sim and "time" in sim:
        return sim.time
    return 0.0

# ─── Input ───

func _input(event):
    if _modal_visible:
        # Esc or hotkey (by keycode) closes modal
        if event is InputEventKey and event.pressed and not event.echo:
            if event.keycode == KEY_ESCAPE or event.keycode == cfg_reopen_key:
                _close_modal()
                get_viewport().set_input_as_handled()
                return
        # Block mouse motion and keyboard from reaching the game
        # Do NOT block mouse buttons — they must reach our CanvasLayer GUI
        if event is InputEventMouseMotion or event is InputEventKey:
            get_viewport().set_input_as_handled()
        return

    # Hotkey to reopen last summary (only when modal is closed)
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == cfg_reopen_key and _last_summary.size() > 0:
            _show_summary_modal()
            get_viewport().set_input_as_handled()

func _unhandled_input(event):
    # Catch any mouse clicks that passed through GUI (clicked overlay, not a button)
    if _modal_visible and event is InputEventMouseButton:
        get_viewport().set_input_as_handled()

# ─── Summary Modal UI ───

func _show_summary_modal():
    if _modal_visible:
        return
    if _last_summary.size() == 0:
        return

    _modal_visible = true
    _history_visible = false
    _prev_mouse_mode = Input.mouse_mode

    # Match the game's own UI pattern (UIManager.UIOpen)
    Input.mouse_mode = Input.MOUSE_MODE_CONFINED
    if "freeze" in gameData:
        gameData.freeze = true

    # CanvasLayer on a high layer ensures our UI gets GUI events above everything
    _canvas_layer = CanvasLayer.new()
    _canvas_layer.name = "RunSummaryLayer"
    _canvas_layer.layer = 100
    _canvas_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    get_tree().root.add_child(_canvas_layer)

    _build_modal(_last_summary)

func _build_modal(summary: Dictionary):
    _cleanup_modal()

    # Full-screen dark overlay
    _overlay = ColorRect.new()
    _overlay.name = "RunSummaryOverlay"
    _overlay.color = Color(0, 0, 0, 0.8)
    _overlay.anchor_right = 1.0
    _overlay.anchor_bottom = 1.0
    _overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    _canvas_layer.add_child(_overlay)

    # Centered panel
    var panel = PanelContainer.new()
    panel.name = "RunSummaryPanel"
    var panel_style = StyleBoxFlat.new()
    panel_style.bg_color = Color(0.08, 0.08, 0.1, 0.95)
    panel_style.border_color = Color(0.3, 0.3, 0.35, 1.0)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(4)
    panel_style.content_margin_left = 24
    panel_style.content_margin_right = 24
    panel_style.content_margin_top = 20
    panel_style.content_margin_bottom = 20
    panel.add_theme_stylebox_override("panel", panel_style)
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.custom_minimum_size = Vector2(480, 0)
    panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
    panel.grow_vertical = Control.GROW_DIRECTION_BOTH
    _overlay.add_child(panel)

    var scroll = ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(480, 520)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    panel.add_child(scroll)

    # Margin inside scroll to prevent scrollbar from overlapping content
    var scroll_margin = MarginContainer.new()
    scroll_margin.add_theme_constant_override("margin_right", 14)
    scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(scroll_margin)

    var vbox = VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll_margin.add_child(vbox)

    # Title
    var is_death = summary.get("outcome", "") == "DEATH"
    var title = Label.new()
    title.text = "DEATH SUMMARY" if is_death else "RUN SUMMARY"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35) if is_death else Color(0.4, 1.0, 0.5))
    vbox.add_child(title)

    # Subtitle: map + duration
    var duration_str = _format_duration(summary.get("duration_sec", 0))
    var subtitle = Label.new()
    subtitle.text = "%s  •  %s" % [summary.get("map", "Unknown"), duration_str]
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subtitle.add_theme_font_size_override("font_size", 14)
    subtitle.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
    vbox.add_child(subtitle)

    _add_spacer(vbox, 12)
    _add_separator(vbox)
    _add_spacer(vbox, 8)

    # ─── Combat ───
    _add_section_header(vbox, "COMBAT")
    _add_stat_row(vbox, "Enemies Killed", str(summary.get("kills", 0)))
    var boss_kills = summary.get("boss_kills", 0)
    if boss_kills > 0:
        _add_stat_row(vbox, "Bosses Killed", str(boss_kills))
    _add_stat_row(vbox, "Damage Taken", str(summary.get("damage_taken", 0)))
    _add_spacer(vbox, 8)

    # ─── Loot ───
    _add_section_header(vbox, "LOOT")
    _add_stat_row(vbox, "Items Picked Up", str(summary.get("items_picked", 0)))
    var val = summary.get("value_gained", 0)
    var val_str = ("+€" if val >= 0 else "-€") + str(abs(val))
    _add_stat_row(vbox, "Value Gained", val_str)
    _add_spacer(vbox, 8)

    # ─── Economy (only show if any economy activity) ───
    var cash_e = summary.get("cash_earned", 0)
    var cash_s = summary.get("cash_spent", 0)
    if cash_e > 0 or cash_s > 0:
        _add_section_header(vbox, "ECONOMY")
        if cash_e > 0:
            _add_stat_row(vbox, "Cash Earned", "+€" + str(cash_e))
        if cash_s > 0:
            _add_stat_row(vbox, "Cash Spent", "-€" + str(cash_s))
        _add_spacer(vbox, 8)

    # ─── Survival ───
    _add_section_header(vbox, "SURVIVAL")
    var energy_drain = summary.get("energy_used", 0)
    var energy_gain = summary.get("energy_restored", 0)
    _add_stat_row(vbox, "Energy Drain", "-%s%%" % str(energy_drain))
    if energy_gain > 0:
        _add_stat_row(vbox, "Energy Restored", "+%s%%" % str(energy_gain))
    var hydro_drain = summary.get("hydration_used", 0)
    var hydro_gain = summary.get("hydration_restored", 0)
    _add_stat_row(vbox, "Hydration Drain", "-%s%%" % str(hydro_drain))
    if hydro_gain > 0:
        _add_stat_row(vbox, "Hydration Restored", "+%s%%" % str(hydro_gain))
    var mental_lost = summary.get("mental_lost", 0)
    var mental_gain = summary.get("mental_restored", 0)
    if mental_lost > 0:
        _add_stat_row(vbox, "Mental Lost", "-%s%%" % str(mental_lost))
    if mental_gain > 0:
        _add_stat_row(vbox, "Mental Restored", "+%s%%" % str(mental_gain))
    var conds = summary.get("conditions", [])
    if conds.size() > 0:
        var cond_names = []
        for c in conds:
            cond_names.append(CONDITIONS.get(c, c))
        _add_stat_row(vbox, "Conditions", ", ".join(cond_names))
    _add_spacer(vbox, 8)

    # ─── XP ───
    var xp = summary.get("xp_gained", 0)
    if xp > 0:
        _add_section_header(vbox, "PROGRESSION")
        _add_stat_row(vbox, "XP Gained", "+" + str(xp))
        _add_spacer(vbox, 8)

    _add_separator(vbox)
    _add_spacer(vbox, 8)

    # Timestamp
    var ts = Label.new()
    ts.text = summary.get("timestamp", "")
    ts.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    ts.add_theme_font_size_override("font_size", 11)
    ts.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
    vbox.add_child(ts)

    _add_spacer(vbox, 12)

    # Buttons row
    var btn_row = HBoxContainer.new()
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_theme_constant_override("separation", 12)
    vbox.add_child(btn_row)

    var history_btn = _make_button("Run History", Color(0.25, 0.25, 0.3))
    history_btn.pressed.connect(_toggle_history)
    btn_row.add_child(history_btn)

    var close_btn = _make_button("Close  [Esc]", Color(0.3, 0.15, 0.15))
    close_btn.pressed.connect(_close_modal)
    btn_row.add_child(close_btn)

func _cleanup_modal():
    if _overlay and is_instance_valid(_overlay):
        _overlay.queue_free()
        _overlay = null

func _close_modal():
    _modal_visible = false
    _history_visible = false
    _cleanup_modal()
    # Also free the canvas layer
    if _canvas_layer and is_instance_valid(_canvas_layer):
        _canvas_layer.queue_free()
        _canvas_layer = null
    Input.mouse_mode = _prev_mouse_mode
    # Always unfreeze on close (matches game's UIManager.UIClose pattern)
    if "freeze" in gameData:
        gameData.freeze = false
    # Allow starting a new run
    if _run_state == RunState.RUN_ENDED:
        _run_state = RunState.IDLE

# ─── History View ───

func _toggle_history():
    if _history_visible:
        # Go back to current summary
        _history_visible = false
        _build_modal(_last_summary)
    else:
        _history_visible = true
        _build_history_view()

func _build_history_view():
    _cleanup_modal()

    _overlay = ColorRect.new()
    _overlay.name = "RunSummaryOverlay"
    _overlay.color = Color(0, 0, 0, 0.8)
    _overlay.anchor_right = 1.0
    _overlay.anchor_bottom = 1.0
    _overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    _canvas_layer.add_child(_overlay)

    var panel = PanelContainer.new()
    var panel_style = StyleBoxFlat.new()
    panel_style.bg_color = Color(0.08, 0.08, 0.1, 0.95)
    panel_style.border_color = Color(0.3, 0.3, 0.35, 1.0)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(4)
    panel_style.content_margin_left = 24
    panel_style.content_margin_right = 24
    panel_style.content_margin_top = 20
    panel_style.content_margin_bottom = 20
    panel.add_theme_stylebox_override("panel", panel_style)
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.custom_minimum_size = Vector2(520, 0)
    panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
    panel.grow_vertical = Control.GROW_DIRECTION_BOTH
    _overlay.add_child(panel)

    var scroll = ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(520, 520)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    panel.add_child(scroll)

    var scroll_margin = MarginContainer.new()
    scroll_margin.add_theme_constant_override("margin_right", 14)
    scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(scroll_margin)

    var vbox = VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll_margin.add_child(vbox)

    var title = Label.new()
    title.text = "RUN HISTORY"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
    vbox.add_child(title)

    _add_spacer(vbox, 8)
    _add_separator(vbox)
    _add_spacer(vbox, 8)

    var history = _load_history()
    if history.size() == 0:
        var empty = Label.new()
        empty.text = "No runs recorded yet."
        empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
        vbox.add_child(empty)
    else:
        for i in range(history.size()):
            var run = history[i]
            _add_history_entry(vbox, run, i)
            if i < history.size() - 1:
                _add_spacer(vbox, 4)
                _add_separator(vbox)
                _add_spacer(vbox, 4)

    _add_spacer(vbox, 12)

    var btn_row = HBoxContainer.new()
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_theme_constant_override("separation", 12)
    vbox.add_child(btn_row)

    var back_btn = _make_button("Back", Color(0.25, 0.25, 0.3))
    back_btn.pressed.connect(_toggle_history)
    btn_row.add_child(back_btn)

    var close_btn = _make_button("Close  [Esc]", Color(0.3, 0.15, 0.15))
    close_btn.pressed.connect(_close_modal)
    btn_row.add_child(close_btn)

func _add_history_entry(parent: VBoxContainer, run: Dictionary, index: int):
    var is_death = run.get("outcome", "") == "DEATH"
    var color = Color(1.0, 0.4, 0.4) if is_death else Color(0.4, 1.0, 0.5)

    var header = HBoxContainer.new()
    header.add_theme_constant_override("separation", 8)
    parent.add_child(header)

    var outcome_label = Label.new()
    outcome_label.text = run.get("outcome", "?")
    outcome_label.add_theme_color_override("font_color", color)
    outcome_label.add_theme_font_size_override("font_size", 15)
    outcome_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(outcome_label)

    var map_label = Label.new()
    map_label.text = run.get("map", "?")
    map_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
    map_label.add_theme_font_size_override("font_size", 13)
    header.add_child(map_label)

    var time_label = Label.new()
    time_label.text = _format_duration(run.get("duration_sec", 0))
    time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
    time_label.add_theme_font_size_override("font_size", 13)
    header.add_child(time_label)

    # Compact stats line
    var stats_parts = []
    var kills = run.get("kills", 0)
    if kills > 0:
        stats_parts.append("%d kill%s" % [kills, "s" if kills != 1 else ""])
    var items = run.get("items_picked", 0)
    if items > 0:
        stats_parts.append("%d item%s" % [items, "s" if items != 1 else ""])
    var xp = run.get("xp_gained", 0)
    if xp > 0:
        stats_parts.append("+%d XP" % xp)
    var cash = run.get("cash_earned", 0)
    if cash > 0:
        stats_parts.append("+€%d" % cash)
    var val = run.get("value_gained", 0)
    if val > 0:
        stats_parts.append("€%d loot" % val)

    if stats_parts.size() > 0:
        var stats_label = Label.new()
        stats_label.text = "  ".join(stats_parts)
        stats_label.add_theme_font_size_override("font_size", 12)
        stats_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
        parent.add_child(stats_label)

    var ts_label = Label.new()
    ts_label.text = run.get("timestamp", "")
    ts_label.add_theme_font_size_override("font_size", 10)
    ts_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.4))
    parent.add_child(ts_label)

# ─── UI Helpers ───

func _add_section_header(parent: VBoxContainer, text: String):
    var label = Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 13)
    label.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
    parent.add_child(label)

func _add_stat_row(parent: VBoxContainer, label_text: String, value_text: String):
    var row = HBoxContainer.new()
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(row)

    var lbl = Label.new()
    lbl.text = label_text
    lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    lbl.add_theme_font_size_override("font_size", 14)
    lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
    row.add_child(lbl)

    var val = Label.new()
    val.text = value_text
    val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    val.add_theme_font_size_override("font_size", 14)
    val.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
    row.add_child(val)

func _add_spacer(parent: VBoxContainer, height: int):
    var spacer = Control.new()
    spacer.custom_minimum_size = Vector2(0, height)
    spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(spacer)

func _add_separator(parent: VBoxContainer):
    var sep = HSeparator.new()
    sep.add_theme_color_override("separator", Color(0.25, 0.25, 0.3))
    parent.add_child(sep)

func _make_button(text: String, bg_color: Color) -> Button:
    var btn = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(130, 32)
    btn.focus_mode = Control.FOCUS_NONE
    var style = StyleBoxFlat.new()
    style.bg_color = bg_color
    style.set_corner_radius_all(3)
    style.content_margin_left = 12
    style.content_margin_right = 12
    style.content_margin_top = 6
    style.content_margin_bottom = 6
    btn.add_theme_stylebox_override("normal", style)
    var hover_style = style.duplicate()
    hover_style.bg_color = bg_color.lightened(0.15)
    btn.add_theme_stylebox_override("hover", hover_style)
    var pressed_style = style.duplicate()
    pressed_style.bg_color = bg_color.darkened(0.1)
    btn.add_theme_stylebox_override("pressed", pressed_style)
    return btn

func _format_duration(seconds: int) -> String:
    var mins = seconds / 60
    var secs = seconds % 60
    if mins >= 60:
        var hrs = mins / 60
        mins = mins % 60
        return "%dh %02dm" % [hrs, mins]
    return "%dm %02ds" % [mins, secs]

# ─── Persistence (Run History) ───

func _save_to_history(summary: Dictionary):
    var history = _load_history()
    history.insert(0, summary)
    if history.size() > 10:
        history.resize(10)

    var cfg = ConfigFile.new()
    cfg.set_value("meta", "count", history.size())
    for i in range(history.size()):
        var section = "run_%d" % i
        var run = history[i]
        for key in run:
            var val = run[key]
            if val is Array:
                cfg.set_value(section, key, ",".join(val))
            else:
                cfg.set_value(section, key, val)
    cfg.save(HISTORY_PATH)

func _load_history() -> Array:
    var cfg = ConfigFile.new()
    if cfg.load(HISTORY_PATH) != OK:
        return []
    var count = cfg.get_value("meta", "count", 0)
    var history = []
    for i in range(count):
        var section = "run_%d" % i
        if !cfg.has_section(section):
            continue
        var run = {}
        for key in cfg.get_section_keys(section):
            var val = cfg.get_value(section, key, "")
            if key == "conditions":
                run[key] = val.split(",") if val != "" else []
            else:
                run[key] = val
        history.append(run)
    return history

# ─── Hotkey ───

func _register_hotkey(key_code: int):
    if not InputMap.has_action(REOPEN_ACTION):
        InputMap.add_action(REOPEN_ACTION)
    else:
        InputMap.action_erase_events(REOPEN_ACTION)
    var ev = InputEventKey.new()
    ev.keycode = key_code
    InputMap.action_add_event(REOPEN_ACTION, ev)

# ─── MCM Integration ───

func _try_load_mcm():
    if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
        return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
    return null

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
    var entry = config.get_value(section, key, null)
    if entry == null or not entry is Dictionary:
        return fallback
    return entry.get("value", fallback)

func _register_mcm():
    var config = ConfigFile.new()

    config.set_value("Bool", "cfg_auto_show", {
        "name" = "Auto-show after run",
        "tooltip" = "Automatically show the run summary modal after death or extraction",
        "default" = true, "value" = true,
        "menu_pos" = 1
    })

    config.set_value("Keycode", "cfg_reopen_key", {
        "name" = "Reopen Summary Hotkey",
        "tooltip" = "Press to reopen the last run summary",
        "default" = KEY_F6, "value" = KEY_F6,
        "menu_pos" = 2
    })

    if !FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
        DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
        config.save(MCM_FILE_PATH + "/config.ini")
    else:
        _mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, config, MCM_FILE_PATH + "/config.ini")
        config.load(MCM_FILE_PATH + "/config.ini")

    _apply_config(config)

    _mcm_helpers.RegisterConfiguration(
        MCM_MOD_ID,
        "Run Summary",
        MCM_FILE_PATH,
        "Post-run summary modal showing combat, loot, survival, and economy stats",
        {"config.ini" = _on_mcm_save}
    )

func _on_mcm_save(config: ConfigFile):
    _apply_config(config)

func _apply_config(config: ConfigFile):
    cfg_auto_show = _mcm_val(config, "Bool", "cfg_auto_show", true)
    var new_key = _mcm_val(config, "Keycode", "cfg_reopen_key", KEY_F6)
    if new_key != cfg_reopen_key:
        cfg_reopen_key = new_key
        _register_hotkey(cfg_reopen_key)

func _load_local_config():
    var cfg = ConfigFile.new()
    if cfg.load(LOCAL_CFG_PATH) == OK:
        cfg_auto_show = cfg.get_value("config", "auto_show", true)
        cfg_reopen_key = cfg.get_value("config", "reopen_key", KEY_F6)
    _save_local_config()

func _save_local_config():
    var cfg = ConfigFile.new()
    cfg.set_value("config", "auto_show", cfg_auto_show)
    cfg.set_value("config", "reopen_key", cfg_reopen_key)
    cfg.save(LOCAL_CFG_PATH)
