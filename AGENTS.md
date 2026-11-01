# AGENTS.md

## Language

All documentation in this repository (README, AGENTS.md, code comments, commit messages) is written in **English**.

## Project

WoW addon `JumpCounter`: counts the player's jumps, announces milestones and shows a jump statistics window with a bar chart, opened from a minimap icon.

- `JumpCounter.toc`: addon manifest, interface `11509` (Classic Era) and `16001` (Classic Forever), localized `Notes-xxXX`, SavedVariable `JumpCounterDB` (account-wide)
- `Locales.lua`: all user-facing strings, number and date formats. English is the base table, every other locale only overrides keys. Loaded first and exposed as `ns.L`.
- `Core.lua`: saved data, jump detection (hook on `JumpOrAscendStart` plus a lift-off check in `OnUpdate`), milestones and announcements, slash commands
- `UI.lua`: statistics window (time bucketing, aggregation, bar chart, character selection) and the minimap button as a LibDataBroker data source registered with LibDBIcon (needed so minimap button managers like SexyMap list it)
- `Libs/`: embedded, unmodified copies of LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0, loaded from the `.toc`. To update them, copy newer versions from another installed addon.
- `README.md`: user documentation, keep it in sync with features and commands

Data layout: `JumpCounterDB.chars["Name-Realm"] = { total, hours = { [floor(time() / 3600)] = count }, name, realm, class }`. All views are aggregated from the hourly buckets, so changing views never needs a data migration.

When adding a user-facing string, add the key to the English base table and to every locale in `Locales.lua`. Character milestones go to party/raid chat; account milestones (all characters) are shown locally only.

## Installed copies

The addon is installed as a plain copy (not a clone) in:

- `C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\JumpCounter`
- `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\JumpCounter`

After changing the `.toc`, any `.lua` or `Libs/`, copy them to both installations. The folder name must stay `JumpCounter`.

## Testing

There is no automated test setup. Changes are verified in game with `/reload`; Lua errors show up with `/console scriptErrors 1`. A syntax check is possible with `luajit -bl <file>.lua`.
