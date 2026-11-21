class_name FixedStep
extends RefCounted
## Fixed-rate simulation clock. Render frames feed real time in; the simulation advances only in
## whole STEP-long ticks, so every timer, cooldown and damage-over-time sees the same dt on every
## device and at every frame rate.
##   - At most MAX_STEPS ticks per frame. A frame slower than that drops the backlog: the game runs
##     slower for that moment instead of spending ever longer catching up (the "spiral of death").
##   - Jitter snap: a frame within SNAP of a whole number of ticks is rounded to it, so a 60 Hz
##     display gets exactly one tick per frame instead of an occasional 0 followed by 2.

const HZ := 60.0
const STEP := 1.0 / HZ
const MAX_STEPS := 2
const SNAP := 0.15 * STEP

var acc := 0.0
var dropped := 0.0               # simulated seconds skipped because frames ran long (diagnostics)

## Adds one frame of real time; returns how many STEP ticks to run now.
func advance(dt: float) -> int:
	acc += maxf(0.0, dt)
	var steps := floori((acc + SNAP) / STEP)
	if steps > MAX_STEPS:
		dropped += acc - MAX_STEPS * STEP
		steps = MAX_STEPS
		acc = 0.0
	else:
		acc -= steps * STEP          # may be slightly negative after a snap up; the next frame repays it
	return steps

## Fraction of a tick left over (0..1), for anything drawn between ticks.
func alpha() -> float:
	return clampf(acc / STEP, 0.0, 1.0)

func reset() -> void:
	acc = 0.0
