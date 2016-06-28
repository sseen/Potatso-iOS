//
//  PacketTunnelProvider.m
//  PacketTunnel
//
//  Created by LEI on 12/13/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

#import "PacketTunnelProvider.h"
#import "ProxyManager.h"
#import "TunnelInterface.h"
#import "dns.h"
#import "PotatsoBase.h"
#import <sys/syslog.h>
#import <ShadowPath/ShadowPath.h>
#import <sys/socket.h>
#import <arpa/inet.h>
@import MMWormhole;
@import CocoaAsyncSocket;

@interface PacketTunnelProvider () <GCDAsyncSocketDelegate>
@property (nonatomic) MMWormhole *wormhole;
@property (nonatomic) GCDAsyncSocket *statusSocket;
@property (nonatomic) GCDAsyncSocket *statusClientSocket;
@property (nonatomic) BOOL didSetupHockeyApp;
@property (nonatomic) NWPath *lastPath;
@property (strong) void (^pendingStartCompletion)(NSError *);
@property (strong) void (^pendingStopCompletion)(void);
@end


@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler {
    [self openLog];

    NSLog(@"starting potatso tunnel...");
    NSError *error = [TunnelInterface setupWithPacketTunnelFlow:self.packetFlow];
    if (error) {
        completionHandler(error);
        exit(1);
        return;
    }
    self.pendingStartCompletion = completionHandler;
    [self startProxies];
    [self startPacketForwarders];
    [self setupWormhole];
}

- (void)setupWormhole {
    self.wormhole = [[MMWormhole alloc] initWithApplicationGroupIdentifier:@"group.com.touchingapp.potatso" optionalDirectory:@"wormhole"];
    __weak typeof(self) weakSelf = self;
    [self.wormhole listenForMessageWithIdentifier:@"getTunnelStatus" listener:^(id  _Nullable messageObject) {
        [weakSelf.wormhole passMessageObject:@"ok" identifier:@"tunnelStatus"];
    }];
    [self.wormhole listenForMessageWithIdentifier:@"stopTunnel" listener:^(id  _Nullable messageObject) {
        [weakSelf stop];
    }];
    [self.wormhole listenForMessageWithIdentifier:@"getTunnelConnectionRecords" listener:^(id  _Nullable messageObject) {
        NSMutableArray *records = [NSMutableArray array];
        struct log_client_states *p = log_clients;
        while (p) {
            struct client_state *client = p->csp;
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            char *url = client->http->url;
            if (url ==  NULL) {
                p = p->next;
                continue;
            }
            d[@"url"] = [NSString stringWithCString:url encoding:NSUTF8StringEncoding];
            d[@"method"] = @(client->http->gpc);
            for (int i=0; i < STATUS_COUNT; i++) {
                d[[NSString stringWithFormat:@"time%d", i]] = @(client->timestamp[i]);
            }
            d[@"version"] = @(client->http->ver);
//            if (p->headers) {
//                d[@"headers"] = [NSString stringWithCString:p->headers->string encoding:NSUTF8StringEncoding];
//            }
//            if (p->rule) {
//                d[@"ruleType"] = @(p->rule->type),
//                d[@"ruleAction"] = @(p->rule->action),
//                d[@"ruleValue"] = [NSString stringWithCString:p->rule->value encoding:NSUTF8StringEncoding];
//            }
            
            d[@"responseCode"] = @(client->http->status);
            [records addObject:d];
            p = p->next;
        }
        NSString *result = [records jsonString];
        [weakSelf.wormhole passMessageObject:result identifier:@"tunnelConnectionRecords"];
    }];
    [self setupStatusSocket];
}

- (void)setupStatusSocket {
    NSError *error;
    self.statusSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)];
    [self.statusSocket acceptOnInterface:@"127.0.0.1" port:0 error:&error];
    [self.statusSocket performBlock:^{
        int port = sock_port(self.statusSocket.socket4FD);
        [[Potatso sharedUserDefaults] setObject:@(port) forKey:@"tunnelStatusPort"];
        [[Potatso sharedUserDefaults] synchronize];
    }];
}

- (void)startProxies {
    __block NSError *proxyError;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_enter(g);
    [[ProxyManager sharedManager] startShadowsocks:^(int port, NSError *error) {
        proxyError = error;
        dispatch_group_leave(g);
    }];
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (proxyError) {
        exit(1);
        return;
    }
    dispatch_group_enter(g);
    [[ProxyManager sharedManager] startHttpProxy:^(int port, NSError *error) {
        proxyError = error;
        dispatch_group_leave(g);
    }];
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (proxyError) {
        exit(1);
        return;
    }
    dispatch_group_enter(g);
    [[ProxyManager sharedManager] startSocksProxy:^(int port, NSError *error) {
        proxyError = error;
        dispatch_group_leave(g);
    }];
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (proxyError) {
        exit(1);
        return;
    }
}

