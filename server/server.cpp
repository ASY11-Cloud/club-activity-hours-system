// ============================================================================
// 社团活动报名与学时认定系统 —— 自主 C++ Web 服务器
// ----------------------------------------------------------------------------
// 功能:
//  1) 手写 HTTP 服务器 (Winsock, bind 0.0.0.0, 多线程, 不依赖任何 Web 框架)
//  2) 服务端 MySQL 存储: 活动 / 报名 / 学时汇总 / 请求日志
//  3) 活动发布、报名(幂等)、服务端审核、审核通过自动累计学时、学时统计报表
//  4) 实时请求日志(内存环形缓冲 + MySQL request_log 表)
//  5) ESP32 刷卡签到接口(嵌入式扩展项)
//
// 编译(Windows + MinGW-w64):
//  g++ -std=c++17 -O2 server.cpp -o server.exe ^
//      -I "C:\Program Files\MySQL\MySQL Server 8.0\include" ^
//      -L "C:\Program Files\MySQL\MySQL Server 8.0\lib" -lmysql -lws2_32
//  (将 libmysql.dll 等复制到 server.exe 同级目录)
//
// 运行: server.exe [port] [db_user] [db_pass] [db_host]   默认端口 8000
// ============================================================================

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <mysql.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

using std::string;
using std::vector;
using std::pair;

// ---------------------------- 配置 ------------------------------------------
static int    g_port    = 8000;
static string g_db_host = "127.0.0.1";
static string g_db_user = "root";
static string g_db_pass = "123456";
static string g_db_name = "club_system";

// 内存请求日志上限
static const size_t LOG_CAP = 500;

// ---------------------------- 登录会话(Token) ---------------------------------
// 登录成功后签发随机 Token, 客户端请求头携带 "Authorization: Bearer <token>",
// 服务端按 Token 识别角色: admin(管理员) / student(普通成员), 管理接口只放行管理员。
struct TokenInfo {
  string role;          // "admin" | "student"
  string name;          // 姓名
  string stu_no;        // 学号(管理员为 admin 账号)
  long long expire_ms;  // 过期时间戳(毫秒)
};
static std::map<string, TokenInfo> g_tokens;
static std::mutex              g_tokens_mtx;
static const long long TOKEN_TTL_MS = 24LL * 3600 * 1000; // 24 小时

static string genToken() {
  static std::mt19937 rng((unsigned)std::chrono::system_clock::now().time_since_epoch().count()
                          ^ (unsigned)GetCurrentProcessId());
  const char* hex = "0123456789abcdef";
  string t(32, '0');
  for (int i = 0; i < 32; i++) t[i] = hex[rng() % 16];
  return t;
}

static long long nowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
           std::chrono::system_clock::now().time_since_epoch()).count();
}


// ---------------------------- 轻量 JSON --------------------------------------
struct Json {
  enum Type { NUL, BOOL, NUM, STR, ARR, OBJ } t = NUL;
  bool        b = false;
  double      num = 0;
  string      str;
  vector<Json>          arr;
  vector<pair<string, Json>> obj;

  static Json Null()        { return Json(); }
  static Json Bool(bool v)  { Json j; j.t = BOOL; j.b = v; return j; }
  static Json Num(double v) { Json j; j.t = NUM; j.num = v; return j; }
  static Json Str(const string& v) { Json j; j.t = STR; j.str = v; return j; }
  static Json Array()       { Json j; j.t = ARR; return j; }
  static Json Object()      { Json j; j.t = OBJ; return j; }

  void push(const Json& v)        { arr.push_back(v); }
  Json& set(const string& k, const Json& v) { obj.push_back({k, v}); return *this; }

  const Json* get(const string& k) const {
    if (t != OBJ) return nullptr;
    for (auto& p : obj) if (p.first == k) return &p.second;
    return nullptr;
  }
  string strVal(const string& k, const string& dflt = "") const {
    const Json* p = get(k);
    if (!p) return dflt;
    if (p->t == STR) return p->str;
    if (p->t == NUM) return std::to_string(p->num);
    return dflt;
  }
  double numVal(const string& k, double dflt = 0) const {
    const Json* p = get(k);
    return (p && p->t == NUM) ? p->num : dflt;
  }
  int intVal(const string& k, int dflt = 0) const {
    return (int)numVal(k, dflt);
  }
};

// --- 字符串转义(JSON) ---
static string jsonEscape(const string& s) {
  string o;
  o.reserve(s.size() + 16);
  for (unsigned char c : s) {
    switch (c) {
      case '"':  o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n";  break;
      case '\r': o += "\\r";  break;
      case '\t': o += "\\t";  break;
      default:
        if (c < 0x20) {
          char buf[8]; snprintf(buf, sizeof(buf), "\\u%04x", c); o += buf;
        } else o += (char)c;
    }
  }
  return o;
}

// --- JSON 序列化 ---
static string jsonDump(const Json& j) {
  switch (j.t) {
    case Json::NUL:  return "null";
    case Json::BOOL: return j.b ? "true" : "false";
    case Json::NUM: {
      char buf[64];
      if (j.num == (long long)j.num)
        snprintf(buf, sizeof(buf), "%lld", (long long)j.num);
      else
        snprintf(buf, sizeof(buf), "%.6f", j.num);
      return buf;
    }
    case Json::STR:  return "\"" + jsonEscape(j.str) + "\"";
    case Json::ARR: {
      string o = "[";
      for (size_t i = 0; i < j.arr.size(); i++) {
        if (i) o += ",";
        o += jsonDump(j.arr[i]);
      }
      return o + "]";
    }
    case Json::OBJ: {
      string o = "{";
      for (size_t i = 0; i < j.obj.size(); i++) {
        if (i) o += ",";
        o += "\"" + jsonEscape(j.obj[i].first) + "\":" + jsonDump(j.obj[i].second);
      }
      return o + "}";
    }
  }
  return "null";
}

// --- JSON 解析(递归下降, 支持 UTF-8 字符串) ---
class JsonParser {
public:
  explicit JsonParser(const string& s) : s_(s), i_(0) {}

  bool parse(Json& out) {
    skipWs();
    if (!parseValue(out)) return false;
    skipWs();
    return i_ >= s_.size();
  }

private:
  const string& s_;
  size_t i_;

