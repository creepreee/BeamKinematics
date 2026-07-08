"""
Blender -> TelekinesisController animation exporter.

Run inside Blender's Text Editor or via:
    blender my.blend --background --python data/blender_export_animation.py

What it does:
  1. Reads the ACTIVE object's location + rotation animation
  2. Exports to animation_data.lua in one of two modes:
     - KEYFRAME mode: preserves Blender keyframes + easing for the mod's
       timeline.sample() engine (smart interpolation with easeIn/Out/InOut/bezier)
     - BAKED mode: samples every frame at a given FPS, writes dense pos+quat
       for a simple frame-by-frame playback engine (no easing)

Rotation:
  Only one rotation mode on the object at a time (XYZ Euler or Quaternion).
  The script reads matrix_world.to_quaternion() so both work automatically.

Usage in Blender:
  - Set EXPORT_MODE below to "keyframe" or "baked"
  - Select the animated object
  - Run this script
  - The lua file lands in the TelekinesisController mod folder
"""

import bpy
import mathutils
import math
import os
import sys

# ---------------------------------------------------------------------------
#  CONFIG  -  tweak before running
# ---------------------------------------------------------------------------

# "keyframe" = smart keyframes with easing (for existing engine)
# "baked"    = every frame at EXPORT_FPS (for frame-by-frame playback)
EXPORT_MODE = "keyframe"

# Only used when EXPORT_MODE = "baked"
EXPORT_FPS = 60

# Set to a string to export a specific object by name, or None for active/selected
EXPORT_OBJECT = None

# Coordinate system: Blender and BeamNG both use Z-up right-handed, metres.
SCALE = 1.0
ROTATE_OFFSET = mathutils.Quaternion()  # identity = no extra rotation

# Output path
# Default: auto-detected from script location (assumes script is in mod's data/).
# To override at runtime: blender my.blend --background --python blender_export_animation.py -- --output C:/path/to/animation_data.lua
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
OUTPUT_LUA = os.path.join(
    MOD_DIR, "lua", "ge", "extensions", "telekinesis", "animation_data.lua"
)


# ---------------------------------------------------------------------------
#  BLENDER INTERPOLATION -> MOD EASING  (KEYFRAME MODE ONLY)
# ---------------------------------------------------------------------------


def blender_fcurve_to_mod_curve(fcurve, kf_index):
    keyframes = fcurve.keyframe_points
    if kf_index < 0 or kf_index >= len(keyframes) - 1:
        return "linear"

    kf = keyframes[kf_index]
    next_kf = keyframes[kf_index + 1]
    interp = kf.interpolation

    if interp == "BEZIER":
        dx = next_kf.co.x - kf.co.x
        dy = next_kf.co.y - kf.co.y
        if abs(dx) < 1e-8 or abs(dy) < 1e-8:
            return "linear"

        h1 = kf.handle_right
        h2 = next_kf.handle_left

        p1x = (h1.x - kf.co.x) / dx if dx != 0 else 0.333
        p1y_raw = (h1.y - kf.co.y) / dy if dy != 0 else 0.333
        p2x = (h2.x - kf.co.x) / dx if dx != 0 else 0.667
        p2y_raw = (h2.y - kf.co.y) / dy if dy != 0 else 0.667

        p1x = max(0.0, min(1.0, p1x))
        p1y = max(0.0, min(1.0, p1y_raw))
        p2x = max(0.0, min(1.0, p2x))
        p2y = max(0.0, min(1.0, p2y_raw))

        if (
            abs(p1x - 0.333) < 0.02
            and abs(p1y - 0.333) < 0.02
            and abs(p2x - 0.667) < 0.02
            and abs(p2y - 0.667) < 0.02
        ):
            return "linear"

        return {
            "type": "bezier",
            "p1": {"x": p1x, "y": p1y},
            "p2": {"x": p2x, "y": p2y},
        }

    easing = getattr(kf, "easing", None) or "AUTO"

    if interp == "LINEAR":
        return "linear"

    if interp == "CONSTANT":
        return "linear"

    if interp in (
        "SINE", "QUAD", "CUBIC", "QUART", "QUINT",
        "EXPO", "BACK", "ELASTIC", "BOUNCE",
    ):
        if easing in ("EASE_IN",):
            return "easeIn"
        elif easing in ("EASE_OUT",):
            return "easeOut"
        elif easing in ("EASE_IN_OUT",):
            return "easeInOut"
        else:
            return "easeInOut"

    return "linear"


