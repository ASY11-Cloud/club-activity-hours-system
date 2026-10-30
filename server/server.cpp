// ============================================================================
// 社团活动报名与学时认定系统 —— 自主 C++ Web 服务器
// ----------------------------------------------------------------------------
// 功能:
//  1) 手写 HTTP 服务器 (Winsock, bind 0.0.0.0, 多线程, 不依赖任何 Web 框架)
//     · 支持 keep-alive 连接复用(单连接最多 128 个请求, 空闲 10s 关闭)
//  2) 服务端 MySQL 存储: 活动 / 报名 / 学时汇总 / 请求日志 / 系统配置
//     · 连接池(最多 16 条空闲连接复用, mysql_ping 探活, 失效自动重建)
//  3) 活动发布/编辑/上下线、报名(幂等)、服务端审核、审核通过自动累计学时、学时统计报表
//  4) 实时请求日志(内存环形缓冲 + MySQL request_log 表, 支持筛选与按天/条数自动清理)
//  5) ESP32 刷卡签到接口(嵌入式扩展项, 可选用 X-Device-Key 校验)
//  6) 管理员口令加盐 SHA-256 存储; 登录失败节流; Token 会话 24 小时
//
// 编译(Windows + MinGW-w64):
//  g++ -std=c++14 -O2 server.cpp -o server.exe ^
//      -I "C:\Program Files\MySQL\MySQL Server 8.0\include" ^
//      -L "C:\Program Files\MySQL\MySQL Server 8.0\lib" -lmysql -lws2_32
//  (将 libmysql.dll 等复制到 server.exe 同级目录)
//
// 运行: server.exe [port] [db_user] [db_pass] [db_host] [device_key]   默认端口 8000
//       device_key 可选, 非空时 /api/signin 必须携带 X-Device-Key 头(也可用环境变量 CLUB_DEVICE_KEY)
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

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")   // MSVC 自动链接; MinGW 由 -lws2_32 指定
#endif

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

// RFID 读卡终端共享密钥: 非空时 /api/signin 必须携带 "X-Device-Key" 请求头,
// 防止局域网内任意设备伪造卡号刷学时。默认为空(=不校验, 保持原有演示行为),
// 可通过第 5 个启动参数或环境变量 CLUB_DEVICE_KEY 启用; 启用后 ESP32 固件需同步发送该头。
static string g_device_key;

// 登录失败节流: 同一账号 60 秒内连续失败 5 次后暂时拒绝, 防止口令暴力猜测
struct LoginFail { int count = 0; long long first_ms = 0; };
static std::map<string, LoginFail> g_login_fail;
static std::mutex g_login_mtx;
static const int       LOGIN_FAIL_MAX       = 5;
static const long long LOGIN_FAIL_WINDOW_MS = 60LL * 1000;

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

// ---------------------------- 口令哈希(SHA-256) --------------------------------
// 管理员口令不再明文入库: 库中保存 "sha256:<64位十六进制>", 值为 SHA256(盐 + 口令)。
// 兼容旧数据: 若库中仍是明文, 登录成功后自动升级为哈希; 启动时也会全表迁移一次。
static const char* PWD_SALT = "club-system::";
static const char* PWD_PREFIX = "sha256:";

