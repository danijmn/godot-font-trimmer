## Implements logic of the Font Trimmer export plugin.
@tool
extends EditorExportPlugin


const FontTrimmerPluginUtils = preload("font_trimmer_plugin_utils.gd")

## Path of the project setting mapping font files to character source files.
const TRIMMER_MAP_SETTING_NAME: String = "plugins/font_trimmer/fonts_to_character_sources"

## Path of the project setting for running the plugin in verbose mode.
const TRIMMER_VERBOSE_SETTING_NAME: String = "plugins/font_trimmer/print_progress_messages_during_export"

## Path of the project setting for enabling cache retrieval for faster exports.
const TRIMMER_USE_CACHE_SETTING_NAME: String = "plugins/font_trimmer/use_cache"

## Path of the project setting determining the maximum cache size in megabytes.
const TRIMMER_CACHE_SIZE_SETTING_NAME: String = "plugins/font_trimmer/max_cache_size_mb"

## Path of the project setting determining optional extra arguments to pass to fonttools subset.
const TRIMMER_EXTRA_ARGS_SETTING_NAME: String = "plugins/font_trimmer/extra_arguments_to_fonttools"

## Default value of setting [TRIMMER_VERBOSE_SETTING_NAME].
const TRIMMER_VERBOSE_SETTING_DEFAULT: bool = true

## Default value of setting [TRIMMER_USE_CACHE_SETTING_NAME].
const TRIMMER_USE_CACHE_SETTING_DEFAULT: bool = true

## Default value of setting [TRIMMER_CACHE_SIZE_SETTING_NAME] (maximum cache size in megabytes).
const TRIMMER_CACHE_SIZE_SETTING_DEFAULT: int = 200

## URL of the fonttools repository to let the user check installation instructions.
const FONTTOOLS_URL: String = "https://github.com/fonttools/fonttools"

var _font_to_sources: Dictionary[String, PackedStringArray] = {}
var _verbose: bool = TRIMMER_VERBOSE_SETTING_DEFAULT
var _use_cache: bool = TRIMMER_USE_CACHE_SETTING_DEFAULT
var _max_cache_size_mb: int = TRIMMER_CACHE_SIZE_SETTING_DEFAULT
var _extra_fonttools_args: PackedStringArray = []
var _backups: Dictionary[String, String] = {} ## Path of original file -> path of backup (absolute)
var _cache_hashes_hit_on_last_run: Dictionary[String, bool] = {}


func _get_name() -> String:
	return "Font Trimmer"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	# Reset state from last export
	_font_to_sources = {}
	_verbose = FontTrimmerPluginUtils.get_setting_with_custom_features_or_default(
		TRIMMER_VERBOSE_SETTING_NAME, features, TRIMMER_VERBOSE_SETTING_DEFAULT)
	_use_cache = FontTrimmerPluginUtils.get_setting_with_custom_features_or_default(
		TRIMMER_USE_CACHE_SETTING_NAME, features, TRIMMER_USE_CACHE_SETTING_DEFAULT)
	_max_cache_size_mb = FontTrimmerPluginUtils.get_setting_with_custom_features_or_default(
		TRIMMER_CACHE_SIZE_SETTING_NAME, features, TRIMMER_CACHE_SIZE_SETTING_DEFAULT)
	_extra_fonttools_args = FontTrimmerPluginUtils.get_setting_with_custom_features_or_default(
		TRIMMER_EXTRA_ARGS_SETTING_NAME, features, PackedStringArray())
	_extra_fonttools_args.sort() # Preserve cache hash if order changes
	_backups = {}
	_cache_hashes_hit_on_last_run = {}

	# If fonttools is not installed, no point in further processing
	if !check_fonttools(true, false):
		return

	# Make sure the plugin's global cache dir exists within the .godot folder
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(_get_cache_path_local()))
	
	# Sanitize project setting containing font to source files mapping.
	# If major user-caused sanity errors are found in the plugin's project settings,
	# suggest reconfiguring from scratch.
	var mapping_raw = FontTrimmerPluginUtils.get_setting_with_custom_features_or_default(
		TRIMMER_MAP_SETTING_NAME, features, {})
	if !_check_basic_mapping_sanity(mapping_raw):
		push_error(
"[Font Trimmer] Project setting '%s' is configured badly. \
Consider resetting its value to default and configuring again. \
No font trimming will take place during this export." % TRIMMER_MAP_SETTING_NAME)
		return

	# Now account for mistakes that the editor can't prevent beforehand (e.g. files being deleted),
	# and produce a _font_to_sources map that's fully validated
	_font_to_sources = _compute_validated_font_to_sources(mapping_raw, _verbose)