  void skipWs() { while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) i_++; }

  bool parseValue(Json& out) {
    if (i_ >= s_.size()) return false;
    char c = s_[i_];
    if (c == '{') return parseObject(out);
    if (c == '[') return parseArray(out);
    if (c == '"') return parseString(out);
    if (c == 't') { out = Json::Bool(true);  i_ += 4; return true; }
    if (c == 'f') { out = Json::Bool(false); i_ += 5; return true; }
    if (c == 'n') { out = Json::Null();      i_ += 4; return true; }
    return parseNumber(out);
  }

  bool parseObject(Json& out) {
    out = Json::Object();
    i_++; // {
    skipWs();
    if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
    while (i_ < s_.size()) {
      skipWs();
      if (i_ >= s_.size() || s_[i_] != '"') return false;
      string key;
      if (!parseStringRaw(key)) return false;
      skipWs();
      if (i_ >= s_.size() || s_[i_] != ':') return false;
      i_++;
      skipWs();
      Json v;
      if (!parseValue(v)) return false;
      out.set(key, v);
      skipWs();
      if (i_ >= s_.size()) return false;
      if (s_[i_] == ',') { i_++; continue; }
      if (s_[i_] == '}') { i_++; return true; }
      return false;
    }
    return false;
  }

  bool parseArray(Json& out) {
    out = Json::Array();
    i_++; // [
    skipWs();
    if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
    while (i_ < s_.size()) {
      skipWs();
      Json v;
      if (!parseValue(v)) return false;
      out.push(v);
      skipWs();
      if (i_ >= s_.size()) return false;
      if (s_[i_] == ',') { i_++; continue; }
      if (s_[i_] == ']') { i_++; return true; }
      return false;
    }
    return false;
  }

  bool parseString(Json& out) {
    string v;
    if (!parseStringRaw(v)) return false;
    out = Json::Str(v);
    return true;
  }

  bool parseStringRaw(string& out) {
    if (i_ >= s_.size() || s_[i_] != '"') return false;
    i_++;
    out.clear();
    while (i_ < s_.size()) {
      unsigned char c = s_[i_];
      if (c == '"') { i_++; return true; }
      if (c == '\\') {
        i_++;
        if (i_ >= s_.size()) return false;
        char e = s_[i_];
        switch (e) {
          case '"':  out += '"';  break;
          case '\\': out += '\\'; break;
          case '/':  out += '/';  break;
          case 'b':  out += '\b'; break;
          case 'f':  out += '\f'; break;
          case 'n':  out += '\n'; break;
          case 'r':  out += '\r'; break;
          case 't':  out += '\t'; break;
          case 'u': {
            if (i_ + 4 >= s_.size()) return false;
            unsigned code = 0;
            for (int k = 1; k <= 4; k++) {
              char h = s_[i_ + k];
              code <<= 4;
              if (h >= '0' && h <= '9') code |= (unsigned)(h - '0');
              else if (h >= 'a' && h <= 'f') code |= (unsigned)(h - 'a' + 10);
              else if (h >= 'A' && h <= 'F') code |= (unsigned)(h - 'A' + 10);
              else return false;
            }
            i_ += 4;
            // 仅处理 BMP 字符(业务数据均为中文/ASCII)
            if (code < 0x80) out += (char)code;
            else if (code < 0x800) {
              out += (char)(0xC0 | (code >> 6));
              out += (char)(0x80 | (code & 0x3F));
            } else {
              out += (char)(0xE0 | (code >> 12));
              out += (char)(0x80 | ((code >> 6) & 0x3F));
              out += (char)(0x80 | (code & 0x3F));
            }
            break;
          }
          default: return false;
        }
        i_++;
      } else {
        out += (char)c;
        i_++;
      }
    }
    return false;
  }

  bool parseNumber(Json& out) {
    size_t start = i_;
    if (i_ < s_.size() && (s_[i_] == '-' || s_[i_] == '+')) i_++;
    while (i_ < s_.size() && (isdigit((unsigned char)s_[i_]) || s_[i_] == '.' || s_[i_] == 'e' || s_[i_] == 'E' || s_[i_] == '-' || s_[i_] == '+')) i_++;
    if (i_ == start) return false;
    out = Json::Num(atof(s_.substr(start, i_ - start).c_str()));
    return true;
  }
};

// ---------------------------- URL 编解码 ------------------------------------
static unsigned char hexVal(char c) {
  if (c >= '0' && c <= '9') return (unsigned char)(c - '0');
  if (c >= 'a' && c <= 'f') return (unsigned char)(c - 'a' + 10);
  if (c >= 'A' && c <= 'F') return (unsigned char)(c - 'A' + 10);
  return 0;
}

static string urlDecode(const string& s) {
  string o;
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '%' && i + 2 < s.size()) {
      o += (char)((hexVal(s[i + 1]) << 4) | hexVal(s[i + 2]));
      i += 2;
    } else if (s[i] == '+') {
      o += ' ';
    } else {
      o += s[i];
    }
  }
  return o;
}

// ---------------------------- MySQL 封装 -------------------------------------
static MYSQL* dbConnect() {
  MYSQL* c = mysql_init(nullptr);
  if (!c) return nullptr;
  mysql_options(c, MYSQL_SET_CHARSET_NAME, "utf8mb4");
  if (!mysql_real_connect(c, g_db_host.c_str(), g_db_user.c_str(), g_db_pass.c_str(),
                          g_db_name.c_str(), 3306, nullptr, 0)) {
    mysql_close(c);
    return nullptr;
  }
  mysql_query(c, "SET NAMES utf8mb4");
  return c;
}

struct QueryResult {
  vector<string>          cols;
  vector<vector<string>>  rows;
};

// 执行查询并取回全部结果; 返回 false 时 err 中有 MySQL 错误信息
static bool dbQuery(MYSQL* c, const string& sql, QueryResult& out, string& err) {
  if (mysql_real_query(c, sql.c_str(), (unsigned long)sql.size()) != 0) {
    err = mysql_error(c);
    return false;
  }
  MYSQL_RES* res = mysql_store_result(c);
  if (!res) {
    if (mysql_field_count(c) == 0) return true; // 非 SELECT
    err = mysql_error(c);
    return false;
  }
  unsigned n = mysql_num_fields(res);
  MYSQL_FIELD* fields = mysql_fetch_fields(res);
  out.cols.clear(); out.rows.clear();
  for (unsigned i = 0; i < n; i++) out.cols.push_back(fields[i].name);
  MYSQL_ROW row;
  while ((row = mysql_fetch_row(res))) {
    unsigned long* lens = mysql_fetch_lengths(res);
    vector<string> r;
    for (unsigned i = 0; i < n; i++) {
      r.push_back(row[i] ? string(row[i], lens[i]) : "");
    }
    out.rows.push_back(std::move(r));
  }
  mysql_free_result(res);
  return true;
}

