#import "PermissionCallbackShim.h"
@implementation SpikePermissionRequester
+ (void)requestAuthorization:(void (^)(BOOL))handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ handler(YES); });
}
@end
