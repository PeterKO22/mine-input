#include "json.h"

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace aihub {
namespace json {

namespace {

void encode_utf8(uint32_t cp, std::string& out) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

const char* const kReplacement = "\xEF\xBF\xBD";  // U+FFFD

class Parser {
 public:
  explicit Parser(const std::string& text) : s_(text) {}

  bool parse(Value& out, std::string& err) {
    skip_ws();
    if (!parse_value(out)) {
      err = err_.empty() ? "invalid JSON" : err_;
      return false;
    }
    skip_ws();
    if (i_ != s_.size()) {
      err = "trailing characters after JSON value";
      return false;
    }
    return true;
  }

 private:
  const std::string& s_;
  size_t i_ = 0;
  std::string err_;

  bool fail(const std::string& e) {
    if (err_.empty()) err_ = e + " at offset " + std::to_string(i_);
    return false;
  }

  void skip_ws() {
    while (i_ < s_.size() &&
           (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r'))
      ++i_;
  }

  bool parse_value(Value& out) {
    if (i_ >= s_.size()) return fail("unexpected end of input");
    char c = s_[i_];
    switch (c) {
      case '{': return parse_object(out);
      case '[': return parse_array(out);
      case '"': {
        std::string str;
        if (!parse_string(str)) return false;
        out = Value(std::move(str));
        return true;
      }
      case 't':
        if (s_.compare(i_, 4, "true") == 0) { i_ += 4; out = Value(true); return true; }
        return fail("bad literal");
      case 'f':
        if (s_.compare(i_, 5, "false") == 0) { i_ += 5; out = Value(false); return true; }
        return fail("bad literal");
      case 'n':
        if (s_.compare(i_, 4, "null") == 0) { i_ += 4; out = Value(); return true; }
        return fail("bad literal");
      default:
        return parse_number(out);
    }
  }

  bool parse_object(Value& out) {
    ++i_;  // '{'
    out = Value::object();
    skip_ws();
    if (i_ < s_.size() && s_[i_] == '}') { ++i_; return true; }
    while (true) {
      skip_ws();
      if (i_ >= s_.size() || s_[i_] != '"') return fail("expected object key string");
      std::string key;
      if (!parse_string(key)) return false;
      skip_ws();
      if (i_ >= s_.size() || s_[i_] != ':') return fail("expected ':'");
      ++i_;
      skip_ws();
      Value v;
      if (!parse_value(v)) return false;
      out.set(key, std::move(v));
      skip_ws();
      if (i_ < s_.size() && s_[i_] == ',') { ++i_; continue; }
      if (i_ < s_.size() && s_[i_] == '}') { ++i_; return true; }
      return fail("expected ',' or '}'");
    }
  }

  bool parse_array(Value& out) {
    ++i_;  // '['
    out = Value::array();
    skip_ws();
    if (i_ < s_.size() && s_[i_] == ']') { ++i_; return true; }
    while (true) {
      skip_ws();
      Value v;
      if (!parse_value(v)) return false;
      out.push_back(std::move(v));
      skip_ws();
      if (i_ < s_.size() && s_[i_] == ',') { ++i_; continue; }
      if (i_ < s_.size() && s_[i_] == ']') { ++i_; return true; }
      return fail("expected ',' or ']'");
    }
  }

  bool parse_hex4(uint32_t& v) {
    if (i_ + 4 > s_.size()) return fail("bad \\u escape");
    v = 0;
    for (int k = 0; k < 4; ++k) {
      char c = s_[i_ + k];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
      else return fail("bad \\u escape");
    }
    i_ += 4;
    return true;
  }

  bool parse_string(std::string& out) {
    ++i_;  // opening quote
    out.clear();
    while (i_ < s_.size()) {
      unsigned char c = static_cast<unsigned char>(s_[i_]);
      if (c == '"') { ++i_; return true; }
      if (c == '\\') {
        ++i_;
        if (i_ >= s_.size()) return fail("bad escape");
        char e = s_[i_++];
        switch (e) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'b': out.push_back('\b'); break;
          case 'f': out.push_back('\f'); break;
          case 'n': out.push_back('\n'); break;
          case 'r': out.push_back('\r'); break;
          case 't': out.push_back('\t'); break;
          case 'u': {
            uint32_t cp;
            if (!parse_hex4(cp)) return false;
            if (cp >= 0xD800 && cp <= 0xDBFF) {  // 高位代理
              if (i_ + 1 < s_.size() && s_[i_] == '\\' && s_[i_ + 1] == 'u') {
                i_ += 2;
                uint32_t lo;
                if (!parse_hex4(lo)) return false;
                if (lo >= 0xDC00 && lo <= 0xDFFF) {
                  cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                  encode_utf8(cp, out);
                } else {
                  out += kReplacement;
                }
              } else {
                out += kReplacement;
              }
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {  // 孤立低位代理
              out += kReplacement;
            } else {
              encode_utf8(cp, out);
            }
            break;
          }
          default:
            return fail("bad escape");
        }
        continue;
      }
      if (c < 0x20) return fail("unescaped control char in string");
      out.push_back(static_cast<char>(c));
      ++i_;
    }
    return fail("unterminated string");
  }

  bool parse_number(Value& out) {
    size_t start = i_;
    if (i_ < s_.size() && s_[i_] == '-') ++i_;
    bool is_int = true;
    while (i_ < s_.size() && isdigit(static_cast<unsigned char>(s_[i_]))) ++i_;
    if (i_ == start + (start < s_.size() && s_[start] == '-' ? 1 : 0))
      return fail("bad number");
    if (i_ < s_.size() && s_[i_] == '.') {
      is_int = false;
      ++i_;
      size_t dstart = i_;
      while (i_ < s_.size() && isdigit(static_cast<unsigned char>(s_[i_]))) ++i_;
      if (i_ == dstart) return fail("bad number: no fraction digits");
    }
    if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
      is_int = false;
      ++i_;
      if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) ++i_;
      size_t estart = i_;
      while (i_ < s_.size() && isdigit(static_cast<unsigned char>(s_[i_]))) ++i_;
      if (i_ == estart) return fail("bad number: no exponent digits");
    }
    std::string lit = s_.substr(start, i_ - start);
    if (is_int) {
      errno = 0;
      long long v = strtoll(lit.c_str(), nullptr, 10);
      if (errno == 0) {
        out = Value(static_cast<int64_t>(v));
        return true;
      }
      // 溢出落回 double
    }
    out = Value(strtod(lit.c_str(), nullptr));
    return true;
  }
};

void serialize_string(const std::string& s, std::string& out) {
  out.push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));  // UTF-8 原样
        }
    }
  }
  out.push_back('"');
}

