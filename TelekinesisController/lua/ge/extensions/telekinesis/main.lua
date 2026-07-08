-- ===========================================================================
--  BKS CONTROLLER  -  main.lua   (GAME-ENGINE / "GE" side)
-- ===========================================================================
--  Keyframe-driven pose control with EASING + a clean external API.
--
--     TARGET(t)  -> desired POSE (pos + rot) from the timeline, with per-segment
--         |          EASING curves (linear / easeIn / easeOut / easeInOut / bezier)
--         v
--     CONTROLLER -> PD (correct error) + FEED-FORWARD (match target's own speed,
--         |          so there is no tracking lag), for both position and rotation
--         v
--     pushAccel  -> thrusters.applyAccel into the car's VM (linear + angular)
--
--  DESIGNED FOR A FUTURE UI:  Nothing is hardcoded inside the logic. All tunables
--  live in the mutable table `M.settings`, and the animation lives in `M.keyframes`.
--  Both are changed ONLY through setter functions (M.setSetting, M.setSettings,
--  M.setKeyframes, M.setKeyframeCurve, M.play, M.stop). Later, an HTML page can map
--  its buttons/sliders straight onto those setters - no logic changes needed.
-- ===========================================================================

local M = {}
local timeline = require("telekinesis.timeline")   -- pos-lerp + rot-slerp + curves

local SAVE_DIR  = "settings/telekinesis"
local SAVE_FILE = SAVE_DIR .. "/controller.json"

-- ---------------------------------------------------------------------------
--  SETTINGS  (all tunables in ONE mutable table - the UI will write to this)
-- ---------------------------------------------------------------------------
M.settings = {
  -- Position controller
  KP_POS        = 6.0,    -- spring: pull toward target point
  KD_POS        = 7.0,    -- damping: settle without oscillating (raised 5→7 to cut stop overshoot)
  -- Rotation controller
  KP_ROT        = 8.0,    -- spring: pull toward target orientation
  KD_ROT        = 6.0,    -- damping. Critical = 2*sqrt(KP_ROT) = 5.66; 6.0 is just over.
                          -- IMPORTANT: damping now uses a FILTERED angular velocity
                          -- (see ANGVEL_SMOOTH). Before, raising KD on the RAW (noisy)
                          -- angVel amplified body-flex jitter -> the swing you saw.
  ANGVEL_SMOOTH = 0.25,   -- angular-velocity low-pass (0..1). Lower = smoother but laggier.
                          -- This is the real stabiliser: it removes the measurement noise
                          -- that the damping term was otherwise multiplying up.
  ROT_DEADBAND  = 0.010,  -- ignore orientation error below this (rad, ~0.6deg). Stops the
                          -- controller from fighting tiny soft-body jitter around level.
  MAX_ANG_ACCEL = 8.0,    -- clamp on angular accel (rad/s^2)
  -- Physics / safety
  GRAVITY       = 9.81,   -- added upward so the car floats
  GRAVITY_RAMP  = 0.5,    -- EASE the anti-gravity thrust in over this many seconds at the
                          -- START (0 = off, instant). Fixes the "spring pop": at rest the car
                          -- sits on COMPRESSED springs; applying full +GRAVITY instantly makes
                          -- it weightless in one frame, so the springs snap to full extension
                          -- and the body jumps up. Ramping transfers the weight gradually so the
                          -- suspension relaxes smoothly instead of bouncing. Raise if it still
                          -- pops; lower toward 0 if the initial lift feels too soft/laggy.
  MAX_ACCEL     = 30.0,   -- clamp on linear accel (m/s^2)
  FF_DT         = 0.02,   -- feed-forward look-ahead (s)
  -- End behaviour
  HOLD_AT_END   = true,   -- keep holding the final pose after timeline ends...
  END_HOLD_TIME = 1.5,    -- ...for this long, then release the car
  -- Debug
  DEBUG         = true,
  DEBUG_EVERY   = 0.25,
}

-- ---------------------------------------------------------------------------
--  KEYFRAMES  (the animation - RELATIVE to spawn pose; the UI will write this)
-- ---------------------------------------------------------------------------
--  Each keyframe:
--    time  = seconds from start
--    off   = position OFFSET from spawn (world axes, z up), metres
--    rot   = orientation DELTA from spawn: { axis="x"/"y"/"z", deg=degrees }
--    curve = easing for the segment LEAVING this keyframe. One of:
--            "linear" | "easeIn" | "easeOut" | "easeInOut"
--            or a bezier table: { type="bezier", p1={x=,y=}, p2={x=,y=} }
M.keyframes = {
  { time = 0.0,  off = vec3( 0, 0, 0), rot = {axis="z", deg= 0}, curve = "easeInOut" },
  { time = 10.0, off = vec3( 0, 0, 8), rot = {axis="z", deg= 0}, curve = "easeInOut" },
  { time = 12.0, off = vec3(-6, 6, 8), rot = {axis="z", deg= 0}, curve = "easeInOut" },
  { time = 15.0, off = vec3(-6, 6, 8), rot = {axis="z", deg= 0}, curve = "easeIn" },
}

