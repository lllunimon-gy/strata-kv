#include <stdint.h>
#include <stddef.h>
int32_t STLock(const char *path);
int32_t STOpen(const char *path);
int32_t STWrite(int32_t fd, const void *bytes, size_t length);
int32_t STRead(int32_t fd, void *bytes, size_t length, int64_t offset);
int32_t STSync(int32_t fd);
int32_t STTruncate(int32_t fd, int64_t length);
int32_t STRename(const char *source, const char *destination);
void STClose(int32_t fd);
uint32_t STCRC32(const void *bytes, size_t length);
