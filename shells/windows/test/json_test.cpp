// The shell's JSON reader and writer (src/json.cpp), which every shell.* request goes through. Plain C++, so it runs
// on any machine with a C++20 compiler, e.g. from the repo's root:
//
//   scripts/studio.sh ShellWindows -- sh -c 'c++ -std=c++20 -Ishells/windows/src shells/windows/src/json.cpp \
//     shells/windows/test/json_test.cpp -o /tmp/json_test && /tmp/json_test'
#include "json.h"

#include <cstdio>
#include <string>

namespace {

int failures = 0;

void expect(bool condition, const char* what) {
    if (condition) return;
    std::printf("FAIL: %s\n", what);
    ++failures;
}

void readsARequest() {
    std::string text =
        R"( {"id": 7, "method":"shell.secretSet", "params":{"key":"k","value":"\u00e9 \ud83d\ude00 \"q\" \\ \/","n":-1.5e2,)"
        R"("on":true,"off":false,"none":null,"data":{"a":[1, 2, {"b": null}]}}} )";
    std::optional<Json> request = parseJson(text);
    expect(request.has_value(), "a request parses");
    if (!request) return;
    expect(request->kind == Json::Kind::Object, "a request is an object");
    expect(request->find("id") && request->find("id")->raw == "7", "id keeps its JSON text");
    expect(request->find("method") && request->find("method")->string == "shell.secretSet", "method decodes");
    const Json* params = request->find("params");
    expect(params && params->kind == Json::Kind::Object, "params is an object");
    if (!params) return;
    expect(params->find("value")->string == "\u00e9 \U0001F600 \"q\" \\ /", "escapes and surrogate pairs decode to UTF-8");
    expect(params->find("n")->kind == Json::Kind::Number && params->find("n")->number == -150, "numbers parse");
    expect(params->find("on")->boolean && params->find("on")->kind == Json::Kind::Bool, "true parses");
    expect(!params->find("off")->boolean && params->find("off")->kind == Json::Kind::Bool, "false parses");
    expect(params->find("none")->kind == Json::Kind::Null, "null parses");
    expect(params->find("data")->raw == R"({"a":[1, 2, {"b": null}]})", "a nested value keeps its exact text");
    expect(params->find("missing") == nullptr, "a missing member is nullptr");
}

void refusesInvalidText() {
    const char* invalid[] = {
        "",           "{",          "{\"a\":1,}", "[1,]",         "{\"a\" 1}", "01",       "1.",       "-",
        "1e",         "+1",         "\"open",     "\"\\x\"",      "\"\\u12\"", "\"a\nb\"", "nul",      "{} {}",
        "{\"a\":1}x", "[1 2]",      "{1:2}",      "'single'",
    };
    for (const char* text : invalid) {
        bool refused = !parseJson(text).has_value();
        if (!refused) std::printf("accepted: %s\n", text);
        expect(refused, "invalid JSON is refused");
    }
    std::string deep(200, '[');
    deep += std::string(200, ']');
    expect(!parseJson(deep).has_value(), "nesting deeper than the limit is refused");
    std::string shallow(100, '[');
    shallow += std::string(100, ']');
    expect(parseJson(shallow).has_value(), "nesting within the limit parses");
}

void replacesLoneSurrogates() {
    std::optional<Json> value = parseJson(R"("a\ud800b\udc00c\ud800\u0041")");
    expect(value && value->string == "a\uFFFDb\uFFFDc\uFFFDA", "a lone surrogate becomes U+FFFD");
}

void quotesText() {
    expect(quote("plain") == "\"plain\"", "plain text is only wrapped");
    expect(quote("a\"b\\c\nd\re\tf") == R"("a\"b\\c\nd\re\tf")", "quotes, backslashes and line breaks are escaped");
    expect(quote(std::string("\x01\x1f", 2)) == R"("\u0001\u001f")", "other control characters are \\u escapes");
    expect(quote("\u00e9 \U0001F600") == "\"\u00e9 \U0001F600\"", "non-ASCII stays UTF-8");
    for (std::string text : {std::string("secret ✓"), std::string("a\"\\\n\x02z"), std::string()}) {
        std::optional<Json> back = parseJson(quote(text));
        expect(back && back->string == text, "quote round-trips through parseJson");
    }
}

}  // namespace

int main() {
    readsARequest();
    refusesInvalidText();
    replacesLoneSurrogates();
    quotesText();
    if (failures > 0) {
        std::printf("%d failed\n", failures);
        return 1;
    }
    std::printf("json_test: all passed\n");
    return 0;
}
