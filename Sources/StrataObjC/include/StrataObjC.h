#include <stdint.h>
#include <stddef.h>
#include <sys/uio.h>
int32_t STLock(const char *path);
int32_t STOpen(const char *path);
int32_t STOpenRead(const char *path);
int64_t STSize(int32_t fd);
int32_t STWrite(int32_t fd, const void *bytes, size_t length);
int32_t STWriteFrame(int32_t fd, const void *header, size_t headerLength,
                     const void *payload, size_t payloadLength, const void *trailer, size_t trailerLength);
// Injectable syscall adapter for short-write/EINTR tests. The vectors are advanced in place.
typedef ssize_t (*STVectorWriter)(int fd, const struct iovec *vectors, int count, void *context);
int32_t STWriteVectorsUsing(int32_t fd, struct iovec *vectors, int count, STVectorWriter writer, void *context);
int32_t STRead(int32_t fd, void *bytes, size_t length, int64_t offset);
int32_t STSync(int32_t fd);
int32_t STFullSync(int32_t fd);
int32_t STSyncDirectory(const char *path);
int32_t STTruncate(int32_t fd, int64_t length);
int32_t STRename(const char *source, const char *destination);
void STClose(int32_t fd);
uint32_t STCRC32(const void *bytes, size_t length);