static inline uint32_t ror32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static string sha256Hex(const string& in) {
  static const uint32_t K[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
  };
  uint32_t h[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,
                   0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
  string msg = in;
  uint64_t bitLen = (uint64_t)in.size() * 8ULL;
  msg += (char)0x80;
  while (msg.size() % 64 != 56) msg += (char)0x00;
  for (int i = 7; i >= 0; i--) msg += (char)((bitLen >> (i * 8)) & 0xFF);

  for (size_t off = 0; off < msg.size(); off += 64) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
      w[i] = ((uint32_t)(unsigned char)msg[off + i * 4] << 24)
           | ((uint32_t)(unsigned char)msg[off + i * 4 + 1] << 16)
           | ((uint32_t)(unsigned char)msg[off + i * 4 + 2] << 8)
           |  (uint32_t)(unsigned char)msg[off + i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      uint32_t S1  = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
      uint32_t ch  = (e & f) ^ ((~e) & g);
      uint32_t t1  = hh + S1 + ch + K[i] + w[i];
      uint32_t S0  = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
      uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      uint32_t t2  = S0 + maj;
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  char buf[65];
  for (int i = 0; i < 8; i++) snprintf(buf + i * 8, 9, "%08x", h[i]);
  return string(buf, 64);
}

/** 明文口令 -> 入库格式(加盐哈希) */
static string pwdHash(const string& secret) {
  return string(PWD_PREFIX) + sha256Hex(string(PWD_SALT) + secret);
}

/** 库中值是否为哈希格式(旧版本为明文) */
static bool pwdIsHashed(const string& stored) {
  return stored.size() == 71 && stored.compare(0, 7, PWD_PREFIX) == 0;
}

/** 校验口令: 哈希走摘要比对, 旧明文走字符串比对(登录成功后由调用方升级) */
static bool pwdVerify(const string& stored, const string& secret) {
  if (pwdIsHashed(stored)) return stored == pwdHash(secret);
  return stored == secret;
}

/** 防时序侧信道: 常量时间比较(用于设备密钥) */
static bool constEq(const string& a, const string& b) {
  if (a.size() != b.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); i++) diff |= (unsigned char)(a[i] ^ b[i]);
  return diff == 0;
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
// 连接池: 每个请求线程从池中借用连接, 用完归还(而不是每次 connect/close)。
// MySQL 建立连接是 TCP + 认证 + 会话初始化的重操作(本机约 2~5ms), 高频请求下
// 每次新建连接会显著拖慢响应并放大 TIME_WAIT; 池化后连接可复用, 同时用
// mysql_ping 探活, 失效连接自动丢弃重建。
static std::vector<MYSQL*> g_db_pool;
static std::mutex          g_db_pool_mtx;
static const size_t        DB_POOL_MAX = 16;   // 池内空闲连接上限

/** 真正建立一条新连接(失败返回 nullptr) */
static MYSQL* dbRawConnect() {
  MYSQL* c = mysql_init(nullptr);
  if (!c) return nullptr;
  mysql_options(c, MYSQL_SET_CHARSET_NAME, "utf8mb4");
  // 连接/读写超时: 数据库卡死时不至于让工作线程永久阻塞
  unsigned int connTimeout = 5, rwTimeout = 15;
  mysql_options(c, MYSQL_OPT_CONNECT_TIMEOUT, &connTimeout);
  mysql_options(c, MYSQL_OPT_READ_TIMEOUT, &rwTimeout);
  mysql_options(c, MYSQL_OPT_WRITE_TIMEOUT, &rwTimeout);
  if (!mysql_real_connect(c, g_db_host.c_str(), g_db_user.c_str(), g_db_pass.c_str(),
                          g_db_name.c_str(), 3306, nullptr, 0)) {
    mysql_close(c);
    return nullptr;
  }
  mysql_query(c, "SET NAMES utf8mb4");
  return c;
}

/** 借用连接: 优先复用池内空闲连接(探活失败则丢弃重建) */
static MYSQL* dbConnect() {
  MYSQL* c = nullptr;
  {
    std::lock_guard<std::mutex> lk(g_db_pool_mtx);
    while (!g_db_pool.empty()) {
      c = g_db_pool.back();
      g_db_pool.pop_back();
      if (mysql_ping(c) == 0) return c;   // 连接仍可用
      mysql_close(c);                     // 已被服务端断开: 丢弃
      c = nullptr;
    }
  }
  return dbRawConnect();
}

/** 归还连接: 复位事务状态后入池; 池满则直接关闭 */
static void dbRelease(MYSQL* c) {
  if (!c) return;
  mysql_rollback(c);        // 兜底回滚(无活动事务时为无害空操作)
  mysql_autocommit(c, 1);   // 归还前必须恢复自动提交, 否则下个借用者会继承事务状态
  {
    std::lock_guard<std::mutex> lk(g_db_pool_mtx);
    if (g_db_pool.size() < DB_POOL_MAX) { g_db_pool.push_back(c); return; }
  }
  mysql_close(c);
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

// 成功但需要向用户回显具体结果(如"删除了几条数据")时使用
static string jsonOkMsg(const string& msg, const Json& data) {
  Json j = Json::Object();
  j.set("code", Json::Num(0));
  j.set("msg", Json::Str(msg));
  j.set("data", data);
  return httpResponse(200, jsonDump(j));
}

// ---- 破坏性操作的审计留痕 --------------------------------------------
// 审计说明随响应头下发, 由请求日志管线摘出并写入 detail(服务器日志页可查)。
// 刻意不用 thread_local: 本项目每个连接一个线程, MinGW 运行时在线程退出时
// 析构 thread_local 非平凡对象会导致进程崩溃(实测"服务完一个请求即死")。
static const char* AUDIT_HDR = "X-Audit-Note";

/** 把审计说明插入响应头 */
static string withAudit(const string& resp, const string& note) {
  if (note.empty()) return resp;
  size_t hp = resp.find("\r\n");            // 状态行之后插入
  if (hp == string::npos) return resp;
  return resp.substr(0, hp + 2) + AUDIT_HDR + ": " + note + "\r\n" + resp.substr(hp + 2);
}

/** 摘出并删除审计头(必须在发送响应前调用, 否则会暴露给客户端) */
static string takeAudit(string& resp) {
  const string key = string("\r\n") + AUDIT_HDR + ": ";
  size_t p = resp.find(key);
  if (p == string::npos) return "";
  size_t vs = p + key.size();
  size_t ve = resp.find("\r\n", vs);
  if (ve == string::npos) return "";
  string note = resp.substr(vs, ve - vs);
  resp.erase(p, ve - p);
  return note;
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
// localtime 返回静态缓冲区, 多线程并发调用会相互覆盖; 加锁并返回副本
static std::mutex g_time_mtx;
static struct tm localTimeSafe(time_t t) {
  std::lock_guard<std::mutex> lk(g_time_mtx);
  struct tm tmp {};
  struct tm* p = localtime(&t);
  if (p != nullptr) tmp = *p;
  return tmp;
}

static string nowStr() {
  time_t t = time(nullptr);
  struct tm tp = localTimeSafe(t);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tp);
  return buf;
}

/** 毫秒时间戳 -> "YYYY-MM-DD HH:MM:SS.mmm"(本地时区), 用于请求日志显示真实时间 */
static string fmtMs(long long ms) {
  time_t sec = (time_t)(ms / 1000);
  struct tm tp = localTimeSafe(sec);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tp);
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
  struct tm back = localTimeSafe(ts);
  if (back.tm_year != t.tm_year || back.tm_mon != t.tm_mon || back.tm_mday != t.tm_mday ||
      back.tm_hour != t.tm_hour || back.tm_min != t.tm_min || back.tm_sec != t.tm_sec) return 0;
  return (long long)ts * 1000;
}

// --- 登录失败节流(防暴力破解) ---
static bool loginBlocked(const string& key) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  auto it = g_login_fail.find(key);
  if (it == g_login_fail.end()) return false;
  if (nowMs() - it->second.first_ms > LOGIN_FAIL_WINDOW_MS) { g_login_fail.erase(it); return false; }
  return it->second.count >= LOGIN_FAIL_MAX;
}
static void loginFailAdd(const string& key) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  LoginFail& f = g_login_fail[key];
  if (f.count == 0) f.first_ms = nowMs();
  if (f.count < LOGIN_FAIL_MAX) f.count++;
}
static void loginFailClear(const string& key) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  g_login_fail.erase(key);
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

  // 同一账号连续失败过多 -> 暂时拒绝(成功登录后清零)
  string failKey = type + ":" + account;
  if (loginBlocked(failKey))
    return jsonErr(429, "登录失败次数过多, 请 60 秒后再试");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  TokenInfo ti;
  if (type == "admin") {
    // 口令不再参与 SQL 比较(明文入库+拼串既不可审计也可被注入), 取出后由程序校验摘要
    if (!dbQuery(c, "SELECT username,name,password FROM admin_user WHERE username=" +
                    dbEscape(c, account), r, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    if (r.rows.empty() || !pwdVerify(r.rows[0][2], secret)) {
      dbRelease(c);
      loginFailAdd(failKey);
      return jsonErr(401, "管理员账号或密码错误");
    }
    // 历史明文口令: 登录成功后顺手升级为加盐哈希, 无需停机改库
    if (!pwdIsHashed(r.rows[0][2])) {
      QueryResult up;
      dbQuery(c, "UPDATE admin_user SET password=" + dbEscape(c, pwdHash(secret)) +
                 " WHERE username=" + dbEscape(c, account), up, err);
    }
    ti.role = "admin";
    ti.name = r.rows[0][1];
    ti.stu_no = account;
  } else {
    if (!dbQuery(c, "SELECT stu_no,name,status FROM student WHERE stu_no=" + dbEscape(c, account) +
                    " AND name=" + dbEscape(c, secret), r, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    if (r.rows.empty()) {
      dbRelease(c);
      loginFailAdd(failKey);
      return jsonErr(401, "学号或姓名错误, 未注册请先注册");
    }
    int regStatus = atoi(r.rows[0][2].c_str());
    if (regStatus == 0) { dbRelease(c); return jsonErr(403, "注册申请审核中, 请等待管理员审核后登录"); }
    if (regStatus == 2) { dbRelease(c); return jsonErr(403, "注册申请已被驳回, 请联系管理员"); }
    ti.role = "student";
    ti.name = r.rows[0][1];
    ti.stu_no = r.rows[0][0];
  }
  dbRelease(c);
  loginFailClear(failKey);

  string token = genToken();
  ti.expire_ms = nowMs() + TOKEN_TTL_MS;
  {
    std::lock_guard<std::mutex> lk(g_tokens_mtx);
    // 顺带清理已过期的 Token, 避免长时间运行后内存只增不减
    for (auto it = g_tokens.begin(); it != g_tokens.end(); ) {
      if (nowMs() > it->second.expire_ms) it = g_tokens.erase(it);
      else ++it;
    }
    g_tokens[token] = ti;
  }

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

// 成员注册申请(公开): {stu_no, name, dept} -> 写入 student 表 status=0 等待管理员审核
static string handleRegister(const Json& body) {
  string stuNo = body.strVal("stu_no");
  string name = body.strVal("name");
  string dept = body.strVal("dept");
  if (stuNo.empty() || name.empty())
    return jsonErr(400, "学号与姓名必填");
  if (stuNo.size() > 20 || name.size() > 50 || dept.size() > 100)
    return jsonErr(400, "字段过长");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT id,status FROM student WHERE stu_no=" + dbEscape(c, stuNo), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (!r.rows.empty()) {
    int st = atoi(r.rows[0][1].c_str());
    dbRelease(c);
    if (st == 1) return jsonErr(409, "该学号已注册并通过审核, 请直接登录");
    if (st == 0) return jsonErr(409, "该学号注册申请审核中, 请勿重复提交");
    return jsonErr(409, "该学号注册曾被驳回, 请联系管理员处理");
  }
  std::ostringstream s;
  s << "INSERT INTO student (stu_no,name,dept,status) VALUES ("
    << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << dbEscape(c, dept) << ",0)";
  if (!dbQuery(c, s.str(), r, err)) { dbRelease(c); return jsonErr(500, err); }
  dbRelease(c);
  Json data = Json::Object();
  data.set("stu_no", Json::Str(stuNo));
  return jsonOk(data);
}

// 注册申请列表(仅管理员): 全部待审核注册申请
static string handleStudentRequests() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  QueryResult r;
  string err;
  string sql = "SELECT id,stu_no,name,dept,card_no,DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s') "
               "FROM student WHERE status=0 ORDER BY id DESC";
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
  Json arr = Json::Array();
  for (auto& row : r.rows) {
    Json o = Json::Object();
    o.set("id", Json::Num(atol(row[0].c_str())));
    o.set("stu_no", Json::Str(row[1]));
    o.set("name", Json::Str(row[2]));
    o.set("dept", Json::Str(row[3]));
    o.set("card_no", Json::Str(row[4]));
    o.set("created_at", Json::Str(row[5]));
    arr.push(o);
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("list", arr);
  return jsonOk(data);
}

static string qparam(const string& query, const string& key);

/**
 * 用户管理(仅管理员): 全量学生信息 + 学时汇总 + 报名统计, 支持分组/关键字/分页。
 * 分组 group:
 *   all       全部学生(默认)
 *   pending   待审核注册(status=0)
 *   approved  已通过(status=1)
 *   rejected  已驳回(status=2)
 *   achieved  已达标(total_hours>=required_hours 且 status=1)
 *   unachieved 未达标(status=1 但 total_hours<required_hours)
 * 关键字 kw: 按 学号/姓名/班级 模糊搜索(与分组同时生效)。
 * 每组返回 group_total(该分组在筛选前的总数)与 total(当前筛选后总数), 供前端分组计数。
 */
static string handleStudentList(const string& query) {
  string group = qparam(query, "group");
  string kw = qparam(query, "kw");
  if (group.empty()) group = "all";
  if (kw.size() > 50) kw = kw.substr(0, 50);
  int page = atoi(qparam(query, "page").c_str());
  int size = atoi(qparam(query, "size").c_str());
  if (page < 1) page = 1;
  if (size < 0) size = 0;
  if (size > 200) size = 200;

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;

  // 达标线(用于 achieved/unachieved 分组)
  double requiredHours = 0;
  QueryResult cf;
  if (dbQuery(c, "SELECT cfg_value FROM sys_config WHERE cfg_key='required_hours'", cf, err) && !cf.rows.empty())
    requiredHours = atof(cf.rows[0][0].c_str());

  // 基础连接: student 左连 hours_total(可能无学时记录)
  string from = " FROM student st LEFT JOIN hours_total ht ON st.stu_no=ht.stu_no";
  string where = " WHERE 1=1";
  if (group == "pending")       where += " AND st.status=0";
  else if (group == "approved") where += " AND st.status=1";
  else if (group == "rejected") where += " AND st.status=2";
  else if (group == "achieved") where += " AND st.status=1 AND COALESCE(ht.total_hours,0)>=" + std::to_string(requiredHours);
  else if (group == "unachieved") where += " AND st.status=1 AND COALESCE(ht.total_hours,0)<" + std::to_string(requiredHours);
  if (!kw.empty()) {
    string like = dbEscape(c, "%" + kw + "%");
    where += " AND (st.stu_no LIKE " + like + " OR st.name LIKE " + like +
             " OR st.dept LIKE " + like + ")";
  }

  // 各分组计数(不受 kw 影响, 用于分组标签上的数字)
  Json groupCount = Json::Object();
  auto cntWhere = [&](const string& g) -> string {
    if (g == "pending") return " WHERE status=0";
    if (g == "approved") return " WHERE status=1";
    if (g == "rejected") return " WHERE status=2";
    if (g == "achieved") return " WHERE status=1 AND stu_no IN (SELECT stu_no FROM hours_total WHERE total_hours>=" + std::to_string(requiredHours) + ")";
    if (g == "unachieved") return " WHERE status=1 AND stu_no NOT IN (SELECT stu_no FROM hours_total WHERE total_hours>=" + std::to_string(requiredHours) + ")";
    return string("");
  };
  const char* groups[6] = {"all", "pending", "approved", "rejected", "achieved", "unachieved"};
  for (int i = 0; i < 6; i++) {
    QueryResult gc;
    string w = cntWhere(groups[i]);
    string sqlc = "SELECT COUNT(*) FROM student" + w;
    long long n = 0;
    if (dbQuery(c, sqlc, gc, err) && !gc.rows.empty()) n = atol(gc.rows[0][0].c_str());
    groupCount.set(groups[i], Json::Num((double)n));
  }

  // 当前分组(带 kw)总数
  QueryResult cnt;
  long long total = 0;
  if (dbQuery(c, "SELECT COUNT(*) " + from + where, cnt, err) && !cnt.rows.empty())
    total = atol(cnt.rows[0][0].c_str());

  string sql =
    "SELECT st.id,st.stu_no,st.name,st.dept,st.card_no,st.status,"
    "DATE_FORMAT(st.created_at,'%Y-%m-%d %H:%i:%s'),"
    "COALESCE(ht.total_hours,0),COALESCE(ht.sign_count,0) " + from + where +
    " ORDER BY st.status=0 DESC, COALESCE(ht.total_hours,0) DESC, st.id ASC";
  if (size > 0) {
    std::ostringstream lim;
    lim << " LIMIT " << size << " OFFSET " << (long long)(page - 1) * size;
    sql += lim.str();
  }
  QueryResult r;
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }

  Json arr = Json::Array();
  for (auto& row : r.rows) {
    Json o = Json::Object();
    int st = atoi(row[5].c_str());
    double th = atof(row[7].c_str());
    o.set("id", Json::Num(atol(row[0].c_str())));
    o.set("stu_no", Json::Str(row[1]));
    o.set("name", Json::Str(row[2]));
    o.set("dept", Json::Str(row[3]));
    o.set("card_no", Json::Str(row[4]));
    o.set("status", Json::Num(st));
    o.set("created_at", Json::Str(row[6]));
    o.set("total_hours", Json::Num(th));
    o.set("sign_count", Json::Num(atol(row[8].c_str())));
    o.set("achieved", Json::Bool(st == 1 && requiredHours > 0 && th >= requiredHours));
    arr.push(o);
  }
  dbRelease(c);

  Json data = Json::Object();
  data.set("list", arr);
  data.set("total", Json::Num((double)total));
  data.set("group_counts", groupCount);
  data.set("required_hours", Json::Num(requiredHours));
  return jsonOk(data);
}

// 注册申请审核(仅管理员): {student_id, action: pass|reject}
static string handleStudentAudit(const Json& body) {
  int studentId = body.intVal("student_id", -1);
  string action = body.strVal("action");
  if (studentId <= 0 || (action != "pass" && action != "reject"))
    return jsonErr(400, "student_id & action(pass|reject) required");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT id,status FROM student WHERE id=" + std::to_string(studentId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "该学生不存在或已注销"); }
  if (atoi(r.rows[0][1].c_str()) != 0) { dbRelease(c); return jsonErr(400, "该申请已审核, 不能重复操作"); }
  // 条件更新(status=0) + 影响行数校验: 并发重复审核时只有一个请求生效
  std::ostringstream s;
  s << "UPDATE student SET status=" << (action == "pass" ? 1 : 2)
    << " WHERE id=" << studentId << " AND status=0";
  if (!dbQuery(c, s.str(), r, err)) { dbRelease(c); return jsonErr(500, err); }
  if (mysql_affected_rows(c) != 1) { dbRelease(c); return jsonErr(409, "该申请已被其他管理员处理, 请刷新"); }
  dbRelease(c);
  Json data = Json::Object();
  data.set("student_id", Json::Num(studentId));
  data.set("action", Json::Str(action));
  return jsonOk(data);
}

/** 取查询串参数(?a=1&b=2), 不存在返回空串 */
static string qparam(const string& query, const string& key) {
  size_t p = 0;
  while (p < query.size()) {
    size_t amp = query.find('&', p);
    string kv = query.substr(p, amp == string::npos ? string::npos : amp - p);
    size_t eq = kv.find('=');
    if (eq != string::npos && kv.compare(0, eq, key) == 0) return urlDecode(kv.substr(eq + 1));
    if (amp == string::npos) break;
    p = amp + 1;
  }
  return "";
}

// 活动列表(含报名人数): 支持分页(page/size), 管理员可带 all=1 查询含已下线活动
// =====================================================================
// 账号注销(学生自助 / 管理员操作)
// 设计要点:
//  1) signup、hours_total 都有指向 student(stu_no) 的外键且没有 ON DELETE CASCADE,
//     直接删主表会被 MySQL 拒绝(1451) -> 必须在事务内按 子表 -> 主表 的顺序删;
//  2) 删完必须让该学号的历史 token 立刻失效, 否则旧 token 仍能调接口(幽灵登录);
//  3) 破坏性操作必须可审计: 注销结果写入请求日志 detail, 服务器日志页可查。
// =====================================================================

/** 学时数值转 1 位小数字符串(4.5 而不是 4.500000) */
static string fmtHours(double v) {
  std::ostringstream os;
  os << std::fixed;
  os.precision(1);
  os << v;
  return os.str();
}

/**
 * 注销影响面(供二次确认弹窗如实告知, 不是"确定要注销吗"这种敷衍确认):
 * 学生只能查自己(忽略传入 stu_no), 管理员必须指定 stu_no。
 */
static string handleStudentImpact(const string& query, const string& role, const string& loginStuNo) {
  string stuNo = (role == "admin") ? qparam(query, "stu_no") : loginStuNo;
  if (stuNo.empty()) return jsonErr(400, "stu_no required");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  if (!dbQuery(c, "SELECT name,dept,card_no,status FROM student WHERE stu_no=" + dbEscape(c, stuNo), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "该学号不存在或已注销"); }
  string name = r.rows[0][0], dept = r.rows[0][1], cardNo = r.rows[0][2];
  int regStatus = atoi(r.rows[0][3].c_str());

  // 报名统计: 总数 / 已通过 / 待审核 / 已驳回 / 已通过记录携带的学时
  int total = 0, passed = 0, pending = 0, rejected = 0;
  double hoursSum = 0;
  QueryResult rs;
  if (dbQuery(c, "SELECT COUNT(*),"
                 "COALESCE(SUM(CASE WHEN status=1 THEN 1 ELSE 0 END),0),"
                 "COALESCE(SUM(CASE WHEN status=0 THEN 1 ELSE 0 END),0),"
                 "COALESCE(SUM(CASE WHEN status=2 THEN 1 ELSE 0 END),0),"
                 "COALESCE(SUM(CASE WHEN status=1 THEN hours ELSE 0 END),0) "
                 "FROM signup WHERE stu_no=" + dbEscape(c, stuNo), rs, err) && !rs.rows.empty()) {
    total    = atoi(rs.rows[0][0].c_str());
    passed   = atoi(rs.rows[0][1].c_str());
    pending  = atoi(rs.rows[0][2].c_str());
    rejected = atoi(rs.rows[0][3].c_str());
    hoursSum = atof(rs.rows[0][4].c_str());
  }

  // 汇总表口径(可能因历史操作与明细不一致, 一并下发便于前端如实展示)
  double hoursTotal = 0;
  int signCount = 0;
  QueryResult rh;
  if (dbQuery(c, "SELECT total_hours,sign_count FROM hours_total WHERE stu_no=" + dbEscape(c, stuNo), rh, err)
      && !rh.rows.empty()) {
    hoursTotal = atof(rh.rows[0][0].c_str());
    signCount  = atoi(rh.rows[0][1].c_str());
  }
  dbRelease(c);

  Json d = Json::Object();
  d.set("stu_no", Json::Str(stuNo));
  d.set("name", Json::Str(name));
  d.set("dept", Json::Str(dept));
  d.set("card_no", Json::Str(cardNo));
  d.set("reg_status", Json::Num(regStatus));
  d.set("signup_total", Json::Num(total));
  d.set("signup_passed", Json::Num(passed));
  d.set("signup_pending", Json::Num(pending));
  d.set("signup_rejected", Json::Num(rejected));
  d.set("hours_sum", Json::Num(hoursSum));        // 由报名明细汇总
  d.set("hours_total", Json::Num(hoursTotal));    // hours_total 表记录值
  d.set("sign_count", Json::Num(signCount));
  return jsonOk(d);
}

/**
 * 事务内级联删除学生账号: signup -> hours_total -> student。
 * 失败整体回滚, 保证"要么全删干净, 要么什么都没变"。
 * @param nSignup       出参: 被删除的报名条数
 * @param hoursDeleted  出参: 被删除的已认定学时合计
 */
static bool dbDeleteStudent(MYSQL* c, const string& stuNo,
                            int& nSignup, double& hoursDeleted, string& err) {
  nSignup = 0;
  hoursDeleted = 0;
  mysql_autocommit(c, 0);

  // 锁学生行: 串行化"学生自己点注销"与"管理员同时注销"的并发请求
  QueryResult rLock;
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, stuNo) + " FOR UPDATE", rLock, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); return false;
  }
  if (rLock.rows.empty()) {
    mysql_rollback(c); mysql_autocommit(c, 1);
    err = "该学号不存在或已注销, 请刷新";
    return false;
  }

  // 先统计(删除后就查不到了), 用于回显与审计
  QueryResult rStat;
  if (dbQuery(c, "SELECT COUNT(*),COALESCE(SUM(CASE WHEN status=1 THEN hours ELSE 0 END),0) "
                 "FROM signup WHERE stu_no=" + dbEscape(c, stuNo), rStat, err) && !rStat.rows.empty()) {
    nSignup = atoi(rStat.rows[0][0].c_str());
    hoursDeleted = atof(rStat.rows[0][1].c_str());
  }

  QueryResult r;
  // 1) 报名记录(外键指向 student 与 activity, 必须先删)
  if (!dbQuery(c, "DELETE FROM signup WHERE stu_no=" + dbEscape(c, stuNo), r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); return false;
  }
  // 2) 学时汇总(外键指向 student, 必须先删)
  if (!dbQuery(c, "DELETE FROM hours_total WHERE stu_no=" + dbEscape(c, stuNo), r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); return false;
  }
  // 3) 学生主表; 影响行数必须为 1, 否则说明已被并发删除
  if (!dbQuery(c, "DELETE FROM student WHERE stu_no=" + dbEscape(c, stuNo), r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); return false;
  }
  if (mysql_affected_rows(c) != 1) {
    mysql_rollback(c); mysql_autocommit(c, 1);
    err = "该学号已被注销, 请刷新";
    return false;
  }

  mysql_commit(c);
  mysql_autocommit(c, 1);
  return true;
}

