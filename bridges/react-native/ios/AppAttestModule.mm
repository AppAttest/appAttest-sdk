// AppAttestModule.mm — React Native module registration macros.
//
// Exposes the Swift class `AppAttestModule` to RN as `RNAppAttest`
// (matches the JS-side TurboModuleRegistry.getEnforcing<Spec>('RNAppAttest')).
// Each RCT_EXTERN_METHOD declares a method the RN runtime may invoke and
// its argument shape. Keep in lockstep with ../src/NativeAppAttest.ts.

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

#if __has_include(<React/RCTBridgeModule.h>)
@interface RCT_EXTERN_REMAP_MODULE(RNAppAttest, AppAttestModule, RCTEventEmitter)

RCT_EXTERN_METHOD(start:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(waitForReady:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(retry:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(reset:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(invalidateBundle:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getSecret:(NSString *)name
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getAllSecrets:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getState:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setDebugMode:(nullable NSString *)name
                  stubs:(nullable NSDictionary *)stubs
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

// setApiBaseUrl is not exposed — base URL is hardcoded.

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

@end
#endif