# ---------------------------------------------------------------------------
#  HELPERS
# ---------------------------------------------------------------------------


def format_float(v):
    return f"{v:.6f}"


def pos_to_lua(pos):
    return f'vec3({format_float(pos["x"])}, {format_float(pos["y"])}, {format_float(pos["z"])})'


def rot_to_lua(rot):
    return f'quat({format_float(rot["x"])}, {format_float(rot["y"])}, {format_float(rot["z"])}, {format_float(rot["w"])})'


def curve_to_lua(curve):
    if isinstance(curve, str):
        return f'"{curve}"'
    if isinstance(curve, dict) and curve.get("type") == "bezier":
        p1 = curve["p1"]
        p2 = curve["p2"]
        return (
            '{type="bezier", p1={x='
            + format_float(p1["x"])
            + ", y="
            + format_float(p1["y"])
            + "}, p2={x="
            + format_float(p2["x"])
            + ", y="
            + format_float(p2["y"])
            + "}}"
        )
    return '"linear"'


def sample_obj_at_frame(scene, obj, frame):
    """Set scene to frame, return (pos_dict, rot_dict) sampled from obj."""
    scene.frame_set(int(frame), subframe=frame - int(frame))
    world_mat = obj.matrix_world.copy()
    loc = world_mat.to_translation()
    pos = {"x": loc.x * SCALE, "y": loc.y * SCALE, "z": loc.z * SCALE}
    rot = world_mat.to_quaternion()
    if ROTATE_OFFSET.angle > 1e-6:
        rot = ROTATE_OFFSET @ rot
    rot.normalize()
    return pos, {"x": rot.x, "y": rot.y, "z": rot.z, "w": rot.w}


# ---------------------------------------------------------------------------
#  EXPORT: KEYFRAME MODE
# ---------------------------------------------------------------------------


def export_keyframes(action, obj, scene, fps):
    """Export Blender keyframes with easing preserved."""
    raw_times = set()
    ref_fcurve = None

    curve_data_paths = ("location", "rotation_euler", "rotation_quaternion")

    for fcurve in action.fcurves:
        dp = fcurve.data_path
        if any(dp == p for p in curve_data_paths):
            if dp == "location" and ref_fcurve is None:
                ref_fcurve = fcurve
            for kf in fcurve.keyframe_points:
                raw_times.add(kf.co.x)

    if not raw_times:
        print(f"ERROR: No keyframes found on '{obj.name}'.")
        return None

    sorted_frames = sorted(raw_times)
    keyframes = []

    for i, frame in enumerate(sorted_frames):
        pos, rot = sample_obj_at_frame(scene, obj, frame)

        if i < len(sorted_frames) - 1:
            if ref_fcurve:
                kf_idx = None
                for j, kf in enumerate(ref_fcurve.keyframe_points):
                    if abs(kf.co.x - frame) < 0.001:
                        kf_idx = j
                        break
                curve = (
                    blender_fcurve_to_mod_curve(ref_fcurve, kf_idx)
                    if kf_idx is not None
                    else "linear"
                )
            else:
                curve = "linear"
        else:
            curve = keyframes[-1].get("curve", "linear") if keyframes else "linear"

        keyframes.append(
            {
                "time": frame / fps,
                "pos": pos,
                "rot": rot,
                "curve": curve,
            }
        )

    return keyframes


# ---------------------------------------------------------------------------
#  EXPORT: BAKED MODE
# ---------------------------------------------------------------------------


def export_baked(obj, scene, fps):
    """Sample the object at every frame from start to end at EXPORT_FPS."""
    # Find the frame range from all F-curves on the object
    if obj.animation_data is None or obj.animation_data.action is None:
        print(f"ERROR: '{obj.name}' has no animation action.")
        return None

    action = obj.animation_data.action
    min_frame = float("inf")
    max_frame = float("-inf")

    for fcurve in action.fcurves:
        for kf in fcurve.keyframe_points:
            min_frame = min(min_frame, kf.co.x)
            max_frame = max(max_frame, kf.co.x)

    if min_frame == float("inf"):
        print(f"ERROR: No keyframes found on '{obj.name}'.")
        return None

    baked_fps = EXPORT_FPS
    # Sample at regular intervals
    start_sec = min_frame / fps
    end_sec = max_frame / fps
    duration = end_sec - start_sec
    total_samples = int(duration * baked_fps) + 1

    baked = []
    for s in range(total_samples):
        t = s / baked_fps
        frame = min_frame + t * fps
        pos, rot = sample_obj_at_frame(scene, obj, frame)
        baked.append(
            {
                "time": t,
                "pos": pos,
                "rot": rot,
            }
        )

    return baked, duration