/** 清除某个学号的全部已发 token, 返回失效数量(管理员 token 的 stu_no 是账号名, 不会被误伤) */
static int dropStudentTokens(const string& stuNo) {
  int n = 0;
  std::lock_guard<std::mutex> lk(g_tokens_mtx);
  for (auto it = g_tokens.begin(); it != g_tokens.end(); ) {
    if (it->second.role == "student" && it->second.stu_no == stuNo) { it = g_tokens.erase(it); n++; }
    else ++it;
  }
  return n;
}

/** 学生自助注销: 必须输入本人学号确认(不可逆操作, 防误触) */
static string handleStudentCancel(const Json& body, const TokenInfo& me) {
  if (me.role != "student")
    return jsonErr(403, "管理员请到「用户管理」页注销学生账号");
  string confirm = body.strVal("confirm_stu_no");
  if (confirm.empty()) return jsonErr(400, "请输入本人学号以确认注销");
  if (confirm != me.stu_no) return jsonErr(400, "学号不一致, 注销已取消");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  int n = 0;
  double hrs = 0;
  if (!dbDeleteStudent(c, me.stu_no, n, hrs, err)) { dbRelease(c); return jsonErr(409, err); }
  dbRelease(c);

  int killed = dropStudentTokens(me.stu_no);   // 含当前这次请求所用的 token

  std::ostringstream note;
  note << "AUDIT 自助注销 stu_no=" << me.stu_no << " name=" << me.name
       << " 删除报名 " << n << " 条(" << fmtHours(hrs) << " 学时) 失效token " << killed;

  Json d = Json::Object();
  d.set("stu_no", Json::Str(me.stu_no));
  d.set("name", Json::Str(me.name));
  d.set("signup_deleted", Json::Num(n));
  d.set("hours_deleted", Json::Num(hrs));
  d.set("token_revoked", Json::Num(killed));
  return withAudit(
    jsonOkMsg("账号已注销: 删除报名 " + std::to_string(n) + " 条, " + fmtHours(hrs) + " 学时", d),
    note.str());
}

