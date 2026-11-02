// shell.notify, notifySchedule and notifyCancel: WinRT toasts. Unpackaged, they belong to the AppUserModelID kAppId,
// which startNotifications registers (HKCU\Software\Classes\AppUserModelId, no Start-menu shortcut needed) with a COM
// activator that Windows calls when a toast is clicked, launching the app first when it is not running. Packaged,
// they belong to the package's app, whose manifest declares the same activator (msix/build-msix.ps1).
#pragma once

#include <cstdint>
#include <string>

struct Toast {
    std::string id;
    std::string title;
    std::string subtitle;  // empty: none
    std::string body;
    std::string data;  // JSON text, `null` when the request had none
};

// Registers the app's AppUserModelID (unpackaged) and toast activator, once; the toast functions call it too.
void startNotifications();

// A newer toast with the same id replaces the shown or scheduled one.
void notify(const Toast& toast);

// Windows' ScheduledToastNotifier posts it at atMs (epoch milliseconds), whether the app runs then or not.
void schedule(const Toast& toast, int64_t atMs);

void cancelNotification(const std::string& id);