static func _get_cache_path_local() -> String:
	# This gets the project-relative path of the cache folder used by the plugin (which is inside
	# the .godot folder), accounting for the Godot setting "use_hidden_project_data_directory"
	var is_hidden: Variant = ProjectSettings.get_setting_with_override(
		"application/config/use_hidden_project_data_directory")
	if is_hidden is bool && is_hidden == false:
		return "res://godot/font_trimmer"
	else:
		return "res://.godot/font_trimmer"


## Checks that fonttools can be called, optionally showing an error message to the user if it can't.
static func check_fonttools(show_error_msg: bool, show_error_as_popup: bool) -> bool:
	if !Engine.is_editor_hint():
		return false

	var exists: bool = OS.execute("fonttools", ["subset", "--help"]) == 0

	if !exists && show_error_msg:
		var msg: String = \
"Font Trimmer requires 'fonttools', which could not be found on your system.
Make sure fonttools is installed and on your system's PATH."
		
		if show_error_as_popup:
			var dialog = AcceptDialog.new()
			dialog.title = "fonttools not found"
			dialog.dialog_text = msg
			var fonttools_button = dialog.add_button("fonttools site...", true)
			fonttools_button.pressed.connect(OS.shell_open.bind(FONTTOOLS_URL))
			dialog.confirmed.connect(dialog.queue_free)
			dialog.canceled.connect(dialog.queue_free)
			EditorInterface.get_base_control().add_child(dialog)
			dialog.popup_centered()
		else:
			msg += "\nfonttools site: %s" % FONTTOOLS_URL
			push_error(msg)

	return exists


static func _check_basic_mapping_sanity(mapping_raw: Variant) -> bool:
	# Verifies that the type sanity checks that would normally be applied by the Godot editor
	# hold true (necessary because e.g. users may edit the project setting manually in the project.godot file)
	# In essence, this enforces that mapping_raw's type is a Dictionary mapping String to Array[String]
	if mapping_raw is not Dictionary:
		return false
	
	for font_file in mapping_raw:
		if font_file is not String:
			return false
		var character_source_files = mapping_raw[font_file]
		if character_source_files is not Array \
		|| character_source_files.any(func(elem): return elem is not String):
			return false
	
	return true


