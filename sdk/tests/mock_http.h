// 本地 mock HTTP 服务器（测试用）：127.0.0.1 随机端口，handler 回调产响应。
#pragma once

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <functional>
#include <string>
#include <thread>

namespace mockhttp {

struct Request {
  std::string method;
  std::string path;
  std::string body;
  std::string authorization;
};

struct Response {
  int status = 200;
  std::string content_type = "application/json";
  std::string body;
};

class Server {
 public:
  using Handler = std::function<Response(const Request&)>;

  explicit Server(Handler handler) : handler_(std::move(handler)) {
    fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) return;
    socklen_t len = sizeof(addr);
    getsockname(fd_, reinterpret_cast<sockaddr*>(&addr), &len);
    port_ = ntohs(addr.sin_port);
    ::listen(fd_, 16);
    running_ = true;
    thread_ = std::thread([this] { loop(); });
  }

  ~Server() {
    running_ = false;
    if (fd_ >= 0) {
      ::shutdown(fd_, SHUT_RDWR);
      ::close(fd_);
    }
    if (thread_.joinable()) thread_.join();
  }

  int port() const { return port_; }
  std::string base_url() const {
    return "http://127.0.0.1:" + std::to_string(port_);
  }

 private:
  void loop() {
    while (running_) {
      int c = ::accept(fd_, nullptr, nullptr);
      if (c < 0) break;
      std::string req = read_request(c);
      if (req.empty()) {
        ::close(c);
        continue;
      }
      Request r = parse(req);
      Response resp = handler_ ? handler_(r) : Response{};
      std::string out = "HTTP/1.1 " + std::to_string(resp.status) + " X\r\n" +
                        "Content-Type: " + resp.content_type + "\r\n" +
                        "Content-Length: " + std::to_string(resp.body.size()) + "\r\n" +
                        "Connection: close\r\n\r\n" + resp.body;
      ::send(c, out.data(), out.size(), 0);
      ::close(c);
    }
  }

  static std::string read_request(int c) {
    std::string data;
    char buf[4096];
    size_t header_end = std::string::npos;
    size_t content_length = 0;
    while (true) {
      ssize_t n = ::recv(c, buf, sizeof(buf), 0);
      if (n <= 0) return "";
      data.append(buf, static_cast<size_t>(n));
      if (header_end == std::string::npos) {
        header_end = data.find("\r\n\r\n");
        if (header_end == std::string::npos) continue;
        size_t cl = data.find("Content-Length:");
        if (cl == std::string::npos) cl = data.find("content-length:");
        if (cl != std::string::npos && cl < header_end) {
          content_length = strtoul(data.c_str() + cl + 15, nullptr, 10);
        }
      }
      if (data.size() >= header_end + 4 + content_length) break;
    }
    return data;
  }

  static Request parse(const std::string& raw) {
    Request r;
    size_t line_end = raw.find("\r\n");
    std::string line = raw.substr(0, line_end);
    size_t sp1 = line.find(' ');
    size_t sp2 = line.find(' ', sp1 + 1);
    if (sp1 != std::string::npos && sp2 != std::string::npos) {
      r.method = line.substr(0, sp1);
      r.path = line.substr(sp1 + 1, sp2 - sp1 - 1);
    }
    size_t auth = raw.find("Authorization:");
    size_t header_end = raw.find("\r\n\r\n");
    if (auth != std::string::npos && auth < header_end) {
      size_t eol = raw.find("\r\n", auth);
      std::string v = raw.substr(auth + 14, eol - auth - 14);
      while (!v.empty() && v[0] == ' ') v.erase(0, 1);
      r.authorization = v;
    }
    if (header_end != std::string::npos) r.body = raw.substr(header_end + 4);
    return r;
  }

  Handler handler_;
  int fd_ = -1;
  int port_ = 0;
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}  // namespace mockhttp
