extends RefCounted

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

static func apply_default_character(player: PlayerController) -> bool:
	if player == null:
		return false
	var catalog = ContentCatalogsScript.characters()
	if catalog == null:
		return false
	var definition = catalog.get_by_id(catalog.default_id())
	if definition == null or definition.model_scene == null:
		return false
	player.apply_character_definition(definition)
	return true