/** 管理员注销指定学生账号 */
static string handleStudentDelete(const Json& body, const TokenInfo& me) {
  if (me.role != "admin") return needAdmin();
  string stuNo = body.strVal("stu_no");
  string confirm = body.strVal("confirm_stu_no");
  if (stuNo.empty()) return jsonErr(400, "stu_no required");
  if (confirm != stuNo) return jsonErr(400, "输入的学号与目标学生不一致, 注销已取消");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  int n = 0;
  double hrs = 0;
  if (!dbDeleteStudent(c, stuNo, n, hrs, err)) { dbRelease(c); return jsonErr(409, err); }
  dbRelease(c);

  int killed = dropStudentTokens(stuNo);

  std::ostringstream note;
  note << "AUDIT 管理员注销(操作者=" << me.stu_no << ") stu_no=" << stuNo
       << " 删除报名 " << n << " 条(" << fmtHours(hrs) << " 学时) 失效token " << killed;

  Json d = Json::Object();
  d.set("stu_no", Json::Str(stuNo));
  d.set("signup_deleted", Json::Num(n));
  d.set("hours_deleted", Json::Num(hrs));
  d.set("token_revoked", Json::Num(killed));
  return withAudit(
    jsonOkMsg("已注销 " + stuNo + ": 删除报名 " + std::to_string(n) + " 条, " + fmtHours(hrs) + " 学时", d),
    note.str());
}

/**
 * 管理端待办统计(仅管理员): 待审报名 / 待批注册 / 今日刷卡 / 活动总数
 * 用途: 管理 Tab 角标与主界面待办横幅 —— 审核是本系统的核心动作,
 * 不能让管理员靠"主动点进去看"才发现有活要干。
 */
static string handleStatsPending() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  long long signupPending = 0, regPending = 0, signinToday = 0, actTotal = 0;
  if (dbQuery(c, "SELECT COUNT(*) FROM signup WHERE status=0", r, err) && !r.rows.empty())
    signupPending = atol(r.rows[0][0].c_str());
  if (dbQuery(c, "SELECT COUNT(*) FROM student WHERE status=0", r, err) && !r.rows.empty())
    regPending = atol(r.rows[0][0].c_str());
  // checked_at 为空的历史数据(本版本之前刷卡)仍算已签到, 只统计今日新增
  if (dbQuery(c, "SELECT COUNT(*) FROM signup WHERE checkin=1 AND checked_at IS NOT NULL "
                 "AND DATE(checked_at)=CURDATE()", r, err) && !r.rows.empty())
    signinToday = atol(r.rows[0][0].c_str());
  if (dbQuery(c, "SELECT COUNT(*) FROM activity WHERE status=1", r, err) && !r.rows.empty())
    actTotal = atol(r.rows[0][0].c_str());
  dbRelease(c);
  Json d = Json::Object();
  d.set("signup_pending", Json::Num((double)signupPending));
  d.set("register_pending", Json::Num((double)regPending));
  d.set("signin_today", Json::Num((double)signinToday));
  d.set("activity_total", Json::Num((double)actTotal));
  d.set("total_pending", Json::Num((double)(signupPending + regPending)));
  return jsonOk(d);
}

