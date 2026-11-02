// The little JSON the shell needs: reading the page's shell.* requests and writing their answers.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

struct Json {
    enum class Kind { Null, Bool, Number, String, Array, Object };

    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<std::pair<std::string, Json>> members;  // an object's; an array keeps only its raw text
    std::string_view raw;  // the value's JSON text, inside the parsed text: valid while that text is

    // The object's member called key, or nullptr.
    const Json* find(std::string_view key) const;
};

// The value text holds, or nothing when it is not one JSON value.
std::optional<Json> parseJson(std::string_view text);

// text as a JSON string literal.
std::string quote(std::string_view text);
