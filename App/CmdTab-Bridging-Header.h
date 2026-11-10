// Private macOS functions exposed to Swift. None of them is in a public header.

#import <Carbon/Carbon.h>

// Symbolic hotkeys 1 and 2 are the Dock's Cmd+Tab and Cmd+Shift+Tab.
// The setting lives in the WindowServer: it outlives the process that changed it.
CGError CGSSetSymbolicHotKeyEnabled(int hotKey, bool enabled);

// The CGWindowID behind an Accessibility window element.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *windowID);