static string handleActivityList(const string& query, const string& role) {
  bool withOffline = (role == "admin" && query.find("all=1") != string::npos);
  // 分页: size<=0 表示不分页(向后兼容, 一次返回全部); 上限 200 防止被当作全表扫描入口
  int page = atoi(qparam(query, "page").c_str());
  int size = atoi(qparam(query, "size").c_str());
  if (page < 1) page = 1;
  if (size < 0) size = 0;
  if (size > 200) size = 200;

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string where = withOffline ? "1=1" : "a.status=1";
  // 列表筛选全部在服务端执行, 保证 total 与筛选结果一致(前端过滤会与分页打架):
  //   scope=available 未结束且还有名额 / expired 已结束 / mine 我报名过的(不含已驳回)
  //   kw 按标题或地点模糊搜索
  string scope = qparam(query, "scope");
  string kw = qparam(query, "kw");
  if (kw.size() > 50) kw = kw.substr(0, 50);
  if (scope == "available") {
    where += " AND a.end_time>=NOW()";
    where += " AND (a.capacity=0 OR (SELECT COUNT(*) FROM signup s1 WHERE s1.activity_id=a.id"
             " AND s1.status<>2) < a.capacity)";
  } else if (scope == "expired") {
    where += " AND a.end_time<NOW()";
  } else if (scope == "mine") {
    string stu = qparam(query, "stu_no");
    if (!stu.empty()) {
      where += " AND a.id IN (SELECT s2.activity_id FROM signup s2 WHERE s2.stu_no=" +
               dbEscape(c, stu) + " AND s2.status<>2)";
    } else {
      where += " AND 1=0"; // 缺少学号不返回全量, 避免"我的活动"变成"全部活动"
    }
  }
  if (!kw.empty()) {
    string like = dbEscape(c, "%" + kw + "%");
    where += " AND (a.title LIKE " + like + " OR a.location LIKE " + like + ")";
  }
  QueryResult cnt;
  string err;
  long long total = 0;
  if (dbQuery(c, "SELECT COUNT(*) FROM activity a WHERE " + where, cnt, err) && !cnt.rows.empty())
    total = atol(cnt.rows[0][0].c_str());

  string sql =
    "SELECT a.id,a.title,a.content,a.location,"
    "DATE_FORMAT(a.start_time,'%Y-%m-%d %H:%i:%s') AS start_time,"
    "DATE_FORMAT(a.end_time,'%Y-%m-%d %H:%i:%s') AS end_time,"
    "a.hours,a.capacity,a.publisher,a.status,a.created_at,"
    "COUNT(s.id) AS signed_count, "
    "SUM(CASE WHEN s.status=1 THEN 1 ELSE 0 END) AS passed_count, "
    "SUM(CASE WHEN s.status<>2 THEN 1 ELSE 0 END) AS valid_count "
    "FROM activity a LEFT JOIN signup s ON a.id=s.activity_id "
    "WHERE " + where +
    " GROUP BY a.id ORDER BY a.created_at DESC";
  if (size > 0) {
    std::ostringstream lim;
    lim << " LIMIT " << size << " OFFSET " << (long long)(page - 1) * size;
    sql += lim.str();
  }
  QueryResult r;
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
  long long now = nowMs();
  Json arr = Json::Array();
  for (auto& row : r.rows) {
    Json o = Json::Object();
    long long cap = atol(row[7].c_str());
    long long valid = row[13].empty() ? 0 : atol(row[13].c_str());
    long long endTs = row[5].empty() ? 0 : parseLocalTime(row[5]);
    o.set("id", Json::Num(atol(row[0].c_str())));
    o.set("title", Json::Str(row[1]));
    o.set("content", Json::Str(row[2]));
    o.set("location", Json::Str(row[3]));
    o.set("start_time", Json::Str(row[4]));
    o.set("end_time", Json::Str(row[5]));
    o.set("hours", Json::Num(atof(row[6].c_str())));
    o.set("capacity", Json::Num(cap));
    o.set("publisher", Json::Str(row[8]));
    o.set("signed_count", Json::Num(row[11].empty() ? 0 : atol(row[11].c_str())));
    o.set("passed_count", Json::Num(row[12].empty() ? 0 : atol(row[12].c_str())));
    // 有效报名数(不含已驳回) 与剩余名额: 与服务端容量判定口径一致, 供 App 直接展示
    o.set("valid_count", Json::Num(valid));
    o.set("remaining", Json::Num(cap > 0 ? (cap > valid ? cap - valid : 0) : -1));
    // 已结束活动仍可查看, 但不可报名/刷卡
    o.set("expired", Json::Bool(endTs > 0 && endTs < now));
    // 上下线状态(0 已下线 / 1 已发布): 管理员活动管理页据此显示"上线/下线"
    o.set("status", Json::Num(atol(row[9].c_str())));
    arr.push(o);
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("list", arr);
  data.set("total", Json::Num((double)total));
  data.set("page", Json::Num(page));
  data.set("size", Json::Num(size));
  data.set("has_more", Json::Bool(size > 0 && (long long)page * size < total));
  return jsonOk(data);
}

// 活动表单(新增/编辑共用)
struct ActivityForm {
  string title, content, location, startTime, endTime, publisher;
  double    hours = 1.0;
  int       capacity = 0;
  long long sTs = 0, eTs = 0;
};

/**
 * 解析并校验活动表单。
 * allowPastStart=true 时允许开始时间早于当前(编辑已有/历史活动, 不能因为时间已过就拒绝保存)。
 */
static bool parseActivityForm(const Json& body, ActivityForm& f, string& errMsg, bool allowPastStart) {
  f.title = body.strVal("title");
  if (f.title.empty()) { errMsg = "title required"; return false; }
  f.content   = body.strVal("content");
  f.location  = body.strVal("location");
  f.startTime = body.strVal("start_time");
  f.endTime   = body.strVal("end_time");
  // 时间规范化: "YYYY-MM-DD HH:MM" -> "YYYY-MM-DD HH:MM:SS"
  auto norm = [](const string& s) -> string {
    if (s.size() == 16 && s[10] == ' ') return s + ":00";
    return s;
  };
  f.startTime = norm(f.startTime);
  f.endTime   = norm(f.endTime);
  // 合法性校验(滚轮选择之外的兜底): 格式 / 前后关系 / 数值范围 / 长度
  f.sTs = f.startTime.empty() ? 0 : parseLocalTime(f.startTime);
  f.eTs = f.endTime.empty()   ? 0 : parseLocalTime(f.endTime);
  if (!f.startTime.empty() && f.sTs == 0) { errMsg = "start_time 格式应为 YYYY-MM-DD HH:MM"; return false; }
  if (!f.endTime.empty()   && f.eTs == 0) { errMsg = "end_time 格式应为 YYYY-MM-DD HH:MM";   return false; }
  if (f.sTs > 0 && f.eTs > 0 && f.eTs <= f.sTs) { errMsg = "结束时间必须晚于开始时间"; return false; }
  if (!allowPastStart && f.sTs > 0 && f.sTs < nowMs()) { errMsg = "开始时间不能早于当前时间"; return false; }
  f.hours    = body.numVal("hours", 1.0);
  f.capacity = body.intVal("capacity", 0);
  if (f.hours <= 0 || f.hours > 999) { errMsg = "hours 应在 (0,999] 范围内"; return false; }
  if (f.capacity < 0 || f.capacity > 99999) { errMsg = "capacity 应在 [0,99999] 范围内"; return false; }
  f.publisher = body.strVal("publisher");
  // 长度截断, 防止超长内容破坏数据
  if (f.title.size() > 100)      f.title = f.title.substr(0, 100);
  if (f.content.size() > 2000)   f.content = f.content.substr(0, 2000);
  if (f.location.size() > 100)   f.location = f.location.substr(0, 100);
  if (f.publisher.size() > 50)   f.publisher = f.publisher.substr(0, 50);
  return true;
}

/** 活动字段的 SET 片段(新增/编辑共用, 保证两处口径一致) */
static string activitySetSql(MYSQL* c, const ActivityForm& f) {
  std::ostringstream s;
  s << "title=" << dbEscape(c, f.title)
    << ",content=" << dbEscape(c, f.content)
    << ",location=" << dbEscape(c, f.location)
    << ",start_time=" << (f.startTime.empty() ? "NULL" : dbEscape(c, f.startTime))
    << ",end_time=" << (f.endTime.empty() ? "NULL" : dbEscape(c, f.endTime))
    << ",hours=" << f.hours
    << ",capacity=" << f.capacity
    << ",publisher=" << dbEscape(c, f.publisher);
  return s.str();
}

// 发布活动
static string handleActivityAdd(const Json& body) {
  ActivityForm f;
  string em;
  if (!parseActivityForm(body, f, em, false)) return jsonErr(400, em);

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  std::ostringstream sql;
  sql << "INSERT INTO activity SET " << activitySetSql(c, f) << ",status=1";
  string err;
  QueryResult r;
  if (!dbQuery(c, sql.str(), r, err)) { dbRelease(c); return jsonErr(500, err); }
  long long id = (long long)mysql_insert_id(c);
  dbRelease(c);
  Json data = Json::Object();
  data.set("id", Json::Num((double)id));
  return jsonOk(data);
}

/**
 * 编辑活动(仅管理员): {activity_id, title, content, location, start_time, end_time, hours, capacity, publisher}
 * 已上线的活动允许在原记录上修改; 人数上限不得小于当前有效报名数, 否则容量口径自相矛盾。
 */
static string handleActivityUpdate(const Json& body) {
  int id = body.intVal("activity_id", -1);
  if (id <= 0) return jsonErr(400, "activity_id required");
  ActivityForm f;
  string em;
  if (!parseActivityForm(body, f, em, true)) return jsonErr(400, em);

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT id FROM activity WHERE id=" + std::to_string(id), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  if (f.capacity > 0) {
    QueryResult rc;
    if (dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(id) +
                   " AND status<>2", rc, err) && !rc.rows.empty()) {
      int cnt = atoi(rc.rows[0][0].c_str());
      if (cnt > f.capacity) {
        dbRelease(c);
        return jsonErr(400, "人数上限不能小于已报名人数(" + std::to_string(cnt) + " 人)");
      }
    }
  }
  std::ostringstream sql;
  sql << "UPDATE activity SET " << activitySetSql(c, f) << " WHERE id=" << id;
  if (!dbQuery(c, sql.str(), r, err)) { dbRelease(c); return jsonErr(500, err); }
  dbRelease(c);
  Json data = Json::Object();
  data.set("id", Json::Num(id));
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
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  // 校验活动
  if (!dbQuery(c, "SELECT id,capacity,hours,status,DATE_FORMAT(end_time,'%Y-%m-%d %H:%i:%s') "
                  "FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  int cap = atoi(r.rows[0][1].c_str());
  int actStatus = atoi(r.rows[0][3].c_str());
  if (actStatus != 1) { dbRelease(c); return jsonErr(400, "活动未开放报名"); }
  // 已结束的活动不再接受报名(原先可对任意历史活动报名)
  long long endTs = r.rows[0][4].empty() ? 0 : parseLocalTime(r.rows[0][4]);
  if (endTs > 0 && endTs < nowMs()) { dbRelease(c); return jsonErr(400, "活动已结束, 无法报名"); }

  // 事务化报名: 锁活动行 + 容量检查 + 插入 + 复检, 保证并发下不超员
  mysql_autocommit(c, 0);
  // 先对活动行加排他锁, 串行化同一活动的并发报名;
  // 否则在 REPEATABLE READ 下 COUNT 读不到其他事务未提交的插入, 并发报名可能超员
  QueryResult rLock;
  if (!dbQuery(c, "SELECT id FROM activity WHERE id=" + std::to_string(activityId) + " FOR UPDATE", rLock, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(500, err);
  }
  // 该学生是否已在名单内(有效报名, 含已通过):
  // 已报名的人重复点击/网络重试时必须幂等成功, 不能被"活动已满"挡住
  bool already = false;
  {
    QueryResult rExist;
    if (!dbQuery(c, "SELECT id FROM signup WHERE activity_id=" + std::to_string(activityId) +
                    " AND stu_no=" + dbEscape(c, stuNo) + " AND status<>2", rExist, err)) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(500, err);
    }
    already = !rExist.rows.empty();
  }
  // 容量检查(事务内): 只统计有效报名, 已驳回不占名额; 已在名单内则跳过
  if (cap > 0 && !already) {
    QueryResult r2;
    if (!dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(activityId) +
                    " AND status<>2", r2, err)) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(500, err);
    }
    int cnt = atoi(r2.rows[0][0].c_str());
    if (cnt >= cap) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
      return jsonErr(403, "名额已满, 无法报名");
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
      // remark 要在 status 之前判断: 只有"驳回后重新报名"才清旧备注, 已通过记录重复报名保留审核意见
      << "remark=IF(status=2,'',remark),status=IF(status=2,0,status),name=VALUES(name)";
  if (!dbQuery(c, sql.str(), r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(500, err);
  }
  long long id = (long long)mysql_insert_id(c);

  // 插入后复检容量(并发窗口保护), 超员则回滚; 已在名单内的幂等重报不参与复检
  if (cap > 0 && !already) {
    QueryResult r3;
    if (!dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(activityId) +
                    " AND status<>2", r3, err) ||
        atoi(r3.rows[0][0].c_str()) > cap) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
      return jsonErr(403, "名额已满, 无法报名");
    }
  }
  mysql_commit(c);
  mysql_autocommit(c, 1);

  // 返回该记录真实状态(重复报名时可能是已通过/已驳回, 不再恒写 0)
  int realStatus = 0, realCheckin = 0;
  double realHours = 0;
  QueryResult r4;
  if (dbQuery(c, "SELECT status,checkin,hours FROM signup WHERE id=" + std::to_string(id), r4, err) && !r4.rows.empty()) {
    realStatus = atoi(r4.rows[0][0].c_str());
    realCheckin = atoi(r4.rows[0][1].c_str());
    realHours = atof(r4.rows[0][2].c_str());
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("id", Json::Num((double)id));
  data.set("status", Json::Num(realStatus));
  data.set("checkin", Json::Num(realCheckin));
  data.set("hours", Json::Num(realHours));
  return jsonOk(data);
}

