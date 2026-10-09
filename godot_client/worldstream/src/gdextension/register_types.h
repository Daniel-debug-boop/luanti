#pragma once

// Module init/term functions registered by the GDExtension entry point.

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_worldstream_module(ModuleInitializationLevel p_level);
void uninitialize_worldstream_module(ModuleInitializationLevel p_level);
