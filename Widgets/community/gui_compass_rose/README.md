# GUI Compass Rose

A widget for Beyond All Reason that displays a compass rose on screen, always oriented to map north, so you can keep your bearings when the camera is rotated.

## How it works

Uses the camera's orientation relative to the map to rotate a 4-point star rose so its N arm always points to map north. The N, E, S and W labels stay upright as the rose turns, and N is shown in red.

- **Pointer:** a yellow arrow at the top marks the direction the camera is facing.
- **Placement:** by default it sits just right of the minimap, near the resource bar.
- **Move:** left-click and drag the rose to reposition it.
- **Lock:** right-click the rose to lock or unlock it. When locked, dragging is disabled and the top arrow changes to a padlock icon.

Mouse clicks are only captured when the cursor is over the rose, so normal unit commands elsewhere are not affected.

## Safety

Only displays the compass; it does not alter the game, units or settings. The only data it stores is its own screen position and lock state, saved in the standard widget config.

## Configuration

Edit the values at the top of `gui_compass_rose.lua`:

| Setting | Default | Description |
|---|---|---|
| `SIZE` | `46` | Radius of the rose in pixels (scaled with resolution and UI scale) |
| `MARGIN` | `12` | Gap between the rose and the minimap |
| `FONT_SIZE` | `14` | Size of the N/E/S/W labels |
| `colNorth` | red | Color of the north arm |
| `colRoseLight` / `colRoseDark` | light/dark grey | Shading of the E, S and W arms |
| `colPointer` | yellow | Color of the camera-facing arrow |
| `colLock` | light grey | Color of the padlock icon |
| `colBg` | translucent black | Background circle behind the rose |

Colors are `{red, green, blue, alpha}` values from 0 to 1.

To reset the position, unlock the widget and drag it back, or disable and re-enable it after removing its entry from `LuaUI/Config/BYAR.lua`.

## Manual installation

Copy `gui_compass_rose.lua` into the `data/LuaUI/Widgets/` folder of your Beyond All Reason installation, then enable **Compass Rose** in the widget list (F11).
