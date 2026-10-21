#import "CacophonyRouting.h"
#import <objc/message.h>

id CACDeviceProperty(NSObject *device, NSString *key) {
    @try {
        return [device valueForKey:key];
    } @catch (id exception) {
        return nil;
    }
}

NSObject *CACCreateAudioContext(void) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"iTunesAudioContext");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return fn(cls, sel);
}

NSObject *CACDefaultSharedAudioContext(void) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"defaultSharedOutputContext");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return fn(cls, sel);
}

NSString *CACContextID(NSObject *context) {
    @try {
        NSString *identifier = [context valueForKey:@"ID"];
        if (identifier) return identifier;
    } @catch (id exception) {
    }
    @try {
        return [context valueForKey:@"contextID"];
    } @catch (id exception) {
        return nil;
    }
}

NSObject *CACContextForID(NSString *contextID) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"outputContextForID:");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL, id) = (id (*)(Class, SEL, id))objc_msgSend;
    return fn(cls, sel, contextID);
}

BOOL CACPickerSetOutputContextID(NSObject *pickerView, NSString *contextID) {
    SEL sel = NSSelectorFromString(@"setOutputContextID:");
    if (![pickerView respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(pickerView, sel, contextID);
    return YES;
}

NSArray<NSObject *> *CACContextOutputDevices(NSObject *context) {
    @try {
        NSArray *devices = [context valueForKey:@"outputDevices"];
        if (devices.count > 0) return devices;
    } @catch (id exception) {
    }
    @try {
        id device = [context valueForKey:@"outputDevice"];
        if (device) return @[ device ];
    } @catch (id exception) {
    }
    return @[];
}

void CACRendererAddToSynchronizer(NSObject *synchronizer, NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"addRenderer:");
    if (![synchronizer respondsToSelector:sel]) return;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(synchronizer, sel, renderer);
}

BOOL CACRendererIsReady(NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"isReadyForMoreMediaData");
    if (![renderer respondsToSelector:sel]) return NO;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return fn(renderer, sel);
}

void CACRendererEnqueue(NSObject *renderer, CMSampleBufferRef sampleBuffer) {
    SEL sel = NSSelectorFromString(@"enqueueSampleBuffer:");
    if (![renderer respondsToSelector:sel]) return;
    void (*fn)(id, SEL, CMSampleBufferRef) = (void (*)(id, SEL, CMSampleBufferRef))objc_msgSend;
    fn(renderer, sel, sampleBuffer);
}

void CACRendererStopRequesting(NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"stopRequestingMediaData");
    if (![renderer respondsToSelector:sel]) return;
    void (*fn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    fn(renderer, sel);
}

void CACRendererFlush(NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"flush");
    if (![renderer respondsToSelector:sel]) return;
    void (*fn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    fn(renderer, sel);
}

BOOL CACRendererFailed(NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"status");
    if (![renderer respondsToSelector:sel]) return NO;
    NSInteger (*fn)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
    return fn(renderer, sel) == AVQueuedSampleBufferRenderingStatusFailed;
}

NSString *CACRendererErrorMessage(NSObject *renderer) {
    SEL sel = NSSelectorFromString(@"error");
    if (![renderer respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSError *error = fn(renderer, sel);
    return error.localizedDescription;
}

BOOL CACRendererSetOutputContext(AVSampleBufferAudioRenderer *renderer, NSObject *context) {
    SEL sel = NSSelectorFromString(@"setOutputContext:");
    if (![renderer respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(renderer, sel, context);
    return YES;
}

BOOL CACDeviceSetVolume(NSObject *device, float volume) {
    SEL sel = NSSelectorFromString(@"setDeviceVolume:");
    if ([device respondsToSelector:sel]) {
        void (*fn)(id, SEL, float) = (void (*)(id, SEL, float))objc_msgSend;
        fn(device, sel, volume);
        return YES;
    }
    sel = NSSelectorFromString(@"setVolume:");
    if ([device respondsToSelector:sel]) {
        void (*fn)(id, SEL, float) = (void (*)(id, SEL, float))objc_msgSend;
        fn(device, sel, volume);
        return YES;
    }
    return NO;
}
