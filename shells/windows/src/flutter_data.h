// shell.flutterData and shell.flutterDataClear (docs/contracts/bridge.md, Flutter data import): what the Flutter app
// kept in %APPDATA%\com.edde746\ompanion\ (path_provider's application support folder, from the Flutter exe's
// VERSIONINFO CompanyName and ProductName): its drift database ompanion.sqlite, and flutter_secure_storage_windows'
// flutter_secure_storage.dat, every secret as one UTF-8 JSON object encrypted with DPAPI (current user, no entropy).
// Packaged, the same calls see the package's own view of %APPDATA%, which holds what the Flutter MSIX wrote.
#pragma once

#include <string>

// {database: path | null, secrets: {key: value}} as JSON text.
std::string flutterData();

// Removes flutter_secure_storage.dat and renames the database's files to <name>.imported, the user's backup.
void flutterDataClear();
