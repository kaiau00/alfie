#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain of an Objective-C exception caught by `MoeObjC`.
FOUNDATION_EXPORT NSErrorDomain const MoeObjCExceptionErrorDomain;

/// Swift cannot catch an Objective-C exception. One thrown through Swift
/// frames — `AVAudioNode installTapOnBus:` raises on a format mismatch after
/// a microphone change — unwinds Swift concurrency frames that were never
/// built to be unwound, leaves the runtime's current-executor record
/// corrupt, and the app dies later somewhere unrelated
/// (`swift_task_isMainExecutorImpl` from a SwiftUI hover). This catches it
/// at the call, as an `NSError`, where Swift can see it.
@interface MoeObjC : NSObject

/// Runs `block`. Returns YES when it finished; NO with `error` set (domain
/// `MoeObjCExceptionErrorDomain`, the exception's name and reason in its
/// userInfo) when it raised. In Swift: `try MoeObjC.catchException { … }`.
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block
           error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(catchException(_:));

@end

NS_ASSUME_NONNULL_END
