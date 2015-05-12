//
//  TSSocketManager.m
//  TextSecureiOS
//
//  Created by Frederic Jacobs on 17/05/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.
//

#import "SubProtocol.pb.h"

#import "TSConstants.h"
#import "TSAccountManager.h"
#import "TSMessagesManager.h"
#import "TSSocketManager.h"
#import "TSStorageManager+keyingMaterial.h"
#import <CocoaLumberjack/DDLog.h>

#import "NSData+Base64.h"
#import "Cryptography.h"
#import "IncomingPushMessageSignal.pb.h"

#define kWebSocketHeartBeat         30
#define kWebSocketReconnectTry      5
#define kBackgroundConnectTimer     120
#define kBackgroundConnectKeepAlive 20

NSString * const SocketOpenedNotification     = @"SocketOpenedNotification";
NSString * const SocketClosedNotification     = @"SocketClosedNotification";
NSString * const SocketConnectingNotification = @"SocketConnectingNotification";

@interface TSSocketManager ()
@property (nonatomic, retain) NSTimer *pingTimer;
@property (nonatomic, retain) NSTimer *reconnectTimer;
@property (nonatomic, retain) NSTimer *backgroundKeepAliveTimer;

@property (nonatomic, retain) SRWebSocket *websocket;
@property (nonatomic) SocketStatus status;

@property (nonatomic) UIBackgroundTaskIdentifier fetchingTaskIdentifier;

@property BOOL didFetchInBackground;

@end

@implementation TSSocketManager

- (instancetype)init{
    self = [super init];
    
    if (self) {
        self.websocket = nil;
        [self addObserver:self forKeyPath:@"status" options:0 context:kSocketStatusObservationContext];
    }
    
    return self;
}

+ (instancetype)sharedManager {
    static TSSocketManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] init];
        sharedMyManager.fetchingTaskIdentifier = UIBackgroundTaskInvalid;
        sharedMyManager.didFetchInBackground   = FALSE;
    });
    return sharedMyManager;
}

#pragma mark - Manage Socket

+ (void)becomeActive {
    TSSocketManager *sharedInstance = [self sharedManager];
    SRWebSocket *socket             = [sharedInstance websocket];
    
    if (socket) {
        switch ([socket readyState]) {
            case SR_OPEN:
                DDLogVerbose(@"WebSocket already open on connection request");
                sharedInstance.status = kSocketStatusOpen;
                return;
            case SR_CONNECTING:
                DDLogVerbose(@"WebSocket is already connecting");
                sharedInstance.status = kSocketStatusConnecting;
                return;
            default:
                [socket close];
                sharedInstance.status = kSocketStatusClosed;
                socket.delegate = nil;
                socket = nil;
                break;
        }
    }
    
    NSString* webSocketConnect   = [textSecureWebSocketAPI stringByAppendingString:[[self sharedManager] webSocketAuthenticationString]];
    NSURL* webSocketConnectURL   = [NSURL URLWithString:webSocketConnect];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:webSocketConnectURL];
    NSString* cerPath            = [[NSBundle mainBundle] pathForResource:@"textsecure" ofType:@"cer"];
    NSData* certData             = [[NSData alloc] initWithContentsOfFile:cerPath];
    CFDataRef certDataRef        = (__bridge CFDataRef)certData;
    SecCertificateRef certRef    = SecCertificateCreateWithData(NULL, certDataRef);
    id certificate               = (__bridge id)certRef;
    [request setSR_SSLPinnedCertificates:@[ certificate ]];
    
    socket                       = [[SRWebSocket alloc] initWithURLRequest:request];
    socket.delegate              = [self sharedManager];
    
    [socket open];
    [[self sharedManager] setWebsocket:socket];
}

+ (void)resignActivity{
    SRWebSocket *socket = [[self sharedManager] websocket];
    [socket close];
}

#pragma mark - Delegate methods

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    self.pingTimer  = [NSTimer scheduledTimerWithTimeInterval:kWebSocketHeartBeat
                                                       target:self
                                                     selector:@selector(webSocketHeartBeat)
                                                     userInfo:nil
                                                      repeats:YES];
    
    // Additionally, we want the ping timer to work in the background too.
    [[NSRunLoop mainRunLoop] addTimer:self.pingTimer
                              forMode:NSDefaultRunLoopMode];
    
    self.status     = kSocketStatusOpen;
    
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    DDLogError(@"Error connecting to socket %@", error);
    [self.pingTimer invalidate];
    self.status = kSocketStatusClosed;
    [self scheduleRetry];
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(NSData*)data {
    WebSocketMessage *wsMessage = [WebSocketMessage parseFromData:data];
    self.didFetchInBackground   = YES;
    
    if (wsMessage.type == WebSocketMessageTypeRequest) {
        [self processWebSocketRequestMessage:wsMessage.request];
    } else if (wsMessage.type == WebSocketMessageTypeResponse){
        [self processWebSocketResponseMessage:wsMessage.response];
    } else{
        DDLogWarn(@"Got a WebSocketMessage of unknown type");
    }
}

- (void)processWebSocketRequestMessage:(WebSocketRequestMessage*)message {
    DDLogInfo(@"Got message with verb: %@ and path: %@", message.verb, message.path);
    
    [self sendWebSocketMessageAcknowledgement:message];
    
    [self keepAliveBackground];
    
    if ([message.path isEqualToString:@"/api/v1/message"] && [message.verb isEqualToString:@"PUT"]){
        NSData *decryptedPayload = [Cryptography decryptAppleMessagePayload:message.body
                                                           withSignalingKey:TSStorageManager.signalingKey];
        
        if (!decryptedPayload) {
            DDLogWarn(@"Failed to decrypt incoming payload or bad HMAC");
            return;
        }
        
        IncomingPushMessageSignal *messageSignal = [IncomingPushMessageSignal parseFromData:decryptedPayload];
        
        [[TSMessagesManager sharedManager] handleMessageSignal:messageSignal];
    } else{
        DDLogWarn(@"Unsupported WebSocket Request");
    }
}

