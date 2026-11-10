// Private macOS functions exposed to Swift. None of them is in a public header.

#import <Carbon/Carbon.h>

// The WindowServer connection of this process.
int CGSMainConnectionID(void);

// Symbolic hotkeys 1 and 2 are the Dock's Cmd+Tab and Cmd+Shift+Tab.
// The setting lives in the WindowServer: it outlives the process that changed it.
CGError CGSSetSymbolicHotKeyEnabled(int hotKey, bool enabled);
bool CGSIsSymbolicHotKeyEnabled(int hotKey);

// The CGWindowID behind an Accessibility window element.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *windowID);

// One CGImage per window id. The caller owns the returned array.
CFArrayRef CGSHWCaptureWindowList(int cid, CGWindowID *list, int count, uint32_t options) CF_RETURNS_RETAINED;