static string dbEscape(MYSQL* c, const string& s) {
  if (s.empty()) return "''";
  string o(s.size() * 2 + 8, '\0');
  unsigned long n = mysql_real_escape_string(c, &o[0], s.c_str(), (unsigned long)s.size());
  o.resize(n);
  return "'" + o + "'";
}

// ---------------------------- 内存请求日志 -----------------------------------
struct LogEntry {
  long long ms;      // 时间戳(ms)
  string    method, path, ip, detail;
  int       status = 200;
  int       cost = 0;
};

static std::deque<LogEntry>    g_logs;
static std::mutex              g_logs_mtx;

static void logPush(const LogEntry& e) {
  std::lock_guard<std::mutex> lk(g_logs_mtx);
  g_logs.push_front(e);
  if (g_logs.size() > LOG_CAP) g_logs.pop_back();
}

// ---------------------------- HTTP 请求结构 ----------------------------------
struct HttpRequest {
  string method, path, query, body, ip;
  string header(const string& name) const {
    // 简单小写匹配
    string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    auto it = headers.find(lower);
    return it == headers.end() ? "" : it->second;
  }
  std::map<string, string> headers;
};

// ---------------------------- 登录会话(Token) ---------------------------------
/** 从请求头取 "Bearer <token>" */
static string bearerToken(const HttpRequest& req) {
  string auth = req.header("Authorization");
  if (auth.size() > 7 && auth.compare(0, 7, "Bearer ") == 0) return auth.substr(7);
  return "";
}

/** 校验 Token, 成功填充用户信息 */
static bool authToken(const HttpRequest& req, TokenInfo& out) {
  string tok = bearerToken(req);
  if (tok.empty()) return false;
  std::lock_guard<std::mutex> lk(g_tokens_mtx);
  auto it = g_tokens.find(tok);
  if (it == g_tokens.end()) return false;
  if (nowMs() > it->second.expire_ms) { g_tokens.erase(it); return false; }
  out = it->second;
  return true;
}

// ---------------------------- HTTP 响应 --------------------------------------
static string httpResponse(int code, const string& body, const string& ctype = "application/json; charset=utf-8") {
  std::ostringstream os;
  os << "HTTP/1.1 " << code << " " << (code == 200 ? "OK" : (code == 404 ? "Not Found" : "Error")) << "\r\n"
     << "Content-Type: " << ctype << "\r\n"
     << "Content-Length: " << body.size() << "\r\n"
     << "Access-Control-Allow-Origin: *\r\n"
     << "Access-Control-Allow-Methods: GET,POST,OPTIONS\r\n"
     << "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
     << "Connection: close\r\n"
     << "\r\n"
     << body;
  return os.str();
}

static string jsonOk(const Json& data) {
  Json j = Json::Object();
  j.set("code", Json::Num(0));
  j.set("msg", Json::Str("ok"));
  j.set("data", data);
  return httpResponse(200, jsonDump(j));
}

static string jsonErr(int code, const string& msg) {
  Json j = Json::Object();
  j.set("code", Json::Num(code));
  j.set("msg", Json::Str(msg));
  j.set("data", Json::Null());
  return httpResponse(200, jsonDump(j));
}

// 循环发送, 保证大响应完整写出(单次 send 可能部分发送)
static void sendAll(SOCKET sock, const string& data) {
  size_t off = 0;
  while (off < data.size()) {
    int n = send(sock, data.c_str() + off, (int)(data.size() - off), 0);
    if (n <= 0) break;
    off += (size_t)n;
  }
}

// ---------------------------- 业务处理 ---------------------------------------
static string nowStr() {
  time_t t = time(nullptr);
  struct tm* tp = localtime(&t);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", tp);
  return buf;
}

/** 毫秒时间戳 -> "YYYY-MM-DD HH:MM:SS.mmm"(本地时区), 用于请求日志显示真实时间 */
static string fmtMs(long long ms) {
  time_t sec = (time_t)(ms / 1000);
  struct tm* tp = localtime(&sec);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", tp);
  char out[40];
  snprintf(out, sizeof(out), "%s.%03lld", buf, ms % 1000);
  return out;
}

/** 解析 "YYYY-MM-DD HH:MM[:SS]" -> 本地时间戳(毫秒); 非法(含日期归一化)返回 0 */
static long long parseLocalTime(const string& s) {
  int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
  char extra = 0;
  int n = sscanf(s.c_str(), "%d-%d-%d %d:%d:%d%c", &y, &mo, &d, &h, &mi, &se, &extra);
  if (n == 6) { /* 已含秒 */ }
  else {
    se = 0;
    if (sscanf(s.c_str(), "%d-%d-%d %d:%d%c", &y, &mo, &d, &h, &mi, &extra) != 5) return 0;
  }
  if (y < 2000 || y > 2100 || mo < 1 || mo > 12 || d < 1 || d > 31 ||
      h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 59) return 0;
  struct tm t {};
  t.tm_year = y - 1900; t.tm_mon = mo - 1; t.tm_mday = d;
  t.tm_hour = h; t.tm_min = mi; t.tm_sec = se;
  time_t ts = mktime(&t);
  if (ts == (time_t)-1) return 0;
  // 反向校验: 防止 2026-13-99 / 2026-02-30 被 mktime 静默归一化
  struct tm* back = localtime(&ts);
  if (back->tm_year != t.tm_year || back->tm_mon != t.tm_mon || back->tm_mday != t.tm_mday ||
      back->tm_hour != t.tm_hour || back->tm_min != t.tm_min || back->tm_sec != t.tm_sec) return 0;
  return (long long)ts * 1000;
}

