#import "LegatoAudioBridge.h"

NSError * _Nullable LegatoAudioCatchException(void (NS_NOESCAPE ^operation)(void)) {
    @try {
        operation();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"LegatoAudio.NativeSetup" code:1 userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            @"exceptionName": exception.name,
        }];
    }
}
