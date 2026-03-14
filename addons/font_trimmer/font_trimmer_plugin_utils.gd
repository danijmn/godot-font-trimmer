## Implements utility functions used internally by the Font Trimmer plugin.
@tool
extends EditorExportPlugin


## Similar to [ProjectSettings.get_setting_with_override_and_custom_features], but
## allows specifying a default value if the setting is missing.
static func get_setting_with_custom_features_or_default(
 name: StringName, features: PackedStringArray, default: Variant) -> Variant:
	var value: Variant = ProjectSettings.get_setting_with_override_and_custom_features(name, features)
	return value if value != null else default


## Get a dictionary mapping the names of the subdirectories (of directory [path]) to
## their respective sizes in bytes, including hidden entries.
## Key "." will be mapped to the total size of directory [path].
## [path] can be local or absolute. If the directory is missing, returns {".": 0}.
static func get_dir_size(path: String) -> Dictionary[String, int]:
	var result: Dictionary[String, int] = {}
	var total_size: int = 0
	
	var dir: DirAccess = DirAccess.open(path)
	if dir != null:
		dir.include_hidden = true
		dir.include_navigational = false

		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while !file_name.is_empty():
			var next_path: String = path.path_join(file_name)
			if dir.current_is_dir():
				var subdir_total_size: int = get_dir_size(next_path)["."]
				total_size += subdir_total_size
				result[file_name] = subdir_total_size
			else:
				total_size += FileAccess.get_size(next_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()

	result["."] = total_size
	return result


## Recursively removes all the files and directories within directory [absolute_path],
## then removes the directory itself.
static func remove_dir_recursive(absolute_path: String) -> void:
	var dir: DirAccess = DirAccess.open(absolute_path)
	if dir != null:
		dir.include_hidden = true
		dir.include_navigational = false

		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while !file_name.is_empty():
			if dir.current_is_dir():
				remove_dir_recursive(absolute_path.path_join(file_name))
			else:
				dir.remove(file_name)
			file_name = dir.get_next()

		dir.list_dir_end()
		DirAccess.remove_absolute(absolute_path)