// 报名列表(支持 activity_id/status/kw 过滤与 page/size 分页; 学生身份强制只看自己的记录)
static string handleSignupList(const string& query, const string& forceStuNo) {
  int activityId = atoi(qparam(query, "activity_id").c_str());
  int status = -1;                                  // -1 全部
  string sv = qparam(query, "status");
  if (!sv.empty()) status = atoi(sv.c_str());
  if (status < -1 || status > 2) status = -1;
  string kw = qparam(query, "kw");                  // 姓名/学号/活动名 模糊搜索(服务端执行, 分页前过滤)
  if (kw.size() > 50) kw = kw.substr(0, 50);
  int page = atoi(qparam(query, "page").c_str());
  int size = atoi(qparam(query, "size").c_str());
  if (page < 1) page = 1;
  if (size < 0) size = 0;
  if (size > 200) size = 200;

  string stuNo = forceStuNo;   // 学生: 服务端强制本人, 忽略 query 中的 stu_no
  int stuFilter = forceStuNo.empty() ? 0 : 1;
  if (forceStuNo.empty()) {
    string q = qparam(query, "stu_no");   // 仅管理员可用 stu_no 过滤
    if (!q.empty()) { stuNo = q; stuFilter = 1; }
  }

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string cond;
  if (activityId > 0) cond += " AND s.activity_id=" + std::to_string(activityId);
  if (status >= 0)    cond += " AND s.status=" + std::to_string(status);
  if (stuFilter)      cond += " AND s.stu_no=" + dbEscape(c, stuNo);
  if (!kw.empty()) {
    string like = dbEscape(c, "%" + kw + "%");
    cond += " AND (s.name LIKE " + like + " OR s.stu_no LIKE " + like + " OR a.title LIKE " + like + ")";
  }

  string err;
  QueryResult cnt;
  long long total = 0;
  if (dbQuery(c, "SELECT COUNT(*) FROM signup s LEFT JOIN activity a ON s.activity_id=a.id "
                 "WHERE 1=1" + cond, cnt, err) && !cnt.rows.empty())
    total = atol(cnt.rows[0][0].c_str());

  string sql =
    "SELECT s.id,s.client_id,s.activity_id,s.stu_no,s.name,s.status,s.checkin,"
    "s.card_no,s.hours,s.remark,DATE_FORMAT(s.created_at,'%Y-%m-%d %H:%i:%s'),"
    "DATE_FORMAT(s.audited_at,'%Y-%m-%d %H:%i:%s'),a.title,"
    "COALESCE(a.hours,0) AS activity_hours,"
    "DATE_FORMAT(s.checked_at,'%Y-%m-%d %H:%i:%s') "
    "FROM signup s LEFT JOIN activity a ON s.activity_id=a.id "
    "WHERE 1=1" + cond + " ORDER BY s.id DESC";
  if (size > 0) {
    std::ostringstream lim;
    lim << " LIMIT " << size << " OFFSET " << (long long)(page - 1) * size;
    sql += lim.str();
  }
  QueryResult r;
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
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
    o.set("activity_hours", Json::Num(atof(row[13].c_str())));
    // 刷卡签到时间(ESP32 上报时刻): 审核列表与成员端都可展示"几点刷的卡"
    o.set("checkin_at", Json::Str(row[14]));
    arr.push(o);
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("list", arr);
  data.set("total", Json::Num((double)total));
  data.set("page", Json::Num(page));
  data.set("size", Json::Num(size));
  data.set("has_more", Json::Bool(size > 0 && (long long)page * size < total));
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
  // 驳回必须给出理由: 成员端会原样显示, 空理由等于"没说为什么", 无法指导他修改后重报
  if (action == "reject" && remark.size() < 2)
    return jsonErr(400, "驳回需填写理由(至少 2 个字), 成员会看到这条理由");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  // 事务内读取并锁定报名行: 防止两个管理员(或重复点击)同时读到 status=0 各累计一次学时
  mysql_autocommit(c, 0);
  string sql = "SELECT s.stu_no,s.name,s.status,a.hours FROM signup s "
               "LEFT JOIN activity a ON s.activity_id=a.id WHERE s.id=" + std::to_string(signupId) +
               " FOR UPDATE";
  if (!dbQuery(c, sql, r, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c); return jsonErr(404, "该报名已被学生撤销或不存在, 请刷新列表");
  }
  string stuNo = r.rows[0][0], name = r.rows[0][1];
  int curStatus = atoi(r.rows[0][2].c_str());
  double actHours = atof(r.rows[0][3].c_str());

  // 已审核记录禁止重复操作, 防止 hours_total 与 signup 状态不一致
  if (curStatus != 0) {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(400, "该记录已审核, 不能重复操作");
  }

  bool ok = true;
  string conflictMsg; // 并发冲突时的业务提示(区别于 SQL 错误)
  if (action == "pass") {
    // 1) 更新报名状态+学时(条件 status=0, 影响行数必须为 1)
    std::ostringstream s1;
    s1 << "UPDATE signup SET status=1,hours=" << actHours
       << ",audited_at=NOW(),remark=" << dbEscape(c, remark)
       << " WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s1.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) != 1) { ok = false; conflictMsg = "该记录已被其他管理员处理, 请刷新"; }
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
       << dbEscape(c, remark) << " WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s1.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) != 1) { ok = false; conflictMsg = "该记录已被其他管理员处理, 请刷新"; }
  }

  if (ok) {
    mysql_commit(c);
  } else {
    mysql_rollback(c);
  }
  mysql_autocommit(c, 1);
  dbRelease(c);
  if (!ok) return conflictMsg.empty() ? jsonErr(500, err) : jsonErr(409, conflictMsg);
  Json data = Json::Object();
  data.set("signup_id", Json::Num(signupId));
  data.set("action", Json::Str(action));
  data.set("hours", Json::Num(action == "pass" ? actHours : 0));
  return jsonOk(data);
}