// 登录: {type: admin|student, account, secret}
//   admin  -> account=管理员账号, secret=密码 (查 admin_user 表)
//   student-> account=学号,      secret=姓名 (查 student 表)
// 成功签发 Token, 返回 {token, role, name, stu_no}
static string handleLogin(const Json& body) {
  string type = body.strVal("type");
  string account = body.strVal("account");
  string secret = body.strVal("secret");
  if (type != "admin" && type != "student")
    return jsonErr(400, "type must be admin|student");
  if (account.empty() || secret.empty())
    return jsonErr(400, "account/secret required");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string err;
  QueryResult r;
  TokenInfo ti;
  if (type == "admin") {
    if (!dbQuery(c, "SELECT username,name FROM admin_user WHERE username=" + dbEscape(c, account) +
                    " AND password=" + dbEscape(c, secret), r, err)) {
      mysql_close(c); return jsonErr(500, err);
    }
    if (r.rows.empty()) { mysql_close(c); return jsonErr(401, "管理员账号或密码错误"); }
    ti.role = "admin";
    ti.name = r.rows[0][1];
    ti.stu_no = account;
  } else {
    if (!dbQuery(c, "SELECT stu_no,name FROM student WHERE stu_no=" + dbEscape(c, account) +
                    " AND name=" + dbEscape(c, secret), r, err)) {
      mysql_close(c); return jsonErr(500, err);
    }
    if (r.rows.empty()) { mysql_close(c); return jsonErr(401, "学号或姓名错误"); }
    ti.role = "student";
    ti.name = r.rows[0][1];
    ti.stu_no = r.rows[0][0];
  }
  mysql_close(c);

  string token = genToken();
  ti.expire_ms = nowMs() + TOKEN_TTL_MS;
  { std::lock_guard<std::mutex> lk(g_tokens_mtx); g_tokens[token] = ti; }

  Json data = Json::Object();
  data.set("token", Json::Str(token));
  data.set("role", Json::Str(ti.role));
  data.set("name", Json::Str(ti.name));
  data.set("stu_no", Json::Str(ti.stu_no));
  return jsonOk(data);
}

// 统一权限错误
static string needLogin() { return jsonErr(401, "未登录或登录已过期, 请先登录"); }
static string needAdmin() { return jsonErr(403, "无权限: 该操作仅限管理员"); }
static string needStudent() { return jsonErr(403, "无权限: 该操作仅限普通成员"); }

// 活动列表(含报名人数)
static string handleActivityList() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string sql =
    "SELECT a.id,a.title,a.content,a.location,"
    "DATE_FORMAT(a.start_time,'%Y-%m-%d %H:%i:%s') AS start_time,"
    "DATE_FORMAT(a.end_time,'%Y-%m-%d %H:%i:%s') AS end_time,"
    "a.hours,a.capacity,a.publisher,a.status,a.created_at,"
    "COUNT(s.id) AS signed_count, "
    "SUM(CASE WHEN s.status=1 THEN 1 ELSE 0 END) AS passed_count "
    "FROM activity a LEFT JOIN signup s ON a.id=s.activity_id "
    "WHERE a.status=1 GROUP BY a.id ORDER BY a.created_at DESC";
  QueryResult r;
  string err;
  if (!dbQuery(c, sql, r, err)) { mysql_close(c); return jsonErr(500, err); }
  Json arr = Json::Array();
  for (auto& row : r.rows) {
    Json o = Json::Object();
    o.set("id", Json::Num(atol(row[0].c_str())));
    o.set("title", Json::Str(row[1]));
    o.set("content", Json::Str(row[2]));
    o.set("location", Json::Str(row[3]));
    o.set("start_time", Json::Str(row[4]));
    o.set("end_time", Json::Str(row[5]));
    o.set("hours", Json::Num(atof(row[6].c_str())));
    o.set("capacity", Json::Num(atol(row[7].c_str())));
    o.set("publisher", Json::Str(row[8]));
    o.set("signed_count", Json::Num(row[11].empty() ? 0 : atol(row[11].c_str())));
    o.set("passed_count", Json::Num(row[12].empty() ? 0 : atol(row[12].c_str())));
    arr.push(o);
  }
  mysql_close(c);
  Json data = Json::Object();
  data.set("list", arr);
  return jsonOk(data);
}

// 发布活动
static string handleActivityAdd(const Json& body) {
  string title = body.strVal("title");
  if (title.empty()) return jsonErr(400, "title required");
  string content = body.strVal("content");
  string location = body.strVal("location");
  string startTime = body.strVal("start_time");
  string endTime = body.strVal("end_time");
  // 时间规范化: "YYYY-MM-DD HH:MM" -> "YYYY-MM-DD HH:MM:SS"
  auto norm = [](const string& s) -> string {
    if (s.size() == 16 && s[10] == ' ') return s + ":00";
    return s;
  };
  startTime = norm(startTime);
  endTime = norm(endTime);
  // 合法性校验(滚轮选择之外的兜底): 格式 / 前后关系 / 数值范围 / 长度
  long long sTs = startTime.empty() ? 0 : parseLocalTime(startTime);
  long long eTs = endTime.empty() ? 0 : parseLocalTime(endTime);
  if (!startTime.empty() && sTs == 0)
    return jsonErr(400, "start_time 格式应为 YYYY-MM-DD HH:MM");
  if (!endTime.empty() && eTs == 0)
    return jsonErr(400, "end_time 格式应为 YYYY-MM-DD HH:MM");
  if (sTs > 0 && eTs > 0 && eTs <= sTs)
    return jsonErr(400, "结束时间必须晚于开始时间");
  if (sTs > 0 && sTs < nowMs())
    return jsonErr(400, "开始时间不能早于当前时间");
  double hours = body.numVal("hours", 1.0);
  int capacity = body.intVal("capacity", 0);
  if (hours <= 0 || hours > 999) return jsonErr(400, "hours 应在 (0,999] 范围内");
  if (capacity < 0 || capacity > 99999) return jsonErr(400, "capacity 应在 [0,99999] 范围内");
  string publisher = body.strVal("publisher");
  // 长度截断, 防止超长内容破坏数据
  if (title.size() > 100) title = title.substr(0, 100);
  if (content.size() > 2000) content = content.substr(0, 2000);
  if (location.size() > 100) location = location.substr(0, 100);
  if (publisher.size() > 50) publisher = publisher.substr(0, 50);

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  std::ostringstream sql;
  sql << "INSERT INTO activity (title,content,location,start_time,end_time,hours,capacity,publisher,status) VALUES ("
      << dbEscape(c, title) << ","
      << dbEscape(c, content) << ","
      << dbEscape(c, location) << ","
      << (startTime.empty() ? "NULL" : dbEscape(c, startTime)) << ","
      << (endTime.empty() ? "NULL" : dbEscape(c, endTime)) << ","
      << hours << ","
      << capacity << ","
      << dbEscape(c, publisher) << ",1)";
  string err;
  QueryResult r;
  if (!dbQuery(c, sql.str(), r, err)) { mysql_close(c); return jsonErr(500, err); }
  long long id = (long long)mysql_insert_id(c);
  mysql_close(c);
  Json data = Json::Object();
  data.set("id", Json::Num((double)id));
  return jsonOk(data);
}

