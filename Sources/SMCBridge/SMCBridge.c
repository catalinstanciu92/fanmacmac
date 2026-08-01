#include "SMCBridge.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_WRITE_BYTES 6

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCKeyDataVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyDataPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyDataKeyInfo;

typedef struct {
    uint32_t key;
    SMCKeyDataVersion vers;
    SMCKeyDataPLimit pLimitData;
    SMCKeyDataKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    char bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "AppleSMC request layout changed");

static uint32_t fourcc(const char value[4]) {
    return ((uint32_t)(uint8_t)value[0] << 24) |
           ((uint32_t)(uint8_t)value[1] << 16) |
           ((uint32_t)(uint8_t)value[2] << 8) |
           (uint32_t)(uint8_t)value[3];
}

static kern_return_t call_smc(SMCBridgeConnection connection, SMCKeyData *input, SMCKeyData *output) {
    size_t output_size = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(
        (io_connect_t)connection,
        KERNEL_INDEX_SMC,
        input,
        sizeof(SMCKeyData),
        output,
        &output_size
    );
}

static kern_return_t read_key_info(SMCBridgeConnection connection, uint32_t key, SMCKeyDataKeyInfo *info_out) {
    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t result = call_smc(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return (kern_return_t)output.result;
    }
    *info_out = output.keyInfo;
    return KERN_SUCCESS;
}

int32_t smc_bridge_open(SMCBridgeConnection *connection_out) {
    if (connection_out == NULL) {
        return kIOReturnBadArgument;
    }

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return kIOReturnNotFound;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        return result;
    }

    *connection_out = (SMCBridgeConnection)connection;
    return KERN_SUCCESS;
}

void smc_bridge_close(SMCBridgeConnection connection) {
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose((io_connect_t)connection);
    }
}

int32_t smc_bridge_read(SMCBridgeConnection connection, const char key[4], SMCBridgeValue *value_out) {
    if (connection == IO_OBJECT_NULL || key == NULL || value_out == NULL) {
        return kIOReturnBadArgument;
    }

    SMCKeyDataKeyInfo info;
    kern_return_t result = read_key_info(connection, fourcc(key), &info);
    if (result != KERN_SUCCESS) {
        return result;
    }

    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = fourcc(key);
    input.data8 = SMC_CMD_READ_BYTES;
    input.keyInfo.dataSize = info.dataSize;
    input.keyInfo.dataType = info.dataType;

    result = call_smc(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return (kern_return_t)output.result;
    }

    memset(value_out, 0, sizeof(*value_out));
    value_out->size = info.dataSize > 32 ? 32 : info.dataSize;
    value_out->type[0] = (char)((info.dataType >> 24) & 0xff);
    value_out->type[1] = (char)((info.dataType >> 16) & 0xff);
    value_out->type[2] = (char)((info.dataType >> 8) & 0xff);
    value_out->type[3] = (char)(info.dataType & 0xff);
    value_out->type[4] = '\0';
    memcpy(value_out->bytes, output.bytes, value_out->size);
    return KERN_SUCCESS;
}

int32_t smc_bridge_key_count(SMCBridgeConnection connection, uint32_t *count_out) {
    if (count_out == NULL) {
        return kIOReturnBadArgument;
    }

    const char key[4] = {'#', 'K', 'E', 'Y'};
    SMCBridgeValue value;
    kern_return_t result = smc_bridge_read(connection, key, &value);
    if (result != KERN_SUCCESS || value.size < 4) {
        return result == KERN_SUCCESS ? kIOReturnUnderrun : result;
    }

    *count_out = ((uint32_t)value.bytes[0] << 24) |
                 ((uint32_t)value.bytes[1] << 16) |
                 ((uint32_t)value.bytes[2] << 8) |
                 (uint32_t)value.bytes[3];
    return KERN_SUCCESS;
}

int32_t smc_bridge_read_index(SMCBridgeConnection connection, uint32_t index, char key_out[5]) {
    if (connection == IO_OBJECT_NULL || key_out == NULL) {
        return kIOReturnBadArgument;
    }

    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.data8 = SMC_CMD_READ_INDEX;
    input.data32 = index;

    kern_return_t result = call_smc(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return (kern_return_t)output.result;
    }

    key_out[0] = (char)((output.key >> 24) & 0xff);
    key_out[1] = (char)((output.key >> 16) & 0xff);
    key_out[2] = (char)((output.key >> 8) & 0xff);
    key_out[3] = (char)(output.key & 0xff);
    key_out[4] = '\0';
    return KERN_SUCCESS;
}

int32_t smc_bridge_write(SMCBridgeConnection connection, const char key[4], const char type[4], const uint8_t *bytes, uint32_t size) {
    if (connection == IO_OBJECT_NULL || key == NULL || type == NULL || bytes == NULL || size > 32) {
        return kIOReturnBadArgument;
    }

    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = fourcc(key);
    input.data8 = SMC_CMD_WRITE_BYTES;
    input.keyInfo.dataSize = size;
    input.keyInfo.dataType = fourcc(type);
    memcpy(input.bytes, bytes, size);

    kern_return_t result = call_smc(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return (kern_return_t)output.result;
    }
    return KERN_SUCCESS;
}
