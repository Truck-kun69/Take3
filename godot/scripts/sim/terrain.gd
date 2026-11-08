class_name Terrain
extends RefCounted
## World terrain (placeholder: flat). Filled in by the elevation pass.

func height(_p: Vector2) -> float:
	return 0.0

func prop_ok(_kind: String, _p: Vector2) -> bool:
	return true

func density(_kind: String, _chunk: Vector2i) -> float:
	return 1.0
