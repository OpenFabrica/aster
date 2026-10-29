// aster-sensors：系统状态条（aster.sysbar）的传感器读取器，输出温度与风扇转速，每行 `键=值`。
// 温度走 IOHIDEventSystem（私有接口，Stats / macmon 同款），风扇走 AppleSMC 用户态连接；
// 两者都不需要 root。读不到的项直接不输出，退出码恒为 0，让脚本按「有哪行显示哪行」处理。
// 构建见 scripts/build-sysbar-sensors.sh。
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// MARK: - 温度（IOHIDEventSystem）

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);

#define kIOHIDEventTypeTemperature 15

/// 读所有温度传感器，按名字归类：SoC 取 `tdie*` 的最高值（最热的核心），电池取 gas gauge，闪存取 NAND。
/// 失效的传感器会返回 -9000 上下的值，所以只收 0–150 ℃。
static void printTemperatures(void) {
  int page = 0xff00, usage = 5;
  CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberIntType, &page);
  CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberIntType, &usage);
  const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
  const void *values[] = {pageNumber, usageNumber};
  CFDictionaryRef matching = CFDictionaryCreate(
      NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(NULL);
  if (!client) return;
  IOHIDEventSystemClientSetMatching(client, matching);
  CFArrayRef services = IOHIDEventSystemClientCopyServices(client);

  double soc = -1, battery = -1, nand = -1;
  for (CFIndex i = 0; services && i < CFArrayGetCount(services); i++) {
    IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
    CFStringRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
    char name[128] = "";
    if (product) CFStringGetCString(product, name, sizeof name, kCFStringEncodingUTF8);
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
    if (!event) continue;
    double value = IOHIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16);
    if (value <= 0 || value > 150) continue;
    if (strstr(name, "tdie") && value > soc) soc = value;
    else if (strstr(name, "gas gauge") && value > battery) battery = value;
    else if (strstr(name, "NAND") && value > nand) nand = value;
  }
  if (soc > 0) printf("temp_soc=%.1f\n", soc);
  if (battery > 0) printf("temp_battery=%.1f\n", battery);
  if (nand > 0) printf("temp_nand=%.1f\n", nand);
}

// MARK: - 风扇（AppleSMC）

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
// 与内核侧 SMCParamStruct 逐字节一致（80 字节），字段顺序和对齐不能改。
typedef struct {
  uint32_t key;
  SMCVersion version;
  SMCPLimit pLimit;
  SMCKeyInfo keyInfo;
  uint8_t result, status, command;
  uint32_t data32;
  uint8_t bytes[32];
} SMCParam;

enum { kSMCUserClientSelector = 2, kSMCReadBytes = 5, kSMCReadKeyInfo = 9 };

static uint32_t fourCC(const char *s) {
  return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 | (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}

static int smcCall(io_connect_t connection, SMCParam *input, SMCParam *output) {
  size_t size = sizeof(SMCParam);
  return IOConnectCallStructMethod(connection, kSMCUserClientSelector, input, sizeof(SMCParam), output, &size) ==
             KERN_SUCCESS &&
         output->result == 0;
}

/// 读一个 SMC 键并按类型转成数值：`flt `（Apple Silicon）、`fpe2`（Intel 风扇）、`ui8 `。读不到返回 0。
static int smcRead(io_connect_t connection, const char *key, double *value) {
  SMCParam input = {0}, output = {0};
  input.key = fourCC(key);
  input.command = kSMCReadKeyInfo;
  if (!smcCall(connection, &input, &output)) return 0;
  uint32_t size = output.keyInfo.dataSize, type = output.keyInfo.dataType;
  SMCParam readInput = {0}, readOutput = {0};
  readInput.key = fourCC(key);
  readInput.keyInfo.dataSize = size;
  readInput.command = kSMCReadBytes;
  if (!smcCall(connection, &readInput, &readOutput)) return 0;
  const uint8_t *b = readOutput.bytes;
  if (type == fourCC("flt ") && size == 4) {
    float f;
    memcpy(&f, b, 4);  // SMC 的 flt 是主机字节序
    *value = f;
  } else if (type == fourCC("fpe2") && size == 2) {
    *value = ((b[0] << 8) | b[1]) / 4.0;
  } else if (type == fourCC("ui8 ") && size == 1) {
    *value = b[0];
  } else {
    return 0;
  }
  return 1;
}

/// 风扇个数与每个风扇的当前 / 最大转速（rpm）。没有风扇（Air）时什么都不输出。
static void printFans(void) {
  io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
  if (!service) return;
  io_connect_t connection;
  kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
  IOObjectRelease(service);
  if (status != KERN_SUCCESS) return;

  double count = 0;
  if (smcRead(connection, "FNum", &count) && count >= 1) {
    printf("fans=%d\n", (int)count);
    for (int i = 0; i < (int)count && i < 4; i++) {
      char key[5];
      double current, maximum;
      snprintf(key, sizeof key, "F%dAc", i);
      if (smcRead(connection, key, &current)) printf("fan%d=%.0f\n", i, current);
      snprintf(key, sizeof key, "F%dMx", i);
      if (smcRead(connection, key, &maximum)) printf("fan%d_max=%.0f\n", i, maximum);
    }
  }
  IOServiceClose(connection);
}

int main(void) {
  printTemperatures();
  printFans();
  return 0;
}
