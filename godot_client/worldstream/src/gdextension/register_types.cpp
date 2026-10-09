// GDExtension entry point.
//
// Registered at SCENE level, which is the level GDScript exists at: a library
// that registers classes at CORE level would be usable before the scripting
// layer is up, which is a licence nothing here needs.

#include "register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "world_stream_native.h"

using namespace godot;

void initialize_worldstream_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(WorldStreamBatch);
    GDREGISTER_CLASS(WorldStreamNative);
}

void uninitialize_worldstream_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
// Initialization. The symbol name is the one worldstream.gdextension declares
// as entry_symbol; renaming it here without renaming it there loads nothing
// and says nothing, which is why the file is the only place it appears twice.
GDExtensionBool GDE_EXPORT worldstream_library_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library,
                                                   r_initialization);
    init_obj.register_initializer(initialize_worldstream_module);
    init_obj.register_terminator(uninitialize_worldstream_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
