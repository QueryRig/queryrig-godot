@tool
extends EditorPlugin

# Registers the QueryRig autoload when the plugin is enabled, so games call
# QueryRig.track(...) from anywhere without wiring anything up themselves.

const AUTOLOAD_NAME := "QueryRig"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/queryrig/queryrig.gd")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
