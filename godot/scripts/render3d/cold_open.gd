class_name ColdOpen
extends Node
## The cold open's 3D half (IntroScreen holds the narration, the words and the clock). Act I itself: the run's
## own WorldView3D bound to a world that never steps, its camera flown along SWEEP down out of the sky over
## Mossglen Hollow while a Rift Shard streaks in through the torn Veil and strikes (FX3D.shard) beside the
## spot where the exile will stand. At the end the camera glides on down into the shard's glow as IntroScreen
## fades to black, and main hands over to the title stage (MenuStage3D).
##
## u runs 0..1 over the narration (the sum of the four beats IntroScreen measured). The shard appears at
## SHARD_AT and strikes at SHARD_HIT; the exile appears at HERO_AT. Heights are kept HOVER over the hills.

const SWEEP := [Vector3(-1150, 640, 940), Vector3(-520, 420, 560), Vector3(40, 300, 420), Vector3(230, 210, 300)]
const LOOK := [Vector3(-200, 0, -260), Vector3(60, 0, -120), Vector3(200, 20, -140), Vector3(210, 30, -150)]
const IMPACT := Vector2(230, -170)
const SHARD_FROM := Vector3(-80, 1400, -900)     # above and beyond the strike, in front of the descending camera
const SHARD_AT := 0.1
const SHARD_HIT := 0.34
const HERO_AT := 0.7
const HOVER := 140.0
const GLIDE := Vector3(0, -150, -220)   # the last push, down toward the glow

var view: WorldView3D
var world: World
var u := 0.0
var struck := false
var _launched := false
var _shake := 0.0
var _total := 12.0

## Builds the Act I world (seeded, headless: it writes no profile) and takes over `v`'s camera.
func begin(v: WorldView3D, hero: int, total_s: float) -> void:
	world = World.new()
	world.setup({"mode": "campaign", "stage": 0, "hero": hero, "seed": 7, "headless": true, "season": ""})
	_total = maxf(1.0, total_s)
	view = v
	view.cine = true
	view.hide_hero = true
	view.bind(world)
	view.cam.make_current()
	if not view.fx.shard_struck.is_connected(_on_struck): view.fx.shard_struck.connect(_on_struck)
	_pose(0.0, 0.0)

## One frame at narration progress k (0..1); glide (0..1) is the hand-over push after the last beat.
func step(dt: float, k: float, glide: float = 0.0) -> void:
	if world == null: return
	u = clampf(k, 0.0, 1.0)
	world._step_feed(dt)                       # the shard's shockwave ring ages, though the world never steps
	if not _launched and u >= SHARD_AT:
		_launched = true
		var g: float = world.terrain.height(IMPACT)
		view.fx.shard(SHARD_FROM, Vector3(IMPACT.x, g, IMPACT.y), maxf(0.4, (SHARD_HIT - SHARD_AT) * _total))
	if u >= HERO_AT: view.hide_hero = false
	_shake = maxf(0.0, _shake - dt * 1.6)
	_pose(u, glide)

func _on_struck(_at: Vector3) -> void:
	struck = true
	_shake = 1.0

## Catmull-Rom through four points (t in 0..1 across the whole path).
static func _spline(pts: Array, t: float) -> Vector3:
	var n := pts.size() - 1
	var f := clampf(t, 0.0, 1.0) * n
	var i := mini(int(f), n - 1)
	var s := f - i
	var p0: Vector3 = pts[maxi(0, i - 1)]
	var p1: Vector3 = pts[i]
	var p2: Vector3 = pts[i + 1]
	var p3: Vector3 = pts[mini(n, i + 2)]
	return 0.5 * (2.0 * p1 + (p2 - p0) * s + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * s * s + (3.0 * p1 - p0 - 3.0 * p2 + p3) * s * s * s)

func _pose(k: float, glide: float) -> void:
	var e := k * k * (3.0 - 2.0 * k)              # ease in and out along the path
	var pos := _spline(SWEEP, e)
	var look := _spline(LOOK, e)
	var gl := glide * glide
	pos += GLIDE * gl
	var gy: float = world.terrain.height(Vector2(pos.x, pos.z))
	pos.y = maxf(pos.y, gy + HOVER * (1.0 - 0.5 * gl))
	look.y += world.terrain.height(Vector2(look.x, look.z))
	var sh := _shake * _shake * 22.0
	var t := Time.get_ticks_msec() / 1000.0
	view.cine_pos = pos + Vector3(sin(t * 53.0), sin(t * 41.0) * 0.6, cos(t * 47.0)) * sh
	view.cine_look = look

## The app closing mid-intro (or main freeing it) still frees the world: its systems point back at it.
func _exit_tree() -> void:
	end()

## Hands the renderer back (no world bound: it draws nothing until a run binds one) and frees the world.
func end() -> void:
	if view != null and is_instance_valid(view):
		if view.fx.shard_struck.is_connected(_on_struck): view.fx.shard_struck.disconnect(_on_struck)
		view.fx.clear_shards()
		view.cine = false
		view.hide_hero = false
		view.w = null
		view.fx.w = null
	view = null
	if world != null: world.dispose()
	world = null
