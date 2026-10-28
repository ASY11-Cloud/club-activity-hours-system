/*
 * ============================================================================
 *  社团活动报名与学时认定系统 —— 嵌入式扩展项: ESP32 + RFID(RC522) 读卡签到终端
 * ----------------------------------------------------------------------------
 *  硬件: ESP32 开发板 + MFRC522(RC522) RFID 读卡模块
 *  接线(MFRC522 -> ESP32):
 *    SDA(SS)  -> GPIO5
 *    SCK      -> GPIO18
 *    MOSI     -> GPIO23
 *    MISO     -> GPIO19
 *    RST      -> GPIO27
 *    3.3V     -> 3.3V
 *    GND      -> GND
 *  功能: 刷卡 -> 读取卡号(UID 大写十六进制) -> POST 到服务器 /api/signin
 *        服务器按卡号匹配学生 -> 该活动报名通过并自动累计学时(到场认定)
 *  注意: 学生表 card_no 字段需与本终端读到的一致(如 A1B2C3D4)
 *        服务器需 bind 0.0.0.0 且与 ESP32 在同一局域网
 * ============================================================================
 */

#include <WiFi.h>
#include <SPI.h>
#include <MFRC522.h>
#include <HTTPClient.h>

// ------------------ 配置区(按实际环境修改) ------------------
const char* WIFI_SSID     = "your_wifi_ssid";        // WiFi 名称
const char* WIFI_PASSWORD = "your_wifi_password";    // WiFi 密码
const char* SERVER_BASE   = "http://192.168.1.100:8000"; // 服务器地址(宿主机局域网 IPv4)
const int   ACTIVITY_ID   = 2;                       // 要签到的活动ID(可改成任意已发布活动)
// 可选: 刷卡终端共享密钥。服务器以 CLUB_DEVICE_KEY / 第5个参数启用校验时, 此处必须填相同值;
// 服务器未启用时留空即可(不发送该请求头)。
const char* DEVICE_KEY    = "";

// MFRC522 引脚定义(ESP32)
#define RST_PIN 27
#define SS_PIN  5

MFRC522 rfid(SS_PIN, RST_PIN);  // 创建 MFRC522 实例

// 同一张卡连续刷的冷却时间: 卡放在读头上时 PICC_IsNewCardPresent 会反复触发,
// 不加冷却会每秒上报一次。服务端虽幂等(不会重复累计学时), 但会产生大量无用请求。
const unsigned long SAME_CARD_COOLDOWN_MS = 5000;
String lastCardNo = "";
unsigned long lastCardMs = 0;
unsigned long lastWifiRetryMs = 0;

// 卡号(UID)转大写十六进制字符串, 与服务器 student.card_no 格式一致
String uidToString(byte* uid, byte size) {
  String s = "";
  for (byte i = 0; i < size; i++) {
    if (uid[i] < 0x10) s += "0";        // 前导 0
    s += String(uid[i], HEX);
  }
  s.toUpperCase();
  return s;
}

// 上报服务器签到
void signinToServer(const String& cardNo) {
  HTTPClient http;
  String url = String(SERVER_BASE) + "/api/signin";
  String body = "{\"card_no\":\"" + cardNo + "\",\"activity_id\":" + String(ACTIVITY_ID) + "}";

  http.begin(url);
  http.setTimeout(5000);   // 避免网络异常时长时间阻塞读卡循环
  http.addHeader("Content-Type", "application/json; charset=utf-8");
  if (String(DEVICE_KEY).length() > 0) {
    http.addHeader("X-Device-Key", DEVICE_KEY);   // 服务器启用设备密钥时必填
  }
  int code = http.POST(body);
  String resp = http.getString();
  http.end();

  Serial.print("  HTTP ");
  Serial.print(code);
  Serial.print(" -> ");
  Serial.println(resp);

  if (code == 200 && resp.indexOf("\"code\":0") >= 0) {
    Serial.println("  [OK] 签到成功, 学时已认定");
  } else if (code == 401) {
    Serial.println("  [!!] 设备密钥错误: 请让 DEVICE_KEY 与服务器 CLUB_DEVICE_KEY 一致");
  } else {
    Serial.println("  [!!] 签到失败(卡未绑定 / 活动已结束 / 驳回需重新报名)");
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n=== 社团活动报名与学时认定系统 - RFID 读卡终端 ===");

  // 初始化 RFID
  SPI.begin();
  rfid.PCD_Init();
  Serial.println("RFID 模块初始化完成, 请刷卡...");

  // 连接 WiFi
  Serial.print("连接 WiFi: ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.print("\nWiFi 已连接, IP: ");
  Serial.println(WiFi.localIP());
  Serial.print("服务器: ");
  Serial.println(SERVER_BASE);
}

void loop() {
  // WiFi 掉线自动重连(每 5 秒尝试一次): 演示现场网络抖动后无需重启设备
  if (WiFi.status() != WL_CONNECTED) {
    unsigned long now = millis();
    if (now - lastWifiRetryMs > 5000) {
      lastWifiRetryMs = now;
      Serial.println("WiFi 已断开, 正在重连...");
      WiFi.reconnect();
    }
  }

  // 检测新卡
  if (!rfid.PICC_IsNewCardPresent()) {
    delay(50);
    return;
  }
  if (!rfid.PICC_ReadCardSerial()) {
    delay(50);
    return;
  }

  String cardNo = uidToString(rfid.uid.uidByte, rfid.uid.size);
  // 停止读取该卡
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();

  // 同一张卡冷却时间内不重复上报(卡一直放在读头上时避免刷屏)
  unsigned long nowMs = millis();
  if (cardNo == lastCardNo && nowMs - lastCardMs < SAME_CARD_COOLDOWN_MS) {
    delay(50);
    return;
  }
  lastCardNo = cardNo;
  lastCardMs = nowMs;

  Serial.print("刷卡卡号: ");
  Serial.println(cardNo);

  // 若 WiFi 已连接则上报
  if (WiFi.status() == WL_CONNECTED) {
    signinToServer(cardNo);
  } else {
    Serial.println("WiFi 未连接, 无法上报(卡号已显示)");
  }

  delay(300);
}