// 报名(幂等: client_id / (activity,stu) 冲突时视为已报名)
// 报名(身份以登录 Token 为准, 忽略请求体中的学号/姓名防伪造)
static string handleSignupAdd(const Json& body, const string& loginStuNo, const string& loginName) {
  string clientId = body.strVal("client_id");
  int activityId = body.intVal("activity_id", -1);
  if (clientId.empty() || activityId <= 0)
    return jsonErr(400, "client_id/activity_id required");
  string stuNo = loginStuNo;
  string name = loginName;

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string err;
  QueryResult r;

  // 校验活动
  if (!dbQuery(c, "SELECT id,capacity,hours,status FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    mysql_close(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { mysql_close(c); return jsonErr(404, "activity not found"); }
  int cap = atoi(r.rows[0][1].c_str());
  int actStatus = atoi(r.rows[0][3].c_str());
  if (actStatus != 1) { mysql_close(c); return jsonErr(400, "activity not open"); }

  // 事务化报名: 容量检查+插入+复检, 保证并发下不超员
  mysql_autocommit(c, 0);
  // 容量检查(事务内行读)
  if (cap > 0) {
    QueryResult r2;
    if (!dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(activityId), r2, err)) {
      mysql_rollback(c); mysql_autocommit(c, 1); mysql_close(c); return jsonErr(500, err);
    }
    int cnt = atoi(r2.rows[0][0].c_str());
    if (cnt >= cap) {
      mysql_rollback(c); mysql_autocommit(c, 1); mysql_close(c);
      return jsonErr(403, "activity full");
    }
  }

  // 幂等插入: client_id 冲突时保留原记录(本地 SQLite 同步匹配), 仅取回 id;
  // 同一学生重复报名(uk_act_stu 冲突)时: 已驳回记录重置为待审核(重新报名), 其余状态保持不变
  std::ostringstream sql;
  sql << "INSERT INTO signup (client_id,activity_id,stu_no,name,status) VALUES ("
      << dbEscape(c, clientId) << ","
      << activityId << ","
      << dbEscape(c, stuNo) << ","
      << dbEscape(c, name) << ",0) "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),client_id=VALUES(client_id),"
      << "status=IF(status=2,0,status),name=VALUES(name),remark=''";
  if (!dbQuery(c, sql.str(), r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); mysql_close(c); return jsonErr(500, err);
  }
  long long id = (long long)mysql_insert_id(c);

  // 插入后复检容量(并发窗口保护), 超员则回滚
  if (cap > 0) {
    QueryResult r3;
    if (!dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(activityId), r3, err) ||
        atoi(r3.rows[0][0].c_str()) > cap) {
      mysql_rollback(c); mysql_autocommit(c, 1); mysql_close(c);
      return jsonErr(403, "activity full");
    }
  }
  mysql_commit(c);
  mysql_autocommit(c, 1);

  // 返回该记录真实状态(重复报名时可能是已通过/已驳回, 不再恒写 0)
  int realStatus = 0;
  QueryResult r4;
  if (dbQuery(c, "SELECT status FROM signup WHERE id=" + std::to_string(id), r4, err) && !r4.rows.empty())
    realStatus = atoi(r4.rows[0][0].c_str());
  mysql_close(c);
  Json data = Json::Object();
  data.set("id", Json::Num((double)id));
  data.set("status", Json::Num(realStatus));
  return jsonOk(data);
}

// 报名列表(按活动或按学号; 学生身份强制只看自己的记录)
static string handleSignupList(const string& query, const string& forceStuNo) {
  int activityId = 0;
  string stuNo = forceStuNo;   // 学生: 服务端强制本人, 忽略 query 中的 stu_no
  int stuFilter = forceStuNo.empty() ? 0 : 1;
  // 解析 query: activity_id= / stu_no= (仅管理员可用 stu_no 过滤)
  size_t p = 0;
  while (p < query.size()) {
    size_t amp = query.find('&', p);
    string kv = query.substr(p, amp == string::npos ? string::npos : amp - p);
    size_t eq = kv.find('=');
    if (eq != string::npos) {
      string k = urlDecode(kv.substr(0, eq));
      string v = urlDecode(kv.substr(eq + 1));
      if (k == "activity_id") activityId = atoi(v.c_str());
      else if (k == "stu_no" && forceStuNo.empty()) { stuNo = v; stuFilter = 1; }
    }
    if (amp == string::npos) break;
    p = amp + 1;
  }

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string cond;
  if (activityId > 0) cond += " AND s.activity_id=" + std::to_string(activityId);
  if (stuFilter) cond += " AND s.stu_no=" + dbEscape(c, stuNo);
  string sql =
    "SELECT s.id,s.client_id,s.activity_id,s.stu_no,s.name,s.status,s.checkin,"
    "s.card_no,s.hours,s.remark,DATE_FORMAT(s.created_at,'%Y-%m-%d %H:%i:%s'),"
    "DATE_FORMAT(s.audited_at,'%Y-%m-%d %H:%i:%s'),a.title "
    "FROM signup s LEFT JOIN activity a ON s.activity_id=a.id "
    "WHERE 1=1" + cond + " ORDER BY s.id DESC";
  QueryResult r;
  string err;
  if (!dbQuery(c, sql, r, err)) { mysql_close(c); return jsonErr(500, err); }
  Json arr = Json::Array();
  for (auto& row : r.rows) {
    Json o = Json::Object();
    o.set("id", Json::Num(atol(row[0].c_str())));
    o.set("client_id", Json::Str(row[1]));
    o.set("activity_id", Json::Num(atol(row[2].c_str())));
    o.set("stu_no", Json::Str(row[3]));
    o.set("name", Json::Str(row[4]));
    o.set("status", Json::Num(atol(row[5].c_str())));
    o.set("checkin", Json::Num(atol(row[6].c_str())));
    o.set("card_no", Json::Str(row[7]));
    o.set("hours", Json::Num(atof(row[8].c_str())));
    o.set("remark", Json::Str(row[9]));
    o.set("created_at", Json::Str(row[10]));
    o.set("audited_at", Json::Str(row[11]));
    o.set("activity_title", Json::Str(row[12]));
    arr.push(o);
  }
  mysql_close(c);
  Json data = Json::Object();
  data.set("list", arr);
  return jsonOk(data);
}

