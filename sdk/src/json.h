// 极简 JSON 读写（内部实现，零第三方依赖）。够用域：Hub API 载荷 + 队列持久化。
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace aihub {
namespace json {

class Value {
 public:
  enum class Type { Null, Bool, Int, Double, String, Array, Object };

  Value() = default;
  Value(std::nullptr_t) {}
  Value(bool b) : type_(Type::Bool), bool_(b) {}
  Value(int v) : type_(Type::Int), int_(v) {}
  Value(long v) : type_(Type::Int), int_(v) {}
  Value(long long v) : type_(Type::Int), int_(v) {}
  Value(double v) : type_(Type::Double), dbl_(v) {}
  Value(const char* s) : type_(Type::String), str_(s ? s : "") {}
  Value(std::string s) : type_(Type::String), str_(std::move(s)) {}

  static Value array();
  static Value object();

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::Null; }
  bool is_bool() const { return type_ == Type::Bool; }
  bool is_int() const { return type_ == Type::Int; }
  bool is_double() const { return type_ == Type::Double; }
  bool is_number() const { return type_ == Type::Int || type_ == Type::Double; }
  bool is_string() const { return type_ == Type::String; }
  bool is_array() const { return type_ == Type::Array; }
  bool is_object() const { return type_ == Type::Object; }

  bool as_bool(bool def = false) const { return is_bool() ? bool_ : def; }
  int64_t as_int(int64_t def = 0) const {
    if (type_ == Type::Int) return int_;
    if (type_ == Type::Double) return static_cast<int64_t>(dbl_);
    return def;
  }
  double as_double(double def = 0.0) const {
    if (type_ == Type::Double) return dbl_;
    if (type_ == Type::Int) return static_cast<double>(int_);
    return def;
  }
  const std::string& as_string() const { return str_; }

  // ---- array
  void push_back(Value v) {
    type_ = Type::Array;
    arr_.push_back(std::move(v));
  }
  size_t size() const { return is_array() ? arr_.size() : (is_object() ? obj_.size() : 0); }
  const Value& at(size_t i) const {
    if (!is_array() || i >= arr_.size()) return null_value();
    return arr_[i];
  }
  const std::vector<Value>& items() const { return arr_; }

  // ---- object
  Value& set(const std::string& key, Value v) {
    type_ = Type::Object;
    obj_[key] = std::move(v);
    return *this;
  }
  const Value* find(const std::string& key) const {
    if (!is_object()) return nullptr;
    auto it = obj_.find(key);
    return it == obj_.end() ? nullptr : &it->second;
  }
  bool has(const std::string& key) const { return find(key) != nullptr; }
  const std::map<std::string, Value>& members() const { return obj_; }

  // ---- parse / serialize
  // 解析失败返回 false 并写 err；文本必须是单个完整 JSON 值。
  static bool parse(const std::string& text, Value& out, std::string& err);
  std::string serialize() const;

  static const Value& null_value();

 private:
  Type type_ = Type::Null;
  bool bool_ = false;
  int64_t int_ = 0;
  double dbl_ = 0.0;
  std::string str_;
  std::vector<Value> arr_;
  std::map<std::string, Value> obj_;
};

}  // namespace json
}  // namespace aihub