-- ---------------------------------------------------------------------------
--  RELEASE MARKER  (the Blender "Animated OFF at frame 3" trick)
-- ---------------------------------------------------------------------------
-- A standalone point in time (seconds from start) where we HAND THE CAR BACK to
-- normal physics - deliberately SEPARATE from the pose keyframes above, exactly like
-- Blender's "Animated" checkbox keyed OFF at frame 3 (independent of the position keys).
--
-- WHY separate: it lets us release the car MID-MOTION, while it is still travelling at
-- speed toward a keyframe further ahead. We only STOP PUSHING - we never zero the car's
-- velocity - so it keeps the momentum it had at that instant and flies on, arcs, drops
-- and crashes realistically. That is the opposite of the dead "animation ended, car
-- falls straight down" drop you get if you release once it has already eased to a stop.
--
-- KEY RULE: set the marker BEFORE the motion finishes (a pose keyframe must still be
-- ahead of it). Releasing between two keyframes = the car is at full speed = maximum
-- momentum carried into physics. Releasing at/after the last keyframe = it has already
-- slowed to ~0, so it just settles (no launch).
--
--   M.releaseTime = 11.0  -- e.g. release mid-flight (between the t=10 and t=12 keys),
--                         --      while still moving fast -> launches on with momentum.
--   M.releaseTime = nil   -- no early release; hold final pose END_HOLD_TIME then drop.
M.releaseTime = 11.0

-- ---------------------------------------------------------------------------
--  STATE  (managed by the code; do not hand-edit)
-- ---------------------------------------------------------------------------
local active      = false
local elapsed     = 0.0
local lastPos     = nil
local lastRot     = nil
local started     = false
local frames      = nil    -- absolute keyframes (built from M.keyframes + spawn pose)
local spawnPos    = nil    -- captured on first frame; used to (re)build frames
local spawnRot    = nil
local endTimer    = 0.0
local debugAccum  = 0.0
local angVelFilt  = nil    -- smoothed angular velocity (low-pass state for damping)
-- NOTE: the release TIME lives in M.releaseTime (a public setting, set near the keyframes),
-- not here. `released` just tracks whether we've already fired it this run.
local released          = false
local loadedKeyframes   = nil    -- absolute keyframes from animation_data.lua (Blender export)
local bakedCount        = 0      -- number of baked frames (0 = not baked)

-- ---------------------------------------------------------------------------
--  SMALL HELPERS
-- ---------------------------------------------------------------------------
local function dbg(msg)
  if M.settings.DEBUG then print("BSKC: " .. tostring(msg)) end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function v3(x, y, z) return vec3(x or 0, y or 0, z or 0) end
local function vlen(v) return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
local function tonumberOr(v, fallback)
  local n = tonumber(v)
  if n == nil then return fallback end
  return n
end

local function tableCopy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    if type(v) == "table" then
      out[k] = tableCopy(v)
    else
      out[k] = v
    end
  end
  return out
end

local function copyCurve(curve)
  if type(curve) ~= "table" then return curve or "linear" end
  return {
    type = curve.type or "bezier",
    p1 = {
      x = tonumberOr(curve.p1 and curve.p1.x, 0.25),
      y = tonumberOr(curve.p1 and curve.p1.y, 0.0),
    },
    p2 = {
      x = tonumberOr(curve.p2 and curve.p2.x, 0.75),
      y = tonumberOr(curve.p2 and curve.p2.y, 1.0),
    },
  }
end

local function plainKeyframes()
  local out = {}
  for i, k in ipairs(M.keyframes or {}) do
    local off = k.off or {}
    local rot = k.rot or {}
    out[i] = {
      time = tonumberOr(k.time, 0),
      off = {
        x = tonumberOr(off.x, 0),
        y = tonumberOr(off.y, 0),
        z = tonumberOr(off.z, 0),
      },
      rot = {
        axis = rot.axis or "z",
        deg = tonumberOr(rot.deg, 0),
      },
      curve = copyCurve(k.curve),
    }
  end
  return out
end

local function normalizeKeyframes(kf)
  local out = {}
  if type(kf) ~= "table" then return out end

  for _, k in ipairs(kf) do
    local off = k.off or { x = k.x, y = k.y, z = k.z }
    local rot = k.rot or { axis = k.axis, deg = k.deg }
    local curve = k.curve or k.interp or "linear"

    if curve == "bezier" then
      curve = {
        type = "bezier",
        p1 = { x = tonumberOr(k.handleOutX, 0.25), y = tonumberOr(k.handleOutY, 0.0) },
        p2 = { x = tonumberOr(k.handleInX, 0.75),  y = tonumberOr(k.handleInY, 1.0) },
      }
    end

    table.insert(out, {
      time = tonumberOr(k.time, 0),
      off = v3(tonumberOr(off.x, 0), tonumberOr(off.y, 0), tonumberOr(off.z, 0)),
      rot = {
        axis = (rot.axis == "x" or rot.axis == "y" or rot.axis == "z") and rot.axis or "z",
        deg = tonumberOr(rot.deg, 0),
      },
      curve = copyCurve(curve),
    })
  end

  table.sort(out, function(a, b) return (a.time or 0) < (b.time or 0) end)
  return out
end

local function ensureSaveDir()
  if FS and not FS:directoryExists(SAVE_DIR) then
    FS:directoryCreate(SAVE_DIR, true)
  end
end