// 审核报名: {signup_id, action: pass|reject, remark}
static string handleSignupAudit(const Json& body) {
  int signupId = body.intVal("signup_id", -1);
  string action = body.strVal("action");
  string remark = body.strVal("remark");
  if (remark.size() > 200) remark = remark.substr(0, 200); // 长度截断
  if (signupId <= 0 || (action != "pass" && action != "reject"))
    return jsonErr(400, "signup_id & action(pass|reject) required");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string err;
  QueryResult r;

  // 读报名与活动学时
  string sql = "SELECT s.stu_no,s.name,s.status,a.hours,s.activity_id FROM signup s "
               "LEFT JOIN activity a ON s.activity_id=a.id WHERE s.id=" + std::to_string(signupId);
  if (!dbQuery(c, sql, r, err)) { mysql_close(c); return jsonErr(500, err); }
  if (r.rows.empty()) { mysql_close(c); return jsonErr(404, "signup not found"); }
  string stuNo = r.rows[0][0], name = r.rows[0][1];
  int curStatus = atoi(r.rows[0][2].c_str());
  double actHours = atof(r.rows[0][3].c_str());
  string actId = r.rows[0][4];

  // 已审核记录禁止重复操作, 防止 hours_total 与 signup 状态不一致
  if (curStatus != 0) { mysql_close(c); return jsonErr(400, "该记录已审核, 不能重复操作"); }

  mysql_autocommit(c, 0);
  bool ok = true;
  if (action == "pass") {
    // 1) 更新报名状态+学时
    std::ostringstream s1;
    s1 << "UPDATE signup SET status=1,hours=" << actHours
       << ",audited_at=NOW(),remark=" << dbEscape(c, remark)
       << " WHERE id=" << signupId;
    if (!dbQuery(c, s1.str(), r, err)) ok = false;
    // 2) 学时汇总自动累计
    if (ok) {
      std::ostringstream s2;
      s2 << "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) VALUES ("
         << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << actHours << ",1) "
         << "ON DUPLICATE KEY UPDATE total_hours=total_hours+VALUES(total_hours),"
         << "sign_count=sign_count+1,name=VALUES(name)";
      if (!dbQuery(c, s2.str(), r, err)) ok = false;
    }
  } else { // reject
    std::ostringstream s1;
    s1 << "UPDATE signup SET status=2,hours=0,audited_at=NOW(),remark="
       << dbEscape(c, remark) << " WHERE id=" << signupId;
    if (!dbQuery(c, s1.str(), r, err)) ok = false;
  }

  if (ok) {
    mysql_commit(c);
  } else {
    mysql_rollback(c);
  }
  mysql_autocommit(c, 1);
  mysql_close(c);
  if (!ok) return jsonErr(500, err);
  Json data = Json::Object();
  data.set("signup_id", Json::Num(signupId));
  data.set("action", Json::Str(action));
  data.set("hours", Json::Num(action == "pass" ? actHours : 0));
  return jsonOk(data);
}

// 学时统计报表(排行公开给登录用户; 明细: 管理员全量 / 学生仅本人)
static string handleHoursReport(const string& role, const string& stuNo) {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  QueryResult r;
  string err;
  string sql = "SELECT stu_no,name,total_hours,sign_count,updated_at FROM hours_total "
               "ORDER BY total_hours DESC, sign_count DESC";
  if (!dbQuery(c, sql, r, err)) { mysql_close(c); return jsonErr(500, err); }
  Json arr = Json::Array();
  int rank = 0;
  for (auto& row : r.rows) {
    rank++;
    Json o = Json::Object();
    o.set("rank", Json::Num(rank));
    o.set("stu_no", Json::Str(row[0]));
    o.set("name", Json::Str(row[1]));
    o.set("total_hours", Json::Num(atof(row[2].c_str())));
    o.set("sign_count", Json::Num(atol(row[3].c_str())));
    o.set("updated_at", Json::Str(row[4]));
    arr.push(o);
  }
  // 已通过报名明细(学生仅本人; 管理员全量)
  string cond = " WHERE s.status=1";
  if (role == "student") cond += " AND s.stu_no=" + dbEscape(c, stuNo);
  QueryResult d;
  string sql2 = "SELECT s.stu_no,s.name,a.title,s.hours,DATE_FORMAT(s.audited_at,'%Y-%m-%d %H:%i:%s') "
                "FROM signup s LEFT JOIN activity a ON s.activity_id=a.id" + cond +
                " ORDER BY s.audited_at DESC";
  Json detail = Json::Array();
  if (dbQuery(c, sql2, d, err)) {
    for (auto& row : d.rows) {
      Json o = Json::Object();
      o.set("stu_no", Json::Str(row[0]));
      o.set("name", Json::Str(row[1]));
      o.set("activity", Json::Str(row[2]));
      o.set("hours", Json::Num(atof(row[3].c_str())));
      o.set("audited_at", Json::Str(row[4]));
      detail.push(o);
    }
  }
  mysql_close(c);
  Json data = Json::Object();
  data.set("report", arr);
  data.set("detail", detail);
  return jsonOk(data);
}

