#include "json.h"

#include <charconv>
#include <cstdio>

namespace {

// Deeper input is refused: every level is a stack frame.
constexpr int kMaxDepth = 128;

bool isDigit(char c) { return c >= '0' && c <= '9'; }

void appendUtf8(std::string& out, char32_t point) {
    if (point < 0x80) {
        out += static_cast<char>(point);
    } else if (point < 0x800) {
        out += static_cast<char>(0xC0 | (point >> 6));
        out += static_cast<char>(0x80 | (point & 0x3F));
    } else if (point < 0x10000) {
        out += static_cast<char>(0xE0 | (point >> 12));
        out += static_cast<char>(0x80 | ((point >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (point & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (point >> 18));
        out += static_cast<char>(0x80 | ((point >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((point >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (point & 0x3F));
    }
}

class Parser {
public:
    explicit Parser(std::string_view text) : text_(text) {}

    bool value(Json& out, int depth) {
        skipSpace();
        if (depth > kMaxDepth || at_ == text_.size()) return false;
        size_t start = at_;
        bool ok;
        switch (text_[at_]) {
        case 'n':
            ok = literal("null");
            break;
        case 't':
            ok = literal("true");
            out.kind = Json::Kind::Bool;
            out.boolean = true;
            break;
        case 'f':
            ok = literal("false");
            out.kind = Json::Kind::Bool;
            break;
        case '"':
            ok = string(out.string);
            out.kind = Json::Kind::String;
            break;
        case '[':
            ok = array(depth);
            out.kind = Json::Kind::Array;
            break;
        case '{':
            ok = object(out, depth);
            out.kind = Json::Kind::Object;
            break;
        default:
            ok = number(out.number);
            out.kind = Json::Kind::Number;
            break;
        }
        out.raw = text_.substr(start, at_ - start);
        return ok;
    }

    bool atEnd() {
        skipSpace();
        return at_ == text_.size();
    }

private:
    bool more() const { return at_ < text_.size(); }

    void skipSpace() {
        while (more() && (text_[at_] == ' ' || text_[at_] == '\t' || text_[at_] == '\n' || text_[at_] == '\r')) ++at_;
    }

    bool consume(char c) {
        skipSpace();
        if (!more() || text_[at_] != c) return false;
        ++at_;
        return true;
    }

    bool literal(std::string_view word) {
        if (text_.substr(at_, word.size()) != word) return false;
        at_ += word.size();
        return true;
    }

    bool array(int depth) {
        ++at_;
        if (consume(']')) return true;
        do {
            Json item;
            if (!value(item, depth + 1)) return false;
        } while (consume(','));
        return consume(']');
    }

    bool object(Json& out, int depth) {
        ++at_;
        if (consume('}')) return true;
        do {
            skipSpace();
            std::string key;
            if (!more() || text_[at_] != '"' || !string(key) || !consume(':')) return false;
            Json member;
            if (!value(member, depth + 1)) return false;
            out.members.emplace_back(std::move(key), std::move(member));
        } while (consume(','));
        return consume('}');
    }

    void skipDigits() {
        while (more() && isDigit(text_[at_])) ++at_;
    }

    bool number(double& out) {
        size_t start = at_;
        if (more() && text_[at_] == '-') ++at_;
        if (more() && text_[at_] == '0') {
            ++at_;
        } else if (more() && isDigit(text_[at_])) {
            skipDigits();
        } else {
            return false;
        }
        if (more() && text_[at_] == '.') {
            ++at_;
            if (!more() || !isDigit(text_[at_])) return false;
            skipDigits();
        }
        if (more() && (text_[at_] == 'e' || text_[at_] == 'E')) {
            ++at_;
            if (more() && (text_[at_] == '+' || text_[at_] == '-')) ++at_;
            if (!more() || !isDigit(text_[at_])) return false;
            skipDigits();
        }
        return std::from_chars(text_.data() + start, text_.data() + at_, out).ec == std::errc();
    }

    bool hex4(unsigned& out) {
        if (text_.size() - at_ < 4) return false;
        const char* end = text_.data() + at_ + 4;
        auto [stop, error] = std::from_chars(text_.data() + at_, end, out, 16);
        if (error != std::errc() || stop != end) return false;
        at_ += 4;
        return true;
    }

    bool string(std::string& out) {
        ++at_;
        while (more()) {
            char c = text_[at_++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return false;
            if (c != '\\') {
                out += c;
                continue;
            }
            if (!more()) return false;
            switch (text_[at_++]) {
            case '"': out += '"'; break;
            case '\\': out += '\\'; break;
            case '/': out += '/'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case 'u': {
                unsigned unit;
                if (!hex4(unit)) return false;
                char32_t point = unit;
                if (unit >= 0xD800 && unit < 0xDC00 && text_.substr(at_, 2) == "\\u") {
                    size_t pair = at_;
                    at_ += 2;
                    unsigned low;
                    if (!hex4(low)) return false;
                    if (low >= 0xDC00 && low < 0xE000) {
                        point = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                    } else {
                        at_ = pair;
                    }
                }
                // A surrogate without its other half has no UTF-8 form.
                if (point >= 0xD800 && point < 0xE000) point = 0xFFFD;
                appendUtf8(out, point);
                break;
            }
            default:
                return false;
            }
        }
        return false;
    }

    std::string_view text_;
    size_t at_ = 0;
};

}  // namespace

const Json* Json::find(std::string_view key) const {
    for (const auto& [name, value] : members)
        if (name == key) return &value;
    return nullptr;
}

std::optional<Json> parseJson(std::string_view text) {
    Parser parser(text);
    Json value;
    if (!parser.value(value, 0) || !parser.atEnd()) return std::nullopt;
    return value;
}

std::string quote(std::string_view text) {
    std::string out;
    out.reserve(text.size() + 2);
    out += '"';
    for (char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char escaped[8];
                std::snprintf(escaped, sizeof escaped, "\\u%04x", static_cast<unsigned>(c));
                out += escaped;
            } else {
                out += c;
            }
        }
    }
    out += '"';
    return out;
}
