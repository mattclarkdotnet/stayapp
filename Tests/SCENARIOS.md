# User facing scenarios that the tests should cover

## Screen Identifier Conventions

- `screen_1` / `screen_2`: generic external-screen identifiers for scenarios where only relative placement matters.
- `primary_screen`: the primary macOS display (menu bar display).
- `secondary_screen`: the non-primary external display used in two-screen scenarios.

## Workspace Identifier Conventions

- `primary_workspace`: the currently active macOS Mission Control space at scenario start.
- `secondary_workspace`: a second Mission Control space on the same display setup.

## 1. Scenarios without a full sleep/wake cycle:
### Scenario 1.1: 2 finder windows
Given that the user has two external screens (`screen_1` and `screen_2`)
And the user's computer has no internal screen
And there are two finder windows, one on each screen (window 1 on `screen_1` and window 2 on `screen_2`)
When the user saves the window layout
And the user moves window 1 to `screen_2`
And the user restores the window layout
Then window 1 should be restored on `screen_1` and window 2 should be restored on `screen_2`

### Scenario 1.2: 2 application windows
Given that the user has two external screens (`screen_1` and `screen_2`)
And the user's computer has no internal screen
And there are two application windows, one on each screen (window 1 on `screen_1` and window 2 on `screen_2`)
When the user saves the window layout
And the user moves window 1 to `screen_2`
And the user restores the window layout
Then window 1 should be restored on `screen_1` and window 2 should be restored on `screen_2`

### Scenario 1.3: FreeCAD child windows
Given that the user has two external screens (`primary_screen` and `secondary_screen`)
And the user's computer has no internal screen
And FreeCAD is launched
And the user moves the main FreeCAD window to `primary_screen`
And the user moves the child windows (tasks, model, report view, python console) to `secondary_screen`
When the user saves the window layout
And the user moves the main FreeCAD window to `secondary_screen`
And the user moves the child windows to `primary_screen`
And the user restores the window layout
Then the main FreeCAD window should be restored on `primary_screen` and the child windows should be restored on `secondary_screen`

### Scenario 1.4: KiCad split editors
Given that the user has two external screens (`primary_screen` and `secondary_screen`)
And the user's computer has no internal screen
And KiCad is launched
And the main KiCad window is on `primary_screen`
And the PCB editor window is on `primary_screen`
And the schematic editor window is on `secondary_screen`
When the user saves the window layout
And the user moves all three windows to the opposite screen from their saved screen
And the user restores the window layout
Then the main KiCad window should be restored on `primary_screen`
And the PCB editor window should be restored on `primary_screen`
And the schematic editor window should be restored on `secondary_screen`

### Scenario 1.5: Basic app window on `secondary_workspace`
Given that the user has two external screens (`primary_screen` and `secondary_screen`)
And the user has two macOS workspaces (`primary_workspace` and `secondary_workspace`)
And the user's computer has no internal screen
And TextEdit is launched
And a TextEdit window is on `secondary_workspace` on `secondary_screen`
When the user saves the window layout
And the user moves that TextEdit window to `primary_screen` (still on `secondary_workspace`)
And the user switches to `primary_workspace`
And the user restores the window layout
Then Stay should restore the TextEdit window as soon as macOS exposes it for reliable movement
And Stay should not force a workspace switch as part of restore
When the user switches back to `secondary_workspace`
Then the TextEdit window should be restored on `secondary_screen` no later than that workspace activation

## 2. Scenarios with a full sleep/wake cycle:
### Scenario 2.1: 2 finder windows
Given that the user has two external screens (`screen_1` and `screen_2`)
Given that the user's computer has no internal screen
Given that there are two finder windows, one on each screen (window 1 on `screen_1` and window 2 on `screen_2`)
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then window 1 should be restored on `screen_1` and window 2 should be restored on `screen_2`

### Scenario 2.2: 2 application windows
Given that the user has two external screens (`screen_1` and `screen_2`)
Given that the user's computer has no internal screen
Given that there are two application windows, one on each screen (window 1 on `screen_1` and window 2 on `screen_2`)
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then window 1 should be restored on `screen_1` and window 2 should be restored on `screen_2`

### Scenario 2.3: FreeCAD child windows
Given that the user has two external screens (`primary_screen` and `secondary_screen`)
Given that the user's computer has no internal screen
Given that FreeCAD is launched
Given that the main FreeCAD window is on `primary_screen`
Given that the child windows (tasks, model, report view, python console) are on `secondary_screen`
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then the main FreeCAD window should be restored on `primary_screen`
And the child windows should be restored on `secondary_screen`

### Scenario 2.4: KiCad split editors
Given that the user has two external screens (`primary_screen` and `secondary_screen`)
Given that the user's computer has no internal screen
Given that KiCad is launched
Given that the main KiCad window is on `primary_screen`
Given that the PCB editor window is on `primary_screen`
Given that the schematic editor window is on `secondary_screen`
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then the main KiCad window should be restored on `primary_screen`
And the PCB editor window should be restored on `primary_screen`
And the schematic editor window should be restored on `secondary_screen`
