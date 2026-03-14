## Simple test script to demonstrate functionality of the Font Trimmer plugin.
extends Node


@export var language_selector: OptionButton
@export var project_link_label: RichTextLabel


func _ready() -> void:
	_on_item_selected(language_selector.selected)
	language_selector.item_selected.connect(_on_item_selected)

	project_link_label.meta_clicked.connect(_on_project_link_clicked)


func _on_item_selected(index: int) -> void:
	var lang: String = language_selector.get_item_text(index).to_upper()
	match lang:
		"ENGLISH": TranslationServer.set_locale("en")
		"PORTUGUESE": TranslationServer.set_locale("pt")
		"SPANISH": TranslationServer.set_locale("es")
		"JAPANESE": TranslationServer.set_locale("ja")


func _on_project_link_clicked(meta: Variant) -> void:
	OS.shell_open(str(meta))