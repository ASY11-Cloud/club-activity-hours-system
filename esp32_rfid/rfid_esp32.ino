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

// MFRC522 引脚定义(ESP32)
#define RST_PIN 27
#define SS_PIN  5

MFRC522 rfid(SS_PIN, RST_PIN);  // 创建 MFRC522 实例

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
  http.addHeader("Content-Type", "application/json; charset=utf-8");
  int code = http.POST(body);
  String resp = http.getString();
  http.end();

  Serial.print("  HTTP ");
  Serial.print(code);
  Serial.print(" -> ");
  Serial.println(resp);

  if (code == 200 && resp.indexOf("\"code\":0") >= 0) {
    Serial.println("  [OK] 签到成功, 学时已认定");
  } else {
    Serial.println("  [!!] 签到失败(卡未绑定或活动不存在?)");
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
  Serial.print("刷卡卡号: ");
  Serial.println(cardNo);

  // 若 WiFi 已连接则上报
  if (WiFi.status() == WL_CONNECTED) {
    signinToServer(cardNo);
  } else {
    Serial.println("WiFi 未连接, 无法上报(卡号已显示)");
  }

  // 停止读取该卡
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
  delay(1000);
}
