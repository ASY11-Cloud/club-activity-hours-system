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
#include <bcrypt.h>   // BCryptGenRandom: 系统 CSPRNG(Token 生成)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
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

// 动态签到码密钥: 启动时用系统 CSPRNG 生成, 重启即失效旧码。
// 签到码 = HMAC 风格(sha256(secret|activity|窗口)) 取 6 位十进制, 60 秒一个窗口,
// 现场大屏/管理员手机出示即可, 截图转发到群里的码 1 分钟内自动作废。
static string g_signin_secret;

// 登录失败节流: 同一账号 60 秒内连续失败 5 次后暂时拒绝, 防止口令暴力猜测
struct LoginFail { int count = 0; long long first_ms = 0; };
static std::map<string, LoginFail> g_login_fail;
static std::mutex g_login_mtx;
static const int       LOGIN_FAIL_MAX       = 5;    // 同一账号
static const int       LOGIN_FAIL_IP_MAX    = 30;   // 同一来源 IP(防换账号爆破, 阈值放宽避免误伤同网段演示)
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
  // Token 是会话凭证, 必须不可预测: 用 Windows 系统 CSPRNG(BCryptGenRandom),
  // 不能用 mt19937 —— 伪随机序列可被观察推断(拿到若干 Token 即可推后续),
  // 一旦被预测就等于任意账号被接管。
  unsigned char raw[32];
  if (BCryptGenRandom(nullptr, raw, (ULONG)sizeof(raw), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    // 极端兜底: CSPRNG 不可用时退回 random_device, 仍不使用可预测的 PRNG
    std::random_device rd;
    for (size_t i = 0; i < sizeof(raw); i++) raw[i] = (unsigned char)(rd() & 0xFF);
  }
  const char* hex = "0123456789abcdef";
  string t(64, '0');                      // 256 bit -> 64 hex
  for (size_t i = 0; i < sizeof(raw); i++) {
    t[i * 2]     = hex[(raw[i] >> 4) & 0x0F];
    t[i * 2 + 1] = hex[raw[i] & 0x0F];
  }
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

/** 防时序侧信道: 常量时间比较(口令摘要 / 设备密钥) */
static bool constEq(const string& a, const string& b) {
  if (a.size() != b.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); i++) diff |= (unsigned char)(a[i] ^ b[i]);
  return diff == 0;
}

// 口令存储格式演进:
//   明文                                   (v1.0, 仅兼容读取, 登录后立即升级)
//   "sha256:<64hex>"                       (单轮加盐, v2.0; 可被 GPU 高速暴破)
//   "sha256i:<64hex>"                      (迭代加盐, 当前格式; 提高离线暴破成本)
// 迭代次数取 12000: 单次登录约 10~20ms(用户无感), 但把离线尝试成本放大约 1.2 万倍。
static const char* PWD_PREFIX_ITER = "sha256i:";
static const int   PWD_ITER        = 12000;
// 学生初始口令: 历史账号/演示账号没有口令, 服务启动时统一初始化为该值,
// 文档与 App 均提示"首次登录后请自行修改"。
static const char*  DEFAULT_STUDENT_PWD = "123456";

/** 明文口令 -> 入库格式(单轮加盐, 保留用于识别与兼容旧库) */
static string pwdHash(const string& secret) {
  return string(PWD_PREFIX) + sha256Hex(string(PWD_SALT) + secret);
}

/** 明文口令 -> 当前入库格式(迭代加盐) */
static string pwdHashStrong(const string& secret) {
  string h = sha256Hex(string(PWD_SALT) + secret);
  for (int i = 1; i < PWD_ITER; i++) h = sha256Hex(h + PWD_SALT);
  return string(PWD_PREFIX_ITER) + h;
}

/** 库中值是否为哈希格式(旧版本可能仍是明文) */
static bool pwdIsHashed(const string& stored) {
  if (stored.size() == 71 && stored.compare(0, 7, PWD_PREFIX) == 0) return true;
  if (stored.size() == 72 && stored.compare(0, 8, PWD_PREFIX_ITER) == 0) return true;
  return false;
}

/** 是否为当前最强格式(迭代加盐); 否则登录成功后需升级 */
static bool pwdIsStrong(const string& stored) {
  return stored.size() == 72 && stored.compare(0, 8, PWD_PREFIX_ITER) == 0;
}

/** 校验口令: 迭代/单轮哈希走摘要比对, 旧明文走字符串比对(登录成功后由调用方升级) */
static bool pwdVerify(const string& stored, const string& secret) {
  if (pwdIsStrong(stored)) return constEq(stored, pwdHashStrong(secret));
  if (pwdIsHashed(stored)) return constEq(stored, pwdHash(secret));
  return constEq(stored, secret);
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
  // 递归深度上限: parseValue/parseObject/parseArray 是相互递归的,
  // 一个 64KB 的 "[[[[[[..." 就能产生数万层调用把线程栈打爆(进程直接消失, 无日志)。
  // 业务 JSON 最深不过 4 层, 64 层足够宽松又能挡住深嵌套攻击。
  int depth_ = 0;
  static const int MAX_DEPTH = 64;

  /** 容器层级计数: 进入 +1, 任何 return 路径都靠析构 -1(避免手写遗漏) */
  struct DepthGuard {
    int& d;
    explicit DepthGuard(int& x) : d(x) { d++; }
    ~DepthGuard() { d--; }
  };

  void skipWs() { while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) i_++; }

  bool parseValue(Json& out) {
    if (i_ >= s_.size()) return false;
    if (depth_ >= MAX_DEPTH) return false;   // 超深嵌套: 直接判非法, 不进入递归
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
    DepthGuard guard(depth_);
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
    DepthGuard guard(depth_);
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

// ---- request_log 落库队列 ------------------------------------------------
// 原先每个请求 detach 一个线程写库, 高并发时线程数随请求量线性上涨(可被打爆)。
// 改为"有界队列 + 单个消费者线程批量写": 请求线程只做一次入队, 不创建线程。
struct DbLogJob {
  string method, path, query, ip, detail;
  int    status = 200;
  int    cost = 0;
};
static std::deque<DbLogJob> g_log_q;
static std::mutex           g_log_q_mtx;
static const size_t         LOG_Q_MAX   = 4096;   // 队列上限
static const size_t         LOG_BATCH   = 200;    // 单批写入条数

static void logEnqueue(const DbLogJob& j) {
  std::lock_guard<std::mutex> lk(g_log_q_mtx);
  // 队列满说明写库跟不上: 丢弃落库(内存环形日志仍可查), 绝不阻塞业务线程
  if (g_log_q.size() >= LOG_Q_MAX) return;
  g_log_q.push_back(j);
}

static void logWriterLoop() {
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    std::vector<DbLogJob> batch;
    {
      std::lock_guard<std::mutex> lk(g_log_q_mtx);
      while (!g_log_q.empty() && batch.size() < LOG_BATCH) {
        batch.push_back(g_log_q.front());
        g_log_q.pop_front();
      }
    }
    if (batch.empty()) continue;
    MYSQL* c = dbConnect();
    if (!c) continue;                 // 数据库暂不可用: 丢这一批, 下一轮继续
    string err;
    QueryResult r;
    for (auto& j : batch) {
      std::ostringstream sql;
      sql << "INSERT INTO request_log (method,path,query,ip,status,cost_ms,detail) VALUES ("
          << dbEscape(c, j.method) << "," << dbEscape(c, j.path) << ","
          << dbEscape(c, j.query) << "," << dbEscape(c, j.ip) << ","
          << j.status << "," << j.cost << "," << dbEscape(c, j.detail) << ")";
      dbQuery(c, sql.str(), r, err);
    }
    dbRelease(c);
  }
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
static bool loginBlocked(const string& key, int maxCount = LOGIN_FAIL_MAX) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  auto it = g_login_fail.find(key);
  if (it == g_login_fail.end()) return false;
  if (nowMs() - it->second.first_ms > LOGIN_FAIL_WINDOW_MS) { g_login_fail.erase(it); return false; }
  return it->second.count >= maxCount;
}
static void loginFailAdd(const string& key, int maxCount = LOGIN_FAIL_MAX) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  // 这里的 key 含 IP 与账号, 不同来源会不断产生新 key; 只按 key 惰性清理会让 map 单调增长,
  // 因此超过阈值时做一次全量过期扫描(O(n) 摊销, 低频触发)。
  if (g_login_fail.size() > 4096) {
    long long now = nowMs();
    for (auto it = g_login_fail.begin(); it != g_login_fail.end(); ) {
      if (now - it->second.first_ms > LOGIN_FAIL_WINDOW_MS) it = g_login_fail.erase(it);
      else ++it;
    }
  }
  LoginFail& f = g_login_fail[key];
  if (f.count == 0) f.first_ms = nowMs();
  if (f.count < maxCount) f.count++;
}
static void loginFailClear(const string& key) {
  std::lock_guard<std::mutex> lk(g_login_mtx);
  g_login_fail.erase(key);
}

