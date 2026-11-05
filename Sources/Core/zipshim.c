/* zipshim.c — 最小 zlib 桥接：raw deflate 进 / raw deflate 出 / crc32
 *
 * 为什么需要它：Office 文件（docx/xlsx/pptx）就是 ZIP，ZIP 内部的 deflate 是
 * "raw" 的（RFC 1951，无 zlib 头尾）。macOS 的 Compression.framework 只提供
 * RFC 1950（带头尾）的 ZLIB，没法直接吃 raw deflate；而 zlib 的 inflateInit2
 * 第二个参数传 -MAX_WBITS 正好就是 raw 模式。所以用 40 行 C 桥一下。
 *
 * 返回的指针由 malloc 分配，调用方负责 free()。失败返回 NULL 并把 *outLen 置 0。
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>

#define LR_CHUNK (64 * 1024)

static unsigned char *lr_grow(unsigned char *buf, size_t used, size_t need, size_t *cap) {
    if (need <= *cap) return buf;
    size_t n = *cap ? *cap : LR_CHUNK;
    while (n < need) n *= 2;
    unsigned char *p = realloc(buf, n);
    if (!p) { free(buf); return NULL; }
    *cap = n;
    return p;
}

/* 解压 raw deflate（ZIP method 8） */
unsigned char *lr_inflate(const unsigned char *src, size_t srcLen, size_t *outLen) {
    *outLen = 0;
    if (!src) return NULL;
    z_stream s; memset(&s, 0, sizeof(s));
    /* 第三个参数必须传 zlib 的版本串与结构体大小，否则 ABI 不匹配 */
    if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return NULL;

    size_t cap = srcLen * 4 + LR_CHUNK;
    unsigned char *out = malloc(cap);
    if (!out) { inflateEnd(&s); return NULL; }

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srcLen;
    s.next_out = out;
    s.avail_out = (uInt)cap;

    for (;;) {
        int rc = inflate(&s, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK && rc != Z_BUF_ERROR) { free(out); inflateEnd(&s); return NULL; }
        if (s.avail_out == 0) {
            size_t used = cap;
            unsigned char *nb = lr_grow(out, used, cap + LR_CHUNK, &cap);
            if (!nb) { inflateEnd(&s); return NULL; }
            out = nb;
            s.next_out = out + used;
            s.avail_out = (uInt)(cap - used);
        } else if (rc == Z_BUF_ERROR) {
            /* 输入吃完了但流没结束 => 数据损坏 */
            free(out); inflateEnd(&s); return NULL;
        }
    }
    *outLen = (size_t)s.total_out;
    inflateEnd(&s);
    return out;
}

/* 压缩成 raw deflate（ZIP method 8） */
unsigned char *lr_deflate(const unsigned char *src, size_t srcLen, size_t *outLen) {
    *outLen = 0;
    z_stream s; memset(&s, 0, sizeof(s));
    if (deflateInit2(&s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) return NULL;

    uLong bound = deflateBound(&s, (uLong)srcLen) + 64;
    unsigned char *out = malloc(bound);
    if (!out) { deflateEnd(&s); return NULL; }

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srcLen;
    s.next_out = out;
    s.avail_out = (uInt)bound;

    int rc = deflate(&s, Z_FINISH);
    if (rc != Z_STREAM_END) { free(out); deflateEnd(&s); return NULL; }
    *outLen = (size_t)s.total_out;
    deflateEnd(&s);
    return out;
}

/* ZIP 用的 CRC-32（IEEE 802.3，初值 0，不做最终取反之外的处理） */
unsigned long lr_crc32(unsigned long crc, const unsigned char *buf, size_t len) {
    return (unsigned long)crc32((uLong)crc, (const Bytef *)buf, (uInt)len);
}