// 学时统计报表(排行公开给登录用户; 明细: 管理员全量 / 学生仅本人)
static string handleHoursReport(const string& role, const string& stuNo) {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  QueryResult r;
  string err;
  // 学时达标线(系统配置): 报表直接给出"是否达标"结论, 而不是只给一个累计数
  double requiredHours = 0;
  QueryResult cf;
  if (dbQuery(c, "SELECT cfg_value FROM sys_config WHERE cfg_key='required_hours'", cf, err) && !cf.rows.empty())
    requiredHours = atof(cf.rows[0][0].c_str());

  string sql = "SELECT stu_no,name,total_hours,sign_count,updated_at FROM hours_total "
               "ORDER BY total_hours DESC, sign_count DESC";
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
  Json arr = Json::Array();
  int rank = 0;
  int achievedCnt = 0;
  double allHours = 0;
  for (auto& row : r.rows) {
    rank++;
    double th = atof(row[2].c_str());
    allHours += th;
    bool ok = requiredHours > 0 && th >= requiredHours;
    if (ok) achievedCnt++;
    Json o = Json::Object();
    o.set("rank", Json::Num(rank));
    o.set("stu_no", Json::Str(row[0]));
    o.set("name", Json::Str(row[1]));
    o.set("total_hours", Json::Num(th));
    o.set("sign_count", Json::Num(atol(row[3].c_str())));
    o.set("updated_at", Json::Str(row[4]));
    o.set("achieved", Json::Bool(ok));
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
  dbRelease(c);
  Json data = Json::Object();
  data.set("report", arr);
  data.set("detail", detail);
  data.set("required_hours", Json::Num(requiredHours));
  data.set("total_hours", Json::Num(allHours));
  data.set("student_count", Json::Num(rank));
  data.set("achieved_count", Json::Num(achievedCnt));
  return jsonOk(data);
}

// 读取系统配置(登录可见): 目前只有学时达标线, 后续新增项无需改接口
static string handleConfigGet() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  QueryResult r;
  string err;
  if (!dbQuery(c, "SELECT cfg_key,cfg_value FROM sys_config", r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  dbRelease(c);
  Json data = Json::Object();
  for (auto& row : r.rows) {
    double n = atof(row[1].c_str());
    // 数值型配置按数字下发(前端可直接参与计算), 其余按字符串
    bool numeric = !row[1].empty() && row[1].find_first_not_of("0123456789.-") == string::npos;
    data.set(row[0], numeric ? Json::Num(n) : Json::Str(row[1]));
  }
  return jsonOk(data);
}

// 设置学时达标线(仅管理员): {required_hours}
static string handleConfigSet(const Json& body) {
  double req = body.numVal("required_hours", -1);
  if (req < 0 || req > 999) return jsonErr(400, "required_hours 应在 [0,999] 范围内(0 表示不设达标线)");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  std::ostringstream s;
  s << "INSERT INTO sys_config (cfg_key,cfg_value) VALUES ('required_hours','" << req << "') "
    << "ON DUPLICATE KEY UPDATE cfg_value=VALUES(cfg_value)";
  string err;
  QueryResult r;
  if (!dbQuery(c, s.str(), r, err)) { dbRelease(c); return jsonErr(500, err); }
  dbRelease(c);
  Json data = Json::Object();
  data.set("required_hours", Json::Num(req));
  return jsonOk(data);
}

// 学时汇总重算(仅管理员): 以 signup(status=1) 为唯一事实来源重建 hours_total。
// 用途: 历史数据手工改动/异常中断导致的汇总漂移可以一键修复, 保证报表与实际认定一致。
static string handleHoursRebuild() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  mysql_autocommit(c, 0);
  bool ok = dbQuery(c, "DELETE FROM hours_total", r, err);
  if (ok) ok = dbQuery(c, "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) "
                          "SELECT stu_no,MAX(name),SUM(hours),COUNT(*) FROM signup "
                          "WHERE status=1 GROUP BY stu_no", r, err);
  int affected = ok ? (int)mysql_affected_rows(c) : 0;
  double total = 0;
  if (ok) {
    QueryResult sum;
    if (dbQuery(c, "SELECT COALESCE(SUM(hours),0) FROM signup WHERE status=1", sum, err) && !sum.rows.empty())
      total = atof(sum.rows[0][0].c_str());
  }
  if (ok) mysql_commit(c); else mysql_rollback(c);
  mysql_autocommit(c, 1);
  dbRelease(c);
  if (!ok) return jsonErr(500, err);
  Json data = Json::Object();
  data.set("students", Json::Num(affected));
  data.set("total_hours", Json::Num(total));
  return jsonOk(data);
}

// 活动上下线(仅管理员): {activity_id, status: 1=上线 0=下线}
// 下线后不出现在活动列表, 但历史报名与学时记录保留(不做物理删除)
static string handleActivityStatus(const Json& body) {
  int actId = body.intVal("activity_id", -1);
  int status = body.intVal("status", -1);
  if (actId <= 0 || (status != 0 && status != 1))
    return jsonErr(400, "activity_id & status(0|1) required");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "UPDATE activity SET status=" + std::to_string(status) +
                  " WHERE id=" + std::to_string(actId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  // 影响 0 行: 可能活动不存在, 也可能已处于目标状态, 需再确认存在性
  if (mysql_affected_rows(c) == 0) {
    QueryResult chk;
    if (!dbQuery(c, "SELECT id FROM activity WHERE id=" + std::to_string(actId), chk, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    if (chk.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("activity_id", Json::Num(actId));
  data.set("status", Json::Num(status));
  return jsonOk(data);
}

// 撤销报名(仅普通成员本人, 仅待审核): 删除记录并释放名额; 已通过/已驳回不可撤销
// 定位方式: signup_id 优先, 否则按 (activity_id + 登录学号) 定位 —— App 本地库不保存服务端报名 id
static string handleSignupCancel(const Json& body, const string& loginStuNo) {
  int signupId = body.intVal("signup_id", -1);
  int activityId = body.intVal("activity_id", -1);
  if (signupId <= 0 && activityId <= 0)
    return jsonErr(400, "signup_id or activity_id required");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  string sql = signupId > 0
    ? "SELECT id,stu_no,status FROM signup WHERE id=" + std::to_string(signupId)
    : "SELECT id,stu_no,status FROM signup WHERE activity_id=" + std::to_string(activityId) +
      " AND stu_no=" + dbEscape(c, loginStuNo);
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "报名记录不存在"); }
  signupId = atoi(r.rows[0][0].c_str());
  if (r.rows[0][1] != loginStuNo) { dbRelease(c); return jsonErr(403, "只能撤销本人的报名记录"); }
  if (atoi(r.rows[0][2].c_str()) != 0) { dbRelease(c); return jsonErr(400, "仅待审核的报名可以撤销"); }
  if (!dbQuery(c, "DELETE FROM signup WHERE id=" + std::to_string(signupId) + " AND status=0", r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (mysql_affected_rows(c) != 1) { dbRelease(c); return jsonErr(409, "该报名已被审核, 无法撤销"); }
  dbRelease(c);
  Json data = Json::Object();
  data.set("signup_id", Json::Num(signupId));
  data.set("activity_id", Json::Num(activityId));
  return jsonOk(data);
}

// ESP32 刷卡签到: {card_no, activity_id}
// 按卡号匹配学生 -> 找到该活动报名:
//   报名不存在 -> 自动创建并通过(到场认定学时)
//   报名待审核 -> 置为通过并认定学时 + 标记签到
//   已通过     -> 仅标记签到
//   已驳回     -> 拒绝(管理员驳回为人工决策, 刷卡不得绕过审核, 需重新报名)
static string handleSignin(const Json& body) {
  string cardNo = body.strVal("card_no");
  int activityId = body.intVal("activity_id", -1);
  if (cardNo.empty() || activityId <= 0)
    return jsonErr(400, "card_no & activity_id required");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  // 1) 卡号找学生
  if (!dbQuery(c, "SELECT stu_no,name FROM student WHERE card_no=" + dbEscape(c, cardNo), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "卡号未绑定任何成员"); }
  string stuNo = r.rows[0][0], name = r.rows[0][1];

  // 2) 活动学时与状态(已下线/已结束活动不可刷卡认定学时)
  if (!dbQuery(c, "SELECT hours,status,DATE_FORMAT(end_time,'%Y-%m-%d %H:%i:%s') FROM activity WHERE id=" +
                  std::to_string(activityId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  double actHours = atof(r.rows[0][0].c_str());
  int actStatus = atoi(r.rows[0][1].c_str());
  if (actStatus != 1) { dbRelease(c); return jsonErr(400, "活动未开放报名"); }
  long long endTs = r.rows[0][2].empty() ? 0 : parseLocalTime(r.rows[0][2]);
  if (endTs > 0 && endTs < nowMs()) { dbRelease(c); return jsonErr(400, "活动已结束, 不能再刷卡认定学时"); }

  // 3) 查该学生该活动报名
  if (!dbQuery(c, "SELECT id,status,checkin FROM signup WHERE activity_id=" + std::to_string(activityId) +
                  " AND stu_no=" + dbEscape(c, stuNo), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  int signupId = 0, st = 0;
  if (!r.rows.empty()) {
    signupId = atoi(r.rows[0][0].c_str());
    st = atoi(r.rows[0][1].c_str());
  }

  // 已驳回的报名不允许刷卡直接通过: 驳回是管理员的人工决策, 学生需重新报名后再签到
  if (st == 2) {
    dbRelease(c);
    return jsonErr(403, "该报名已被管理员驳回, 请重新报名后再刷卡签到");
  }

  mysql_autocommit(c, 0);
  bool ok = true;
  bool needAccumulate = false; // 仅当本次操作使其首次通过/认定时才累计学时
  string conflictMsg;
  string clientId = "rfid-" + cardNo + "-" + std::to_string(activityId);
  if (signupId == 0) {
    // 无报名: 创建并通过; 影响行数为 1 才说明本次真正新建(2=命中唯一键更新, 说明并发已建)
    std::ostringstream s;
    s << "INSERT INTO signup (client_id,activity_id,stu_no,name,status,checkin,card_no,hours,audited_at) VALUES ("
      << dbEscape(c, clientId) << "," << activityId << ","
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << ",1,1,"
      << dbEscape(c, cardNo) << "," << actHours << ",NOW()) "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),checkin=1,card_no=VALUES(card_no),hours=VALUES(hours)";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) == 1) needAccumulate = true;
    else { ok = false; conflictMsg = "签到冲突(并发刷卡), 请重新刷卡"; }
  } else if (st == 0) {
    // 待审核 -> 通过 + 签到(条件 status=0, 防止并发重复累计学时)
    std::ostringstream s;
    s << "UPDATE signup SET status=1,checkin=1,card_no=" << dbEscape(c, cardNo)
      << ",hours=" << actHours << ",audited_at=NOW() WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) == 1) needAccumulate = true;
    else { ok = false; conflictMsg = "该报名刚刚被审核, 请重新刷卡"; }
  } else if (st == 1) {
    // 已通过 -> 仅签到(不重复累计学时)
    std::ostringstream s;
    s << "UPDATE signup SET checkin=1,checked_at=NOW(),card_no=" << dbEscape(c, cardNo) << " WHERE id=" << signupId;
    if (!dbQuery(c, s.str(), r, err)) ok = false;
  } else {
    // 未知状态(数据异常): 拒绝处理, 避免误绕过审核
    ok = false;
    err = "unexpected signup status";
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
  dbRelease(c);
  if (!ok) return conflictMsg.empty() ? jsonErr(500, err) : jsonErr(409, conflictMsg);
  Json data = Json::Object();
  data.set("stu_no", Json::Str(stuNo));
  data.set("name", Json::Str(name));
  data.set("activity_id", Json::Num(activityId));
  data.set("hours", Json::Num(actHours));
  data.set("checkin", Json::Num(1));
  return jsonOk(data);
}

// 实时请求日志(支持筛选: level=err|slow, method=GET|POST, kw=路径关键词)
static string handleLogs(const string& query) {
  int limit = atoi(qparam(query, "limit").c_str());
  if (limit <= 0 || limit > 500) limit = 50;
  string level  = qparam(query, "level");    // "" 全部 | err 失败(>=400) | slow 慢请求(>=500ms)
  string method = qparam(query, "method");   // "" 全部 | GET | POST
  string kw     = qparam(query, "kw");       // 路径/明细关键词
  for (auto& ch : method) ch = (char)toupper((unsigned char)ch);

  std::lock_guard<std::mutex> lk(g_logs_mtx);
  Json arr = Json::Array();
  int shown = 0;
  int matched = 0;
  for (auto& e : g_logs) {
    if (!method.empty() && e.method != method) continue;
    if (level == "err" && e.status < 400) continue;
    if (level == "slow" && e.cost < 500) continue;
    if (!kw.empty() && e.path.find(kw) == string::npos && e.detail.find(kw) == string::npos) continue;
    matched++;
    if (shown >= limit) continue;   // 已满: 只统计命中数, 不再序列化
    Json o = Json::Object();
    o.set("time", Json::Str(fmtMs(e.ms)));
    o.set("method", Json::Str(e.method));
    o.set("path", Json::Str(e.path));
    o.set("ip", Json::Str(e.ip));
    o.set("status", Json::Num(e.status));
    o.set("cost_ms", Json::Num(e.cost));
    o.set("detail", Json::Str(e.detail));
    arr.push(o);
    shown++;
  }
  Json data = Json::Object();
  data.set("total", Json::Num((double)g_logs.size()));
  data.set("matched", Json::Num(matched));
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
    d.set("version", Json::Str("3.0"));
    d.set("time", Json::Str(nowStr()));
    // 数据库连通性: 验收时可直接确认"服务器在线且 MySQL 可用", 前端仍按 code==0 判在线,
    // db=false 只作为附加信息(不改变健康检查的业务 code, 避免数据库抖动时健康检查整体变红)
    bool dbOk = false;
    MYSQL* hc = dbConnect();
    if (hc) { dbOk = true; dbRelease(hc); }
    d.set("db", Json::Bool(dbOk));
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
    // 配置了设备密钥(CLUB_DEVICE_KEY)后必须携带 X-Device-Key, 防止局域网内任意设备伪造刷卡
    if (!g_device_key.empty() && !constEq(req.header("X-Device-Key"), g_device_key))
      return jsonErr(401, "invalid device key");
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignin(body);
  }

  // 成员注册申请(公开): 提交后由管理员在审核中心同意/拒绝
  if (req.method == "POST" && p == "/api/register") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleRegister(body);
  }

  // ---- 以下接口全部需要登录 ----
  TokenInfo me;
  if (!authToken(req, me)) return needLogin();

  // 注销: 立即让当前 Token 失效(客户端同时清理本地会话)
  if (req.method == "POST" && p == "/api/logout") {
    string tok = bearerToken(req);
    {
      std::lock_guard<std::mutex> lk(g_tokens_mtx);
      g_tokens.erase(tok);
    }
    Json d = Json::Object();
    d.set("logout", Json::Bool(true));
    return jsonOk(d);
  }

  // 注册申请列表 / 审核: 仅管理员
  if (req.method == "GET" && p == "/api/student/requests") {
    if (me.role != "admin") return needAdmin();
    return handleStudentRequests();
  }

  // 用户管理(全量学生 + 分组查找): 仅管理员
  if (req.method == "GET" && p == "/api/student/list") {
    if (me.role != "admin") return needAdmin();
    return handleStudentList(req.query);
  }

  // 注销影响面预览: 学生查自己, 管理员查指定学号(二次确认弹窗据此如实告知后果)
  if (req.method == "GET" && p == "/api/student/impact")
    return handleStudentImpact(req.query, me.role, me.stu_no);

  // 学生自助注销: {confirm_stu_no} 必须与本人学号一致
  if (req.method == "POST" && p == "/api/student/cancel") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentCancel(body, me);
  }

  // 管理员注销学生账号: {stu_no, confirm_stu_no}
  if (req.method == "POST" && p == "/api/student/delete") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentDelete(body, me);
  }

  if (req.method == "POST" && p == "/api/student/audit") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentAudit(body);
  }

  // 发布活动: 仅管理员
  if (req.method == "POST" && p == "/api/activity/add") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleActivityAdd(body);
  }

  // 编辑活动: 仅管理员(原地更新, 已报名记录与学时不受影响)
  if (req.method == "POST" && p == "/api/activity/update") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleActivityUpdate(body);
  }

  if (req.method == "GET" && p == "/api/activity/list")
    return handleActivityList(req.query, me.role);

  // 系统配置: 读取对所有登录用户开放, 修改仅管理员
  if (req.method == "GET" && p == "/api/config/get")
    return handleConfigGet();
  if (req.method == "POST" && p == "/api/config/set") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleConfigSet(body);
  }

  // 活动上下线: 仅管理员(下线后不再出现在活动列表, 历史数据保留)
  if (req.method == "POST" && p == "/api/activity/status") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleActivityStatus(body);
  }

  // 报名: 仅普通成员, 身份强制为登录者
  if (req.method == "POST" && p == "/api/signup/add") {
    if (me.role != "student") return needStudent();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignupAdd(body, me.stu_no, me.name);
  }

  // 报名列表: 管理员全量(可用 stu_no/activity_id 过滤), 学生仅本人
  // 注意: 学生也要把 query 透传下去 —— forceStuNo 已强制本人, 透传后
  // activity_id / status / kw / page / size 才能生效(详情页按活动查本人报名就靠它)。
  if (req.method == "GET" && p == "/api/signup/list") {
    if (me.role == "admin") return handleSignupList(req.query, "");
    return handleSignupList(req.query, me.stu_no);
  }

  // 审核: 仅管理员(通过自动累计学时)
  if (req.method == "POST" && p == "/api/signup/audit") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignupAudit(body);
  }

  // 撤销本人的待审核报名: 仅普通成员(释放名额, 已通过/已驳回不可撤销)
  if (req.method == "POST" && p == "/api/signup/cancel") {
    if (me.role != "student") return needStudent();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSignupCancel(body, me.stu_no);
  }

  // 学时报表: 排行公开, 明细按角色
  if (req.method == "GET" && p == "/api/hours/report")
    return handleHoursReport(me.role, me.stu_no);

  // 管理端待办统计(角标/横幅): 仅管理员
  if (req.method == "GET" && p == "/api/stats/pending") {
    if (me.role != "admin") return needAdmin();
    return handleStatsPending();
  }

  // 学时汇总重算(以 signup 为事实来源重建 hours_total): 仅管理员
  if (req.method == "POST" && p == "/api/hours/rebuild") {
    if (me.role != "admin") return needAdmin();
    return handleHoursRebuild();
  }

  // 服务器实时请求日志: 仅管理员
  if (req.method == "GET" && p == "/api/logs") {
    if (me.role != "admin") return needAdmin();
    return handleLogs(req.query);
  }

  return httpResponse(404, jsonDump(Json::Object()
    .set("code", Json::Num(404)).set("msg", Json::Str("not found"))));
}

// ---------------------------- 单连接处理 -------------------------------------
/**
 * 处理连接上的一个请求; 返回 true 表示连接仍可复用(继续读下一个请求)。
 * carry 保存本次预读到的多余字节(可能已包含下一个请求), 供下一轮解析。
 */
static bool serveOne(SOCKET sock, string& carry, const string& ip) {
  HttpRequest req;
  req.ip = ip;
  string raw = carry;
  carry.clear();

  char buf[8192];
  // 读请求头
  while (raw.find("\r\n\r\n") == string::npos) {
    int n = recv(sock, buf, sizeof(buf), 0);
    if (n <= 0) return false;                 // 对端关闭 / 空闲超时
    raw.append(buf, n);
    if (raw.size() > 64 * 1024) return false; // 头部过大: 直接断链
  }
  size_t hdrEnd = raw.find("\r\n\r\n");

  // 请求行(第三段是协议版本, 决定默认是否保持连接)
  std::istringstream head(raw.substr(0, hdrEnd));
  string line;
  if (!std::getline(head, line)) return false;
  string version;
  {
    std::istringstream reqline(line);
    reqline >> req.method >> req.path >> version;
  }
  if (req.method.empty() || req.path.empty()) return false;
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

  // 连接复用判定: HTTP/1.1 默认 keep-alive, HTTP/1.0 默认 close, 显式头优先
  string conn = req.header("Connection");
  for (auto& ch : conn) ch = (char)tolower((unsigned char)ch);
  bool keepAlive = (version != "HTTP/1.0");
  if (conn == "close") keepAlive = false;
  else if (conn == "keep-alive") keepAlive = true;

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
      return false;
    }
    string bodyPart = raw.substr(hdrEnd + 4);
    while (bodyPart.size() < need) {
      int n = recv(sock, buf, sizeof(buf), 0);
      if (n <= 0) break;
      bodyPart.append(buf, n);
    }
    if (bodyPart.size() < need) return false;   // 半包: 断链
    req.body = bodyPart.substr(0, need);
    carry = bodyPart.substr(need);              // 可能是流水线中的下一个请求
  } else {
    carry = raw.substr(hdrEnd + 4);
  }

  auto t0 = std::chrono::steady_clock::now();
  string resp;
  int status = 500;
  string detail;
  // 分发
  try {
    resp = route(req);
    status = extractCode(resp);
    string audit = takeAudit(resp);      // 摘出注销等破坏性操作的审计说明
    detail = req.method + " " + req.path + (req.query.empty() ? "" : "?" + req.query);
    if (!audit.empty()) detail += " | " + audit;               // 留痕
    if (detail.size() > 480) detail = detail.substr(0, 480); // 适配日志列宽
  } catch (...) {
    resp = jsonErr(500, "服务器内部错误, 请查看服务端日志");
    status = 500;
  }
  // 响应头里的 Connection 与实际行为保持一致(否则客户端等待/提前关闭)
  if (keepAlive) {
    size_t p = resp.find("Connection: close");
    if (p != string::npos) resp.replace(p, 17, "Connection: keep-alive");
  }

  sendAll(sock, resp);

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
    dbRelease(c);
  }).detach();

  return keepAlive;
}