static func _compute_validated_font_to_sources(mapping_raw: Dictionary, verbose: bool) -> \
 Dictionary[String, PackedStringArray]:
	var result: Dictionary[String, PackedStringArray] = {}

	for font_path_raw: String in mapping_raw:
		# Font paths are usually supplied as UIDs but we need path consistency e.g. for dictionary use
		var font_path_global: String = ProjectSettings.globalize_path(font_path_raw)
		var font_path_local: String = ProjectSettings.localize_path(font_path_global)

		var font_resource = load(font_path_global)
		if font_resource is not FontFile:
			push_error("[Font Trimmer] Found an entry for a font file that doesn't seem to exist \
or is not a valid FontFile resource: %s (skipping entry)." % font_path_raw)
			continue

		var character_source_files_raw: Array = mapping_raw[font_path_raw]
		if character_source_files_raw.is_empty():
			push_error("[Font Trimmer] Found an entry for font file '%s', but it's not mapped to \
any character source files (did you make a mistake?). This font file won't be trimmed." % font_path_local)
			continue

		var character_source_files_sanitized: PackedStringArray = []
		var missing_source_files: bool = false
		for source_file_path_raw: String in character_source_files_raw:
			var source_file_path_global: String = ProjectSettings.globalize_path(source_file_path_raw)
			var source_file_path_local: String = ProjectSettings.localize_path(source_file_path_global)
			
			if !FileAccess.file_exists(source_file_path_global):
				push_error(
"[Font Trimmer] One of the character source files mapped to font file '%s' doesn't seem to exist: '%s' \
...cancelling trimming for this font file!!!" % [font_path_local, source_file_path_raw])
				missing_source_files = true
				break
			else:
				# All is good -> file can be used as a text character source for subsetting
				character_source_files_sanitized.append(source_file_path_global)
				if verbose:
					print("[Font Trimmer] Found valid mapping from font '%s' to character source file '%s'" %
					[font_path_local, source_file_path_local])

		# Keep track of valid font file -> text source file pairs (as global paths) for the subsequent export process
		if !missing_source_files:
			result[font_path_global] = character_source_files_sanitized
	
	return result


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	var font_file_absolute_path := ProjectSettings.globalize_path(path)
	if !_font_to_sources.has(font_file_absolute_path):
		return
	
	if _verbose:
		print("[Font Trimmer] Starting subset process for font '%s'" %
		ProjectSettings.localize_path(font_file_absolute_path))

	var fontdata_absolute_path := _get_fontdata_absolute_path(font_file_absolute_path)
	if fontdata_absolute_path.is_empty():
		return

	# Save backups of original font file and its .fontdata to user folder
	_backups[font_file_absolute_path] = ProjectSettings.globalize_path(
		"user://BKP_" + font_file_absolute_path.get_file())
	_backups[fontdata_absolute_path] = ProjectSettings.globalize_path(
		"user://BKP_" + fontdata_absolute_path.get_file())
	DirAccess.copy_absolute(font_file_absolute_path, _backups[font_file_absolute_path])
	DirAccess.copy_absolute(fontdata_absolute_path, _backups[fontdata_absolute_path])

	# Check if a cached subsetted font + .fontdata exists for the same configuration.
	# If so, overwrite original files with them.
	var character_source_file_paths: PackedStringArray = _font_to_sources[font_file_absolute_path]
	var hash_str := _compute_font_hash(font_file_absolute_path, character_source_file_paths, _extra_fonttools_args)
	_cache_hashes_hit_on_last_run[hash_str] = true
	var font_cache_dir := ProjectSettings.globalize_path(_get_cache_path_local().path_join(hash_str))
	if _use_cache && _fetch_cache(font_cache_dir, font_file_absolute_path, fontdata_absolute_path):
		_print_success(_verbose, font_file_absolute_path, _backups[font_file_absolute_path], true)
		return
	else:
		DirAccess.make_dir_absolute(font_cache_dir) # Make sure the font's cache dir exists

	# Nothing in the cache so we need to compute the subsetted font.
	# Start by condensing all content from all source files mapped to the font into a temp file.
	var condensed_text_file_absolute_path := _condense_source_text(character_source_file_paths)
	if condensed_text_file_absolute_path.is_empty():
		return
	
	# Execute "fonttools subset", using the condensed text and routing output to a temp file
	var output_file_absolute_path := ProjectSettings.globalize_path(
		"user://font_trimmer_output_temp_file")
	# NOTE: using "--retain-gids" is necessary to keep font glyphs on the same index,
	# otherwise the font's pre-render cache configuration gets broken.
	# This increases file size a bit, but not too much
	# (about 700 KB for a 16 MB font before compression).
	var args: PackedStringArray = [
		"subset",
		font_file_absolute_path,
		"--retain-gids",
		"--text-file=" + condensed_text_file_absolute_path,
		"--output-file=" + output_file_absolute_path]
	args.append_array(_extra_fonttools_args)
	var execute_output: Array = []
	var subset_result: int = OS.execute("fonttools", args, execute_output, true, false)

	# Check if subsetting succeeded, and if so, copy the subsetted font to
	# the original font location and trigger reimport, then save to cache
	if subset_result != 0:
		push_error("[Font Trimmer] fonttools failed with code %d%s" %
			[subset_result, ". Output:" if !execute_output.is_empty() else ""])
		for output in execute_output:
			push_error(output)
	else:
		DirAccess.copy_absolute(output_file_absolute_path, font_file_absolute_path)
		EditorInterface.get_resource_filesystem().reimport_files(
			[ProjectSettings.localize_path(font_file_absolute_path)])
		
		fontdata_absolute_path = _get_fontdata_absolute_path(font_file_absolute_path) # NOTE: changes after reimport
		DirAccess.copy_absolute(output_file_absolute_path, font_cache_dir.path_join("subset"))
		DirAccess.copy_absolute(fontdata_absolute_path, font_cache_dir.path_join("fontdata"))

		_print_success(_verbose, font_file_absolute_path, _backups[font_file_absolute_path], false)

	# Remove temporary input/output files
	DirAccess.remove_absolute(condensed_text_file_absolute_path)
	DirAccess.remove_absolute(output_file_absolute_path)


