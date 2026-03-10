# User facing scenarios that the tests should cover
## 1. Scenarios without a full sleep/wake cycle:
### Scenario 1.1: 2 finder windows
Given that the user has two external screens (screen 1 and screen 2)
And the user's computer has no internal screen
And there are two finder windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user saves the window layout
And the user moves window 1 to screen 2
And the user restores the window layout
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2

### Scenario 1.2: 2 application windows
Given that the user has two external screens (screen 1 and screen 2)
And the user's computer has no internal screen
And there are two application windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user saves the window layout
And the user moves window 1 to screen 2
And the user restores the window layout
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2

### Scenario 1.3: FreeCAD child windows
Given that the user has two external screens (screen 1 and screen 2)
And the user's computer has no internal screen
And FreeCAD is launched
And the user moves the main FreeCAD window to screen 1
And the user moves the child windows (tasks, model, report view, python console) to screen 2
When the user saves the window layout
And the user moves the main FreeCAD window to screen 2
And the user moves the child windows to screen 1
And the user restores the window layout
Then the main FreeCAD window should be restored on screen 1 and the child windows should be restored on screen 2

## 2. Scenarios with a full sleep/wake cycle:
### Scenario 2.1: 2 finder windows
Given that the user has two external screens (screen 1 and screen 2)
Given that the user's computer has no internal screen
Given that there are two finder windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2

### Scenario 2.2: 2 application windows
Given that the user has two external screens (screen 1 and screen 2)
Given that the user's computer has no internal screen
Given that there are two application windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user sleeps the computer
And the user waits until both screens have gone into power standby
And the user wakes the computer
And the user waits until both screens have come out of power standby
And the user logs in
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2
