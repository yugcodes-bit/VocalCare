#include <ESP8266WiFi.h>
#include <PubSubClient.h>

// ── WiFi credentials ──────────────────────────
const char* WIFI_SSID     = "Q7bois_2.4G";
const char* WIFI_PASSWORD = "9022345818";

// ── HiveMQ broker ─────────────────────────────
const char* MQTT_BROKER = "broker.hivemq.com";
const int   MQTT_PORT   = 1883;
const char* CLIENT_ID   = "ESP8266_VocalCare";

// Topics
const char* TOPIC_COMMAND = "vocalcare/command";
const char* TOPIC_SENSORS = "vocalcare/sensors";

// ── Pin definitions ───────────────────────────
const int LED_PIN    = D1;  // GPIO5
const int BUZZER_PIN = D2;  // GPIO4
const int MQ135_PIN  = A0;  // Analog pin for Air Quality
const int MQ7_PIN    = D5;  // Digital pin for CO Alarm

// ── State tracking ────────────────────────────
bool ledState    = false;
bool buzzerState = false;

// ── Timing variables ──────────────────────────
unsigned long lastSensorPublish = 0;
const long SENSOR_INTERVAL      = 5000; // Publish every 5 seconds

WiFiClient   espClient;
PubSubClient mqtt(espClient);

// ─────────────────────────────────────────────
// Connect to WiFi
// ─────────────────────────────────────────────
void connectWiFi() {
  Serial.print("Connecting to WiFi: ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println("\nWiFi connected!");
  Serial.print("IP address: ");
  Serial.println(WiFi.localIP());
}

// ─────────────────────────────────────────────
// Connect to MQTT broker
// ─────────────────────────────────────────────
void connectMQTT() {
  while (!mqtt.connected()) {
    Serial.print("Connecting to MQTT broker...");

    if (mqtt.connect(CLIENT_ID)) {
      Serial.println("connected!");
      mqtt.subscribe(TOPIC_COMMAND);
      Serial.print("Subscribed to: ");
      Serial.println(TOPIC_COMMAND);

      // Blink LED twice to show ready
      for (int i = 0; i < 2; i++) {
        digitalWrite(LED_PIN, HIGH);
        delay(200);
        digitalWrite(LED_PIN, LOW);
        delay(200);
      }
    } else {
      Serial.print("Failed. State=");
      Serial.println(mqtt.state());
      Serial.println("Retrying in 3 seconds...");
      delay(3000);
    }
  }
}

// ─────────────────────────────────────────────
// Handle incoming MQTT commands
// NOTE: "stop" removed — "go" now handles alert + LED
// ─────────────────────────────────────────────
void onMessageReceived(char* topic, byte* payload, unsigned int length) {
  String command = "";
  for (int i = 0; i < length; i++) {
    command += (char)payload[i];
  }

  Serial.print("Command received: ");
  Serial.println(command);

  if (command == "on" || command == "yes" || command == "up") {
    ledState = true;
    digitalWrite(LED_PIN, HIGH);
    Serial.println("→ LED ON");
  }
  else if (command == "off" || command == "no" || command == "down") {
    ledState = false;
    digitalWrite(LED_PIN, LOW);
    Serial.println("→ LED OFF");
  }
  else if (command == "go") {
    // LED ON + buzzer beeps 3 times (alert/confirm)
    ledState = true;
    digitalWrite(LED_PIN, HIGH);
    Serial.println("→ LED ON + Alert beeps");
    for (int i = 0; i < 3; i++) {
      digitalWrite(BUZZER_PIN, HIGH);
      delay(300);
      digitalWrite(BUZZER_PIN, LOW);
      delay(200);
    }
  }
  else {
    Serial.println("→ Unknown command, ignoring");
  }
}

// ─────────────────────────────────────────────
// Read and Publish Sensor Data
// ─────────────────────────────────────────────
void publishSensorData() {
  int airQuality   = analogRead(MQ135_PIN);
  int coAlarmState = digitalRead(MQ7_PIN);
  String coStatus  = (coAlarmState == LOW) ? "DANGER" : "SAFE";

  // JSON payload
  String payload = "{\"air_quality\":" + String(airQuality) +
                   ",\"co_status\":\"" + coStatus + "\"}";

  mqtt.publish(TOPIC_SENSORS, payload.c_str());

  Serial.print("Published Data -> AQI: ");
  Serial.print(airQuality);
  Serial.print(" | CO: ");
  Serial.println(coStatus);

  // Auto-emergency: trigger buzzer if CO danger or AQI too high
  if (coAlarmState == LOW || airQuality > 800) {
    Serial.println("WARNING: BAD AIR QUALITY! Triggering alarm!");
    for (int i = 0; i < 3; i++) {
      digitalWrite(BUZZER_PIN, HIGH);
      delay(200);
      digitalWrite(BUZZER_PIN, LOW);
      delay(200);
    }
  }
}

// ─────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);

  pinMode(LED_PIN,    OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(MQ7_PIN,    INPUT);

  digitalWrite(LED_PIN,    LOW);
  digitalWrite(BUZZER_PIN, LOW);

  Serial.println("\n=== VocalCare ESP8266 Starting ===");
  connectWiFi();
  mqtt.setServer(MQTT_BROKER, MQTT_PORT);
  mqtt.setCallback(onMessageReceived);
  connectMQTT();

  Serial.println("=== Ready! Waiting for commands ===");
}

// ─────────────────────────────────────────────
// Loop
// ─────────────────────────────────────────────
void loop() {
  if (!mqtt.connected()) connectMQTT();
  mqtt.loop();

  unsigned long currentMillis = millis();
  if (currentMillis - lastSensorPublish >= SENSOR_INTERVAL) {
    lastSensorPublish = currentMillis;
    publishSensorData();
  }
}
