#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SpikePermissionRequester : NSObject
+ (void)requestAuthorization:(void (^)(BOOL granted))handler;
@end
NS_ASSUME_NONNULL_END
