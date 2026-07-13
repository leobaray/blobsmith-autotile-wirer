@tool
extends EditorPlugin

const MENU_LABEL := "Blobsmith Autotile Wirer..."
var _dialog: AcceptDialog
var _file_dialog: EditorFileDialog
var _path_edit: LineEdit
var _tile_size: SpinBox
var _mode: OptionButton
var _collision: CheckBox
var _terrain_name: LineEdit
var _status: Label


func _enter_tree() -> void:
	add_tool_menu_item(MENU_LABEL, _open_dialog)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_LABEL)
	if _dialog:
		_dialog.queue_free()


func _open_dialog() -> void:
	if _dialog == null:
		_build_dialog()
	_dialog.popup_centered(Vector2i(460, 0))


func _build_dialog() -> void:
	_dialog = AcceptDialog.new()
	_dialog.title = "Blobsmith Autotile Wirer"
	_dialog.ok_button_text = "Generate TileSet"
	_dialog.confirmed.connect(_generate)

	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = 430

	var intro := Label.new()
	intro.text = "Pick a 47-blob (8×6 tiles) or 16-tile (8×2) sheet in\nBlobsmith layout. Output: a wired .tres next to the PNG."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(intro)

	var row := HBoxContainer.new()
	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "res://path/to/tilesheet.png"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_path_edit)
	var browse := Button.new()
	browse.text = "Browse"
	browse.pressed.connect(_browse)
	row.add_child(browse)
	vb.add_child(row)

	var grid := GridContainer.new()
	grid.columns = 2

	grid.add_child(_label("Tile size (px)"))
	_tile_size = SpinBox.new()
	_tile_size.min_value = 2
	_tile_size.max_value = 256
	_tile_size.value = 16
	grid.add_child(_tile_size)

	grid.add_child(_label("Mode"))
	_mode = OptionButton.new()
	_mode.add_item("47-tile blob (corners + sides)", 0)
	_mode.add_item("16-tile (sides only)", 1)
	grid.add_child(_mode)

	grid.add_child(_label("Terrain name"))
	_terrain_name = LineEdit.new()
	_terrain_name.text = "Terrain"
	grid.add_child(_terrain_name)

	grid.add_child(_label("Collision"))
	_collision = CheckBox.new()
	_collision.text = "Full-square shapes (physics layer 0)"
	_collision.button_pressed = true
	grid.add_child(_collision)

	vb.add_child(grid)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)

	var promo := LinkButton.new()
	promo.text = "Need the sheet itself? Blobsmith draws it from 6 base tiles →"
	promo.uri = "https://blobsmith.itch.io/blobsmith"
	vb.add_child(promo)

	_dialog.add_child(vb)
	EditorInterface.get_base_control().add_child(_dialog)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _browse() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_file_dialog.add_filter("*.png", "PNG tilesheet")
		_file_dialog.file_selected.connect(_on_file)
		EditorInterface.get_base_control().add_child(_file_dialog)
	_file_dialog.popup_file_dialog()


func _on_file(path: String) -> void:
	_path_edit.text = path
	var tex: Texture2D = load(path)
	if tex:
		var layout := BlobsmithWirerCore.detect_layout(tex.get_width(), tex.get_height())
		if layout.is_empty():
			_status.text = "⚠ %d×%d doesn't match a Blobsmith layout (8×6 or 8×2 tiles) — set tile size manually." % [tex.get_width(), tex.get_height()]
		else:
			_tile_size.value = layout.tile_size
			_mode.selected = 1 if layout.sides_only else 0
			_status.text = "Detected: %dpx tiles, %s." % [layout.tile_size, "16 sides-only" if layout.sides_only else "47-blob"]


func _generate() -> void:
	var path := _path_edit.text.strip_edges()
	if path == "":
		_status.text = "⚠ Pick a tilesheet first."
		_dialog.popup_centered(Vector2i(460, 0))
		return
	var out := BlobsmithWirerCore.wire_and_save(path, int(_tile_size.value),
		_mode.selected == 1, _collision.button_pressed, _terrain_name.text)
	if out == "":
		_status.text = "⚠ Failed — see Output panel."
		_dialog.popup_centered(Vector2i(460, 0))
		return
	EditorInterface.get_resource_filesystem().scan()
	_status.text = "✅ Saved %s\nAdd a TileMapLayer → set its TileSet → paint in the Terrains tab." % out
	_dialog.popup_centered(Vector2i(460, 0))