// ESP32 刷卡签到: {card_no, activity_id}
// 按卡号匹配学生 -> 找到该活动报名:
//   报名不存在 -> 自动创建并通过(到场认定学时)
//   报名待审核 -> 置为通过并认定学时 + 标记签到
//   已通过     -> 仅标记签到
static string handleSignin(const Json& body) {
  string cardNo = body.strVal("card_no");
  int activityId = body.intVal("activity_id", -1);
  if (cardNo.empty() || activityId <= 0)
    return jsonErr(400, "card_no & activity_id required");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "db connect failed");
  string err;
  QueryResult r;

  // 1) 卡号找学生
  if (!dbQuery(c, "SELECT stu_no,name FROM student WHERE card_no=" + dbEscape(c, cardNo), r, err)) {
    mysql_close(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { mysql_close(c); return jsonErr(404, "card not bound"); }
  string stuNo = r.rows[0][0], name = r.rows[0][1];

  // 2) 活动学时与状态(已下线活动不可刷卡认定学时)
  if (!dbQuery(c, "SELECT hours,status FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    mysql_close(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { mysql_close(c); return jsonErr(404, "activity not found"); }
  double actHours = atof(r.rows[0][0].c_str());
  int actStatus = atoi(r.rows[0][1].c_str());
  if (actStatus != 1) { mysql_close(c); return jsonErr(400, "activity not open"); }

  // 3) 查该学生该活动报名
  if (!dbQuery(c, "SELECT id,status,checkin FROM signup WHERE activity_id=" + std::to_string(activityId) +
                  " AND stu_no=" + dbEscape(c, stuNo), r, err)) {
    mysql_close(c); return jsonErr(500, err);
  }
  int signupId = 0, st = 0;
  if (!r.rows.empty()) {
    signupId = atoi(r.rows[0][0].c_str());
    st = atoi(r.rows[0][1].c_str());
  }

  mysql_autocommit(c, 0);
  bool ok = true;
  bool needAccumulate = false; // 仅当本次操作使其首次通过/认定时才累计学时
  string clientId = "rfid-" + cardNo + "-" + std::to_string(activityId);
  if (signupId == 0) {
    // 无报名: 创建并通过
    std::ostringstream s;
    s << "INSERT INTO signup (client_id,activity_id,stu_no,name,status,checkin,card_no,hours,audited_at) VALUES ("
      << dbEscape(c, clientId) << "," << activityId << ","
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << ",1,1,"
      << dbEscape(c, cardNo) << "," << actHours << ",NOW()) "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),checkin=1,card_no=VALUES(card_no),hours=VALUES(hours)";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else needAccumulate = true;
  } else if (st == 0) {
    // 待审核 -> 通过 + 签到
    std::ostringstream s;
    s << "UPDATE signup SET status=1,checkin=1,card_no=" << dbEscape(c, cardNo)
      << ",hours=" << actHours << ",audited_at=NOW() WHERE id=" << signupId;
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else needAccumulate = true;
  } else if (st == 1) {
    // 已通过 -> 仅签到(不重复累计学时)
    std::ostringstream s;
    s << "UPDATE signup SET checkin=1,card_no=" << dbEscape(c, cardNo) << " WHERE id=" << signupId;
    if (!dbQuery(c, s.str(), r, err)) ok = false;
  } else {
    // 已驳回 -> 重新通过并认定学时(到场认定)
    std::ostringstream s;
    s << "UPDATE signup SET status=1,checkin=1,card_no=" << dbEscape(c, cardNo)
      << ",hours=" << actHours << ",audited_at=NOW() WHERE id=" << signupId;
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else needAccumulate = true;
  }

  // 学时汇总累计(仅首次认定)
  if (ok && needAccumulate) {
    std::ostringstream s;
    s << "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) VALUES ("
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << actHours << ",1) "
      << "ON DUPLICATE KEY UPDATE total_hours=total_hours+VALUES(total_hours),"
      << "sign_count=sign_count+1,name=VALUES(name)";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
  }

  if (ok) mysql_commit(c); else mysql_rollback(c);
  mysql_autocommit(c, 1);
  mysql_close(c);
  if (!ok) return jsonErr(500, err);
  Json data = Json::Object();
  data.set("stu_no", Json::Str(stuNo));
  data.set("name", Json::Str(name));
  data.set("activity_id", Json::Num(activityId));
  data.set("hours", Json::Num(actHours));
  data.set("checkin", Json::Num(1));
  return jsonOk(data);
}

// 实时请求日志
static string handleLogs(const string& query) {
  int limit = 50;
  size_t p = query.find("limit=");
  if (p != string::npos) {
    string v = query.substr(p + 6);
    size_t amp = v.find('&');
    if (amp != string::npos) v = v.substr(0, amp);
    limit = atoi(v.c_str());
  }
  if (limit <= 0 || limit > 500) limit = 50;

  std::lock_guard<std::mutex> lk(g_logs_mtx);
  Json arr = Json::Array();
  int n = 0;
  for (auto& e : g_logs) {
    if (n >= limit) break;
    Json o = Json::Object();
    o.set("time", Json::Str(fmtMs(e.ms)));
    o.set("method", Json::Str(e.method));
    o.set("path", Json::Str(e.path));
    o.set("ip", Json::Str(e.ip));
    o.set("status", Json::Num(e.status));
    o.set("cost_ms", Json::Num(e.cost));
    o.set("detail", Json::Str(e.detail));
    arr.push(o);
    n++;
  }
  Json data = Json::Object();
  data.set("total", Json::Num((double)g_logs.size()));
  data.set("logs", arr);
  return jsonOk(data);
}

// ---------------------------- 请求分发 ---------------------------------------
// 从响应 JSON 中提取业务 code 作为日志状态
static int extractCode(const string& resp) {
  size_t p = resp.find("\"code\":");
  if (p == string::npos) return 200;
  p += 7;
  while (p < resp.size() && resp[p] == ' ') p++;
  int code = atoi(resp.c_str() + p);
  return code <= 0 ? 200 : code;
}

static string route(const HttpRequest& req) {
  string p = req.path;
  // 去掉末尾 /
  while (p.size() > 1 && p.back() == '/') p.pop_back();

  if (p == "/api/health") {
    Json d = Json::Object();
    d.set("server", Json::Str("club-system-server"));
    d.set("time", Json::Str(nowStr()));
    return jsonOk(d);
  }

  // CORS 预检(OPTIONS 无鉴权, 提前处理; 供浏览器/调试工具跨域使用)
  if (req.method == "OPTIONS")
    return httpResponse(200, "", "text/plain");

  // ---- 登录(公开) ----
  if (req.method == "POST" && p == "/api/login") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleLogin(body);
  }

  // ESP32 刷卡签到: 读卡终端无登录态, 按卡号识别, 保持公开
  if (req.method == "POST" && p == "/api/signin") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignin(body);
  }

  // ---- 以下接口全部需要登录 ----
  TokenInfo me;
  if (!authToken(req, me)) return needLogin();

  // 发布活动: 仅管理员
  if (req.method == "POST" && p == "/api/activity/add") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleActivityAdd(body);
  }

  if (req.method == "GET" && p == "/api/activity/list")
    return handleActivityList();

  // 报名: 仅普通成员, 身份强制为登录者
  if (req.method == "POST" && p == "/api/signup/add") {
    if (me.role != "student") return needStudent();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignupAdd(body, me.stu_no, me.name);
  }

  // 报名列表: 管理员全量(可用 stu_no/activity_id 过滤), 学生仅本人
  if (req.method == "GET" && p == "/api/signup/list") {
    if (me.role == "admin") return handleSignupList(req.query, "");
    return handleSignupList("", me.stu_no);
  }

  // 审核: 仅管理员(通过自动累计学时)
  if (req.method == "POST" && p == "/api/signup/audit") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignupAudit(body);
  }

  // 学时报表: 排行公开, 明细按角色
  if (req.method == "GET" && p == "/api/hours/report")
    return handleHoursReport(me.role, me.stu_no);

  // 服务器实时请求日志: 仅管理员
  if (req.method == "GET" && p == "/api/logs") {
    if (me.role != "admin") return needAdmin();
    return handleLogs(req.query);
  }

  return httpResponse(404, jsonDump(Json::Object()
    .set("code", Json::Num(404)).set("msg", Json::Str("not found"))));
}

