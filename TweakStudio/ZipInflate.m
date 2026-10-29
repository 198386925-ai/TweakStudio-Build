#import "ZipInflate.h"
#import <zlib.h>
#import <string.h>

static NSString * const TSZipInflateErrorDomain = @"com.youyou.tweakstudio.zipinflate";

@implementation TSZipInflate

+ (NSData *)inflate:(NSData *)compressed error:(NSError **)error {
    if (compressed.length == 0) {
        return [NSData data];
    }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)compressed.bytes;
    stream.avail_in = (uInt)compressed.length;
    // -MAX_WBITS 表示输入是无 zlib 头的 raw deflate（ZIP 条目的格式）
    int status = inflateInit2(&stream, -MAX_WBITS);
    if (status != Z_OK) {
        if (error) {
            *error = [NSError errorWithDomain:TSZipInflateErrorDomain code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"解压初始化失败"}];
        }
        return nil;
    }
    NSMutableData *output = [NSMutableData data];
    const NSUInteger chunkSize = 256 * 1024;
    NSMutableData *chunk = [NSMutableData dataWithLength:chunkSize];
    while (status != Z_STREAM_END) {
        stream.next_out = (Bytef *)chunk.mutableBytes;
        stream.avail_out = (uInt)chunkSize;
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            NSString *detail = stream.msg ? [NSString stringWithUTF8String:stream.msg] : @"数据流损坏或不完整";
            inflateEnd(&stream);
            if (error) {
                *error = [NSError errorWithDomain:TSZipInflateErrorDomain code:status
                                         userInfo:@{NSLocalizedDescriptionKey: detail}];
            }
            return nil;
        }
        NSUInteger produced = chunkSize - stream.avail_out;
        if (produced > 0) {
            [output appendBytes:chunk.bytes length:produced];
        }
    }
    inflateEnd(&stream);
    return output;
}

@end
