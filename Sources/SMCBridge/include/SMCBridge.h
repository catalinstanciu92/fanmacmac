#ifndef FANMAC_SMC_BRIDGE_H
#define FANMAC_SMC_BRIDGE_H

#include <stdint.h>

typedef uint32_t SMCBridgeConnection;

typedef struct {
    uint32_t size;
    char type[5];
    uint8_t bytes[32];
} SMCBridgeValue;

int32_t smc_bridge_open(SMCBridgeConnection *connection_out);
void smc_bridge_close(SMCBridgeConnection connection);
int32_t smc_bridge_read(SMCBridgeConnection connection, const char key[4], SMCBridgeValue *value_out);
int32_t smc_bridge_key_count(SMCBridgeConnection connection, uint32_t *count_out);
int32_t smc_bridge_read_index(SMCBridgeConnection connection, uint32_t index, char key_out[5]);
int32_t smc_bridge_write(SMCBridgeConnection connection, const char key[4], const char type[4], const uint8_t *bytes, uint32_t size);

#endif
