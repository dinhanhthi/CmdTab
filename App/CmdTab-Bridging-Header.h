// Private macOS functions exposed to Swift. None of them is in a public header.

#import <Carbon/Carbon.h>

// Symbolic hotkeys 1 and 2 are the Dock's Cmd+Tab and Cmd+Shift+Tab.
// The setting lives in the WindowServer: it outlives the process that changed it.
CGError CGSSetSymbolicHotKeyEnabled(int hotKey, bool enabled);

// The CGWindowID behind an Accessibility window element.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *windowID);

// Process Manager's pid → PSN lookup. Swift refuses the SDK declaration (deprecated in 10.9); the asm label
// calls the same symbol.
OSStatus CmdTabGetProcessForPID(pid_t pid, ProcessSerialNumber *psn) __asm("_GetProcessForPID");

// SkyLight (linked in project.yml). Bring a process forward with one of its windows, and post an event record
// to a process. Declarations as in yabai (MIT, github.com/koekeishiya/yabai, src/misc/extern.h).
CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, CGWindowID windowID, uint32_t mode);
CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
