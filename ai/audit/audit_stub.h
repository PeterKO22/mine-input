/*
 * audit_stub.h — 审计日志接口桩（FR6：只记字段不记全文，W3）
 *
 * AuditSink 的内存桩实现：只接收 AuditRecord（结构上不含全文），环形保留
 * 最近 capacity 条，供单元测试断言与上层查询；真实落盘实现（SQLite/文件，
 * §8.2 交互日志 30 天滚动）后续替换，接口不变（换实现零改动）。
 */
#ifndef MINE_INPUT_AI_AUDIT_AUDIT_STUB_H_
#define MINE_INPUT_AI_AUDIT_AUDIT_STUB_H_

#include <cstddef>
#include <mutex>
#include <vector>

#include "ai/spi/ai_assist.h"

namespace mine {
namespace ai {

class MemoryAuditSink final : public AuditSink {
 public:
  explicit MemoryAuditSink(std::size_t capacity = 256) : capacity_(capacity) {}

  void record(const AuditRecord& rec) override {
    std::lock_guard<std::mutex> lock(mu_);
    if (records_.size() >= capacity_) {
      records_.erase(records_.begin());  // 环形：丢最旧
    }
    records_.push_back(rec);
  }

  std::vector<AuditRecord> snapshot() const {
    std::lock_guard<std::mutex> lock(mu_);
    return records_;
  }

  std::size_t size() const {
    std::lock_guard<std::mutex> lock(mu_);
    return records_.size();
  }

 private:
  std::size_t capacity_;
  mutable std::mutex mu_;
  std::vector<AuditRecord> records_;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_AUDIT_AUDIT_STUB_H_
