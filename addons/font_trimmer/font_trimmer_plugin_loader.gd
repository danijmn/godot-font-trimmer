## Setup script that activates the Font Trimmer export plugin and populates relevant project settings.
@tool
extends EditorPlugin


const FontTrimmerPlugin = preload("font_trimmer_plugin.gd")

var _export_plugin


func _enter_tree():
	var settings_found: int = 0
	settings_found += _init_setting(FontTrimmerPlugin.TRIMMER_MAP_SETTING_NAME, {})
	settings_found += _init_setting(FontTrimmerPlugin.TRIMMER_VERBOSE_SETTING_NAME,
									FontTrimmerPlugin.TRIMMER_VERBOSE_SETTING_DEFAULT)
	settings_found += _init_setting(FontTrimmerPlugin.TRIMMER_USE_CACHE_SETTING_NAME,
									FontTrimmerPlugin.TRIMMER_USE_CACHE_SETTING_DEFAULT)
	settings_found += _init_setting(FontTrimmerPlugin.TRIMMER_CACHE_SIZE_SETTING_NAME,
									FontTrimmerPlugin.TRIMMER_CACHE_SIZE_SETTING_DEFAULT)
	settings_found += _init_setting(FontTrimmerPlugin.TRIMMER_EXTRA_ARGS_SETTING_NAME,
									PackedStringArray())

	if settings_found <= 0:
		# Probable first-time setup -> check fonttools installation and report errors with popup
		FontTrimmerPlugin.check_fonttools(true, true)
	else:
		# Plugin already setup before -> check fonttools installation, but log errors discretely
		FontTrimmerPlugin.check_fonttools(true, false)

	ProjectSettings.add_property_info({
		"name": FontTrimmerPlugin.TRIMMER_MAP_SETTING_NAME,
		"type": TYPE_DICTIONARY,
		"hint": PROPERTY_HINT_DICTIONARY_TYPE,
		"hint_string": "%d/%d:*.ttf,*.ttc,*.otf,*.otc,*.woff,*.woff2;%d:%d/%d:" %
			[TYPE_STRING, PROPERTY_HINT_FILE, TYPE_ARRAY, TYPE_STRING, PROPERTY_HINT_FILE_PATH]
		# NOTE: PROPERTY_HINT_FILE (i.e. UIDs) is not reliable for *.translation files, but we want to support those
		# files, so we use PROPERTY_HINT_FILE_PATH instead. Downside is user may move the file and break connection,
		# but the same issue occurs on all native Godot menus using *.translation files anyway (as of Godot 4.6)
	})
	ProjectSettings.add_property_info({
		"name": FontTrimmerPlugin.TRIMMER_VERBOSE_SETTING_NAME,
		"type": TYPE_BOOL
	})
	ProjectSettings.add_property_info({
		"name": FontTrimmerPlugin.TRIMMER_USE_CACHE_SETTING_NAME,
		"type": TYPE_BOOL
	})
	ProjectSettings.add_property_info({
		"name": FontTrimmerPlugin.TRIMMER_CACHE_SIZE_SETTING_NAME,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "-1,1000,1,or_greater"
	})
	ProjectSettings.add_property_info({
		"name": FontTrimmerPlugin.TRIMMER_EXTRA_ARGS_SETTING_NAME,
		"type": TYPE_PACKED_STRING_ARRAY
	})

	_export_plugin = FontTrimmerPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree():
	remove_export_plugin(_export_plugin)
	_export_plugin = null


static func _init_setting(setting_name: String, default_value: Variant) -> int:
	var existed: bool = ProjectSettings.has_setting(setting_name)
	if !existed:
		ProjectSettings.set_setting(setting_name, default_value)
	ProjectSettings.set_as_basic(setting_name, true)
	ProjectSettings.set_initial_value(setting_name, default_value)
	return 1 if existed else 0
