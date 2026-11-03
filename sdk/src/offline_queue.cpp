// 离线队列：SQLite 文件队列。断网入队、联网补传、失败静默重试。
// 策略：
//   - FIFO 补传，遇可重试错误（network/timeout/5xx/429/auth）即停并留队（保序）；
//   - 永久 4xx（400/422/409 等）丢弃该条后继续，避免死循环；
//   - push 条目持久化原 push_id，重试幂等（服务端 duplicate 去重，不重复累加）。
#include "ai_hub_client/ai_hub_client.h"

#include <sqlite3.h>

#include <ctime>

#include "json.h"
#include "serialize.h"

namespace aihub {

using json::Value;

struct OfflineQueue::Impl {
  sqlite3* db = nullptr;
  std::string path;
};

namespace {

Status io_error(const std::string& what, sqlite3* db) {
  Status s;
  s.code = Error::QueueIo;
  s.message = what + (db ? std::string(": ") + sqlite3_errmsg(db) : "");
  return s;
}

int64_t now_ms() {
  return static_cast<int64_t>(time(nullptr)) * 1000;
}

}  // namespace

OfflineQueue::OfflineQueue(const std::string& db_path) : impl_(new Impl) {
  impl_->path = db_path;
  if (sqlite3_open(db_path.c_str(), &impl_->db) != SQLITE_OK) {
    // db 可能为 nullptr 或半开；留给 enqueue 报错
    return;
  }
  sqlite3_exec(impl_->db,
               "CREATE TABLE IF NOT EXISTS queue("
               " id INTEGER PRIMARY KEY AUTOINCREMENT,"
               " kind TEXT NOT NULL,"
               " payload TEXT NOT NULL,"
               " push_id TEXT,"
               " attempts INTEGER NOT NULL DEFAULT 0,"
               " created_at INTEGER NOT NULL)",
               nullptr, nullptr, nullptr);
}

OfflineQueue::~OfflineQueue() {
  if (impl_) {
    if (impl_->db) sqlite3_close(impl_->db);
    delete impl_;
  }
}

Status OfflineQueue::enqueue_push(const PushPayload& payload) {
  if (!impl_ || !impl_->db) return io_error("queue not open", nullptr);
  PushPayload p = payload;
  if (p.push_id.empty()) p.push_id = HubClient::make_push_id();
  std::string json = ser::push_payload_to_json(p).serialize();

  sqlite3_stmt* stmt = nullptr;
  if (sqlite3_prepare_v2(impl_->db,
                         "INSERT INTO queue(kind, payload, push_id, attempts, created_at)"
                         " VALUES('push', ?, ?, 0, ?)",
                         -1, &stmt, nullptr) != SQLITE_OK) {
    return io_error("prepare failed", impl_->db);
  }
  sqlite3_bind_text(stmt, 1, json.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, p.push_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 3, now_ms());
  Status st;
  if (sqlite3_step(stmt) != SQLITE_DONE) st = io_error("insert failed", impl_->db);
  sqlite3_finalize(stmt);
  return st;
}

Status OfflineQueue::enqueue_ingest(const InteractionEvent& event) {
  if (!impl_ || !impl_->db) return io_error("queue not open", nullptr);
  std::string json = ser::event_to_json(event).serialize();

  sqlite3_stmt* stmt = nullptr;
  if (sqlite3_prepare_v2(impl_->db,
                         "INSERT INTO queue(kind, payload, push_id, attempts, created_at)"
                         " VALUES('ingest', ?, NULL, 0, ?)",
                         -1, &stmt, nullptr) != SQLITE_OK) {
    return io_error("prepare failed", impl_->db);
  }
  sqlite3_bind_text(stmt, 1, json.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 2, now_ms());
  Status st;
  if (sqlite3_step(stmt) != SQLITE_DONE) st = io_error("insert failed", impl_->db);
  sqlite3_finalize(stmt);
  return st;
}

size_t OfflineQueue::pending() const {
  if (!impl_ || !impl_->db) return 0;
  sqlite3_stmt* stmt = nullptr;
  size_t n = 0;
  if (sqlite3_prepare_v2(impl_->db, "SELECT COUNT(*) FROM queue", -1, &stmt, nullptr) ==
      SQLITE_OK) {
    if (sqlite3_step(stmt) == SQLITE_ROW) n = static_cast<size_t>(sqlite3_column_int64(stmt, 0));
    sqlite3_finalize(stmt);
  }
  return n;
}

std::vector<QueueItem> OfflineQueue::items() const {
  std::vector<QueueItem> out;
  if (!impl_ || !impl_->db) return out;
  sqlite3_stmt* stmt = nullptr;
  if (sqlite3_prepare_v2(impl_->db,
                         "SELECT id, kind, payload, push_id, attempts, created_at"
                         " FROM queue ORDER BY id",
                         -1, &stmt, nullptr) != SQLITE_OK) {
    return out;
  }
  while (sqlite3_step(stmt) == SQLITE_ROW) {
    QueueItem it;
    it.id = sqlite3_column_int64(stmt, 0);
    it.kind = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
    const char* payload = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
    it.payload_json = payload ? payload : "";
    const char* pid = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3));
    it.push_id = pid ? pid : "";
    it.attempts = sqlite3_column_int(stmt, 4);
    it.created_at = sqlite3_column_int64(stmt, 5);
    out.push_back(std::move(it));
  }
  sqlite3_finalize(stmt);
  return out;
}