-- ---- quaternion math -----------------------------------------------------
local function qnorm(q)
  local l = math.sqrt(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
  if l < 1e-12 then return quat(0, 0, 0, 1) end
  return quat(q.x/l, q.y/l, q.z/l, q.w/l)
end

local function qmul(a, b)
  return quat(
    a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
    a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
    a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
    a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z
  )
end

local function qinv(q)
  local n = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w
  if n < 1e-12 then return quat(0, 0, 0, 1) end
  return quat(-q.x/n, -q.y/n, -q.z/n, q.w/n)
end

local function quatAxisDeg(axisName, deg)
  local ax, ay, az = 0, 0, 0
  if     axisName == "x" then ax = 1
  elseif axisName == "y" then ay = 1
  else                        az = 1 end
  local half = math.rad(deg) * 0.5
  local s, c = math.sin(half), math.cos(half)
  return qnorm(quat(ax*s, ay*s, az*s, c))
end

-- Quaternion -> single-axis {axis, deg} for the UI keyframe TABLE. This is a DISPLAY
-- approximation: the table only offers x/y/z + degrees, so we take the rotation's dominant
-- axis and its signed angle. Multi-axis (tilted) spins lose their off-axis part here, but the
-- true playback never uses this - it uses the full quaternion in loadedKeyframes. Editing a
-- row + Apply is what commits this simplified value back (see the caveat in loadAnimationData).
local function quatToAxisDeg(q)
  q = qnorm(q)
  if q.w < 0 then q = quat(-q.x, -q.y, -q.z, -q.w) end
  local w = clamp(q.w, -1, 1)
  local angle = 2 * math.acos(w)          -- radians, 0..pi
  local s = math.sqrt(math.max(0, 1 - w*w))
  if s < 1e-6 then return "z", 0 end       -- ~no rotation
  local ax, ay, az = q.x/s, q.y/s, q.z/s
  local absx, absy, absz = math.abs(ax), math.abs(ay), math.abs(az)
  local axisName, comp
  if absx >= absy and absx >= absz then axisName, comp = "x", ax
  elseif absy >= absz then                axisName, comp = "y", ay
  else                                    axisName, comp = "z", az end
  local deg = math.deg(angle) * (comp < 0 and -1 or 1)
  return axisName, deg
end

local function qToRotVec(q)
  q = qnorm(q)
  if q.w < 0 then q = quat(-q.x, -q.y, -q.z, -q.w) end
  local w = clamp(q.w, -1, 1)
  local s = math.sqrt(math.max(0, 1 - w*w))
  -- SMALL-ANGLE CASE: for a tiny rotation the sin term s is near zero. The OLD code
  -- returned v3(0,0,0) here - which was the real stability bug: between two frames the
  -- car rotates only a fraction of a degree, so this branch hit EVERY frame and the
  -- measured angular velocity was ALWAYS zero -> the damping term was always zero ->
  -- the rotation controller was an UNDAMPED spring that oscillated forever.
  -- Correct small-angle result: rotation vector ~= 2 * (x,y,z) (since xyz ~= axis*angle/2).
  if s < 1e-6 then
    return v3(2*q.x, 2*q.y, 2*q.z)
  end
  local angle = 2 * math.acos(w)
  return v3(q.x/s * angle, q.y/s * angle, q.z/s * angle)
end

local function getCarRot(veh)
  local okF, f = pcall(function() return veh:getDirectionVector() end)
  local okU, u = pcall(function() return veh:getDirectionVectorUp() end)
  if not okF or not okU then return quat(0, 0, 0, 1) end
  f = v3(f.x, f.y, f.z)
  u = v3(u.x, u.y, u.z)
  local r = v3(f.y*u.z - f.z*u.y, f.z*u.x - f.x*u.z, f.x*u.y - f.y*u.x)
  local rl = vlen(r); if rl < 1e-9 then r = v3(1,0,0) else r = v3(r.x/rl, r.y/rl, r.z/rl) end
  u = v3(r.y*f.z - r.z*f.y, r.z*f.x - r.x*f.z, r.x*f.y - r.y*f.x)
  local ul = vlen(u); if ul > 1e-9 then u = v3(u.x/ul, u.y/ul, u.z/ul) end
  local m00,m01,m02 = r.x, f.x, u.x
  local m10,m11,m12 = r.y, f.y, u.y
  local m20,m21,m22 = r.z, f.z, u.z
  local tr = m00 + m11 + m22
  local qx, qy, qz, qw
  if tr > 0 then
    local s = math.sqrt(tr + 1.0) * 2
    qw = 0.25*s; qx = (m21-m12)/s; qy = (m02-m20)/s; qz = (m10-m01)/s
  elseif m00 > m11 and m00 > m22 then
    local s = math.sqrt(1.0 + m00 - m11 - m22) * 2
    qw = (m21-m12)/s; qx = 0.25*s; qy = (m01+m10)/s; qz = (m02+m20)/s
  elseif m11 > m22 then
    local s = math.sqrt(1.0 + m11 - m00 - m22) * 2
    qw = (m02-m20)/s; qx = (m01+m10)/s; qy = 0.25*s; qz = (m12+m21)/s
  else
    local s = math.sqrt(1.0 + m22 - m00 - m11) * 2
    qw = (m10-m01)/s; qx = (m02+m20)/s; qy = (m12+m21)/s; qz = 0.25*s
  end
  return qnorm(quat(qx, qy, qz, qw))
end

local function angVelFrom(prevRot, curRot, dt)
  if not prevRot or not dt or dt <= 0 then return v3(0,0,0) end
  local rv = qToRotVec(qmul(curRot, qinv(prevRot)))
  return v3(rv.x/dt, rv.y/dt, rv.z/dt)
end

local function pushAccel(veh, lin, ang, dt)
  if not (veh and veh.queueLuaCommand) then return end
  veh:queueLuaCommand(string.format(
    "if thrusters and thrusters.applyAccel then thrusters.applyAccel(vec3(%.5f,%.5f,%.5f), %.5f, nil, vec3(%.5f,%.5f,%.5f)) end",
    lin.x, lin.y, lin.z, dt or 0.016, ang.x, ang.y, ang.z))
end

local function releaseCar(veh)
  if not (veh and veh.queueLuaCommand) then return end
  veh:queueLuaCommand(
    "if thrusters and thrusters.applyAccel then thrusters.applyAccel(vec3(0,0,0), 0.001, nil, vec3(0,0,0)) end")
end

-- Turn RELATIVE M.keyframes into ABSOLUTE frames (world pos + world quat) using
-- the captured spawn pose. Produces the {time,pos,rot,curve} shape timeline wants.
local function buildFrames()
  if not spawnPos then return nil end
  local out = {}
  for i, k in ipairs(M.keyframes) do
    local off = k.off or vec3(0,0,0)
    local rk  = k.rot or {axis="z", deg=0}
    out[i] = {
      time  = k.time or 0,
      pos   = v3(spawnPos.x + off.x, spawnPos.y + off.y, spawnPos.z + off.z),
      rot   = qmul(spawnRot, quatAxisDeg(rk.axis or "z", rk.deg or 0)),
      curve = k.curve or "linear",   -- string OR bezier table; timeline/curves handle both
    }
  end
  return out
end

-- ===========================================================================
--  PUBLIC API  (a future HTML UI drives the engine ONLY through these)
-- ===========================================================================

-- Change one setting, e.g. M.setSetting("KP_POS", 8.0)
function M.setSetting(key, value)
  if M.settings[key] == nil then
    dbg("setSetting: unknown key '" .. tostring(key) .. "'")
    return false
  end
  M.settings[key] = value
  dbg(string.format("setSetting %s = %s", tostring(key), tostring(value)))
  return true
end

-- Change many settings at once, e.g. M.setSettings({KP_POS=8, KD_POS=6})
function M.setSettings(tbl)
  if type(tbl) ~= "table" then return false end
  for k, v in pairs(tbl) do M.setSetting(k, v) end
  return true
end

-- Replace the whole animation. `kf` is a list of {time, off, rot, curve} like
-- M.keyframes above. Rebuilds against the current spawn pose immediately.
function M.setKeyframes(kf)
  if type(kf) ~= "table" then return false end
  local normalized = normalizeKeyframes(kf)
  if #normalized == 0 then
    dbg("setKeyframes: empty keyframe list ignored")
    return false
  end
  loadedKeyframes = nil   -- user set keyframes explicitly, clear Blender data
  bakedCount      = 0     -- not baked anymore
  M.keyframes = normalized
  frames = buildFrames()
  dbg(string.format("setKeyframes: %d frames", #M.keyframes))
  return true
end

-- Set the easing curve of one keyframe by index (1-based).
-- curve is a string ("linear"/"easeIn"/"easeOut"/"easeInOut") or a bezier table.
function M.setKeyframeCurve(index, curve)
  local k = M.keyframes[index]
  if not k then dbg("setKeyframeCurve: bad index " .. tostring(index)); return false end
  loadedKeyframes = nil
  k.curve = curve
  frames = buildFrames()
  dbg(string.format("setKeyframeCurve[%d] = %s", index, tostring(curve)))
  return true
end

-- Set the standalone RELEASE TIME (seconds from start) where physics takes over,
-- mid-motion, carrying the car's momentum. Pass nil to disable (hold-at-end instead).
-- See the "RELEASE MARKER" block near the keyframes for the how/why and the KEY RULE.
function M.setReleaseTime(t)
  M.releaseTime = t ~= nil and tonumber(t) or nil   -- number or nil
  dbg(string.format("setReleaseTime = %s", tostring(t)))
  return true
end

-- Jump the animation to a specific time (for playhead scrubbing in the UI).
-- The car will move to the pose at that time on the next onUpdate frame.
-- Clamped to 0 so negative values don't break the sampler.
function M.setElapsedTime(t)
  elapsed = math.max(0, tonumber(t) or 0)
  return elapsed
end

-- Activate or deactivate the engine without resetting any state.
-- Used by the UI scrubber to wake up onUpdate when stopped.
function M.setActive(state)
  active = state == true
  return active
end

-- Load (or RE-load) animation_data.lua exported from Blender, ON DEMAND.
-- This is what the UI "Load" button calls. It clears the require cache first so a
-- freshly re-exported file is picked up WITHOUT a full extension reload, then stores
-- the absolute Blender keyframes in loadedKeyframes. The next M.play() offsets them to
-- the car's current position (see the `not started` block in onUpdate). Handles both
-- exporter modes: "keyframe" (with easing) and "baked" (dense per-frame → linear).
-- Returns a UI-friendly result table. Call M.play() after this to run the animation.
function M.loadAnimationData()
  loadedKeyframes = nil
  -- Drop the cached module so a re-exported animation_data.lua is re-read from disk.
  package.loaded["telekinesis.animation_data"] = nil

  local okAD, animData = pcall(require, "telekinesis.animation_data")
  if not okAD or type(animData) ~= "table" then
    dbg("loadAnimationData: telekinesis.animation_data not found / not a table")
    return { ok = false, count = 0, error = "animation_data.lua not found or invalid" }
  end

  if animData.mode == "keyframe" and type(animData.keyframes) == "table" and #animData.keyframes > 0 then
    loadedKeyframes = animData.keyframes
    if animData.releaseTime ~= nil then M.releaseTime = animData.releaseTime end
    dbg(string.format("loadAnimationData: %d keyframes (keyframe mode), releaseTime=%s",
      #loadedKeyframes, tostring(M.releaseTime)))
  elseif animData.mode == "baked" and type(animData.frames) == "table" and #animData.frames > 0 then
    loadedKeyframes = {}
    for _, f in ipairs(animData.frames) do
      table.insert(loadedKeyframes, { time = f.time, pos = f.pos, rot = f.rot, curve = "linear" })
    end
    if animData.releaseTime ~= nil then M.releaseTime = animData.releaseTime end
    dbg(string.format("loadAnimationData: %d baked frames at %d FPS (→linear), releaseTime=%s",
      #loadedKeyframes, animData.fps or 0, tostring(M.releaseTime)))
  else
    dbg("loadAnimationData: animation_data.lua has no usable keyframes/frames")
    return { ok = false, count = 0, error = "animation_data.lua has no keyframes/frames" }
  end

  -- TRACK the baked frame count for the UI summary.
  local isBaked = animData.mode == "baked"
  bakedCount = isBaked and #loadedKeyframes or 0

  -- MIRROR the loaded animation into M.keyframes so the UI keyframe TABLE shows every
  -- loaded keyframe (all 33, or however many). loadedKeyframes hold ABSOLUTE Blender pos+quat;
  -- the table wants RELATIVE {off, rot={axis,deg}, curve}. We express each relative to the FIRST
  -- loaded keyframe (its own origin), exactly matching how onUpdate offsets them for playback:
  --   off  = kf.pos - origin.pos            (world offset)
  --   rot  = axisDeg( kf.rot * origin.rot⁻¹ ) (world delta, then simplified to one axis for the table)
  -- IMPORTANT: we do NOT clear loadedKeyframes here — PLAYBACK still uses the full quaternion
  -- world-space path (see onUpdate `not started`). This M.keyframes copy is DISPLAY-ONLY, so the
  -- table's single-axis rotation is a lossy view of any tilted spin. The full rotation is
  -- preserved and played correctly. (Only if the user edits a row + Apply does the simplified
  -- table value take over — at that point setKeyframes() clears loadedKeyframes by design.)
  --
  -- BAKED MODE: skip the mirror — 1549 rows would lag the UI. M.keyframes stays as a short
  -- placeholder pair (first+last). The user can toggle "Show all frames" via the UI button
  -- which calls toggleShowBakedFrames() to populate M.keyframes on demand.
  do
    local originPos = loadedKeyframes[1].pos
    local originRot = loadedKeyframes[1].rot
    local invOrigin = qinv(originRot)
    local uiKf = {}
    if isBaked and #loadedKeyframes > 100 then
      -- Only keep first + last as a lightweight summary
      for _, idx in ipairs({1, #loadedKeyframes}) do
        local kf = loadedKeyframes[idx]
        local axisName, deg = quatToAxisDeg(qmul(kf.rot, invOrigin))
        uiKf[#uiKf + 1] = {
          time = kf.time,
          off  = v3(kf.pos.x - originPos.x, kf.pos.y - originPos.y, kf.pos.z - originPos.z),
          rot  = { axis = axisName, deg = deg },
          curve = "linear",
        }
      end
    else
      for i, kf in ipairs(loadedKeyframes) do
        local axisName, deg = quatToAxisDeg(qmul(kf.rot, invOrigin))
        uiKf[i] = {
          time = kf.time,
          off  = v3(kf.pos.x - originPos.x, kf.pos.y - originPos.y, kf.pos.z - originPos.z),
          rot  = { axis = axisName, deg = deg },
          curve = copyCurve(kf.curve),
        }
      end
    end
    M.keyframes = uiKf
  end

  -- Force the next update to rebuild absolute frames against the car's live pose.
  started = false
  frames  = nil
  return {
    ok = true,
    count = #loadedKeyframes,
    mode = animData.mode,
    releaseTime = M.releaseTime,
    state = M.getUiState(),
  }
end

-- Populate M.keyframes from loadedKeyframes (full mirror). Used by the
-- UI "Show all frames" toggle for baked animations. Returns getUiState().
function M.toggleShowBakedFrames(show)
  show = show == true
  if show and loadedKeyframes and #loadedKeyframes > 0 then
    local originPos = loadedKeyframes[1].pos
    local originRot = loadedKeyframes[1].rot
    local invOrigin = qinv(originRot)
    local uiKf = {}
    for i, kf in ipairs(loadedKeyframes) do
      local axisName, deg = quatToAxisDeg(qmul(kf.rot, invOrigin))
      uiKf[i] = {
        time = kf.time,
        off  = v3(kf.pos.x - originPos.x, kf.pos.y - originPos.y, kf.pos.z - originPos.z),
        rot  = { axis = axisName, deg = deg },
        curve = copyCurve(kf.curve),
      }
    end
    M.keyframes = uiKf
  elseif not show then
    -- Collapse back to first+last summary.
    local originPos = loadedKeyframes[1].pos
    local originRot = loadedKeyframes[1].rot
    local invOrigin = qinv(originRot)
    local uiKf = {}
    for _, idx in ipairs({1, #loadedKeyframes}) do
      local kf = loadedKeyframes[idx]
      local axisName, deg = quatToAxisDeg(qmul(kf.rot, invOrigin))
      uiKf[#uiKf + 1] = {
        time = kf.time,
        off  = v3(kf.pos.x - originPos.x, kf.pos.y - originPos.y, kf.pos.z - originPos.z),
        rot  = { axis = axisName, deg = deg },
        curve = "linear",
      }
    end
    M.keyframes = uiKf
  end
  return M.getUiState()
end

function M.getUiState()
  return {
    version = 1,
    keyframes = plainKeyframes(),
    settings = tableCopy(M.settings),
    releaseEnabled = M.releaseTime ~= nil,
    releaseTime = M.releaseTime,
    saveFile = SAVE_FILE,
    active = active,
    elapsed = elapsed,
    isBaked = bakedCount > 0,
    bakedCount = bakedCount,
  }
end

function M.applyUiState(state)
  if type(state) ~= "table" then return false end
  if type(state.settings) == "table" then M.setSettings(state.settings) end
  if state.releaseEnabled == false or state.releaseTime == "" or state.releaseTime == false then
    M.setReleaseTime(nil)
  elseif state.releaseTime ~= nil then
    M.setReleaseTime(state.releaseTime)
  end
  if type(state.keyframes) == "table" then M.setKeyframes(state.keyframes) end
  return M.getUiState()
end

function M.savePreset()
  ensureSaveDir()
  local ok = jsonWriteFile(SAVE_FILE, M.getUiState(), true)
  local exists = FS and FS:fileExists(SAVE_FILE)
  dbg(string.format("savePreset %s -> %s", SAVE_FILE, tostring(ok)))
  return { ok = ok ~= false and (exists or ok == true or ok == 0), file = SAVE_FILE, state = M.getUiState() }
end

function M.loadPreset()
  if FS and not FS:fileExists(SAVE_FILE) then
    dbg("loadPreset: no saved preset at " .. SAVE_FILE)
    return { ok = false, missing = true, file = SAVE_FILE, state = M.getUiState() }
  end

  local data = jsonReadFile(SAVE_FILE)
  if type(data) ~= "table" then
    dbg("loadPreset: failed to read " .. SAVE_FILE)
    return { ok = false, file = SAVE_FILE, state = M.getUiState() }
  end

  local state = M.applyUiState(data)
  dbg("loadPreset " .. SAVE_FILE)
  return { ok = true, file = SAVE_FILE, state = state }
end

function M.resetDefaults()
  M.settings = {
    KP_POS        = 6.0,
    KD_POS        = 7.0,
    KP_ROT        = 8.0,
    KD_ROT        = 6.0,
    ANGVEL_SMOOTH = 0.25,
    ROT_DEADBAND  = 0.010,
    MAX_ANG_ACCEL = 8.0,
    GRAVITY       = 9.81,
    GRAVITY_RAMP  = 0.5,
    MAX_ACCEL     = 30.0,
    FF_DT         = 0.02,
    HOLD_AT_END   = true,
    END_HOLD_TIME = 1.5,
    DEBUG         = true,
    DEBUG_EVERY   = 0.25,
  }
  M.keyframes = normalizeKeyframes({
    { time = 0.0,  off = {x = 0,  y = 0, z = 0}, rot = {axis = "z", deg = 0}, curve = "easeInOut" },
    { time = 10.0, off = {x = 0,  y = 0, z = 8}, rot = {axis = "z", deg = 0}, curve = "easeInOut" },
    { time = 12.0, off = {x = -6, y = 6, z = 8}, rot = {axis = "z", deg = 0}, curve = "easeInOut" },
    { time = 15.0, off = {x = -6, y = 6, z = 8}, rot = {axis = "z", deg = 0}, curve = "easeIn" },
  })
  loadedKeyframes = nil
  bakedCount      = 0
  M.releaseTime = 11.0
  frames = buildFrames()
  dbg("resetDefaults")
  return M.getUiState()
end

-- Start (or restart) the animation from the beginning.
function M.play()
  active      = true
  started     = false   -- forces spawn-pose re-capture + frame rebuild next update
  elapsed     = 0.0
  endTimer    = 0.0
  angVelFilt  = nil     -- reset the angular-velocity filter
  released    = false   -- allow the release marker to fire again this run
  dbg("play")
end

-- Stop immediately and release the car to normal physics.
function M.stop()
  active = false
  local ok, veh = pcall(function() return getPlayerVehicle(0) end)
  if ok then releaseCar(veh) end
  dbg("stop")
end

-- ---------------------------------------------------------------------------
--  LIFECYCLE HOOKS
-- ---------------------------------------------------------------------------
function M.onExtensionLoaded()
  print("BSKC: extension loaded")
  active     = true
  elapsed    = 0.0
  lastPos    = nil
  lastRot    = nil
  started    = false
  frames     = nil
  spawnPos   = nil
  spawnRot   = nil
  endTimer   = 0.0
  debugAccum = 0.0
  angVelFilt = nil
  released   = false
  bakedCount = 0
  if FS and FS:fileExists(SAVE_FILE) then
    M.loadPreset()
  end

  -- Load animation_data.lua exported from Blender (if present). Stored in
  -- loadedKeyframes as absolute pos+quat; the first onUpdate offsets them relative to
  -- the car's current position (so the animation follows the car, not absolute Blender
  -- coordinates). Same code path the UI "Load" button uses (M.loadAnimationData).
  M.loadAnimationData()

  dbg(string.format("loaded. %d keyframes over %.1fs, releaseTime=%s (easing + feed-forward)",
    #M.keyframes, M.keyframes[#M.keyframes].time, tostring(M.releaseTime)))
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not active then return end

  local veh = getPlayerVehicle(0)
  if not veh then return end
  local pos = veh:getPosition()
  if not pos then return end
  local rot = getCarRot(veh)
  local s = M.settings

  elapsed    = elapsed + (dtSim or 0)
  debugAccum = debugAccum + (dtSim or 0)

  -- First frame after play/load: capture spawn pose and build the timeline.
  -- If animation_data.lua is loaded, offset its absolute keyframes so the
  -- animation plays relative to the car's current position (like buildFrames
  -- does for inline keyframes, but in reverse: absolute → relative → re-absolute).
  if not started then
    started  = true
    spawnPos = v3(pos.x, pos.y, pos.z)
    spawnRot = qnorm(rot)
    if loadedKeyframes then
      local originPos = loadedKeyframes[1].pos
      local originRot = loadedKeyframes[1].rot
      local invOrigin = qinv(originRot)
      frames = {}
      for i, kf in ipairs(loadedKeyframes) do
        -- ROTATION: (kf.rot * origin^-1) is the WORLD-space rotation the Blender object
        -- underwent (from its first keyframe to this one). Because position already maps
        -- Blender world axes 1:1 onto BeamNG world axes (proven by position matching), we
        -- must apply that delta in WORLD space too -> LEFT-multiply onto spawnRot:
        --     target = (kf.rot * origin^-1) * spawnRot
        -- At i=1 this is identity*spawnRot = spawnRot (no orientation jump), and every later
        -- frame reproduces the exact same world spin the animation had.
        -- (The earlier `spawnRot * (kf.rot*origin^-1)` RIGHT-multiplied it as a LOCAL delta,
        --  which conjugated the world spin by the car's spawn yaw -> the reversed rotation.)
        -- NOTE: this differs from buildFrames() on purpose. There the delta is authored in the
        -- car's OWN frame ("rotate about the car's z"), so local `spawnRot * delta` is right.
        frames[i] = {
          time  = kf.time,
          pos   = v3(spawnPos.x + kf.pos.x - originPos.x,
                     spawnPos.y + kf.pos.y - originPos.y,
                     spawnPos.z + kf.pos.z - originPos.z),
          rot   = qmul(qmul(kf.rot, invOrigin), spawnRot),
          curve = kf.curve or "linear",
        }
      end
      dbg(string.format("offset %d loaded keyframes to car pos (origin=(%.2f,%.2f,%.2f))",
        #frames, originPos.x, originPos.y, originPos.z))
    else
      frames = buildFrames()
      dbg(string.format("captured spawn pose, built %d frames", #frames))
    end
    lastPos  = v3(pos.x, pos.y, pos.z)
    lastRot  = qnorm(rot)
  end

  -- Measure current linear + angular velocity (for the damping terms).
  local vel = v3(0, 0, 0)
  if lastPos and dtSim and dtSim > 0 then
    vel = v3((pos.x-lastPos.x)/dtSim, (pos.y-lastPos.y)/dtSim, (pos.z-lastPos.z)/dtSim)
  end
  local angVelRaw = angVelFrom(lastRot, rot, dtSim)
  lastPos = v3(pos.x, pos.y, pos.z)
  lastRot = qnorm(rot)

  -- Low-pass filter the angular velocity. The raw value is a finite-difference of a
  -- soft-body-derived orientation, so it is NOISY; feeding that straight into the
  -- damping term (KD_ROT * angVel) amplified the noise into a visible swing. Smoothing
  -- it first is the actual fix - now damping fights real rotation, not measurement jitter.
  local a = clamp(s.ANGVEL_SMOOTH or 0.25, 0.01, 1.0)
  if not angVelFilt then
    angVelFilt = angVelRaw
  else
    angVelFilt = v3(
      angVelFilt.x + (angVelRaw.x - angVelFilt.x) * a,
      angVelFilt.y + (angVelRaw.y - angVelFilt.y) * a,
      angVelFilt.z + (angVelRaw.z - angVelFilt.z) * a)
  end
  local angVel = angVelFilt

  -- 1) TARGET now (eased interpolation happens inside timeline.sample).
  local targetPos, targetRot, done = timeline.sample(frames, elapsed)
  targetRot = qnorm(targetRot)

  -- 1b) FEED-FORWARD: sample a hair into the future to learn the target's own
  --     linear & angular velocity. Past the end the sampler clamps, so these
  --     fall to ~0 - which (with easeOut) means a smooth, bounce-free stop.
  local futPos, futRot = timeline.sample(frames, elapsed + s.FF_DT)
  futRot = qnorm(futRot)
  local ffVel = v3((futPos.x - targetPos.x)/s.FF_DT,
                   (futPos.y - targetPos.y)/s.FF_DT,
                   (futPos.z - targetPos.z)/s.FF_DT)
  local ffAngRV = qToRotVec(qmul(futRot, qinv(targetRot)))
  local ffAng = v3(ffAngRV.x/s.FF_DT, ffAngRV.y/s.FF_DT, ffAngRV.z/s.FF_DT)

  -- 2) CONTROLLER = PD (correct error) + feed-forward (match target's motion).
  -- Anti-gravity RAMP: ease the +GRAVITY thrust from 0 to full over GRAVITY_RAMP seconds so
  -- the compressed suspension unloads gradually instead of snapping the body up on frame 1
  -- (the "spring pop"). After the ramp window gravFactor = 1 and behaviour is unchanged.
  local gravRamp = s.GRAVITY_RAMP or 0
  local gravFactor = 1.0
  if gravRamp > 1e-6 then gravFactor = clamp(elapsed / gravRamp, 0, 1) end
  local gravNow = s.GRAVITY * gravFactor

  local ex, ey, ez = targetPos.x - pos.x, targetPos.y - pos.y, targetPos.z - pos.z
  local ax = clamp(ex * s.KP_POS - (vel.x - ffVel.x) * s.KD_POS,            -s.MAX_ACCEL, s.MAX_ACCEL)
  local ay = clamp(ey * s.KP_POS - (vel.y - ffVel.y) * s.KD_POS,            -s.MAX_ACCEL, s.MAX_ACCEL)
  local az = clamp(ez * s.KP_POS - (vel.z - ffVel.z) * s.KD_POS + gravNow,  -s.MAX_ACCEL, s.MAX_ACCEL)

  local rotErr = qToRotVec(qmul(targetRot, qinv(rot)))
  -- Deadband: if the car is already within ROT_DEADBAND of the target angle, treat the
  -- error as zero. This stops the spring from endlessly chasing sub-degree soft-body
  -- jitter (which is what kept re-exciting the swing) while still correcting real tilt.
  local db = s.ROT_DEADBAND or 0.0
  if vlen(rotErr) < db then rotErr = v3(0, 0, 0) end
  local ang = v3(rotErr.x * s.KP_ROT - (angVel.x - ffAng.x) * s.KD_ROT,
                 rotErr.y * s.KP_ROT - (angVel.y - ffAng.y) * s.KD_ROT,
                 rotErr.z * s.KP_ROT - (angVel.z - ffAng.z) * s.KD_ROT)
  local am = vlen(ang)
  if am > s.MAX_ANG_ACCEL and am > 1e-9 then
    local sc = s.MAX_ANG_ACCEL / am
    ang = v3(ang.x*sc, ang.y*sc, ang.z*sc)
  end

  -- 3) PUSH
  pushAccel(veh, v3(ax, ay, az), ang, dtSim)

  -- End handling.
  -- (a) RELEASE MARKER (Blender "Animated"-off trick): M.releaseTime is a standalone
  --     time on the timeline. The instant we reach it we STOP pushing and hand the car
  --     back to soft-body physics - even mid-animation. If the marker sits BEFORE the
  --     motion finishes, the car is still moving fast, so it keeps that momentum and
  --     flies on/arcs/drops/rolls instead of dead-dropping from a standstill.
  --     releaseCar() never zeroes velocity - it just stops adding accel - so whatever
  --     speed the controller built up carries straight into physics.
  if M.releaseTime ~= nil and not released and elapsed >= M.releaseTime then
    released = true
    active   = false
    releaseCar(veh)
    dbg(string.format("release marker reached at t=%.2f (releaseTime=%.2f) - car handed to physics with momentum",
      elapsed, M.releaseTime))
    return
  end

  -- (b) NORMAL END: no release keyframe -> when the timeline finishes, optionally hold
  --     the final pose for END_HOLD_TIME, then release.
  if done then
    if not s.HOLD_AT_END then
      active = false; releaseCar(veh); dbg("timeline done - released car"); return
    end
    endTimer = endTimer + (dtSim or 0)
    if endTimer >= s.END_HOLD_TIME then
      active = false; releaseCar(veh)
      dbg(string.format("timeline done + held %.1fs - released car", endTimer))
      return
    end
  end

  if debugAccum >= s.DEBUG_EVERY then
    debugAccum = 0.0
    dbg(string.format(
      "t=%.2f  z=%.2f  posErr=(%.3f, %.3f, %.3f)  angErr=(%.3f, %.3f, %.3f)  angVelRaw=(%.3f, %.3f, %.3f)  angVelFilt=(%.3f, %.3f, %.3f)  angCmd=(%.3f, %.3f, %.3f)  done=%s",
      elapsed, pos.z, ex, ey, ez, rotErr.x, rotErr.y, rotErr.z,
      angVelRaw.x, angVelRaw.y, angVelRaw.z, angVel.x, angVel.y, angVel.z,
      ang.x, ang.y, ang.z, tostring(done)))
  end
end

function M.onExtensionUnloaded()
  active = false
  local ok, veh = pcall(function() return getPlayerVehicle(0) end)
  if ok then releaseCar(veh) end
  dbg("unloaded")
end

return M
