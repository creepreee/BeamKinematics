# BeamNG Softbody Kinematics Controller/ keyframe animations mod for BeamNG

**BKS Controller** — a BeamNG.drive mod that drives a vehicle through a timed sequence of positions and rotations using the thrusters API. A PD controller with feed-forward follows a keyframe animation timeline, then hands the car back to physics with full momentum at a chosen moment.

## Quick start

1. Copy the `TelekinesisController/` folder into BeamNG's `mods/unpacked/` directory.
2. Start BeamNG, load any vehicle.
3. Open **UI apps** and then search for **telekinesis**. Add that to the layout of beamng. 
4. The default animation lifts the car, arcs it sideways, and releases it mid-flight at t=11 s.
5. Click **Play** to run the animation, **Stop** to release the car immediately.
6. ~~Press **Y** to hide/show the entire UI panel.~~ #NOTE: this function is not working right now. **TODO**

## Animation sources

The engine accepts keyframes from two sources. The in-game table always wins — once you add or edit a keyframe there, any loaded file is cleared.

### 1. In-game keyframe table

Edit keyframes in the **Keyframes** table at the bottom of the panel. Each row:

| Field | Meaning |
|-------|---------|
| **Time** | Seconds on the timeline. |
| **X, Y, Z** | World-space offset from the car's starting position (metres). |
| **Axis** | Which axis to rotate around (`X`, `Y`, or `Z`). |
| **Deg** | Degrees of rotation around that axis. |
| **Curve** | Easing between this keyframe and the next one. |

Curve options:
- **Linear** — constant speed through the segment.
- **Ease In** — starts slow, speeds up toward the end.
- **Ease Out** — starts fast, slows to a stop.
- **Ease In-Out** — slow start and end, fast in the middle.
- **Bezier** — custom handle bars for precise velocity shaping.

### 2. Blender export
MAKE SURE BLENDER IS OPENED AS ADMINISTRATOR!!!
in the folder "blender export script", 
Animate any object in Blender, then run the exporter to generate `animation_data.lua`. On reload the car follows the Blender animation, offset to wherever the car is spawned.

#### Workflow

1. **Animate** an object in Blender (location + rotation, XYZ Euler or Quaternion).
2. **Set export mode** in `data/blender_export_animation.py`:
   - `EXPORT_MODE = "keyframe"` — preserves Blender keyframes with easing mapping.
   - `EXPORT_MODE = "baked"` — samples every frame at `EXPORT_FPS` (default 60).
3. **Select the animated object** in Blender.
4. **Run the script** — from Blender's Text Editor, or headless:
   ```
   blender my.blend --background --python data/blender_export_animation.py
   ```
5. The `.lua` file is written to `lua/ge/extensions/telekinesis/animation_data.lua` automatically.
6. In BeamNG, click **Load Anim** in the UI or run `extensions.reload("telekinesis.main")`.

> **Tip:** If Blender can't write to the mod folder (admin rights), specify a custom output path:
> ```
> blender my.blend --background --python data/blender_export_animation.py -- --output C:/Users/You/Documents/animation_data.lua
> ```
> Then copy the file to `lua/ge/extensions/telekinesis/animation_data.lua` manually.

#### Release marker via Blender 
(what is this? Release marker is basically a physics engine control keyframe. just like the animated checkbox of rigid body in blender, it is kind of liek a switch that when placed at a desired aniation time, gets the physics engien take over the animation)

Add this line to `animation_data.lua` to release the car mid-flight:
```lua
M.releaseTime = 11.0
```

NOTE:THIS is via blender. you can also control te release marker form the mod UI itself too

### 3. Manual `animation_data.lua`

Write the file by hand for precise control. See **Keyframe mode** and **Baked mode** formats in the source at `data/blender_export_animation.py`.

## Graph editor

The centre panel shows a value-over-time curve for the selected axis (Z/X/Y/Speed). Click a diamond keyframe to select it. Drag the **● handles** on the selected segment to shape bezier easing. Use the **Zoom** slider to scale the time axis.

Click or drag on the graph to **scrub** the timeline — the car follows the playhead position instantly.

## Release marker

The **Release** panel lets you pick a time when the controller stops pushing and hands the car to soft-body physics. The car **keeps whatever speed it had**.

- Place the marker **before** the last keyframe for a mid-flight launch with momentum.
- Disable it → the car holds the final pose for `END_HOLD_TIME` seconds, then settles.

## Advanced settings

Open the **Advanced** panel (left column) to tune the controller.

### Position

| Setting | Default | What it does |
|---------|---------|-------------|
| `KP_POS` | 6.0 | Stiffness. How hard the controller pulls toward the target. |
| `KD_POS` | 7.0 | Damping. Resists velocity to stop bouncing. |
| `Max Accel` | 30.0 | Max linear acceleration (m/s²). |

### Rotation

| Setting | Default | What it does |
|---------|---------|-------------|
| `KP_ROT` | 8.0 | Stiffness. How hard the controller rights the car. |
| `KD_ROT` | 6.0 | Damping. Smooths out wobble. |
| `Max Ang` | 8.0 | Max angular acceleration (rad/s²). |

### End behaviour

| Setting | Default | What it does |
|---------|---------|-------------|
| `Grav Ramp` | 0.5 | Anti-gravity fade-in (seconds). Prevents suspension pop. |
| `FF Dt` | 0.02 | Feed-forward look-ahead (seconds). |
| `End Hold` | 1.5 | Hold final pose (seconds) before release. |

### Debug

| Setting | Default | What it does |
|---------|---------|-------------|
| **Debug Log** | ON | Toggle debug prints to the console. Uncheck to silence. |

## Keybinds

| Key | Action |
|-----|--------|
| **Y** | Toggle panel visibility. | #not working currently. Use the hide button to hide the ui panel

## File locations (internal)

| Path | Purpose |
|------|---------|
| `mods/unpacked/TelekinesisController/` | Mod root folder. |
| `settings/telekinesis/controller.json` | Saved presets. |
| `data/blender_export_animation.py` | Blender export script. |
| `lua/ge/extensions/telekinesis/animation_data.lua` | Blender output (auto-generated). |