OfflineQueue::FlushReport OfflineQueue::flush(HubClient& client) {
  FlushReport report;
  if (!impl_ || !impl_->db) {
    report.kept = pending();
    report.last_error = io_error("queue not open", nullptr);
    return report;
  }

  while (true) {
    // 取队首
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(impl_->db,
                           "SELECT id, kind, payload, push_id FROM queue ORDER BY id LIMIT 1",
                           -1, &stmt, nullptr) != SQLITE_OK) {
      report.last_error = io_error("prepare failed", impl_->db);
      report.kept = pending();
      return report;
    }
    QueueItem item;
    bool have = false;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      have = true;
      item.id = sqlite3_column_int64(stmt, 0);
      item.kind = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
      const char* payload = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
      item.payload_json = payload ? payload : "";
      const char* pid = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3));
      item.push_id = pid ? pid : "";
    }
    sqlite3_finalize(stmt);
    if (!have) break;  // 队列清空

    // 发送
    Status st;
    bool sent = false;
    if (item.kind == "push") {
      Value v;
      std::string err;
      PushPayload p;
      if (!Value::parse(item.payload_json, v, err) ||
          !ser::push_payload_from_json(v, &p, &err)) {
        st.code = Error::Parse;
        st.message = "corrupt queue payload: " + err;
      } else {
        p.push_id = item.push_id;  // 幂等键沿用
        auto res = client.push(p);
        st = res.status;
        sent = st.ok();
      }
    } else if (item.kind == "ingest") {
      Value v;
      std::string err;
      InteractionEvent e;
      if (!Value::parse(item.payload_json, v, err) ||
          !ser::event_from_json(v, &e, &err)) {
        st.code = Error::Parse;
        st.message = "corrupt queue payload: " + err;
      } else {
        auto res = client.ingest(e);
        st = res.status;
        sent = st.ok();
      }
    } else {
      st.code = Error::Parse;
      st.message = "unknown queue kind: " + item.kind;
    }

    auto delete_item = [&]() {
      sqlite3_stmt* d = nullptr;
      if (sqlite3_prepare_v2(impl_->db, "DELETE FROM queue WHERE id=?", -1, &d, nullptr) ==
          SQLITE_OK) {
        sqlite3_bind_int64(d, 1, item.id);
        sqlite3_step(d);
        sqlite3_finalize(d);
      }
    };
    auto bump_attempts = [&]() {
      sqlite3_stmt* d = nullptr;
      if (sqlite3_prepare_v2(impl_->db,
                             "UPDATE queue SET attempts=attempts+1 WHERE id=?", -1, &d,
                             nullptr) == SQLITE_OK) {
        sqlite3_bind_int64(d, 1, item.id);
        sqlite3_step(d);
        sqlite3_finalize(d);
      }
    };

    if (sent) {
      delete_item();
      ++report.sent;
      continue;
    }

    report.last_error = st;
    if (st.retryable() || st.code == Error::QueueIo) {
      // 静默留队（attempts 留痕），下次补传；保序即停
      bump_attempts();
      report.kept = pending();
      return report;
    }
    // 永久失败（4xx/Parse/InvalidArgument）：丢弃，避免死循环
    delete_item();
    ++report.dropped;
  }
  return report;
}

}  // namespace aihub
