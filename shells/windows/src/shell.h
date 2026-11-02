// The page's shell.* requests (docs/contracts/bridge.md, Shell services), answered here and never forwarded to the
// core.
#pragma once

#include <string>

// Takes message when it is a shell.* request. Requests are answered from the window's message loop
// (runShellRequests, on kShellRequests), outside the WebView2 event that delivered them: a save panel runs a nested
// message loop, which WebView2 events must not.
bool takeShellRequest(std::string& message);
void runShellRequests();

// The page is gone: its queued requests are dropped, and so is the answer to one still being handled (a save panel
// open), since the next page reuses its ids.
void forgetShellRequests();

// shell.appState: sent when the app comes to the front or leaves it.
void sendAppState(bool active);
