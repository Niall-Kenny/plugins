// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#import <LocalAuthentication/LocalAuthentication.h>

#import "FLTLocalAuthPlugin.h"

@interface FLTLocalAuthPlugin ()
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSNumber *> *lastCallArgs;
@property(nonatomic, nullable) FlutterResult lastResult;
// For unit tests to inject dummy LAContext instances that will be used when a new context would
// normally be created. Each call to createAuthContext will remove the current first element from
// the array.
- (void)setAuthContextOverrides:(NSArray<LAContext *> *)authContexts;
@end

@implementation FLTLocalAuthPlugin {
  NSMutableArray<LAContext *> *_authContextOverrides;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/local_auth"
                                  binaryMessenger:[registrar messenger]];
  FLTLocalAuthPlugin *instance = [[FLTLocalAuthPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
  [registrar addApplicationDelegate:instance];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([@"authenticate" isEqualToString:call.method]) {
    bool isBiometricOnly = [call.arguments[@"biometricOnly"] boolValue];
    if (isBiometricOnly) {
      [self authenticateWithBiometrics:call.arguments withFlutterResult:result];
    } else {
      [self authenticate:call.arguments withFlutterResult:result];
    }
  } else if ([@"getAvailableBiometrics" isEqualToString:call.method]) {
    [self getAvailableBiometrics:result];
  } else if ([@"isDeviceSupported" isEqualToString:call.method]) {
    result(@YES);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark Private Methods

- (void)setAuthContextOverrides:(NSArray<LAContext *> *)authContexts {
  _authContextOverrides = [authContexts mutableCopy];
}

- (LAContext *)createAuthContext {
  if ([_authContextOverrides count] > 0) {
    LAContext *context = [_authContextOverrides firstObject];
    [_authContextOverrides removeObjectAtIndex:0];
    return context;
  }
  return [[LAContext alloc] init];
}

- (void)alertMessage:(NSString *)message
         firstButton:(NSString *)firstButton
       flutterResult:(FlutterResult)result
    additionalButton:(NSString *)secondButton {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:nil
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *defaultAction = [UIAlertAction actionWithTitle:firstButton
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
                                                          result(@NO);
                                                        }];

  [alert addAction:defaultAction];
  if (secondButton != nil) {
    UIAlertAction *additionalAction = [UIAlertAction
        actionWithTitle:secondButton
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                  if (UIApplicationOpenSettingsURLString != NULL) {
                    NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                    [[UIApplication sharedApplication] openURL:url];
                    result(@NO);
                  }
                }];
    [alert addAction:additionalAction];
  }
  [[UIApplication sharedApplication].delegate.window.rootViewController presentViewController:alert
                                                                                     animated:YES
                                                                                   completion:nil];
}

- (void)getAvailableBiometrics:(FlutterResult)result {
  LAContext *context = self.createAuthContext;
  NSError *authError = nil;
  NSMutableArray<NSString *> *biometrics = [[NSMutableArray<NSString *> alloc] init];
  if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                           error:&authError]) {
    if (authError == nil) {
      if (@available(iOS 11.0.1, *)) {
        if (context.biometryType == LABiometryTypeFaceID) {
          [biometrics addObject:@"face"];
        } else if (context.biometryType == LABiometryTypeTouchID) {
          [biometrics addObject:@"fingerprint"];
        }
      } else {
        [biometrics addObject:@"fingerprint"];
      }
    }
  } else if (authError.code == LAErrorTouchIDNotEnrolled) {
    [biometrics addObject:@"undefined"];
  }
  result(biometrics);
}

- (void)authenticateWithBiometrics:(NSDictionary *)arguments
                 withFlutterResult:(FlutterResult)result {
  LAContext *context = self.createAuthContext;
  NSError *authError = nil;
  self.lastCallArgs = nil;
  self.lastResult = nil;
  context.localizedFallbackTitle = nil;

  if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                           error:&authError]) {
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:arguments[@"localizedReason"]
                      reply:^(BOOL success, NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                          [self handleAuthReplyWithSuccess:success
                                                     error:error
                                          flutterArguments:arguments
                                             flutterResult:result];
                        });
                      }];
  } else {
    [self handleErrors:authError flutterArguments:arguments withFlutterResult:result];
  }
}

- (void)authenticate:(NSDictionary *)arguments withFlutterResult:(FlutterResult)result {
  LAContext *context = self.createAuthContext;
  NSError *authError = nil;
  _lastCallArgs = nil;
  _lastResult = nil;
  context.localizedFallbackTitle = nil;

  if (@available(iOS 9.0, *)) {
    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&authError]) {
      [context evaluatePolicy:kLAPolicyDeviceOwnerAuthentication
              localizedReason:arguments[@"localizedReason"]
                        reply:^(BOOL success, NSError *error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                            [self handleAuthReplyWithSuccess:success
                                                       error:error
                                            flutterArguments:arguments
                                               flutterResult:result];
                          });
                        }];
    } else {
      [self handleErrors:authError flutterArguments:arguments withFlutterResult:result];
    }
  } else {
    // Fallback on earlier versions
  }
}

- (void)handleAuthReplyWithSuccess:(BOOL)success
                             error:(NSError *)error
                  flutterArguments:(NSDictionary *)arguments
                     flutterResult:(FlutterResult)result {
  NSAssert([NSThread isMainThread], @"Response handling must be done on the main thread.");
  if (success) {
    result(@YES);
  } else {
    switch (error.code) {
      case LAErrorPasscodeNotSet:
      case LAErrorTouchIDNotAvailable:
      case LAErrorTouchIDNotEnrolled:
      case LAErrorTouchIDLockout:
        [self handleErrors:error flutterArguments:arguments withFlutterResult:result];
        return;
      case LAErrorSystemCancel:
        if ([arguments[@"stickyAuth"] boolValue]) {
          self->_lastCallArgs = arguments;
          self->_lastResult = result;
          return;
        }
    }
    result(@NO);
  }
}

- (void)handleErrors:(NSError *)authError
     flutterArguments:(NSDictionary *)arguments
    withFlutterResult:(FlutterResult)result {
  NSString *errorCode = @"NotAvailable";
  switch (authError.code) {
    case LAErrorPasscodeNotSet:
    case LAErrorTouchIDNotEnrolled:
      if ([arguments[@"useErrorDialogs"] boolValue]) {
        [self alertMessage:arguments[@"goToSettingDescriptionIOS"]
                 firstButton:arguments[@"okButton"]
               flutterResult:result
            additionalButton:arguments[@"goToSetting"]];
        return;
      }
      errorCode = authError.code == LAErrorPasscodeNotSet ? @"PasscodeNotSet" : @"NotEnrolled";
      break;
    case LAErrorTouchIDLockout:
      [self alertMessage:arguments[@"lockOut"]
               firstButton:arguments[@"okButton"]
             flutterResult:result
          additionalButton:nil];
      return;
  }
  result([FlutterError errorWithCode:errorCode
                             message:authError.localizedDescription
                             details:authError.domain]);
}

#pragma mark - AppDelegate

- (void)applicationDidBecomeActive:(UIApplication *)application {
  if (self.lastCallArgs != nil && self.lastResult != nil) {
    [self authenticateWithBiometrics:_lastCallArgs withFlutterResult:self.lastResult];
  }
}

@end