- (void)startPacketForwarders {
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTun2SocksFinished) name:kTun2SocksStoppedNotification object:nil];
    [self startVPNWithOptions:nil completionHandler:^(NSError *error) {
        if (error == nil) {
            [weakSelf addObserver:weakSelf forKeyPath:@"defaultPath" options:NSKeyValueObservingOptionInitial context:nil];
            [TunnelInterface startTun2Socks:[ProxyManager sharedManager].socksProxyPort];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [TunnelInterface processPackets];
            });
        }
        if (weakSelf.pendingStartCompletion) {
            weakSelf.pendingStartCompletion(error);
            weakSelf.pendingStartCompletion = nil;
        }
    }];
}

- (void)startVPNWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *error))completionHandler {
    NSString *generalConfContent = [NSString stringWithContentsOfURL:[Potatso sharedGeneralConfUrl] encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *generalConf = [generalConfContent jsonDictionary];
    NSString *dns = generalConf[@"dns"];
    NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.0.2.1"] subnetMasks:@[@"255.255.255.0"]];
    NSArray *dnsServers;
    if (dns.length) {
        dnsServers = [dns componentsSeparatedByString:@","];
        NSLog(@"custom dns servers: %@", dnsServers);
    }else {
        dnsServers = [DNSConfig getSystemDnsServers];
        NSLog(@"system dns servers: %@", dnsServers);
    }
    NSMutableArray *excludedRoutes = [NSMutableArray array];
    for (NSString *server in dnsServers) {
        [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:[server stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] subnetMask:@"255.255.255.255"]];
    }
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"192.168.0.0" subnetMask:@"255.255.0.0"]];
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"10.0.0.0" subnetMask:@"255.0.0.0"]];
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"172.16.0.0" subnetMask:@"255.240.0.0"]];
    ipv4Settings.includedRoutes = @[[NEIPv4Route defaultRoute]];
    ipv4Settings.excludedRoutes = excludedRoutes;
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"192.0.2.2"];
    settings.IPv4Settings = ipv4Settings;
    settings.MTU = @(TunnelMTU);
    NEProxySettings* proxySettings = [[NEProxySettings alloc] init];
    NSInteger proxyServerPort = [ProxyManager sharedManager].httpProxyPort;
    NSString *proxyServerName = @"localhost";

    proxySettings.HTTPEnabled = YES;
    proxySettings.HTTPServer = [[NEProxyServer alloc] initWithAddress:proxyServerName port:proxyServerPort];
    proxySettings.HTTPSEnabled = YES;
    proxySettings.HTTPSServer = [[NEProxyServer alloc] initWithAddress:proxyServerName port:proxyServerPort];
    proxySettings.excludeSimpleHostnames = YES;
    settings.proxySettings = proxySettings;
    settings.DNSSettings = [[NEDNSSettings alloc] initWithServers:dnsServers];
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError * _Nullable error) {
        if (error) {
            if (completionHandler) {
                completionHandler(error);
            }
        }else{
            if (completionHandler) {
                completionHandler(nil);
            }
        }
    }];
}

- (void)openLog {
    NSString *logFilePath = [Potatso sharedLogUrl].path;
    [[NSFileManager defaultManager] createFileAtPath:logFilePath contents:nil attributes:nil];
    freopen([logFilePath cStringUsingEncoding:NSASCIIStringEncoding], "w+", stdout);
    freopen([logFilePath cStringUsingEncoding:NSASCIIStringEncoding], "w+", stderr);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"defaultPath"]) {
        if (self.defaultPath.status == NWPathStatusSatisfied && ![self.defaultPath isEqualToPath:self.lastPath]) {
            if (!self.lastPath) {
                self.lastPath = self.defaultPath;
            }else {
                NSLog(@"received network change notifcation");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self startVPNWithOptions:nil completionHandler:nil];
                });
            }
        }else {
            self.lastPath = self.defaultPath;
        }
    }
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler
{
	// Add code here to start the process of stopping the tunnel
    self.pendingStopCompletion = completionHandler;
    [self stop];
}

- (void)stop {
    NSLog(@"stoping potatso tunnel...");
    [[Potatso sharedUserDefaults] setObject:@(0) forKey:@"tunnelStatusPort"];
    [[Potatso sharedUserDefaults] synchronize];
    [[ProxyManager sharedManager] stopHttpProxy];
    [[ProxyManager sharedManager] stopSocksProxy];
    [TunnelInterface stop];
}

- (void)onTun2SocksFinished {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.pendingStopCompletion) {
        self.pendingStopCompletion();
        self.pendingStopCompletion = nil;
    }
    [self cancelTunnelWithError:nil];
    exit(EXIT_SUCCESS);
}

- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler {
    if (completionHandler != nil) {
        completionHandler(nil);
    }
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    NSLog(@"sleeping potatso tunnel...");
	completionHandler();
}

- (void)wake {
    NSLog(@"waking potatso tunnel...");
}

#pragma mark - GCDAsyncSocket Delegate 

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    self.statusClientSocket = newSocket;
}


@end
