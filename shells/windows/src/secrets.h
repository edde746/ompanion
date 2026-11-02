// shell.secretGet/Set/Delete: a Credential Manager generic credential `com.edde746.ompanion/<key>` per secret. A value
// larger than a credential holds (CRED_MAX_CREDENTIAL_BLOB_SIZE, 2560 bytes: an RSA private key can be more) goes to a
// DPAPI-encrypted file under the data folder instead.
#pragma once

#include <optional>
#include <string>

std::optional<std::string> secretGet(const std::string& key);
void secretSet(const std::string& key, const std::string& value);
void secretDelete(const std::string& key);

// DPAPI-decrypts bytes the current user encrypted without entropy: the sealed files above, and
// flutter_secure_storage's file (flutter_data.cpp).
std::string unseal(const std::string& sealed);