- (void)keepAliveBackground {
    if (self.fetchingTaskIdentifier) {
        [self.backgroundKeepAliveTimer invalidate];
        
        self.backgroundKeepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:kBackgroundConnectKeepAlive
                                                                         target:self
                                                                       selector:@selector(backgroundTimeExpired)
                                                                       userInfo:nil
                                                                        repeats:NO];
        // Additionally, we want the reconnect timer to work in the background too.
        [[NSRunLoop mainRunLoop] addTimer:self.backgroundKeepAliveTimer
                                  forMode:NSDefaultRunLoopMode];

    }
}

- (void)processWebSocketResponseMessage:(WebSocketResponseMessage*)message {
    DDLogWarn(@"Client should not receive WebSocket Respond messages");
}

- (void)sendWebSocketMessageAcknowledgement:(WebSocketRequestMessage*)request {
    WebSocketResponseMessageBuilder *response = [WebSocketResponseMessage builder];
    [response setStatus:200];
    [response setMessage:@"OK"];
    [response setId:request.id];
    
    WebSocketMessageBuilder *message = [WebSocketMessage builder];
    [message setResponse:response.build];
    [message setType:WebSocketMessageTypeResponse];
    
    @try {
        [self.websocket send:message.build.data];
    }
    @catch (NSException *exception) {
        DDLogWarn(@"Caught exception while trying to write on the socket %@", exception.debugDescription);
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    DDLogVerbose(@"WebSocket did close");
    [self.pingTimer invalidate];
    self.status = kSocketStatusClosed;
    [self scheduleRetry];
}

- (void)webSocketHeartBeat {
    @try {
        [self.websocket sendPing:nil];
    }
    @catch (NSException *exception) {
        DDLogWarn(@"Caught exception while trying to write on the socket %@", exception.debugDescription);
    }
}

- (NSString*)webSocketAuthenticationString {
    return [NSString stringWithFormat:@"?login=%@&password=%@", [[TSAccountManager registeredNumber] stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"],[TSStorageManager serverAuthToken]];
}

- (void)scheduleRetry {
    if (!self.reconnectTimer || ![self.reconnectTimer isValid]) {
        self.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:kWebSocketReconnectTry
                                                               target:[self class]
                                                             selector:@selector(becomeActive)
                                                             userInfo:nil
                                                              repeats:YES];
        // Additionally, we want the reconnect timer to work in the background too.
        [[NSRunLoop mainRunLoop] addTimer:self.reconnectTimer
                                  forMode:NSDefaultRunLoopMode];
    }
}

#pragma mark - Background Connect

+ (void)becomeActiveFromForeground {
    TSSocketManager *sharedInstance = [self sharedManager];
    [sharedInstance.backgroundKeepAliveTimer invalidate];
    
    if (sharedInstance.fetchingTaskIdentifier != UIBackgroundTaskInvalid) {
        [sharedInstance closeBackgroundTask];
    }
    
    [self becomeActive];
}


+ (void)becomeActiveFromBackground {
    TSSocketManager *sharedInstance = [TSSocketManager sharedManager];
    
    if (sharedInstance.fetchingTaskIdentifier == UIBackgroundTaskInvalid) {
        [sharedInstance.backgroundKeepAliveTimer invalidate];
        sharedInstance.didFetchInBackground = NO;
        sharedInstance.fetchingTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            DDLogWarn(@"Running expiration handler");

            [TSSocketManager resignActivity];
            [sharedInstance closeBackgroundTask];
        }];
        
        [self becomeActive];
    } else {
        DDLogWarn(@"Got called to become active in the background but there was already a background task running.");
    }
}

- (void)backgroundTimeExpired {
    [[self class] resignActivity];
    [self closeBackgroundTask];
}

- (void)closeBackgroundTask {
    UIBackgroundTaskIdentifier identifier = self.fetchingTaskIdentifier;
    self.fetchingTaskIdentifier           = UIBackgroundTaskInvalid;
    [self.backgroundKeepAliveTimer invalidate];
    
    if (!self.didFetchInBackground) {
        DDLogWarn(@"Didn't fetch anything in background!");
        [self backgroundConnectTimedOut];
    }
    
    [[UIApplication sharedApplication] endBackgroundTask:identifier];
}

- (void)backgroundConnectTimedOut {
    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.alertBody            = NSLocalizedString(@"APN_FETCHED_FAILED", nil);
    [[UIApplication sharedApplication] presentLocalNotificationNow:notification];
}

#pragma mark UI Delegates

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == kSocketStatusObservationContext)
    {
        [self notifyStatusChange];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)notifyStatusChange {
    switch (self.status) {
        case kSocketStatusOpen:
            [[NSNotificationCenter defaultCenter] postNotificationName:SocketOpenedNotification object:self];
            break;
        case kSocketStatusClosed:
            [[NSNotificationCenter defaultCenter] postNotificationName:SocketClosedNotification object:self];
            break;
        case kSocketStatusConnecting:
            [[NSNotificationCenter defaultCenter] postNotificationName:SocketConnectingNotification object:self];
            break;
        default:
            break;
    }
}

+ (void)sendNotification {
    [[self sharedManager] notifyStatusChange];
}

@end
