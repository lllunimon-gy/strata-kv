#import "StrataObjC.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
int32_t STLock(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
    return fd;
}
int32_t STOpen(const char *path) { return open(path, O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW, 0600); }
int32_t STWrite(int32_t fd, const void *bytes, size_t length) {
    const unsigned char *p = bytes;
    while (length) {
        ssize_t n = write(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        p += n; length -= (size_t)n;
    }
    return 0;
}
int32_t STRead(int32_t fd, void *bytes, size_t length, int64_t offset) {
    unsigned char *p = bytes;
    while (length) {
        ssize_t n = pread(fd, p, length, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        p += n; length -= (size_t)n; offset += n;
    }
    return 0;
}
int32_t STSync(int32_t fd) { return fsync(fd) == 0 ? 0 : errno; }
int32_t STTruncate(int32_t fd, int64_t length) { return ftruncate(fd, length) == 0 ? 0 : errno; }
int32_t STRename(const char *source, const char *destination) { return rename(source, destination) == 0 ? 0 : errno; }
void STClose(int32_t fd) { if (fd >= 0) close(fd); }
uint32_t STCRC32(const void *bytes, size_t length) {
    const unsigned char *p = bytes;
    uint32_t crc = 0xffffffffU;
    for (size_t i = 0; i < length; ++i) {
        crc ^= p[i];
        for (int j = 0; j < 8; ++j) crc = (crc >> 1) ^ (0xedb88320U & (0U - (crc & 1U)));
    }
    return crc ^ 0xffffffffU;
}
