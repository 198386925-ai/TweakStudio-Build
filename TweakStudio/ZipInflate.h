#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统 zlib 的最小包装：只做 ZIP 条目用的 raw deflate 流（RFC 1951）解压。
@interface TSZipInflate : NSObject

/// 把 deflate 原始流解压成完整数据；失败返回 nil 并在 error 里写明原因。
+ (nullable NSData *)inflate:(NSData *)compressed error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
