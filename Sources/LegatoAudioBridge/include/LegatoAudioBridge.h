#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Turns AVFAudio's Objective-C setup exceptions into retryable errors for Swift callers.
FOUNDATION_EXPORT NSError * _Nullable LegatoAudioCatchException(void (NS_NOESCAPE ^operation)(void));
NS_ASSUME_NONNULL_END
