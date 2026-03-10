# User facing scenarios that the tests should cover
## Scenarios without a full sleep/wake cycle:
### Scenario 1: 2 finder windows
Given that the user has two external screens (screen 1 and screen 2)
Given that the user's computer has no internal screen
Given that there are two finder windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user saves the window layout
And the user moves window 1 to screen 2
And the user restores the window layout
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2

### Scenario 1: 2 application windows
Given that the user has two external screens (screen 1 and screen 2)
Given that the user's computer has no internal screen
Given that there are two application windows, one on each screen (window 1 on screen 1 and window 2 on screen 2)
When the user saves the window layout
And the user moves window 1 to screen 2
And the user restores the window layout
Then window 1 should be restored on screen 1 and window 2 should be restored on screen 2