# ---------------------------------------------------------------------------
#  WRITE LUA FILE
# ---------------------------------------------------------------------------


def write_lua_keyframe(keyframes, duration, last_curve, fps):
    os.makedirs(os.path.dirname(OUTPUT_LUA), exist_ok=True)
    with open(OUTPUT_LUA, "w", encoding="utf-8") as f:
        f.write("-- auto-generated by blender_export_animation.py (keyframe mode)\n")
        f.write("local M = {}\n\n")
        f.write('M.mode = "keyframe"\n\n')
        f.write("M.keyframes = {\n")
        for kf in keyframes:
            f.write("  {\n")
            f.write(f'    time = {format_float(kf["time"])},\n')
            f.write(f"    pos  = {pos_to_lua(kf['pos'])},\n")
            f.write(f"    rot  = {rot_to_lua(kf['rot'])},\n")
            f.write(f"    curve = {curve_to_lua(kf['curve'])},\n")
            f.write("  },\n")
        f.write("}\n\n")
        f.write(f"M.duration = {format_float(duration)}\n")
        f.write(f"M.fps = {int(round(fps))}\n")
        f.write(f"M.lastKeyframeCurve = {curve_to_lua(last_curve)}\n")
        f.write("\nreturn M\n")


def write_lua_baked(baked, duration, fps):
    os.makedirs(os.path.dirname(OUTPUT_LUA), exist_ok=True)
    with open(OUTPUT_LUA, "w", encoding="utf-8") as f:
        f.write("-- auto-generated by blender_export_animation.py (baked mode)\n")
        f.write("local M = {}\n\n")
        f.write('M.mode = "baked"\n\n')
        f.write(f"M.fps = {int(round(fps))}\n")
        f.write(f"M.duration = {format_float(duration)}\n\n")
        f.write("M.frames = {\n")
        for bf in baked:
            f.write("  {\n")
            f.write(f'    time = {format_float(bf["time"])},\n')
            f.write(f"    pos  = {pos_to_lua(bf['pos'])},\n")
            f.write(f"    rot  = {rot_to_lua(bf['rot'])},\n")
            f.write("  },\n")
        f.write("}\n\n")
        f.write("return M\n")


# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------


def export_animation(obj):
    if obj is None:
        print("ERROR: No object selected / found.")
        return False

    if obj.animation_data is None or obj.animation_data.action is None:
        print(f"ERROR: '{obj.name}' has no animation action.")
        return False

    scene = bpy.context.scene
    fps = scene.render.fps / scene.render.fps_base

    if EXPORT_MODE == "baked":
        result = export_baked(obj, scene, fps)
        if result is None:
            return False
        baked, duration = result
        write_lua_baked(baked, duration, EXPORT_FPS)
        print(f"Done (baked). Exported {len(baked)} frames at {EXPORT_FPS} FPS to:")
        print(f"  {OUTPUT_LUA}")
    else:
        action = obj.animation_data.action
        keyframes = export_keyframes(action, obj, scene, fps)
        if keyframes is None:
            return False
        duration = keyframes[-1]["time"] if keyframes else 0.0
        last_curve = keyframes[-1]["curve"] if keyframes else "linear"
        write_lua_keyframe(keyframes, duration, last_curve, fps)
        print(f"Done (keyframe). Exported {len(keyframes)} keyframes with easing to:")
        print(f"  {OUTPUT_LUA}")

    return True


def main():
    obj = None
    if EXPORT_OBJECT:
        obj = bpy.data.objects.get(EXPORT_OBJECT)
        if not obj:
            print(f"ERROR: Object '{EXPORT_OBJECT}' not found in scene.")
            return
    else:
        obj = bpy.context.active_object
        if not obj:
            obj = bpy.context.selected_objects
            obj = obj[0] if obj else None
        if not obj:
            print("ERROR: No active or selected object. Select an animated object first.")
            return

    export_animation(obj)


if __name__ == "__main__":
    # Parse --output argument (must come after -- in CLI to avoid Blender consuming it)
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", help="Override output path for animation_data.lua")
    args, remaining = parser.parse_known_args()
    if args.output:
        global OUTPUT_LUA
        OUTPUT_LUA = os.path.abspath(args.output)
    main()