// 登录: {type: admin|student, account, secret}
//   admin  -> account=管理员账号, secret=密码 (查 admin_user 表)
//   student-> account=学号,      secret=密码 (查 student.pwd_hash)
// 成功签发 Token, 返回 {token, role, name, stu_no}
// 注: v3.0 之前学生用"学号+姓名"登录, 姓名在排行/用户列表里本就是公开信息,
//     等于"知道学号即可登录"; 现改为密码校验, 姓名不再参与认证。
static string handleLogin(const Json& body, const string& ip) {
  string type = body.strVal("type");
  string account = body.strVal("account");
  string secret = body.strVal("secret");
  if (type != "admin" && type != "student")
    return jsonErr(400, "type must be admin|student");
  if (account.empty() || secret.empty())
    return jsonErr(400, "account/secret required");
  // 长度上限: 口令校验要跑 12000 轮迭代哈希, 若不限长, 一个 60KB 的 secret
  // 会让单次登录消耗数百 MB 的哈希计算量(把"防暴破的迭代"变成 CPU 放大攻击)。
  if (secret.size() > 128 || account.size() > 64)
    return jsonErr(400, "账号或口令过长");

  // 节流 key 带上来源 IP: 攻击者用别人的账号名连续试错, 只会锁住"自己 IP + 该账号",
  // 不会把真实用户锁在门外(原实现只按账号计数, 可被用来恶意锁定任意账号)。
  string failKey = ip + "|" + type + ":" + account;
  string ipKey   = "ip|" + ip;                 // 同一来源的总失败次数(防换账号爆破)
  if (loginBlocked(failKey) || loginBlocked(ipKey, LOGIN_FAIL_IP_MAX))
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
      loginFailAdd(ipKey, LOGIN_FAIL_IP_MAX);
      return jsonErr(401, "管理员账号或密码错误");
    }
    // 旧格式口令(明文 / 单轮哈希): 登录成功后顺手升级为迭代哈希, 无需停机改库
    if (!pwdIsStrong(r.rows[0][2])) {
      QueryResult up;
      dbQuery(c, "UPDATE admin_user SET password=" + dbEscape(c, pwdHashStrong(secret)) +
                 " WHERE username=" + dbEscape(c, account), up, err);
    }
    ti.role = "admin";
    ti.name = r.rows[0][1];
    ti.stu_no = account;
  } else {
    if (!dbQuery(c, "SELECT stu_no,name,status,pwd_hash FROM student WHERE stu_no=" + dbEscape(c, account), r, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    // 先校验口令再报审核状态: 未通过认证的人不该知道该学号是"审核中"还是"已驳回"
    if (r.rows.empty() || !pwdVerify(r.rows[0][3], secret)) {
      dbRelease(c);
      loginFailAdd(failKey);
      loginFailAdd(ipKey, LOGIN_FAIL_IP_MAX);
      return jsonErr(401, "学号或密码错误, 未注册请先注册");
    }
    int regStatus = atoi(r.rows[0][2].c_str());
    if (regStatus == 0) { dbRelease(c); return jsonErr(403, "注册申请审核中, 请等待管理员审核后登录"); }
    if (regStatus == 2) { dbRelease(c); return jsonErr(403, "注册申请已被驳回, 请联系管理员"); }
    // 旧格式(明文/单轮哈希)口令: 登录成功后升级为迭代哈希
    if (!pwdIsStrong(r.rows[0][3])) {
      QueryResult up;
      dbQuery(c, "UPDATE student SET pwd_hash=" + dbEscape(c, pwdHashStrong(secret)) +
                 " WHERE stu_no=" + dbEscape(c, account), up, err);
    }
    ti.role = "student";
    ti.name = r.rows[0][1];
    ti.stu_no = r.rows[0][0];
  }
  dbRelease(c);
  loginFailClear(failKey);
  loginFailClear(ipKey);

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

/**
 * 管理员修改口令: {old_secret, new_secret}
 * 必须校验原口令 —— 否则 Token 一旦泄露, 攻击者可直接改密并长期占用账号。
 * 修改成功后旧 Token 仍然有效(Token 存内存, 不做版本号), 但口令已换, 重新登录需新口令。
 */
static string handleAdminPassword(const Json& body, const TokenInfo& me) {
  if (me.role != "admin") return needAdmin();
  string oldSecret = body.strVal("old_secret");
  string newSecret = body.strVal("new_secret");
  if (oldSecret.empty()) return jsonErr(400, "请输入原口令");
  if (newSecret.size() < 6) return jsonErr(400, "新口令至少 6 位");
  if (newSecret.size() > 64) return jsonErr(400, "新口令不能超过 64 位");
  if (newSecret == oldSecret) return jsonErr(400, "新口令不能与原口令相同");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT password FROM admin_user WHERE username=" + dbEscape(c, me.stu_no), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty() || !pwdVerify(r.rows[0][0], oldSecret)) {
    dbRelease(c); return jsonErr(401, "原口令不正确");
  }
  QueryResult up;
  if (!dbQuery(c, "UPDATE admin_user SET password=" + dbEscape(c, pwdHashStrong(newSecret)) +
                  " WHERE username=" + dbEscape(c, me.stu_no), up, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  dbRelease(c);
  return withAudit(jsonOkMsg("口令已更新", Json::Object()),
                   "AUDIT 管理员改密 account=" + me.stu_no);
}

/** 成员修改自己的登录密码: {old_pwd, new_pwd} */
static string handleStudentPassword(const Json& body, const TokenInfo& me) {
  if (me.role != "student") return jsonErr(403, "仅普通成员可在此修改密码");
  string oldPwd = body.strVal("old_pwd");
  string newPwd = body.strVal("new_pwd");
  if (oldPwd.empty()) return jsonErr(400, "请输入原密码");
  if (newPwd.size() < 6 || newPwd.size() > 64) return jsonErr(400, "新密码长度需 6~64 位");
  if (newPwd == oldPwd) return jsonErr(400, "新密码不能与原密码相同");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT pwd_hash FROM student WHERE stu_no=" + dbEscape(c, me.stu_no), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty() || !pwdVerify(r.rows[0][0], oldPwd)) {
    dbRelease(c); return jsonErr(401, "原密码不正确");
  }
  QueryResult up;
  if (!dbQuery(c, "UPDATE student SET pwd_hash=" + dbEscape(c, pwdHashStrong(newPwd)) +
                  " WHERE stu_no=" + dbEscape(c, me.stu_no), up, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  dbRelease(c);
  return withAudit(jsonOkMsg("密码已更新", Json::Object()), "AUDIT 成员改密 stu_no=" + me.stu_no);
}

/** 管理员重置某成员密码(成员忘记密码时使用): {student_id, new_pwd} */
static string handleStudentResetPwd(const Json& body) {
  int studentId = body.intVal("student_id", -1);
  string newPwd = body.strVal("new_pwd");
  if (studentId <= 0) return jsonErr(400, "student_id required");
  if (newPwd.size() < 6 || newPwd.size() > 64) return jsonErr(400, "新密码长度需 6~64 位");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT stu_no FROM student WHERE id=" + std::to_string(studentId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "学生不存在"); }
  string stuNo = r.rows[0][0];
  QueryResult up;
  if (!dbQuery(c, "UPDATE student SET pwd_hash=" + dbEscape(c, pwdHashStrong(newPwd)) +
                  " WHERE id=" + std::to_string(studentId), up, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  dbRelease(c);
  return withAudit(jsonOkMsg("密码已重置", Json::Object()), "AUDIT 重置成员密码 stu_no=" + stuNo);
}

/** 卡号规范化: 去空白 + 转大写(避免同一张卡因大小写/空格差异被当成两张卡) */
static string normalizeCardNo(const string& raw) {
  string t;
  for (char ch : raw) {
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') continue;
    t += (char)toupper((unsigned char)ch);
  }
  return t;
}

// 成员注册申请(公开): {stu_no, name, dept, card_no?} -> 写入 student 表 status=0 等待管理员审核
static string handleRegister(const Json& body) {
  string stuNo = body.strVal("stu_no");
  string name = body.strVal("name");
  string dept = body.strVal("dept");
  string cardNo = normalizeCardNo(body.strVal("card_no"));
  string pwd = body.strVal("pwd");
  if (stuNo.empty() || name.empty())
    return jsonErr(400, "学号与姓名必填");
  if (stuNo.size() > 20 || name.size() > 50 || dept.size() > 100)
    return jsonErr(400, "字段过长");
  if (pwd.size() < 6 || pwd.size() > 64)
    return jsonErr(400, "密码长度需 6~64 位");
  if (cardNo.size() > 32)
    return jsonErr(400, "卡号过长(最多 32 位)");
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
  // 卡号唯一: 一张卡只能绑一个学号, 否则刷卡签到会记到别人头上(按卡号查学生只会取到第一行)
  if (!cardNo.empty()) {
    QueryResult rc;
    if (!dbQuery(c, "SELECT stu_no FROM student WHERE card_no=" + dbEscape(c, cardNo), rc, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    if (!rc.rows.empty()) { dbRelease(c); return jsonErr(409, "该卡号已被其他学号绑定"); }
  }
  std::ostringstream s;
  s << "INSERT INTO student (stu_no,name,dept,card_no,pwd_hash,status) VALUES ("
    << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << dbEscape(c, dept) << ","
    << (cardNo.empty() ? string("NULL") : dbEscape(c, cardNo)) << ","
    << dbEscape(c, pwdHashStrong(pwd)) << ",0)";
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
// 注册申请审核: {student_id, action: pass|reject, card_no?}
// card_no 仅在通过时绑定: 新注册成员没有卡号就永远刷不了卡(此前只能手工改库)
static string handleStudentAudit(const Json& body) {
  int studentId = body.intVal("student_id", -1);
  string action = body.strVal("action");
  string cardNo = normalizeCardNo(body.strVal("card_no"));
  if (studentId <= 0 || (action != "pass" && action != "reject"))
    return jsonErr(400, "student_id & action(pass|reject) required");
  if (cardNo.size() > 32)
    return jsonErr(400, "卡号过长(最多 32 位)");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  if (!dbQuery(c, "SELECT id,status FROM student WHERE id=" + std::to_string(studentId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "该学生不存在或已注销"); }
  if (atoi(r.rows[0][1].c_str()) != 0) { dbRelease(c); return jsonErr(400, "该申请已审核, 不能重复操作"); }
  // 绑卡前先查重(与注册同一口径), 冲突时给出明确原因而不是数据库 500
  if (action == "pass" && !cardNo.empty()) {
    QueryResult rc;
    if (!dbQuery(c, "SELECT id FROM student WHERE card_no=" + dbEscape(c, cardNo) +
                    " AND id<>" + std::to_string(studentId), rc, err)) {
      dbRelease(c); return jsonErr(500, err);
    }
    if (!rc.rows.empty()) { dbRelease(c); return jsonErr(409, "该卡号已被其他学号绑定"); }
  }
  // 条件更新(status=0) + 影响行数校验: 并发重复审核时只有一个请求生效
  std::ostringstream s;
  s << "UPDATE student SET status=" << (action == "pass" ? 1 : 2);
  if (action == "pass" && !cardNo.empty()) s << ",card_no=" << dbEscape(c, cardNo);
  s << " WHERE id=" << studentId << " AND status=0";
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
/**
 * 事务内硬删除学生(报名 -> 学时 -> 学生行)。
 * expectPwd 非空时在同一事务、同一把行锁内校验登录密码:
 * 校验与删除之间不存在"被并发改密"的窗口(TOCTOU), 也不需要第二次查库。
 * 密码不匹配时回滚、置 pwdMismatch=true, 由调用方决定返回码。
 */
static void signupReleaseSlotsOf(MYSQL* c, const string& stuNo);   // 定义在报名辅助区, 此处先用

static bool dbDeleteStudent(MYSQL* c, const string& stuNo,
                            int& nSignup, double& hoursDeleted, string& err,
                            const string* expectPwd = nullptr, bool* pwdMismatch = nullptr) {
  nSignup = 0;
  hoursDeleted = 0;
  if (pwdMismatch) *pwdMismatch = false;
  mysql_autocommit(c, 0);

  // 锁学生行: 串行化"学生自己点注销"与"管理员同时注销"的并发请求
  QueryResult rLock;
  if (!dbQuery(c, "SELECT id,pwd_hash FROM student WHERE stu_no=" + dbEscape(c, stuNo) + " FOR UPDATE", rLock, err)) {
    mysql_rollback(c); mysql_autocommit(c, 1); return false;
  }
  if (rLock.rows.empty()) {
    mysql_rollback(c); mysql_autocommit(c, 1);
    err = "该学号不存在或已注销, 请刷新";
    return false;
  }
  // 锁定行之后再校验口令: 此刻该行的 pwd_hash 不会再被并发修改
  if (expectPwd != nullptr) {
    if (!pwdVerify(rLock.rows[0][1], *expectPwd)) {
      mysql_rollback(c); mysql_autocommit(c, 1);
      if (pwdMismatch) *pwdMismatch = true;
      err = "登录密码不正确";
      return false;
    }
  }

  // 先统计(删除后就查不到了), 用于回显与审计
  QueryResult rStat;
  if (dbQuery(c, "SELECT COUNT(*),COALESCE(SUM(CASE WHEN status=1 THEN hours ELSE 0 END),0) "
                 "FROM signup WHERE stu_no=" + dbEscape(c, stuNo), rStat, err) && !rStat.rows.empty()) {
    nSignup = atoi(rStat.rows[0][0].c_str());
    hoursDeleted = atof(rStat.rows[0][1].c_str());
  }

  QueryResult r;
  // 0) 级联删报名前先把该生占用的名额归还(按活动分组一次扣减), 否则活动会永久"假满员"
  signupReleaseSlotsOf(c, stuNo);
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

/**
 * 学生自助注销: 必须输入**本人登录密码**确认。
 * 不用学号: 学号在排行/用户列表里是公开信息, 拿它当凭据等于没有确认 ——
 * Token 一旦泄露(手机丢失/共享设备未退出), 攻击者用公开学号就能一键把账号连同
 * 报名与学时物理删除。密码是唯一"只有本人知道"的要素。
 */
static string handleStudentCancel(const Json& body, const TokenInfo& me, const string& ip) {
  if (me.role != "student")
    return jsonErr(403, "管理员请到「用户管理」页注销学生账号");
  string confirmPwd = body.strVal("confirm_pwd");
  if (confirmPwd.empty()) return jsonErr(400, "请输入登录密码以确认注销");
  // 与登录同一口径: 口令长度上限, 避免把"密码校验"变成哈希放大入口
  if (confirmPwd.size() > 128) return jsonErr(400, "口令过长");

  // 节流: 持 Token 者可反复猜密码, 猜中即毁号; 按 IP + 学号计数, 不影响登录节流
  string failKey = "cancel|" + ip + "|" + me.stu_no;
  if (loginBlocked(failKey))
    return jsonErr(429, "密码错误次数过多, 请 60 秒后再试");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  int n = 0;
  double hrs = 0;
  bool pwdMismatch = false;
  // 口令校验在事务内、锁行之后完成(见 dbDeleteStudent), 不存在校验后被改密的窗口
  if (!dbDeleteStudent(c, me.stu_no, n, hrs, err, &confirmPwd, &pwdMismatch)) {
    dbRelease(c);
    if (pwdMismatch) {
      loginFailAdd(failKey);
      return jsonErr(403, "登录密码不正确, 注销已取消");
    }
    return jsonErr(409, err);   // 并发注销/学号已不存在等
  }
  dbRelease(c);
  loginFailClear(failKey);

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

// 前向声明: 类别白名单在活动列表/表单(定义在文件更靠前的位置)里就要用到
static bool   isCategory(const string& v);
static string normCategory(const string& v);

static string handleActivityList(const string& query, const string& role, const string& loginStuNo) {
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
    // 用 taken 缓存判定剩余名额(与报名时的条件 UPDATE 同一口径), 避免每行一次子查询
    where += " AND (a.capacity=0 OR a.taken < a.capacity)";
  } else if (scope == "expired") {
    where += " AND a.end_time<NOW()";
  } else if (scope == "mine") {
    // 学生只能查自己的: 忽略客户端传入的 stu_no, 否则可枚举"他人在报名哪些活动"
    string stu = (role == "student") ? loginStuNo : qparam(query, "stu_no");
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
  // 按类别筛选(七大类白名单; 非法值忽略, 避免拼进 SQL)
  string cat = qparam(query, "category");
  if (!cat.empty() && isCategory(cat)) where += " AND a.category=" + dbEscape(c, cat);
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
    "SUM(CASE WHEN s.status<>2 THEN 1 ELSE 0 END) AS valid_count, "
    "a.category,a.taken "
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
    o.set("category", Json::Str(row[14].empty() ? string("sports") : row[14]));
    // 名额计数缓存(status<>2 的行数): 与报名条件 UPDATE 同源, 供并发/调试核对
    o.set("taken", Json::Num(row[15].empty() ? 0 : atol(row[15].c_str())));
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
  string category = "sports";   // 七大类之一, 非法值回落 sports
  bool   hasCategory = false;   // 请求体是否显式带 category(编辑时缺省则保留原值)
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
  // 类别白名单: 未知值一律回落 sports(文体活动), 保证统计口径不会出现"第八类"
  // 编辑接口允许不带 category(旧版 App 兼容): 缺省时保留库中原值, 避免一次编辑把类别刷回 sports
  f.hasCategory = (body.get("category") != nullptr);
  f.category  = normCategory(body.strVal("category"));
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
    << ",category=" << dbEscape(c, f.category)
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
  if (!dbQuery(c, "SELECT id,category FROM activity WHERE id=" + std::to_string(id), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  // 未显式传类别: 沿用库中原值(兼容旧版 App / 老脚本的编辑请求)
  if (!f.hasCategory) f.category = normCategory(r.rows[0][1]);
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

// ---------------------------- 报名辅助 ----------------------------------------
/** 活动类别白名单(七大类): 非法值一律回落 sports, 防止脏值进库影响规则匹配与统计 */
static const char* kCategoryList[7] = {"thought","practice","volunteer","innovation","sports","social","skill"};
static bool isCategory(const string& v) {
  for (int i = 0; i < 7; i++) if (v == kCategoryList[i]) return true;
  return false;
}
static string normCategory(const string& v) { return isCategory(v) ? v : string("sports"); }

/** 读取数值型系统配置(缺省 0; 规则里 0 表示"不限") */
static double cfgNum(MYSQL* c, const string& key) {
  QueryResult r; string e;
  if (!dbQuery(c, "SELECT cfg_value FROM sys_config WHERE cfg_key=" + dbEscape(c, key) + " LIMIT 1", r, e))
    return 0;
  if (r.rows.empty()) return 0;
  return atof(r.rows[0][0].c_str());
}

/** 学时统一保留 1 位小数 */
static double roundHours(double v) {
  if (v <= 0) return 0;
  return std::floor(v * 10.0 + 0.5) / 10.0;
}

/**
 * 占名额: 一条条件 UPDATE 同时完成"判满 + 计数", 不再把 activity 行锁进整个事务。
 * 依赖 InnoDB 行锁: 并发的两条 UPDATE 只有一条能让 taken<capacity 成立。
 */
static bool signupTakeSlot(MYSQL* c, int activityId, string& err) {
  QueryResult r;
  std::ostringstream s;
  s << "UPDATE activity SET taken=taken+1 WHERE id=" << activityId
    << " AND (capacity=0 OR taken<capacity)";
  if (!dbQuery(c, s.str(), r, err)) return false;
  return mysql_affected_rows(c) == 1;
}

/** 释放名额(幂等): 驳回/撤销/注销时调用, taken>0 才递减, 防止异常数据减成负数 */
static void signupReleaseSlot(MYSQL* c, int activityId) {
  QueryResult r; string e;
  std::ostringstream s;
  s << "UPDATE activity SET taken=taken-1 WHERE id=" << activityId << " AND taken>0";
  dbQuery(c, s.str(), r, e);
}

/** 释放某学生占用的全部名额(注销级联删报名前调用) */
static void signupReleaseSlotsOf(MYSQL* c, const string& stuNo) {
  QueryResult r; string e;
  std::ostringstream s;
  s << "UPDATE activity a JOIN (SELECT activity_id, COUNT(*) n FROM signup WHERE stu_no="
    << dbEscape(c, stuNo) << " AND status<>2 GROUP BY activity_id) t ON t.activity_id=a.id "
    << "SET a.taken=GREATEST(0, a.taken - t.n)";
  dbQuery(c, s.str(), r, e);
}

// 报名(幂等: client_id / (activity,stu) 冲突时视为已报名)
// 报名(身份以登录 Token 为准, 忽略请求体中的学号/姓名防伪造)
// v3.2: 锁序改为"先学生行、后活动行"(全站统一), 增加时间冲突校验, 名额改为条件 UPDATE 扣减
static string handleSignupAdd(const Json& body, const string& loginStuNo, const string& loginName) {
  string clientId = body.strVal("client_id");
  int activityId = body.intVal("activity_id", -1);
  if (clientId.empty() || activityId <= 0)
    return jsonErr(400, "client_id/activity_id required");
  if (clientId.size() > 64) clientId = clientId.substr(0, 64);   // 防超长主键撑爆索引
  const string stuNo = loginStuNo;
  const string name  = loginName;

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  mysql_autocommit(c, 0);
  auto fail = [&](int code, const string& msg) -> string {
    mysql_rollback(c);
    mysql_autocommit(c, 1);
    dbRelease(c);
    return jsonErr(code, msg);
  };

  // 1) 先锁学生行: 同一学生的并发报名/撤销在此串行化, 时间冲突校验才成立;
  //    全站统一"学生 -> 活动"的加锁顺序(与审核/注销一致), 避免 ABBA 死锁。
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, stuNo) + " FOR UPDATE", r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "该学号不存在或已注销");

  // 2) 活动信息(不加锁: 名额由条件 UPDATE 原子扣减, 无需长时间持锁)
  if (!dbQuery(c, "SELECT capacity,status,DATE_FORMAT(start_time,'%Y-%m-%d %H:%i:%s'),"
                  "DATE_FORMAT(end_time,'%Y-%m-%d %H:%i:%s'),category "
                  "FROM activity WHERE id=" + std::to_string(activityId), r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "活动不存在或已下线");
  int cap = atoi(r.rows[0][0].c_str());
  int actStatus = atoi(r.rows[0][1].c_str());
  string startTime = r.rows[0][2];
  string endTime   = r.rows[0][3];
  string category  = normCategory(r.rows[0][4]);
  if (actStatus != 1) return fail(400, "活动未开放报名");
  long long endTs = endTime.empty() ? 0 : parseLocalTime(endTime);
  if (endTs > 0 && endTs < nowMs()) return fail(400, "活动已结束, 无法报名");

  // 3) 是否已在名单内(已驳回视为未报名, 重新报名需重新占名额)
  bool already = false;
  if (!dbQuery(c, "SELECT id,status FROM signup WHERE activity_id=" + std::to_string(activityId) +
                  " AND stu_no=" + dbEscape(c, stuNo), r, err))
    return fail(500, err);
  if (!r.rows.empty() && atoi(r.rows[0][1].c_str()) != 2) already = true;

  // 4) 时间冲突: 同一时段只能有一个有效报名, 否则两个活动都被审核通过会重复认定学时
  if (!already && !startTime.empty() && !endTime.empty()) {
    QueryResult rc;
    string sql = "SELECT a.title FROM signup s JOIN activity a ON s.activity_id=a.id "
                 "WHERE s.stu_no=" + dbEscape(c, stuNo) +
                 " AND s.status<>2 AND s.activity_id<>" + std::to_string(activityId) +
                 " AND a.start_time IS NOT NULL AND a.end_time IS NOT NULL"
                 " AND a.start_time < " + dbEscape(c, endTime) +
                 " AND a.end_time > " + dbEscape(c, startTime) + " LIMIT 1";
    if (!dbQuery(c, sql, rc, err)) return fail(500, err);
    if (!rc.rows.empty())
      return fail(409, "与「" + rc.rows[0][0] + "」时间冲突, 请先撤销原报名");
  }

  // 5) 占名额(仅新建/驳回后重报): 已在名单内重复点击不重复占位
  if (!already) {
    string serr;
    if (!signupTakeSlot(c, activityId, serr)) {
      QueryResult chk;
      string e2;
      if (!dbQuery(c, "SELECT id FROM activity WHERE id=" + std::to_string(activityId), chk, e2))
        return fail(500, e2);
      if (chk.rows.empty()) return fail(404, "活动不存在或已下线");
      return fail(403, "名额已满, 无法报名");
    }
  }

  // 6) 幂等插入(沿用旧语义, 另补类别快照):
  //    client_id 冲突保留原记录; uk_act_stu 冲突时"已驳回"重置为待审核, 其余状态不变。
  //    注意不要覆盖 client_id —— 换设备重报会带来新 UUID, 覆盖会让旧设备本地记录被同步清掉。
  std::ostringstream sql;
  sql << "INSERT INTO signup (client_id,activity_id,stu_no,name,status,category) VALUES ("
      << dbEscape(c, clientId) << ","
      << activityId << ","
      << dbEscape(c, stuNo) << ","
      << dbEscape(c, name) << ",0,"
      << dbEscape(c, category) << ") "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),"
      << "remark=IF(status=2,'',remark),status=IF(status=2,0,status),name=VALUES(name),"
      << "category=IF(category='',VALUES(category),category)";
  if (!dbQuery(c, sql.str(), r, err)) return fail(500, err);
  long long id = (long long)mysql_insert_id(c);

  // 7) 兜底复检: 条件 UPDATE 已保证不超员, 这里只防"历史数据 taken 与真实行数不一致"
  if (cap > 0 && !already) {
    QueryResult r3;
    if (!dbQuery(c, "SELECT COUNT(*) FROM signup WHERE activity_id=" + std::to_string(activityId) +
                    " AND status<>2", r3, err) ||
        atoi(r3.rows[0][0].c_str()) > cap) {
      return fail(403, "名额已满, 无法报名");
    }
  }
  mysql_commit(c);
  mysql_autocommit(c, 1);

  // 返回该记录真实状态(重复报名时可能是已通过/已驳回)
  int realStatus = 0, realCheckin = 0;
  double realHours = 0;
  string realClientId = clientId;   // 服务器上真实的 client_id(命中已有记录时可能与本次不同)
  string realCategory = category;
  QueryResult r4;
  if (dbQuery(c, "SELECT client_id,status,checkin,hours,category FROM signup WHERE id=" + std::to_string(id), r4, err)
      && !r4.rows.empty()) {
    realClientId = r4.rows[0][0];
    realStatus   = atoi(r4.rows[0][1].c_str());
    realCheckin  = atoi(r4.rows[0][2].c_str());
    realHours    = atof(r4.rows[0][3].c_str());
    if (!r4.rows[0][4].empty()) realCategory = r4.rows[0][4];
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("id", Json::Num((double)id));
  data.set("client_id", Json::Str(realClientId));   // App 据此校正本地 client_id, 双端唯一
  data.set("status", Json::Num(realStatus));
  data.set("checkin", Json::Num(realCheckin));
  data.set("hours", Json::Num(realHours));
  data.set("category", Json::Str(realCategory));
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
    "DATE_FORMAT(s.checked_at,'%Y-%m-%d %H:%i:%s'),"
    "COALESCE(NULLIF(s.category,''),a.category,'sports') AS category,"
    "DATE_FORMAT(s.signout_at,'%Y-%m-%d %H:%i:%s') "
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
    o.set("category", Json::Str(row[15]));
    o.set("signout_at", Json::Str(row[16]));   // 动态码签退时间(空 = 未签退)
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

  // 先取学号/活动号(不加锁), 以便按"学生 -> 报名"的固定顺序加锁, 与报名路径保持一致
  QueryResult pre;
  if (!dbQuery(c, "SELECT stu_no,activity_id FROM signup WHERE id=" + std::to_string(signupId), pre, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (pre.rows.empty()) { dbRelease(c); return jsonErr(404, "该报名已被学生撤销或不存在, 请刷新列表"); }
  string preStuNo = pre.rows[0][0];

  mysql_autocommit(c, 0);
  auto fail = [&](int code, const string& msg) -> string {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(code, msg);
  };

  // 1) 锁学生行: 类别累计上限需要"同一学生的并发审核"串行化, 否则两条审核会读到相同的已用学时
  QueryResult lk;
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, preStuNo) + " FOR UPDATE", lk, err))
    return fail(500, err);

  // 2) 锁报名行并读活动信息(防止两个管理员/重复点击同时读到 status=0 各累计一次学时)
  string sql = "SELECT s.stu_no,s.name,s.status,a.hours,a.category,a.id FROM signup s "
               "LEFT JOIN activity a ON s.activity_id=a.id WHERE s.id=" + std::to_string(signupId) +
               " FOR UPDATE";
  if (!dbQuery(c, sql, r, err)) return fail(500, err);
  if (r.rows.empty()) return fail(404, "该报名已被学生撤销或不存在, 请刷新列表");
  string stuNo = r.rows[0][0], name = r.rows[0][1];
  int curStatus = atoi(r.rows[0][2].c_str());
  double actHours = atof(r.rows[0][3].c_str());
  string category = r.rows[0][4].empty() ? string("sports") : r.rows[0][4];
  int actId = atoi(r.rows[0][5].c_str());

  // 已审核记录禁止重复操作, 防止 hours_total 与 signup 状态不一致
  if (curStatus != 0) return fail(400, "该记录已审核, 不能重复操作");

  bool ok = true;
  string conflictMsg; // 并发冲突时的业务提示(区别于 SQL 错误)
  double finalHours = 0;
  bool capped = false;

  if (action == "pass") {
    // 3) 按类别规则折算: 先"单活动上限", 再"类别累计上限"; 规则为 0 表示不限,
    //    因此历史数据(未配置规则)审核结果与旧版完全一致, 不影响 20.5 学时基线。
    finalHours = actHours;
    double maxAct = cfgNum(c, "rule." + category + ".max_activity");
    if (maxAct > 0 && finalHours > maxAct) { finalHours = maxAct; capped = true; }
    double maxTotal = cfgNum(c, "rule." + category + ".max_total");
    if (maxTotal > 0) {
      QueryResult uq;
      if (!dbQuery(c, "SELECT COALESCE(SUM(s.hours),0) FROM signup s JOIN activity a ON s.activity_id=a.id "
                      "WHERE s.stu_no=" + dbEscape(c, stuNo) + " AND s.status=1 AND a.category=" +
                      dbEscape(c, category), uq, err)) return fail(500, err);
      double used = uq.rows.empty() ? 0 : atof(uq.rows[0][0].c_str());
      double remain = maxTotal - used;
      if (remain < 0) remain = 0;
      if (finalHours > remain) { finalHours = remain; capped = true; }
    }
    finalHours = roundHours(finalHours);

    string finalRemark = remark;
    if (capped) {
      std::ostringstream cs;
      cs << (finalRemark.empty() ? "" : "; ") << "按类别上限折算为 " << finalHours << " 学时";
      finalRemark += cs.str();
      if (finalRemark.size() > 200) finalRemark = finalRemark.substr(0, 200);
    }

    // 4) 更新报名状态+学时(条件 status=0, 影响行数必须为 1), 同时补齐类别快照
    std::ostringstream s1;
    s1 << "UPDATE signup SET status=1,hours=" << finalHours
       << ",audited_at=NOW(),remark=" << dbEscape(c, finalRemark)
       << ",category=" << dbEscape(c, category)
       << " WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s1.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) != 1) { ok = false; conflictMsg = "该记录已被其他管理员处理, 请刷新"; }
    // 5) 学时汇总自动累计
    if (ok) {
      std::ostringstream s2;
      s2 << "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) VALUES ("
         << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << finalHours << ",1) "
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
    // 驳回 = 该报名不再占用名额
    if (ok) signupReleaseSlot(c, actId);
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
  data.set("hours", Json::Num(action == "pass" ? finalHours : 0));
  data.set("category", Json::Str(category));
  data.set("hours_capped", Json::Bool(capped));
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
    // 姓名/学号按原样公开: 登录已改为「学号 + 密码」, 姓名不再是认证要素,
    // 排行/用户列表里显示全名不再构成"冒名登录"风险(此前脱敏正是为了堵这条链)。
    bool isMe = (role == "student" && !stuNo.empty() && row[0] == stuNo);
    Json o = Json::Object();
    o.set("rank", Json::Num(rank));
    o.set("stu_no", Json::Str(row[0]));
    o.set("name", Json::Str(row[1]));
    o.set("is_me", Json::Bool(isMe));
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
  string sql2 = "SELECT s.stu_no,s.name,a.title,s.hours,DATE_FORMAT(s.audited_at,'%Y-%m-%d %H:%i:%s'),"
                "COALESCE(NULLIF(s.category,''),a.category,'sports') "
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
      o.set("category", Json::Str(row[5].empty() ? string("sports") : row[5]));
      detail.push(o);
    }
  }
  // 分类汇总(图表用): 与明细同一口径, 学生端仅统计本人
  QueryResult cat;
  Json byCat = Json::Array();
  string sql3 = "SELECT COALESCE(NULLIF(s.category,''),a.category,'sports') AS cat,"
                "SUM(s.hours) AS h, COUNT(*) AS n "
                "FROM signup s LEFT JOIN activity a ON s.activity_id=a.id" + cond +
                " GROUP BY cat ORDER BY h DESC";
  if (dbQuery(c, sql3, cat, err)) {
    for (auto& row : cat.rows) {
      Json o = Json::Object();
      o.set("category", Json::Str(row[0]));
      o.set("hours", Json::Num(atof(row[1].c_str())));
      o.set("count", Json::Num(atol(row[2].c_str())));
      byCat.push(o);
    }
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("report", arr);
  data.set("detail", detail);
  data.set("by_category", byCat);
  data.set("required_hours", Json::Num(requiredHours));
  data.set("total_hours", Json::Num(allHours));
  data.set("student_count", Json::Num(rank));
  data.set("achieved_count", Json::Num(achievedCnt));
  return jsonOk(data);
}

// 读取系统配置(登录可见): 学时达标线 + v4.0 七大类学时规则
// 兼容口径: 顶层仍平铺 rule.<cat>.<key>(老客户端可直接取), 另给结构化 rules 供新版使用
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
  std::map<string, string> kv;
  for (auto& row : r.rows) {
    kv[row[0]] = row[1];
    double n = atof(row[1].c_str());
    // 数值型配置按数字下发(前端可直接参与计算), 其余按字符串
    bool numeric = !row[1].empty() && row[1].find_first_not_of("0123456789.-") == string::npos;
    data.set(row[0], numeric ? Json::Num(n) : Json::Str(row[1]));
  }
  Json rules = Json::Object();
  for (int i = 0; i < 7; i++) {
    string cat = kCategoryList[i];
    Json o = Json::Object();
    auto a = kv.find("rule." + cat + ".max_activity");
    auto b = kv.find("rule." + cat + ".max_total");
    o.set("max_activity", Json::Num(a == kv.end() ? 0 : atof(a->second.c_str())));
    o.set("max_total",    Json::Num(b == kv.end() ? 0 : atof(b->second.c_str())));
    rules.set(cat, o);
  }
  data.set("rules", rules);
  return jsonOk(data);
}

// 设置配置(仅管理员): {required_hours?, rules?: {cat: {max_activity?, max_total?}}}
// 先全量校验再落库: 任意一项非法就整体拒绝, 避免"改了一半"的半配置状态。
static string handleConfigSet(const Json& body) {
  const Json* reqJ   = body.get("required_hours");
  const Json* rulesJ = body.get("rules");
  if (!reqJ && !rulesJ) return jsonErr(400, "无可更新配置(required_hours / rules)");
  double req = reqJ ? body.numVal("required_hours", -1) : -1;
  if (reqJ && (req < 0 || req > 999))
    return jsonErr(400, "required_hours 应在 [0,999] 范围内(0 表示不设达标线)");
  if (rulesJ && rulesJ->t != Json::OBJ) return jsonErr(400, "rules 应为对象");
  struct KV { string k; double v; };
  vector<KV> updates;
  if (reqJ) updates.push_back({"required_hours", req});
  if (rulesJ) {
    for (auto& p : rulesJ->obj) {
      if (!isCategory(p.first)) return jsonErr(400, "未知类别: " + p.first);
      if (p.second.t != Json::OBJ) return jsonErr(400, "规则应为对象: " + p.first);
      for (auto& f : p.second.obj) {
        if (f.first != "max_activity" && f.first != "max_total")
          return jsonErr(400, "未知规则项: " + f.first + "(仅 max_activity / max_total)");
        if (f.second.t != Json::NUM)
          return jsonErr(400, "规则值应为数字: " + p.first + "." + f.first);
        if (f.second.num < 0 || f.second.num > 999)
          return jsonErr(400, "规则值应在 [0,999]: " + p.first + "." + f.first);
        updates.push_back({"rule." + p.first + "." + f.first, f.second.num});
      }
    }
  }
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  mysql_autocommit(c, 0);
  for (auto& u : updates) {
    std::ostringstream s;
    s << "INSERT INTO sys_config (cfg_key,cfg_value) VALUES (" << dbEscape(c, u.k) << ",'" << u.v << "') "
      << "ON DUPLICATE KEY UPDATE cfg_value=VALUES(cfg_value)";
    if (!dbQuery(c, s.str(), r, err)) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
      return jsonErr(500, err);
    }
  }
  mysql_commit(c);
  mysql_autocommit(c, 1);
  dbRelease(c);
  Json data = Json::Object();
  if (reqJ) data.set("required_hours", Json::Num(req));
  Json changed = Json::Object();
  for (auto& u : updates) {
    if (u.k == "required_hours") continue;
    changed.set(u.k, Json::Num(u.v));
  }
  data.set("rules", changed);
  data.set("updated", Json::Num((double)updates.size()));
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
    ? "SELECT id,stu_no,status,activity_id FROM signup WHERE id=" + std::to_string(signupId)
    : "SELECT id,stu_no,status,activity_id FROM signup WHERE activity_id=" + std::to_string(activityId) +
      " AND stu_no=" + dbEscape(c, loginStuNo);
  if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "报名记录不存在"); }
  signupId = atoi(r.rows[0][0].c_str());
  if (r.rows[0][1] != loginStuNo) { dbRelease(c); return jsonErr(403, "只能撤销本人的报名记录"); }
  if (atoi(r.rows[0][2].c_str()) != 0) { dbRelease(c); return jsonErr(400, "仅待审核的报名可以撤销"); }
  int actId = atoi(r.rows[0][3].c_str());   // DELETE 会覆盖 r, 先存下来
  if (!dbQuery(c, "DELETE FROM signup WHERE id=" + std::to_string(signupId) + " AND status=0", r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (mysql_affected_rows(c) != 1) { dbRelease(c); return jsonErr(409, "该报名已被审核, 无法撤销"); }
  signupReleaseSlot(c, actId);   // 撤销后名额归还
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
  if (!dbQuery(c, "SELECT hours,status,DATE_FORMAT(end_time,'%Y-%m-%d %H:%i:%s'),category "
                  "FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  double actHours = atof(r.rows[0][0].c_str());
  int actStatus = atoi(r.rows[0][1].c_str());
  string category = normCategory(r.rows[0][3]);   // 新建报名时写入类别快照
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
    // 新建报名同样占名额(条件 UPDATE 原子扣减): 容量满了不能再"刷卡补录"绕过上限
    string serr;
    if (!signupTakeSlot(c, activityId, serr)) {
      mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
      return jsonErr(403, "名额已满, 无法刷卡认定学时");
    }
    // 无报名: 创建并通过; 影响行数为 1 才说明本次真正新建(2=命中唯一键更新, 说明并发已建)
    std::ostringstream s;
    s << "INSERT INTO signup (client_id,activity_id,stu_no,name,status,checkin,checked_at,card_no,hours,audited_at,category) VALUES ("
      << dbEscape(c, clientId) << "," << activityId << ","
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << ",1,1,NOW(),"
      << dbEscape(c, cardNo) << "," << actHours << ",NOW()," << dbEscape(c, category) << ") "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),checkin=1,"
      << "checked_at=COALESCE(checked_at,NOW()),card_no=VALUES(card_no),hours=VALUES(hours)";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) == 1) needAccumulate = true;
    else { ok = false; conflictMsg = "签到冲突(并发刷卡), 请重新刷卡"; }
  } else if (st == 0) {
    // 待审核 -> 通过 + 签到(条件 status=0, 防止并发重复累计学时)
    std::ostringstream s;
    s << "UPDATE signup SET status=1,checkin=1,checked_at=NOW(),card_no=" << dbEscape(c, cardNo)
      << ",hours=" << actHours << ",audited_at=NOW() WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s.str(), r, err)) ok = false;
    else if (mysql_affected_rows(c) == 1) needAccumulate = true;
    else { ok = false; conflictMsg = "该报名刚刚被审核, 请重新刷卡"; }
  } else if (st == 1) {
    // 已通过 -> 仅签到(不重复累计学时)
    std::ostringstream s;
    // 保留首次签到时间: 卡一直放在读头上重复上报时不覆盖原始时刻
    s << "UPDATE signup SET checkin=1,checked_at=COALESCE(checked_at,NOW()),card_no="
      << dbEscape(c, cardNo) << " WHERE id=" << signupId;
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

// ---------------------------- 动态签到码(v3.2) --------------------------------
// 现场签到: 管理员端每 60 秒刷新一个 6 位码, 学生输入即完成签到。
// 与 RFID 刷卡并存 —— 刷卡走 /api/signin(设备密钥), 输码走 /api/signin/code(本人 Token)。

/** 第 window 个 60 秒窗口的 6 位签到码(由启动时随机 secret 派生, 重启即全量失效) */
static string signinCodeFor(int activityId, long long window) {
  string raw = g_signin_secret + "|" + std::to_string(activityId) + "|" + std::to_string(window);
  string h = sha256Hex(raw);
  unsigned long v = 0;
  for (int i = 0; i < 8 && i < (int)h.size(); i++) {
    char ch = h[i];
    int d = (ch >= '0' && ch <= '9') ? (ch - '0')
          : (ch >= 'a' && ch <= 'f') ? (ch - 'a' + 10)
          : (ch >= 'A' && ch <= 'F') ? (ch - 'A' + 10) : 0;
    v = v * 16 + (unsigned long)d;
  }
  char buf[8];
  snprintf(buf, sizeof(buf), "%06lu", v % 1000000UL);
  return string(buf);
}

/** GET /api/activity/signin_code?activity_id= (管理员): 当前签到码 + 剩余秒数 */
static string handleSigninCode(const string& query) {
  int activityId = atoi(qparam(query, "activity_id").c_str());
  if (activityId <= 0) return jsonErr(400, "activity_id required");
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  QueryResult r; string err;
  if (!dbQuery(c, "SELECT title,status FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  string title = r.rows[0][0];
  dbRelease(c);
  long long w = nowMs() / 60000;
  Json d = Json::Object();
  d.set("activity_id", Json::Num(activityId));
  d.set("activity_title", Json::Str(title));
  d.set("code", Json::Str(signinCodeFor(activityId, w)));
  d.set("window", Json::Num((double)w));
  d.set("expire_in", Json::Num(60 - (int)((nowMs() / 1000) % 60)));   // 本窗口剩余秒数
  return jsonOk(d);
}

/** POST /api/signin/code {activity_id, code} (学生): 校验签到码并签到 */
static string handleSigninByCode(const Json& body, const TokenInfo& me) {
  int activityId = body.intVal("activity_id", -1);
  string code = body.strVal("code");
  if (activityId <= 0 || code.empty()) return jsonErr(400, "activity_id & code required");
  long long w = nowMs() / 60000;
  // 允许当前与前一个窗口(最多 60 秒宽限): 学生点提交时正好跨窗口也不至于失败
  if (code != signinCodeFor(activityId, w) && code != signinCodeFor(activityId, w - 1))
    return jsonErr(403, "签到码错误或已过期, 请向管理员索取最新签到码");

  const string stuNo = me.stu_no;
  const string name  = me.name;
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err; QueryResult r;
  auto fail = [&](int code2, const string& msg) -> string {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(code2, msg);
  };

  if (!dbQuery(c, "SELECT hours,status,DATE_FORMAT(end_time,'%Y-%m-%d %H:%i:%s'),category "
                  "FROM activity WHERE id=" + std::to_string(activityId), r, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (r.rows.empty()) { dbRelease(c); return jsonErr(404, "活动不存在或已下线"); }
  double actHours = atof(r.rows[0][0].c_str());
  int actStatus = atoi(r.rows[0][1].c_str());
  string category = normCategory(r.rows[0][3]);
  if (actStatus != 1) { dbRelease(c); return jsonErr(400, "活动未开放报名"); }
  long long endTs = r.rows[0][2].empty() ? 0 : parseLocalTime(r.rows[0][2]);
  if (endTs > 0 && endTs < nowMs()) { dbRelease(c); return jsonErr(400, "活动已结束, 不能再签到"); }

  mysql_autocommit(c, 0);
  // 锁学生行(与报名同序), 串行化同一学生的重复/并发签到
  QueryResult lk;
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, stuNo) + " FOR UPDATE", lk, err))
    return fail(500, err);
  if (lk.rows.empty()) return fail(404, "该学号不存在或已注销");

  QueryResult ex;
  if (!dbQuery(c, "SELECT id,status FROM signup WHERE activity_id=" + std::to_string(activityId) +
                  " AND stu_no=" + dbEscape(c, stuNo), ex, err))
    return fail(500, err);
  int signupId = 0, st = 0;
  if (!ex.rows.empty()) { signupId = atoi(ex.rows[0][0].c_str()); st = atoi(ex.rows[0][1].c_str()); }
  if (st == 2) return fail(403, "该报名已被管理员驳回, 请重新报名后再签到");

  bool needAccumulate = false;
  if (signupId == 0) {
    string serr;
    if (!signupTakeSlot(c, activityId, serr)) return fail(403, "名额已满, 无法签到");
    std::ostringstream s;
    s << "INSERT INTO signup (client_id,activity_id,stu_no,name,status,checkin,checked_at,hours,audited_at,category) VALUES ("
      << dbEscape(c, "code-" + stuNo + "-" + std::to_string(activityId)) << "," << activityId << ","
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << ",1,1,NOW(),"
      << actHours << ",NOW()," << dbEscape(c, category) << ") "
      << "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id),checkin=1,"
      << "checked_at=COALESCE(checked_at,NOW())";
    if (!dbQuery(c, s.str(), r, err)) return fail(500, err);
    needAccumulate = (mysql_affected_rows(c) == 1);
  } else if (st == 0) {
    std::ostringstream s;
    s << "UPDATE signup SET status=1,checkin=1,checked_at=NOW(),hours=" << actHours
      << ",audited_at=NOW(),category=" << dbEscape(c, category)
      << " WHERE id=" << signupId << " AND status=0";
    if (!dbQuery(c, s.str(), r, err)) return fail(500, err);
    if (mysql_affected_rows(c) != 1) return fail(409, "该报名刚刚被审核, 请重新签到");
    needAccumulate = true;
  } else {
    // 已通过: 只补签到时刻, 不重复累计学时
    std::ostringstream s;
    s << "UPDATE signup SET checkin=1,checked_at=COALESCE(checked_at,NOW()) WHERE id=" << signupId;
    if (!dbQuery(c, s.str(), r, err)) return fail(500, err);
  }

  if (needAccumulate) {
    std::ostringstream s;
    s << "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) VALUES ("
      << dbEscape(c, stuNo) << "," << dbEscape(c, name) << "," << actHours << ",1) "
      << "ON DUPLICATE KEY UPDATE total_hours=total_hours+VALUES(total_hours),"
      << "sign_count=sign_count+1,name=VALUES(name)";
    if (!dbQuery(c, s.str(), r, err)) return fail(500, err);
  }
  mysql_commit(c);
  mysql_autocommit(c, 1);
  dbRelease(c);

  Json d = Json::Object();
  d.set("activity_id", Json::Num(activityId));
  d.set("hours", Json::Num(actHours));
  d.set("checkin", Json::Num(1));
  d.set("signin_at", Json::Str(nowStr()));
  d.set("category", Json::Str(category));
  return jsonOk(d);
}

/** POST /api/signin/out {activity_id} (学生): 记录签退, 按实际在场时长折算本次学时 */
static string handleSigninOut(const Json& body, const TokenInfo& me) {
  int activityId = body.intVal("activity_id", -1);
  if (activityId <= 0) return jsonErr(400, "activity_id required");
  const string stuNo = me.stu_no;
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err; QueryResult r;
  auto fail = [&](int code2, const string& msg) -> string {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(code2, msg);
  };

  mysql_autocommit(c, 0);
  string sql = "SELECT s.id,s.status,s.checkin,DATE_FORMAT(s.checked_at,'%Y-%m-%d %H:%i:%s'),s.hours,"
               "DATE_FORMAT(s.signout_at,'%Y-%m-%d %H:%i:%s'),a.hours,"
               "DATE_FORMAT(a.start_time,'%Y-%m-%d %H:%i:%s'),DATE_FORMAT(a.end_time,'%Y-%m-%d %H:%i:%s') "
               "FROM signup s JOIN activity a ON s.activity_id=a.id WHERE s.stu_no=" + dbEscape(c, stuNo) +
               " AND s.activity_id=" + std::to_string(activityId) + " FOR UPDATE";
  if (!dbQuery(c, sql, r, err)) return fail(500, err);
  if (r.rows.empty()) return fail(404, "没有该活动的报名记录");
  int signupId = atoi(r.rows[0][0].c_str());
  int st = atoi(r.rows[0][1].c_str());
  int checkin = atoi(r.rows[0][2].c_str());
  string checkedAt = r.rows[0][3];
  double curHours = atof(r.rows[0][4].c_str());
  string signoutAt = r.rows[0][5];
  double actHours = atof(r.rows[0][6].c_str());
  string aStart = r.rows[0][7], aEnd = r.rows[0][8];

  if (!checkin) return fail(409, "尚未签到, 不能签退");
  if (!signoutAt.empty()) return fail(409, "已签退, 请勿重复操作");

  long long now = nowMs();
  long long checkedTs = checkedAt.empty() ? 0 : parseLocalTime(checkedAt);
  long long sTs = aStart.empty() ? 0 : parseLocalTime(aStart);
  long long eTs = aEnd.empty() ? 0 : parseLocalTime(aEnd);

  if (!dbQuery(c, "UPDATE signup SET signout_at=NOW() WHERE id=" + std::to_string(signupId), r, err))
    return fail(500, err);

  // 折算规则: 实际在场 / 计划时长, 上限 1.0; 按 0.5 学时步进取整, 下限 0.5(到场即认定)。
  // 仅在"计划时长 > 0 且活动本身有学时"时生效:
  //   - 0 学时活动(导入/历史数据)不能因为下限被抬成 0.5, 否则等于凭空发学时;
  //   - 零时长活动(start=end)没有计划时长, 折算没有意义, 保留审核时的学时。
  double newHours = curHours;
  double minutes = 0;
  if (checkedTs > 0 && sTs > 0 && eTs > sTs && actHours > 0) {
    double planned = (double)(eTs - sTs) / 60000.0;
    double actual  = (double)(now - checkedTs) / 60000.0;
    if (actual < 0) actual = 0;
    if (actual > planned) actual = planned;
    minutes = actual;
    newHours = actHours * (planned > 0 ? actual / planned : 1.0);
    newHours = std::floor(newHours * 2.0 + 0.5) / 2.0;   // 0.5 步进
    if (newHours < 0.5) newHours = 0.5;
    if (newHours > actHours) newHours = actHours;
  }

  if (st == 1 && fabs(newHours - curHours) >= 0.05) {
    double delta = newHours - curHours;
    std::ostringstream s1;
    s1 << "UPDATE signup SET hours=" << newHours << " WHERE id=" << signupId;
    if (!dbQuery(c, s1.str(), r, err)) return fail(500, err);
    std::ostringstream s2;
    s2 << "UPDATE hours_total SET total_hours=GREATEST(0,total_hours+" << delta
       << ") WHERE stu_no=" << dbEscape(c, stuNo);
    if (!dbQuery(c, s2.str(), r, err)) return fail(500, err);
  }

  mysql_commit(c);
  mysql_autocommit(c, 1);
  dbRelease(c);

  Json d = Json::Object();
  d.set("activity_id", Json::Num(activityId));
  d.set("hours", Json::Num(newHours));
  d.set("minutes", Json::Num((double)(int)(minutes + 0.5)));
  d.set("signout_at", Json::Str(nowStr()));
  return jsonOk(d);
}

// ---------------------------- v4.0 学时申诉 ----------------------------------
/**
 * 学生发起申诉: {signup_id, reason}
 * 仅本人、仅"已通过"的报名、同一报名只能有一条待处理申诉。
 * 加锁顺序与报名/审核一致(学生行 -> 报名行), 避免并发重复申诉与 ABBA 死锁。
 */
static string handleAppealAdd(const Json& body, const TokenInfo& me) {
  int signupId = body.intVal("signup_id", -1);
  string reason = body.strVal("reason");
  if (signupId <= 0) return jsonErr(400, "signup_id required");
  if (reason.size() < 5) return jsonErr(400, "请填写申诉理由(至少 5 个字)");
  if (reason.size() > 500) reason = reason.substr(0, 500);

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  mysql_autocommit(c, 0);
  auto fail = [&](int code, const string& msg) -> string {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(code, msg);
  };
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, me.stu_no) + " FOR UPDATE", r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "账号不存在或已注销");

  if (!dbQuery(c, "SELECT stu_no,status,hours FROM signup WHERE id=" + std::to_string(signupId), r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "报名记录不存在");
  if (r.rows[0][0] != me.stu_no) return fail(403, "只能申诉本人的报名记录");
  if (atoi(r.rows[0][1].c_str()) != 1) return fail(400, "仅已通过认定的报名可以申诉");
  double hoursBefore = atof(r.rows[0][2].c_str());

  QueryResult ex;
  if (!dbQuery(c, "SELECT id FROM appeal WHERE signup_id=" + std::to_string(signupId) + " AND status=0", ex, err))
    return fail(500, err);
  if (!ex.rows.empty()) return fail(409, "该报名已有待处理申诉, 请等待管理员处理");

  std::ostringstream ins;
  ins << "INSERT INTO appeal (stu_no,signup_id,reason,hours_before) VALUES("
      << dbEscape(c, me.stu_no) << "," << signupId << "," << dbEscape(c, reason) << "," << hoursBefore << ")";
  if (!dbQuery(c, ins.str(), r, err)) return fail(500, err);
  long long id = (long long)mysql_insert_id(c);
  mysql_commit(c);
  mysql_autocommit(c, 1);
  dbRelease(c);
  Json d = Json::Object();
  d.set("id", Json::Num((double)id));
  d.set("status", Json::Num(0));
  d.set("hours_before", Json::Num(hoursBefore));
  return jsonOk(d);
}

/**
 * 申诉列表: 学生只看本人; 管理员可看全量, 支持 status / stu_no / 分页。
 * 附带报名与活动信息, App 无需二次查询。
 */
static string handleAppealList(const string& query, const string& role, const string& loginStuNo) {
  int status = -1;
  string sv = qparam(query, "status");
  if (!sv.empty()) status = atoi(sv.c_str());
  if (status < -1 || status > 2) status = -1;
  int page = atoi(qparam(query, "page").c_str());
  int size = atoi(qparam(query, "size").c_str());
  if (page < 1) page = 1;
  if (size < 0) size = 0;
  if (size > 200) size = 200;

  string stuNo = (role == "student") ? loginStuNo : qparam(query, "stu_no");

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  string cond;
  if (!stuNo.empty()) cond += " AND ap.stu_no=" + dbEscape(c, stuNo);
  if (status >= 0) cond += " AND ap.status=" + std::to_string(status);

  QueryResult cnt;
  long long total = 0;
  if (dbQuery(c, "SELECT COUNT(*) FROM appeal ap WHERE 1=1" + cond, cnt, err) && !cnt.rows.empty())
    total = atol(cnt.rows[0][0].c_str());

  string sql =
    "SELECT ap.id,ap.stu_no,ap.signup_id,ap.reason,ap.status,ap.reply,"
    "DATE_FORMAT(ap.created_at,'%Y-%m-%d %H:%i:%s'),"
    "DATE_FORMAT(ap.handled_at,'%Y-%m-%d %H:%i:%s'),ap.handler,"
    "ap.hours_before,ap.hours_after,"
    "s.name,s.activity_id,COALESCE(a.title,''),COALESCE(a.hours,0),COALESCE(s.hours,0) "
    "FROM appeal ap JOIN signup s ON ap.signup_id=s.id "
    "LEFT JOIN activity a ON s.activity_id=a.id WHERE 1=1" + cond + " ORDER BY ap.id DESC";
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
    o.set("stu_no", Json::Str(row[1]));
    o.set("signup_id", Json::Num(atol(row[2].c_str())));
    o.set("reason", Json::Str(row[3]));
    o.set("status", Json::Num(atol(row[4].c_str())));
    o.set("reply", Json::Str(row[5]));
    o.set("created_at", Json::Str(row[6]));
    o.set("handled_at", Json::Str(row[7]));
    o.set("handler", Json::Str(row[8]));
    o.set("hours_before", Json::Num(atof(row[9].c_str())));
    // 驳回时 hours_after 为 NULL: 用 -1 表示"未调整", App 显示"—"
    o.set("hours_after", Json::Num(row[10].empty() ? -1 : atof(row[10].c_str())));
    o.set("name", Json::Str(row[11]));
    o.set("activity_id", Json::Num(atol(row[12].c_str())));
    o.set("activity_title", Json::Str(row[13]));
    o.set("activity_hours", Json::Num(atof(row[14].c_str())));
    o.set("signup_hours", Json::Num(atof(row[15].c_str())));
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

/**
 * 管理员处理申诉: {appeal_id, action: pass|reject, reply, hours?}
 * pass 时可把认定学时调整到 [0, 活动学时]; 调整后按明细重算该生 hours_total(锁学生行, 无并发)。
 * reject 只记录理由, 不改学时。
 */
static string handleAppealAudit(const Json& body, const TokenInfo& me) {
  int appealId = body.intVal("appeal_id", -1);
  string action = body.strVal("action");
  string reply = body.strVal("reply");
  double reqHours = body.numVal("hours", -1);
  if (appealId <= 0 || (action != "pass" && action != "reject"))
    return jsonErr(400, "appeal_id & action(pass|reject) required");
  if (reply.size() > 500) reply = reply.substr(0, 500);
  if (action == "reject" && reply.size() < 2)
    return jsonErr(400, "驳回需填写原因(至少 2 个字), 学生端会看到");
  string handler = me.name.empty() ? string("管理员") : me.name;

  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;
  // 预读学号(不加锁), 之后严格按 student -> appeal 顺序加锁
  QueryResult pre;
  if (!dbQuery(c, "SELECT stu_no FROM appeal WHERE id=" + std::to_string(appealId), pre, err)) {
    dbRelease(c); return jsonErr(500, err);
  }
  if (pre.rows.empty()) { dbRelease(c); return jsonErr(404, "申诉不存在"); }
  string stuNo = pre.rows[0][0];

  mysql_autocommit(c, 0);
  auto fail = [&](int code, const string& msg) -> string {
    mysql_rollback(c); mysql_autocommit(c, 1); dbRelease(c);
    return jsonErr(code, msg);
  };
  if (!dbQuery(c, "SELECT id FROM student WHERE stu_no=" + dbEscape(c, stuNo) + " FOR UPDATE", r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "申诉人已注销");

  if (!dbQuery(c, "SELECT ap.status,ap.signup_id,ap.hours_before,s.status,s.hours,"
                  "COALESCE(a.hours,0),COALESCE(s.name,'') "
                  "FROM appeal ap JOIN signup s ON ap.signup_id=s.id "
                  "LEFT JOIN activity a ON s.activity_id=a.id "
                  "WHERE ap.id=" + std::to_string(appealId) + " FOR UPDATE", r, err))
    return fail(500, err);
  if (r.rows.empty()) return fail(404, "申诉对应的报名不存在");
  if (atoi(r.rows[0][0].c_str()) != 0) return fail(409, "该申诉已处理, 请刷新列表");
  int signupId = atoi(r.rows[0][1].c_str());
  double curHours = atof(r.rows[0][4].c_str());
  double actHours = atof(r.rows[0][5].c_str());
  string stuName = r.rows[0][6];

  if (action == "reject") {
    std::ostringstream s;
    s << "UPDATE appeal SET status=2,reply=" << dbEscape(c, reply)
      << ",handled_at=NOW(),handler=" << dbEscape(c, handler)
      << " WHERE id=" << appealId << " AND status=0";
    if (!dbQuery(c, s.str(), r, err)) return fail(500, err);
    if (mysql_affected_rows(c) != 1) return fail(409, "该申诉已被其他管理员处理");
    mysql_commit(c); mysql_autocommit(c, 1); dbRelease(c);
    Json d = Json::Object();
    d.set("id", Json::Num(appealId));
    d.set("status", Json::Num(2));
    d.set("hours_after", Json::Num(-1));
    return jsonOk(d);
  }

  if (atoi(r.rows[0][3].c_str()) != 1) return fail(409, "该报名已不是已通过状态, 无法调整学时");
  double target = (reqHours < 0) ? curHours : reqHours;
  if (target < 0 || target > actHours + 1e-6) {
    std::ostringstream em;
    em << "调整学时应在 0 ~ " << actHours << " 之间";
    return fail(400, em.str());
  }

  std::ostringstream upd;
  upd << "UPDATE signup SET hours=" << target << " WHERE id=" << signupId << " AND status=1";
  if (!dbQuery(c, upd.str(), r, err)) return fail(500, err);
  if (mysql_affected_rows(c) != 1) return fail(409, "该报名状态已变化, 请刷新");

  // 以明细为事实来源重算该生汇总: 比对差额增减更不容易漂移
  std::ostringstream ht;
  ht << "INSERT INTO hours_total (stu_no,name,total_hours,sign_count) "
     << "SELECT stu_no,MAX(name),COALESCE(SUM(hours),0),COUNT(*) FROM signup "
     << "WHERE stu_no=" << dbEscape(c, stuNo) << " AND status=1 GROUP BY stu_no "
     << "ON DUPLICATE KEY UPDATE total_hours=VALUES(total_hours),sign_count=VALUES(sign_count),name=VALUES(name)";
  if (!dbQuery(c, ht.str(), r, err)) return fail(500, err);

  std::ostringstream upa;
  upa << "UPDATE appeal SET status=1,reply=" << dbEscape(c, reply)
      << ",hours_after=" << target << ",handled_at=NOW(),handler=" << dbEscape(c, handler)
      << " WHERE id=" << appealId << " AND status=0";
  if (!dbQuery(c, upa.str(), r, err)) return fail(500, err);
  if (mysql_affected_rows(c) != 1) return fail(409, "该申诉已被其他管理员处理");
  mysql_commit(c); mysql_autocommit(c, 1); dbRelease(c);
  Json d = Json::Object();
  d.set("id", Json::Num(appealId));
  d.set("status", Json::Num(1));
  d.set("hours_before", Json::Num(curHours));
  d.set("hours_after", Json::Num(target));
  d.set("student", Json::Str(stuName));
  return jsonOk(d);
}

/**
 * 签到异常检测(管理员, 只读): 三类运营风险
 *   burst          同一活动 10 分钟内签到 >= 5 条(疑似代签/批量刷卡)
 *   not_signed_out 签到后超过 24 小时仍未签退(学时按全额认定偏高)
 *   hours_exceed   认定学时大于活动学时(历史脏数据/手工改库)
 */
static string handleAnomalyReport() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  string err;
  QueryResult r;

  Json burst = Json::Array();
  string sqlBurst =
    "SELECT a.id,a.title,DATE_FORMAT(FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(s.checked_at)/600)*600),"
    "'%Y-%m-%d %H:%i') AS w,COUNT(*) AS cnt,"
    "GROUP_CONCAT(DISTINCT s.stu_no ORDER BY s.stu_no SEPARATOR '|') "
    "FROM signup s JOIN activity a ON s.activity_id=a.id "
    "WHERE s.checkin=1 AND s.checked_at IS NOT NULL "
    // 按 SELECT 别名分组: only_full_group_by 下重复写窗口表达式会判定为
    // "非聚合列不在 GROUP BY"(表达式等价性不被识别), 别名分组可绕过且语义一致
    "GROUP BY a.id,w "
    "HAVING COUNT(*)>=5 ORDER BY cnt DESC LIMIT 20";
  if (dbQuery(c, sqlBurst, r, err)) {
    for (auto& row : r.rows) {
      Json o = Json::Object();
      o.set("activity_id", Json::Num(atol(row[0].c_str())));
      o.set("activity_title", Json::Str(row[1]));
      o.set("window_start", Json::Str(row[2]));
      o.set("count", Json::Num(atol(row[3].c_str())));
      o.set("students", Json::Str(row[4]));
      burst.push(o);
    }
  }

  Json notOut = Json::Array();
  string sqlNotOut =
    "SELECT s.id,s.stu_no,s.name,a.title,"
    "DATE_FORMAT(s.checked_at,'%Y-%m-%d %H:%i:%s'),"
    "TIMESTAMPDIFF(HOUR,s.checked_at,NOW()),s.hours "
    "FROM signup s JOIN activity a ON s.activity_id=a.id "
    "WHERE s.checkin=1 AND s.signout_at IS NULL AND s.checked_at IS NOT NULL "
    "AND s.checked_at < NOW()-INTERVAL 24 HOUR "
    "ORDER BY s.checked_at ASC LIMIT 50";
  if (dbQuery(c, sqlNotOut, r, err)) {
    for (auto& row : r.rows) {
      Json o = Json::Object();
      o.set("signup_id", Json::Num(atol(row[0].c_str())));
      o.set("stu_no", Json::Str(row[1]));
      o.set("name", Json::Str(row[2]));
      o.set("activity_title", Json::Str(row[3]));
      o.set("checked_at", Json::Str(row[4]));
      o.set("hours_waiting", Json::Num(atol(row[5].c_str())));
      o.set("hours", Json::Num(atof(row[6].c_str())));
      notOut.push(o);
    }
  }

  Json exceed = Json::Array();
  string sqlExceed =
    "SELECT s.id,s.stu_no,s.name,a.title,s.hours,COALESCE(a.hours,0) "
    "FROM signup s JOIN activity a ON s.activity_id=a.id "
    "WHERE s.status=1 AND s.hours > a.hours "
    "ORDER BY (s.hours-a.hours) DESC LIMIT 50";
  if (dbQuery(c, sqlExceed, r, err)) {
    for (auto& row : r.rows) {
      Json o = Json::Object();
      o.set("signup_id", Json::Num(atol(row[0].c_str())));
      o.set("stu_no", Json::Str(row[1]));
      o.set("name", Json::Str(row[2]));
      o.set("activity_title", Json::Str(row[3]));
      o.set("hours", Json::Num(atof(row[4].c_str())));
      o.set("activity_hours", Json::Num(atof(row[5].c_str())));
      exceed.push(o);
    }
  }
  dbRelease(c);

  Json summary = Json::Object();
  summary.set("burst", Json::Num((double)burst.arr.size()));
  summary.set("not_signed_out", Json::Num((double)notOut.arr.size()));
  summary.set("hours_exceed", Json::Num((double)exceed.arr.size()));
  Json data = Json::Object();
  data.set("generated_at", Json::Str(nowStr()));
  data.set("burst", burst);
  data.set("not_signed_out", notOut);
  data.set("hours_exceed", exceed);
  data.set("summary", summary);
  return jsonOk(data);
}

/** GET /api/report/warning (管理员): 未达标名单 + 缺口学时, 供导出/通知 */
static string handleHoursWarning() {
  MYSQL* c = dbConnect();
  if (!c) return jsonErr(500, "数据库连接失败, 请检查 MySQL 服务");
  QueryResult r; string err;
  double required = 0;
  QueryResult cf;
  if (dbQuery(c, "SELECT cfg_value FROM sys_config WHERE cfg_key='required_hours'", cf, err) && !cf.rows.empty())
    required = atof(cf.rows[0][0].c_str());

  Json arr = Json::Array();
  int nWarn = 0;
  if (required > 0) {
    std::ostringstream req;
    req << required;
    string sql =
      "SELECT st.stu_no,st.name,st.dept,COALESCE(ht.total_hours,0) AS th,"
      "COALESCE(ht.sign_count,0) AS sc,"
      "(SELECT DATE_FORMAT(MAX(s.audited_at),'%Y-%m-%d %H:%i:%s') FROM signup s "
      " WHERE s.stu_no=st.stu_no AND s.status=1) AS last_at "
      "FROM student st LEFT JOIN hours_total ht ON ht.stu_no=st.stu_no "
      "WHERE st.status=1 AND COALESCE(ht.total_hours,0) < " + req.str() +
      " ORDER BY th ASC, st.stu_no ASC";
    if (!dbQuery(c, sql, r, err)) { dbRelease(c); return jsonErr(500, err); }
    for (auto& row : r.rows) {
      double th = atof(row[3].c_str());
      double gap = required - th;
      if (gap < 0) gap = 0;
      Json o = Json::Object();
      o.set("stu_no", Json::Str(row[0]));
      o.set("name", Json::Str(row[1]));
      o.set("dept", Json::Str(row[2]));
      o.set("total_hours", Json::Num(th));
      o.set("sign_count", Json::Num(atol(row[4].c_str())));
      o.set("gap", Json::Num(roundHours(gap)));
      o.set("last_activity_at", Json::Str(row[5]));
      arr.push(o);
      nWarn++;
    }
  }
  dbRelease(c);
  Json data = Json::Object();
  data.set("required_hours", Json::Num(required));
  data.set("list", arr);
  data.set("count", Json::Num((double)nWarn));
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
  // 只认响应体里第一个字段("code" 是 jsonOk/jsonErr 的首字段),
  // 避免 msg/detail 文本里恰好出现 "code": 时误判状态
  size_t bodyPos = resp.find("\r\n\r\n");
  size_t from = (bodyPos == string::npos) ? 0 : bodyPos + 4;
  size_t p = resp.find("\"code\":", from);
  if (p == string::npos) return 200;
  if (bodyPos != string::npos && p > bodyPos + 12) return 200;
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
    d.set("version", Json::Str("4.0"));
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
    return handleLogin(body, req.ip);
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

  // 动态签到码: 管理员取当前码(60 秒刷新), 学生输码签到
  if (req.method == "GET" && p == "/api/activity/signin_code") {
    if (me.role != "admin") return needAdmin();
    return handleSigninCode(req.query);
  }
  if (req.method == "POST" && p == "/api/signin/code") {
    if (me.role != "student") return jsonErr(403, "仅普通成员可通过签到码签到");
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSigninByCode(body, me);
  }
  if (req.method == "POST" && p == "/api/signin/out") {
    if (me.role != "student") return jsonErr(403, "仅普通成员可签退");
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleSigninOut(body, me);
  }

  // 学分预警名单(未达标 + 缺口学时): 仅管理员
  if (req.method == "GET" && p == "/api/report/warning") {
    if (me.role != "admin") return needAdmin();
    return handleHoursWarning();
  }

  // ---- v4.0 学时申诉 ----
  if (req.method == "POST" && p == "/api/appeal/add") {
    if (me.role != "student") return jsonErr(403, "仅普通成员可发起学时申诉");
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleAppealAdd(body, me);
  }
  if (req.method == "GET" && p == "/api/appeal/list")
    return handleAppealList(req.query, me.role, me.stu_no);
  if (req.method == "POST" && p == "/api/appeal/audit") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleAppealAudit(body, me);
  }
  // 签到异常检测(只读): 仅管理员
  if (req.method == "GET" && p == "/api/report/anomaly") {
    if (me.role != "admin") return needAdmin();
    return handleAnomalyReport();
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

  // 学生自助注销: {confirm_pwd} 必须为本人登录密码(学号是公开信息, 不能当凭据)
  if (req.method == "POST" && p == "/api/student/cancel") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentCancel(body, me, req.ip);
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
    return handleActivityList(req.query, me.role, me.stu_no);

  // 成员修改自己的登录密码
  if (req.method == "POST" && p == "/api/student/password") {
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentPassword(body, me);
  }

  // 管理员重置成员密码
  if (req.method == "POST" && p == "/api/student/reset_pwd") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleStudentResetPwd(body);
  }

  // 管理员修改口令(需校验原口令)
  if (req.method == "POST" && p == "/api/admin/password") {
    if (me.role != "admin") return needAdmin();
    Json body; JsonParser jp(req.body);
    if (!jp.parse(body) || body.t != Json::OBJ) return jsonErr(400, "bad json");
    return handleAdminPassword(body, me);
  }

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

  // 分块传输(chunked)未实现: 明确拒绝。
  // 若忽略该头按 Content-Length 解析, chunked 的块长度行会被当成下一个请求,
  // 造成请求走私/解析错位 —— 拒绝比"猜"安全。
  if (!req.header("Transfer-Encoding").empty()) {
    sendAll(sock, httpResponse(411, jsonDump(Json::Object()
      .set("code", Json::Num(411)).set("msg", Json::Str("chunked not supported, use Content-Length")))));
    return false;
  }

  // 请求体(限制大小, 防恶意大包撑爆内存)
  string cl = req.header("Content-Length");
  if (!cl.empty()) {
    long long needLL = atoll(cl.c_str());
    // 负数/非法长度: 直接 400。原实现 (size_t)(-5) 会变成天文数字, 把线程卡在 drain 里
    if (needLL < 0) {
      sendAll(sock, httpResponse(400, jsonDump(Json::Object()
        .set("code", Json::Num(400)).set("msg", Json::Str("invalid Content-Length")))));
      return false;
    }
    size_t need = (size_t)needLL;
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

  // 落库: 入队由单消费者线程批量写(不创建线程, 不阻塞响应)
  // path/query 列是 VARCHAR(255), 超长会导致 INSERT 失败并静默丢日志, 这里先截断
  DbLogJob job;
  job.method = le.method;
  job.path   = le.path.size() > 250 ? le.path.substr(0, 250) : le.path;
  job.query  = req.query.size() > 250 ? req.query.substr(0, 250) : req.query;
  job.ip     = le.ip;
  job.detail = le.detail;
  job.status = le.status;
  job.cost   = le.cost;
  logEnqueue(job);

  return keepAlive;
}

// 并发连接上限: 每连接一个线程, 没有上限时慢连接/半开连接可以把线程数打满
static std::atomic<int> g_conns(0);
static const int        MAX_CONNS = 256;

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
  // 不在这里 closesocket: 由启动该线程的 lambda 统一关闭,
  // 这样即使处理过程中抛异常, socket 与连接计数也不会泄漏(M2)
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
  // ---- v4.0 学时申诉表: 老库启动时自动补表, 不需要手工执行 ALTER ----
  dbQuery(c, "CREATE TABLE IF NOT EXISTS appeal ("
             "id INT AUTO_INCREMENT PRIMARY KEY,"
             "stu_no VARCHAR(20) NOT NULL,"
             "signup_id INT NOT NULL,"
             "reason VARCHAR(500) NOT NULL,"
             "status TINYINT NOT NULL DEFAULT 0 COMMENT '0待处理 1已通过 2已驳回',"
             "reply VARCHAR(500) NOT NULL DEFAULT '',"
             "hours_before DECIMAL(5,1) NOT NULL DEFAULT 0,"
             "hours_after DECIMAL(5,1) NULL,"
             "created_at DATETIME DEFAULT CURRENT_TIMESTAMP,"
             "handled_at DATETIME NULL,"
             "handler VARCHAR(50) NOT NULL DEFAULT '',"
             "KEY idx_stu (stu_no), KEY idx_status (status), KEY idx_signup (signup_id),"
             "CONSTRAINT fk_appeal_signup FOREIGN KEY (signup_id) REFERENCES signup(id),"
             "CONSTRAINT fk_appeal_student FOREIGN KEY (stu_no) REFERENCES student(stu_no)"
             // 必须与 student.stu_no 的排序规则一致, 否则外键报 3780 incompatible
             ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci", r, err);
  // 日志表按时间清理需要索引(已存在时 MySQL 报重复, 直接忽略)
  QueryResult ig;
  dbQuery(c, "CREATE INDEX idx_req_time ON request_log (req_time)", ig, err);
  // 刷卡签到时间: 老库补列(列已存在时 MySQL 报重复列, 忽略即可)
  // 验收时可直接展示"几点刷的卡", 比只有一个 checkin=1 更有说服力
  dbQuery(c, "ALTER TABLE signup ADD COLUMN checked_at DATETIME NULL COMMENT '刷卡签到时间'", ig, err);
  // 待审报名是管理端最高频查询, 单独建索引避免全表扫描(已存在同样忽略)
  dbQuery(c, "CREATE INDEX idx_signup_status ON signup (status)", ig, err);
  // 卡号唯一: 允许 NULL(未绑卡), 但同一张卡只能绑一个学号。
  // 老库 card_no 是 NOT NULL DEFAULT '', 多行空串会违反唯一索引, 所以先放开 NULL 再清空串。
  dbQuery(c, "ALTER TABLE student MODIFY card_no VARCHAR(32) NULL DEFAULT NULL COMMENT 'RFID卡号(RFID刷卡签到绑定)'", ig, err);
  dbQuery(c, "UPDATE student SET card_no=NULL WHERE card_no=''", ig, err);
  // 迁移告警(S2): 这些 DDL 失败会被忽略, 但"补列/建索引"失败是会影响登录与刷卡的,
  // 不能静默 —— 先查存在性, 缺了才建, 建完仍缺就打到 stderr。
  auto hasIdx = [&](const char* name) -> bool {
    QueryResult q; string e;
    return dbQuery(c, string("SELECT 1 FROM information_schema.statistics WHERE table_schema=DATABASE()"
                             " AND table_name='student' AND index_name='") + name + "'", q, e) && !q.rows.empty();
  };
  auto hasCol = [&](const char* name) -> bool {
    QueryResult q; string e;
    return dbQuery(c, string("SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE()"
                             " AND table_name='student' AND column_name='") + name + "'", q, e) && !q.rows.empty();
  };
  if (!hasIdx("uk_card")) {
    dbQuery(c, "CREATE UNIQUE INDEX uk_card ON student (card_no)", ig, err);
    if (!hasIdx("uk_card"))
      std::cerr << "[migrate] WARN uk_card 唯一索引创建失败(可能存在重复卡号, 刷卡会认错人): " << err << "\n";
  }
  // 学生登录口令(v3.1 起"学号+密码", 不再用姓名认证)
  if (!hasCol("pwd_hash")) {
    dbQuery(c, "ALTER TABLE student ADD COLUMN pwd_hash VARCHAR(100) NOT NULL DEFAULT '' COMMENT '登录口令: sha256i:<hex>'", ig, err);
    if (!hasCol("pwd_hash")) {
      // 缺这一列 = 所有学生登录必然 401, 必须显式告警
      std::cerr << "[migrate] WARN student.pwd_hash 缺失且补列失败(学生将无法登录): " << err << "\n";
      dbRelease(c);
      return;
    }
  }
  QueryResult pws;
  if (dbQuery(c, "SELECT id FROM student WHERE pwd_hash='' LIMIT 1", pws, err) && !pws.rows.empty()) {
    // 只更新确实为空的账号(已改过密码的不受影响); 迭代哈希算一次即可
    string initHash = dbEscape(c, pwdHashStrong(string(DEFAULT_STUDENT_PWD)));
    dbQuery(c, "UPDATE student SET pwd_hash=" + initHash + " WHERE pwd_hash=''", ig, err);
  }

  // ---- v3.2 增量: 活动类别 / 名额计数 / 报名类别快照 / 签退时间 ----
  auto hasColOf = [&](const char* table, const char* name) -> bool {
    QueryResult q; string e;
    return dbQuery(c, string("SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE()"
                             " AND table_name='") + table + "' AND column_name='" + name + "'", q, e)
           && !q.rows.empty();
  };
  if (!hasColOf("activity", "category")) {
    dbQuery(c, "ALTER TABLE activity ADD COLUMN category VARCHAR(20) NOT NULL DEFAULT 'sports'", ig, err);
    if (!hasColOf("activity", "category"))
      std::cerr << "[migrate] WARN activity.category 补列失败(分类统计与学时规则不可用): " << err << "\n";
  }
  if (!hasColOf("activity", "taken")) {
    dbQuery(c, "ALTER TABLE activity ADD COLUMN taken INT NOT NULL DEFAULT 0", ig, err);
    if (!hasColOf("activity", "taken"))
      std::cerr << "[migrate] WARN activity.taken 补列失败(名额判定会退化为 COUNT 查询): " << err << "\n";
  }
  if (!hasColOf("signup", "category")) {
    dbQuery(c, "ALTER TABLE signup ADD COLUMN category VARCHAR(20) NOT NULL DEFAULT ''", ig, err);
    if (!hasColOf("signup", "category"))
      std::cerr << "[migrate] WARN signup.category 补列失败(报表分类会退回 JOIN): " << err << "\n";
  }
  if (!hasColOf("signup", "signout_at")) {
    dbQuery(c, "ALTER TABLE signup ADD COLUMN signout_at DATETIME NULL", ig, err);
    if (!hasColOf("signup", "signout_at"))
      std::cerr << "[migrate] WARN signup.signout_at 补列失败(签退功能不可用): " << err << "\n";
  }
  // 老数据补类别快照(只补空值, 不覆盖已有快照)
  dbQuery(c, "UPDATE signup s JOIN activity a ON s.activity_id=a.id SET s.category=a.category WHERE s.category=''", ig, err);
  // 名额计数对账: 启动时无并发流量, 以真实行数为准重算, 修正历史漂移/漏改点
  QueryResult rec;
  if (dbQuery(c, "UPDATE activity a SET a.taken=(SELECT COUNT(*) FROM signup s "
                 "WHERE s.activity_id=a.id AND s.status<>2)", rec, err)) {
    QueryResult bad;
    if (dbQuery(c, "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s "
                   "WHERE s.activity_id=a.id AND s.status<>2)", bad, err)
        && !bad.rows.empty() && atol(bad.rows[0][0].c_str()) > 0)
      std::cerr << "[migrate] WARN 仍有 " << bad.rows[0][0] << " 个活动的 taken 与真实报名数不一致\n";
  } else {
    std::cerr << "[migrate] WARN taken 对账失败(名额可能不准): " << err << "\n";
  }
  // 时间冲突校验与"我的报名"都按 (stu_no,status) 过滤
  dbQuery(c, "CREATE INDEX idx_signup_stu_status ON signup (stu_no, status)", ig, err);
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
    // 只迁移明文; 已有的单轮哈希无法反推出明文, 等该账号下次登录时由 handleLogin 升级
    if (pwdIsHashed(row[2])) continue;
    QueryResult up;
    std::ostringstream s;
    s << "UPDATE admin_user SET password=" << dbEscape(c, pwdHashStrong(row[2])) << " WHERE id=" << row[0];
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
  // 动态签到码密钥: 每次启动重新生成(64 位 hex), 重启后旧的签到码全部失效
  g_signin_secret = genToken();

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
  std::thread(logWriterLoop).detach();    // 后台: 批量写 request_log(单消费者)

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
    // 超过上限直接 503 并关闭: 宁可拒绝新连接, 也不让线程数无限增长
    if (g_conns.fetch_add(1) >= MAX_CONNS) {
      g_conns.fetch_sub(1);
      // 这里是 accept 主线程: 必须设发送超时, 否则对端不读会让 send 无限阻塞,
      // 进而卡死 accept, 表现为整个服务端无响应(M1)
      DWORD sendTimeout = 1000;
      setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sendTimeout, sizeof(sendTimeout));
      sendAll(sock, httpResponse(503, jsonDump(Json::Object()
        .set("code", Json::Num(503)).set("msg", Json::Str("server busy: too many connections")))));
      closesocket(sock);
      continue;
    }
    try {
      std::thread([sock, ip]() {
        // 线程内异常绝不能逃出线程(否则 std::terminate 直接把进程干掉),
        // 也不能因为异常跳过 closesocket / 计数回收
        try {
          handleClient(sock, ip);
        } catch (...) {
          // 单连接异常只影响该连接, 服务端继续工作
        }
        closesocket(sock);          // 正常/异常路径统一关闭
        g_conns.fetch_sub(1);       // 连接线程结束才释放名额
      }).detach();
    } catch (...) {
      g_conns.fetch_sub(1);       // 线程创建失败: 不能让计数泄漏
      closesocket(sock);
    }
  }

  closesocket(listenSock);
  WSACleanup();
  return 0;
}