static func _get_fontdata_absolute_path(font_file_absolute_path: String) -> String:
	var cf := ConfigFile.new()
	if cf.load(font_file_absolute_path + ".import") == OK:
		var fontdata_path: String = cf.get_value("remap", "path", "")
		if fontdata_path != "":
			return ProjectSettings.globalize_path(fontdata_path)
	
	push_error("[Font Trimmer] Could not find corresponding .fontdata for font file '%s'"
		% ProjectSettings.localize_path(font_file_absolute_path))
	return ""


static func _compute_font_hash(font_absolute_path: String,
 sources_absolute_paths: PackedStringArray, extra_args: PackedStringArray) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_MD5)
	
	# Hash the font file and source files (including file paths).
	# The import settings of the font file also need to be hashed,
	# because they impact the generated .fontdata file.
	# Also include the Godot version, as the binary output of font imports may change.
	# Also include extra arguments to fonttools, as those may change output.
	hasher.update(("%s=%s" % [ProjectSettings.localize_path(font_absolute_path),
							  FileAccess.get_md5(font_absolute_path)]).to_utf8_buffer())
	hasher.update(("\n%s" % FileAccess.get_md5(font_absolute_path + ".import")).to_utf8_buffer())
	hasher.update(("\n%s" % Engine.get_version_info().string).to_utf8_buffer())
	hasher.update(("\n%s" % " ".join(extra_args)).to_utf8_buffer())
	for source_path: String in sources_absolute_paths:
		hasher.update(("\n%s=%s" % [ProjectSettings.localize_path(source_path),
									FileAccess.get_md5(source_path)]).to_utf8_buffer())

	var hash_bytes: PackedByteArray = hasher.finish()
	return hash_bytes.hex_encode()


static func _fetch_cache(
 font_cache_dir_absolute: String, font_absolute_path: String, fontdata_absolute_path: String) -> bool:
	if DirAccess.dir_exists_absolute(font_cache_dir_absolute) \
	&& FileAccess.file_exists(font_cache_dir_absolute.path_join("subset")) \
	&& FileAccess.file_exists(font_cache_dir_absolute.path_join("fontdata")):
		# NOTE: as of version 4.6, Godot also keeps an .md5 file alongside .fontdata,
		# but it seems like it's not checked on _export_file. We *could* cache the file and
		# fetch it back at this point, but the process is undocumented and could
		# change in the future (e.g. Godot could switch to SHA hashes).
		# So it's best not to do anything about it, unless the cache or export fails because
		# the .md5 starts to get checked on _export_file in some future Godot version (unlikely).
		DirAccess.copy_absolute(font_cache_dir_absolute.path_join("subset"), font_absolute_path)
		DirAccess.copy_absolute(font_cache_dir_absolute.path_join("fontdata"), fontdata_absolute_path)
		return true
	return false


static func _print_success(
 verbose: bool, font_absolute_path: String, font_backup_absolute_path: String, used_cache: bool) -> void:
	if verbose:
		print("[Font Trimmer] Successfully trimmed font '%s' from %d KB to %d KB%s" %
			[ProjectSettings.localize_path(font_absolute_path),
			ceili(FileAccess.get_size(font_backup_absolute_path) / 1024.0),
			ceili(FileAccess.get_size(font_absolute_path) / 1024.0),
			" (used cached files)" if used_cache else ""])


