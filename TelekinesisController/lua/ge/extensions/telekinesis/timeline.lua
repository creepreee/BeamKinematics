local M = {}
local curves = require("telekinesis.curves")

-- Helper: Spherical Linear Interpolation (SLERP) - the ONLY way to smoothly rotate.
local function slerp(q1, q2, t)
  -- Clamp t just in case
  t = math.max(0, math.min(1, t))

  -- Calculate the angle between the quaternions
  local dot = q1.x*q2.x + q1.y*q2.y + q1.z*q2.z + q1.w*q2.w

  -- If the dot product is negative, slerp won't take the short path, so we flip one.
  local q2Adj = q2
  if dot < 0 then
    dot = -dot
    q2Adj = quat(-q2.x, -q2.y, -q2.z, -q2.w)
  end

  -- If they are very close, just linear interpolate to avoid division by zero
  if dot > 0.9995 then
    return quat(
      q1.x + (q2Adj.x - q1.x) * t,
      q1.y + (q2Adj.y - q1.y) * t,
      q1.z + (q2Adj.z - q1.z) * t,
      q1.w + (q2Adj.w - q1.w) * t
    ):normalized()
  end

  local angle = math.acos(dot)
  local sinAngle = math.sin(angle)
  local invSin = 1.0 / sinAngle
  local a = math.sin((1 - t) * angle) * invSin
  local b = math.sin(t * angle) * invSin

  return quat(
    a * q1.x + b * q2Adj.x,
    a * q1.y + b * q2Adj.y,
    a * q1.z + b * q2Adj.z,
    a * q1.w + b * q2Adj.w
  ):normalized()
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function getSegmentCurve(k1, k2)
  if type(k1.curve) == "table" then
    return k1.curve
  end

  if type(k2.curve) == "table" then
    return k2.curve
  end

  if type(k1.curve) == "string" then
    return k1.curve
  end

  if type(k2.curve) == "string" then
    return k2.curve
  end

  if k1.outHandle or k2.inHandle then
    return {
      type = "bezier",
      p1 = k1.outHandle,
      p2 = k2.inHandle
    }
  end

  if k1.easing then
    return k1.easing
  end

  if k2.easing then
    return k2.easing
  end

  return "linear"
end

-- The New Sample Function (Returns Pos AND Rot)
function M.sample(keyframes, time)
  if not keyframes or #keyframes == 0 then
    return vec3(0, 0, 0), quat(0, 0, 0, 1), true
  end

  if time <= keyframes[1].time then
    return keyframes[1].pos, keyframes[1].rot, false
  end

  if time >= keyframes[#keyframes].time then
    local last = keyframes[#keyframes]
    return last.pos, last.rot, true
  end

  local k1, k2
  for i = 1, #keyframes - 1 do
    if time >= keyframes[i].time and time <= keyframes[i+1].time then
      k1, k2 = keyframes[i], keyframes[i+1]
      break
    end
  end

  if not k1 then
    local last = keyframes[#keyframes]
    return last.pos, last.rot, true
  end

  local localT = (time - k1.time) / (k2.time - k1.time)
  local curveSpec = getSegmentCurve(k1, k2)
  local t = curves.evaluate(localT, curveSpec)

  -- Position: Simple lerp
  local pos = vec3(
    lerp(k1.pos.x, k2.pos.x, t),
    lerp(k1.pos.y, k2.pos.y, t),
    lerp(k1.pos.z, k2.pos.z, t)
  )

  -- Rotation: SLERP
  local rot = slerp(k1.rot, k2.rot, t)

  return pos, rot, false
end

return M