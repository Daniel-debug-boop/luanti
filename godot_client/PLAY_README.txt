LuantiVoxel -- a voxel sandbox
=============================

A Godot 4.4 voxel sandbox: procedural terrain across six biomes and two
dimensions, mining and building, crafting, villagers who work and trade, and
an engineering/automation system.


PLAYING
-------

1. Unpack:

       tar xzf luantivoxel-<version>-linux-x86_64.tar.gz
       cd luantivoxel-<version>-linux-x86_64

2. Run:

       ./luantivoxel.x86_64

   Keep luantivoxel.pck in the same folder as the executable -- it holds the
   game itself. Without it the game will not start.

   To play with sound and a window you need a normal desktop session. On a
   headless machine it still runs (add --headless) but there is nothing to see.


REQUIREMENTS
------------

* Linux x86_64
* OpenGL 4.3 / Vulkan-capable GPU
  The default quality tier asks for SSAO, SSIL, volumetric fog and glow. On a
  weak GPU, press F1 at the title screen to drop the tier.
* ~215 MB on disk


CONTROLS
--------

  WASD .............. move
  Space ............. jump / rise while flying
  Shift ............. sprint
  F ................. toggle flight
  G ................. switch dimension
  Left mouse ........ mine
  Right mouse ....... place block
  1-8 or scroll ..... select a block (also clickable in the hotbar)
  E ................. talk to / trade with a nearby villager
  C ................. crafting grid -- drag blocks into it
  F5 / F9 ........... save / load
  F1-F3 ............. render quality
  F4-F7 ............. texture mapping mode
  F8 ................ toggle the Voxel Tools backend
  F10 ............... profiler overlay
  F11 ............... show the architecture contract, live
  Esc ............... release the mouse


CRAFTING
--------

Press C. Drag blocks from the inventory strip along the bottom into the 3x3
grid. When the grid matches a recipe the result appears on the right; drag
from the result slot, or click it, to collect. Shaped and shapeless recipes
both work, and a craft you cannot afford is refused without consuming
anything.


VILLAGERS
---------

A village generates with named villagers who each have a job. They keep a
daily routine -- work through the day, rest in the late afternoon, sleep at
night -- and they do their jobs for real: the Farmer tills grass into soil
underfoot, the Miner cuts stone out of the ground, the Woodcutter fells
nearby trees. A job whose resource is not nearby produces nothing, so siting
the district matters. Press E next to one to trade stone for their produce.

Note: the Miner and Woodcutter deplete what they work on. A village left
running unattended will slowly exhaust its own trees and stone.


WORLD FORMAT
------------

Saves are written under the Godot user directory, not next to the executable.
F5 saves, F9 loads.


LICENSE
-------

Code: LGPL 2.1+ (inherited from the Luanti codebase this was migrated from).
Bundled art and audio are CC0. Third-party licences are in addons/*/LICENSE*
and addons/thirdparty/*/LICENSE.