// ---------------------------- 单连接处理 -------------------------------------
static void handleClient(SOCKET sock, const string& ip) {
  auto t0 = std::chrono::steady_clock::now();
  string resp;
  int status = 500;
  string detail;
  HttpRequest req;
  req.ip = ip;

  char buf[8192];
  string raw;
  // 读请求头
  while (raw.find("\r\n\r\n") == string::npos) {
    int n = recv(sock, buf, sizeof(buf), 0);
    if (n <= 0) break;
    raw.append(buf, n);
    if (raw.size() > 64 * 1024) break;
  }
  size_t hdrEnd = raw.find("\r\n\r\n");
  if (hdrEnd == string::npos) { closesocket(sock); return; }

  // 请求行
  std::istringstream head(raw.substr(0, hdrEnd));
  string line;
  std::getline(head, line);
  std::istringstream reqline(line);
  reqline >> req.method >> req.path;
  if (req.path.find('?') != string::npos) {
    size_t q = req.path.find('?');
    req.query = req.path.substr(q + 1);
    req.path = req.path.substr(0, q);
  }
  while (std::getline(head, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    size_t colon = line.find(':');
    if (colon != string::npos) {
      string k = line.substr(0, colon), v = line.substr(colon + 1);
      while (!v.empty() && v[0] == ' ') v.erase(v.begin());
      std::transform(k.begin(), k.end(), k.begin(), ::tolower);
      req.headers[k] = v;
    }
  }
  // 请求体(限制大小, 防恶意大包撑爆内存)
  string cl = req.header("Content-Length");
  if (!cl.empty()) {
    size_t need = (size_t)atol(cl.c_str());
    if (need > 64 * 1024) {
      // 先读完请求体再响应, 避免连接上残留数据导致对端收到 RST 而读不到 413
      size_t got = 0;
      char tmp[4096];
      while (got < need) {
        int n = recv(sock, tmp, sizeof(tmp), 0);
        if (n <= 0) break;
        got += (size_t)n;
      }
      sendAll(sock, httpResponse(413, jsonDump(Json::Object()
        .set("code", Json::Num(413)).set("msg", Json::Str("request body too large")))));
      closesocket(sock);
      return;
    }
    string bodyPart = raw.substr(hdrEnd + 4);
    while (bodyPart.size() < need) {
      int n = recv(sock, buf, sizeof(buf), 0);
      if (n <= 0) break;
      bodyPart.append(buf, n);
    }
    req.body = bodyPart.substr(0, need);
  }

  // 分发
  try {
    resp = route(req);
    status = extractCode(resp);
    detail = req.method + " " + req.path + (req.query.empty() ? "" : "?" + req.query);
    if (detail.size() > 480) detail = detail.substr(0, 480); // 适配日志列宽
  } catch (...) {
    resp = jsonErr(500, "internal error");
    status = 500;
  }

  // 发送
  sendAll(sock, resp);
  closesocket(sock);

  auto t1 = std::chrono::steady_clock::now();
  int cost = (int)std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();

  // 控制台(英文, 避免控制台编码问题) + 内存日志
  LogEntry le;
  le.ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
  le.method = req.method; le.path = req.path; le.ip = ip;
  le.status = status; le.cost = cost; le.detail = detail;
  logPush(le);
  std::cout << "[" << nowStr() << "] " << req.method << " " << req.path
            << " from " << ip << " -> " << status << " (" << cost << "ms)\n";

  // 异步写 MySQL 日志表(不阻塞响应)
  std::thread([=]() {
    MYSQL* c = dbConnect();
    if (!c) return;
    string err; QueryResult r;
    std::ostringstream sql;
    sql << "INSERT INTO request_log (method,path,query,ip,status,cost_ms,detail) VALUES ("
        << dbEscape(c, le.method) << "," << dbEscape(c, le.path) << ","
        << dbEscape(c, req.query) << "," << dbEscape(c, le.ip) << ","
        << le.status << "," << le.cost << "," << dbEscape(c, le.detail) << ")";
    dbQuery(c, sql.str(), r, err);
    mysql_close(c);
  }).detach();
}

// ---------------------------- 主程序 -----------------------------------------
int main(int argc, char* argv[]) {
  if (argc > 1) g_port = atoi(argv[1]);
  if (argc > 2) g_db_user = argv[2];
  if (argc > 3) g_db_pass = argv[3];
  if (argc > 4) g_db_host = argv[4];

  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    std::cerr << "WSAStartup failed\n"; return 1;
  }

  // 预热: 验证 MySQL 连接
  {
    MYSQL* c = dbConnect();
    if (!c) {
      std::cerr << "MySQL connect failed: host=" << g_db_host << " user=" << g_db_user
                << " db=" << g_db_name << " 请先执行 init_db.sql\n";
      WSACleanup();
      return 1;
    }
    mysql_close(c);
  }

  SOCKET listenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listenSock == INVALID_SOCKET) {
    std::cerr << "socket failed: " << WSAGetLastError() << "\n";
    WSACleanup(); return 1;
  }
  int reuse = 1;
  setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY); // bind 0.0.0.0, 宿主机局域网可访问
  addr.sin_port = htons((u_short)g_port);
  if (bind(listenSock, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
    std::cerr << "bind 0.0.0.0:" << g_port << " failed: " << WSAGetLastError() << "\n";
    closesocket(listenSock); WSACleanup(); return 1;
  }
  if (listen(listenSock, SOMAXCONN) == SOCKET_ERROR) {
    std::cerr << "listen failed\n"; closesocket(listenSock); WSACleanup(); return 1;
  }

  std::cout << "==========================================================\n";
  std::cout << "  Club System Server  (社团活动报名与学时认定系统)\n";
  std::cout << "  Listen 0.0.0.0:" << g_port << "\n";
  std::cout << "  MySQL  " << g_db_host << ":3306 / " << g_db_name << "\n";
  std::cout << "==========================================================\n";

  while (true) {
    sockaddr_in client{};
    int len = sizeof(client);
    SOCKET sock = accept(listenSock, (sockaddr*)&client, &len);
    if (sock == INVALID_SOCKET) {
      if (WSAGetLastError() == WSAEINTR) continue;
      std::cerr << "accept failed: " << WSAGetLastError() << "\n";
      continue;
    }
    char* ipc = inet_ntoa(client.sin_addr);
    string ip = ipc ? ipc : "0.0.0.0";
    std::thread(handleClient, sock, ip).detach();
  }

  closesocket(listenSock);
  WSACleanup();
  return 0;
}
