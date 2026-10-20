#import "MoeObjC.h"

NSErrorDomain const MoeObjCExceptionErrorDomain = @"MoeObjCException";

@implementation MoeObjC

+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block
           error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"MoeObjCExceptionName"] = exception.name;
            if (exception.reason) info[@"MoeObjCExceptionReason"] = exception.reason;
            *error = [NSError errorWithDomain:MoeObjCExceptionErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}

@end