static func _condense_source_text(character_source_file_paths: PackedStringArray) -> String:
	# Start by grabing all content from all source files (as UTF-8 strings)
	var all_strings: PackedStringArray = []
	for source_file_path: String in character_source_file_paths:
		if source_file_path.get_extension() == "translation":
			# Special case: handle .translation files gracefully
			# (fetch actual text instead of binary content)
			var translation: Translation = load(source_file_path)
			all_strings += translation.get_translated_message_list()
		else:
			all_strings.append(FileAccess.get_file_as_string(source_file_path))

	# Write all strings to a temp input file (that will be processed by fonttools)
	var condensed_text_file_absolute_path := ProjectSettings.globalize_path(
		"user://font_trimmer_chars_temp_file")
	var condensed_text_file = FileAccess.open(condensed_text_file_absolute_path, FileAccess.WRITE)
	if condensed_text_file == null:
		push_error(
"[Font Trimmer] Unable to create temp file to process \
font subsetting (FileAccess error %d)" % FileAccess.get_open_error())
		return ""
	condensed_text_file.store_string("".join(all_strings))
	condensed_text_file.close()
	return condensed_text_file_absolute_path


func _export_end() -> void:
	# Restore original font and .fontdata files, and prune the cache to _max_cache_size_mb
	for original_path: String in _backups:
		var backup_path: String = _backups[original_path]
		DirAccess.copy_absolute(backup_path, original_path)
		DirAccess.remove_absolute(backup_path)
	if !_backups.is_empty():
		EditorInterface.get_resource_filesystem().scan()
	if _max_cache_size_mb >= 0:
		_prune_cache(_cache_hashes_hit_on_last_run, _max_cache_size_mb * 1024 * 1024)


static func _prune_cache(cache_hashes_hit: Dictionary[String, bool], max_size_bytes: int) -> void:
	var cache_path_absolute := ProjectSettings.globalize_path(_get_cache_path_local())
	if !DirAccess.dir_exists_absolute(cache_path_absolute):
		return

	# Compute total cache size, keeping track of size per cache directory so that
	# later we can know how many bytes were freed by deleting certain directories
	var dir_to_size: Dictionary[String, int] = FontTrimmerPluginUtils.get_dir_size(cache_path_absolute)
	var total_size: int = dir_to_size["."]
	dir_to_size.erase(".")
	
	# Init dict mapping each cache directory to last use in unix time (defaulting to 0)
	var dir_to_last_use: Dictionary[String, int] = {}
	for dir: String in dir_to_size:
		dir_to_last_use[dir] = 0

	# Read record of last used cache directories (if it exists)
	var record_file_path := cache_path_absolute.path_join("last_used")
	var file_string: String = FileAccess.get_file_as_string(record_file_path)
	if !file_string.is_empty():
		var raw_records: Variant = JSON.parse_string(file_string)
		if raw_records is Dictionary:
			for key in raw_records:
				if dir_to_last_use.has(key):
					dir_to_last_use[key] = raw_records[key] as int

	# Update record with all cache directories used during the last export run
	var now: int = Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system(true))
	for hash_hit: String in cache_hashes_hit:
		if dir_to_last_use.has(hash_hit):
			dir_to_last_use[hash_hit] = now

	# Make a sorted dictionary mapping last use times to directories
	var last_use_to_dirs: Dictionary[int, PackedStringArray] = {}
	for dir: String in dir_to_last_use:
		var last_use: int = dir_to_last_use[dir]
		last_use_to_dirs.get_or_add(last_use, PackedStringArray()).append(dir)
	last_use_to_dirs.sort()

	# Delete cache directories until we come under the cache limit
	while total_size > max_size_bytes && !last_use_to_dirs.is_empty():
		var earliest_dir := _pop_dir_from_last_use_to_dirs(last_use_to_dirs)
		FontTrimmerPluginUtils.remove_dir_recursive(cache_path_absolute.path_join(earliest_dir))
		total_size -= dir_to_size[earliest_dir]
		dir_to_size.erase(earliest_dir)
		dir_to_last_use.erase(earliest_dir)

	# Write updated record of last used cache directories back to file
	var f := FileAccess.open(record_file_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(dir_to_last_use))
		f.close()


static func _pop_dir_from_last_use_to_dirs(dict: Dictionary[int, PackedStringArray]) -> String:
	var earliest: int = 0
	for key: int in dict:
		earliest = key
		break
	var earliest_dirs: PackedStringArray = dict[earliest]
	var popped_dir: String = earliest_dirs[-1]
	earliest_dirs.remove_at(earliest_dirs.size() - 1)
	if earliest_dirs.is_empty():
		dict.erase(earliest)
	return popped_dir
