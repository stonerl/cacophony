#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Thin C wrappers over the private AVFCore routing classes
// (AVOutputDevice, AVOutputContext). Everything is resolved at runtime via
// NSClassFromString/objc_msgSend so we never reference private symbols at
// link time.

/// KVC property read that swallows exceptions; nil when absent.
id _Nullable CACDeviceProperty(NSObject *device, NSString *key);

/// The audio-type AVOutputContext (+iTunesAudioContext).
NSObject *_Nullable CACCreateAudioContext(void);

/// +[AVOutputContext defaultSharedOutputContext] (audio type).
NSObject *_Nullable CACDefaultSharedAudioContext(void);

/// -[AVOutputContext ID] (falls back to contextID).
NSString *_Nullable CACContextID(NSObject *context);

/// +[AVOutputContext outputContextForID:] — rehydrates a context by ID.
NSObject *_Nullable CACContextForID(NSString *contextID);

/// -[AVRoutePickerView setOutputContextID:] — attaches the system AirPlay
/// picker (which runs in the entitled AirPlayUIAgent) to our context.
BOOL CACPickerSetOutputContextID(NSObject *pickerView, NSString *contextID);

/// -[AVOutputContext outputDevices] (falls back to outputDevice, wrapped in an array).
NSArray<NSObject *> *CACContextOutputDevices(NSObject *context);

/// -[AVSampleBufferAudioRenderer setOutputContext:]. Returns NO if missing.
BOOL CACRendererSetOutputContext(AVSampleBufferAudioRenderer *renderer, NSObject *context);

// AVFoundation deprecated these renderer methods in macOS 27. Keep the proven
// renderer path while avoiding compile-time deprecation warnings.
void CACRendererAddToSynchronizer(NSObject *synchronizer, NSObject *renderer);
BOOL CACRendererIsReady(NSObject *renderer);
void CACRendererEnqueue(NSObject *renderer, CMSampleBufferRef sampleBuffer);
void CACRendererStopRequesting(NSObject *renderer);
void CACRendererFlush(NSObject *renderer);
BOOL CACRendererFailed(NSObject *renderer);
NSString *_Nullable CACRendererErrorMessage(NSObject *renderer);

/// -[AVOutputDevice setDeviceVolume:] / volume read, when supported.
BOOL CACDeviceSetVolume(NSObject *device, float volume);

NS_ASSUME_NONNULL_END