// 每个连接一个线程: 连接内可连续处理多个请求(keep-alive), 空闲 10s 或达上限后关闭
static void handleClient(SOCKET sock, const string& ip) {
  // 收发超时: 防止慢连接/半开连接长期占用工作线程
  DWORD ioTimeout = 10000;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&ioTimeout, sizeof(ioTimeout));
  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&ioTimeout, sizeof(ioTimeout));

  string carry;
  for (int i = 0; i < 128; i++) {   // 单连接最多复用 128 次, 防止单连接长期占用线程
    if (!serveOne(sock, carry, ip)) break;
  }
  closesocket(sock);
}

// ---------------------------- 启动期自维护 -----------------------------------
/** 建表兜底: 老库直接运行新版本时自动补出 sys_config, 无需手工重跑 init_db.sql */
static void dbEnsureSchema() {
  MYSQL* c = dbConnect();
  if (!c) return;
  string err;
  QueryResult r;
  dbQuery(c, "CREATE TABLE IF NOT EXISTS sys_config ("
             "cfg_key VARCHAR(50) PRIMARY KEY,"
             "cfg_value VARCHAR(200) NOT NULL DEFAULT '',"
             "updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"
             ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='系统配置'", r, err);
  dbQuery(c, "INSERT IGNORE INTO sys_config (cfg_key,cfg_value) VALUES ('required_hours','20')", r, err);
  // 日志表按时间清理需要索引(已存在时 MySQL 报重复, 直接忽略)
  QueryResult ig;
  dbQuery(c, "CREATE INDEX idx_req_time ON request_log (req_time)", ig, err);
  // 刷卡签到时间: 老库补列(列已存在时 MySQL 报重复列, 忽略即可)
  // 验收时可直接展示"几点刷的卡", 比只有一个 checkin=1 更有说服力
  dbQuery(c, "ALTER TABLE signup ADD COLUMN checked_at DATETIME NULL COMMENT '刷卡签到时间'", ig, err);
  // 待审报名是管理端最高频查询, 单独建索引避免全表扫描(已存在同样忽略)
  dbQuery(c, "CREATE INDEX idx_signup_status ON signup (status)", ig, err);
  dbRelease(c);
}

/** 管理员口令迁移: 把历史明文口令一次性升级为加盐 SHA-256 */
static void dbMigratePasswords() {
  MYSQL* c = dbConnect();
  if (!c) return;
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT id,username,password FROM admin_user", r, err)) { dbRelease(c); return; }
  int n = 0;
  for (auto& row : r.rows) {
    if (pwdIsHashed(row[2])) continue;
    QueryResult up;
    std::ostringstream s;
    s << "UPDATE admin_user SET password=" << dbEscape(c, pwdHash(row[2])) << " WHERE id=" << row[0];
    if (dbQuery(c, s.str(), up, err)) n++;
  }
  dbRelease(c);
  if (n > 0) std::cout << "[migrate] " << n << " admin password(s) upgraded to salted SHA-256\n";
}

// request_log 无限增长治理: 只保留最近 7 天且总量不超过 20000 条
static const int LOG_KEEP_DAYS = 7;
static const int LOG_KEEP_ROWS = 20000;
static void logCleanerOnce() {
  MYSQL* c = dbConnect();
  if (!c) return;
  string err;
  QueryResult r;
  dbQuery(c, "DELETE FROM request_log WHERE req_time < NOW() - INTERVAL " +
             std::to_string(LOG_KEEP_DAYS) + " DAY", r, err);
  long long n = 0;
  QueryResult cnt;
  if (dbQuery(c, "SELECT COUNT(*) FROM request_log", cnt, err) && !cnt.rows.empty())
    n = atol(cnt.rows[0][0].c_str());
  // 超过阈值 20% 才触发大批删除, 避免每小时都做一次全表扫描式删除
  if (n > (long long)LOG_KEEP_ROWS * 6 / 5) {
    QueryResult d;
    dbQuery(c, "DELETE FROM request_log WHERE id NOT IN (SELECT id FROM "
               "(SELECT id FROM request_log ORDER BY id DESC LIMIT " +
               std::to_string(LOG_KEEP_ROWS) + ") t)", d, err);
  }
  dbRelease(c);
}

static void logCleanerLoop() {
  logCleanerOnce();
  while (true) {
    std::this_thread::sleep_for(std::chrono::hours(1));
    logCleanerOnce();
  }
}

// ---------------------------- 主程序 -----------------------------------------
int main(int argc, char* argv[]) {
  if (argc > 1) g_port = atoi(argv[1]);
  if (argc > 2) g_db_user = argv[2];
  if (argc > 3) g_db_pass = argv[3];
  if (argc > 4) g_db_host = argv[4];
  // 可选的刷卡终端共享密钥(第 5 个参数优先, 其次环境变量); 留空则不校验
  if (argc > 5) g_device_key = argv[5];
  if (g_device_key.empty()) {
    const char* envKey = getenv("CLUB_DEVICE_KEY");
    if (envKey != nullptr) g_device_key = envKey;
  }

  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    std::cerr << "WSAStartup failed\n"; return 1;
  }

  // 预热: 验证 MySQL 连接, 并做一次启动期自维护(补表 / 口令升级 / 日志清理)
  {
    MYSQL* c = dbConnect();
    if (!c) {
      std::cerr << "MySQL connect failed: host=" << g_db_host << " user=" << g_db_user
                << " db=" << g_db_name << " 请先执行 init_db.sql\n";
      WSACleanup();
      return 1;
    }
    dbRelease(c);
  }
  dbEnsureSchema();
  dbMigratePasswords();
  std::thread(logCleanerLoop).detach();   // 后台: 每小时清理一次历史日志

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