void serialize_value(const Value& v, std::string& out) {
  switch (v.type()) {
    case Value::Type::Null: out += "null"; break;
    case Value::Type::Bool: out += v.as_bool() ? "true" : "false"; break;
    case Value::Type::Int: out += std::to_string(v.as_int()); break;
    case Value::Type::Double: {
      char buf[40];
      snprintf(buf, sizeof(buf), "%.15g", v.as_double());
      out += buf;
      break;
    }
    case Value::Type::String: serialize_string(v.as_string(), out); break;
    case Value::Type::Array: {
      out.push_back('[');
      const auto& items = v.items();
      for (size_t i = 0; i < items.size(); ++i) {
        if (i) out.push_back(',');
        serialize_value(items[i], out);
      }
      out.push_back(']');
      break;
    }
    case Value::Type::Object: {
      out.push_back('{');
      bool first = true;
      for (const auto& kv : v.members()) {
        if (!first) out.push_back(',');
        first = false;
        serialize_string(kv.first, out);
        out.push_back(':');
        serialize_value(kv.second, out);
      }
      out.push_back('}');
      break;
    }
  }
}

}  // namespace

Value Value::array() {
  Value v;
  v.type_ = Type::Array;
  return v;
}

Value Value::object() {
  Value v;
  v.type_ = Type::Object;
  return v;
}

const Value& Value::null_value() {
  static const Value kNull;
  return kNull;
}

bool Value::parse(const std::string& text, Value& out, std::string& err) {
  Parser p(text);
  return p.parse(out, err);
}

std::string Value::serialize() const {
  std::string out;
  serialize_value(*this, out);
  return out;
}

}  // namespace json
}  // namespace aihub
