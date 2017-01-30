//
// Copyright 2010-2016 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
// http://aws.amazon.com/apache2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//

#import "ViewController.h"

#import <AVFoundation/AVAudioSession.h>
#import "CAXException.h"
#import "CAStreamBasicDescription.h"

@interface ViewController ()<AWSLexVoiceButtonDelegate, AVAudioPlayerDelegate>

@end

@implementation ViewController{

    AVAudioPlayer *_audioPlayer;
    // from aurioTouch
    AudioUnit               _rioUnit;
    snowboy::SnowboyDetect* _snowboyDetect;     // Detector.

    BOOL isVoiceProcessing;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.voiceButton.delegate = self;
    _audioPlayer = [[AVAudioPlayer alloc] init];

    _snowboyDetect = NULL;
    cd.voiceButton = self.voiceButton;

    isVoiceProcessing = NO;
    cd.isVoiceProcessing = isVoiceProcessing;

//    cd.player = _audioPlayer;

    [self setupAudioSession];
    [self setupIOUnit];
    [self startIOUnit];

}

#pragma mark - VoiceButtonDelegate Methods

- (void)voiceButton:(AWSLexVoiceButton *)button onResponse:(nonnull AWSLexVoiceButtonResponse *)response{
    NSLog(@"on text output %@", response.outputText);

    if(response.dialogState == AWSLexDialogStateElicitIntent){
        return;
    }

    NSString *attr = response.sessionAttributes[@"message"];
    AWSPollySynthesizeSpeechURLBuilderRequest *buildReq = [[AWSPollySynthesizeSpeechURLBuilderRequest alloc] init];
    [buildReq setText:attr];
    [buildReq setOutputFormat:AWSPollyOutputFormatMp3];
    [buildReq setVoiceId:AWSPollyVoiceIdMizuki];

    NSString *recipe = response.sessionAttributes[@"Recipe"];

    AWSTask *builder = [[AWSPollySynthesizeSpeechURLBuilder defaultPollySynthesizeSpeechURLBuilder] getPreSignedURL:buildReq];

    __weak ViewController *weakSelf = self;

    [builder continueWithSuccessBlock:^id _Nullable(AWSTask<NSURL *> * _Nonnull task) {
        NSURL *url = [task result];
        //AVAudioPlayer can not play mp3 from network. Use NSData.
        NSData *data = [[NSData alloc] initWithContentsOfURL:url];
        _audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:nil];
        [_audioPlayer play];

        [weakSelf.interactionKit audioInTextOutWithSessionAttributes:@{@"Recipe": recipe}];
        cd.isVoiceProcessing = NO;
        return nil;
    }];
}

- (void)voiceButton:(AWSLexVoiceButton *)button onError:(NSError *)error{
    cd.isVoiceProcessing = NO;
    NSLog(@"error %@", error);
}


# pragma mark voice Capture functions From aurioTouch

#pragma mark from aurioTouch

struct CallbackData {
    AudioUnit               rioUnit;
    snowboy::SnowboyDetect* snowboyDetect;
    AWSLexVoiceButton *voiceButton;
    BOOL isVoiceProcessing;
    AVAudioPlayer *player;
    CallbackData(): rioUnit(NULL), snowboyDetect(NULL), voiceButton(NULL), isVoiceProcessing(NULL), player(NULL){}
} cd;

// Render callback function
static OSStatus	performRender (void                         *inRefCon,
                               AudioUnitRenderActionFlags 	*ioActionFlags,
                               const AudioTimeStamp 		*inTimeStamp,
                               UInt32 						inBusNumber,
                               UInt32 						inNumberFrames,
                               AudioBufferList              *ioData)
{
    OSStatus err = noErr;

    // we are calling AudioUnitRender on the input bus of AURemoteIO
    // this will store the audio data captured by the microphone in ioData
    err = AudioUnitRender(cd.rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);

    // Creates Float32 data that is required by the original app.
    Float32 *float32_data = new Float32[inNumberFrames];
    for (UInt32 i = 0; i < inNumberFrames; i++)
    {
        float32_data[i] = (Float32) (((SInt16 *) ioData->mBuffers[0].mData)[i]) / ((Float32) 32768);
    }

    // Runs detection.
    if (cd.snowboyDetect != NULL)
    {
        int result = cd.snowboyDetect->RunDetection((SInt16 *) ioData->mBuffers[0].mData, inNumberFrames);
        if (result > 0 && cd.isVoiceProcessing == NO)
        {
            NSLog(@"Snowboy detected.");
            CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFStringRef([[NSBundle mainBundle] pathForResource:@"detection" ofType:@"caf"]), kCFURLPOSIXPathStyle, false);
            cd.player = [[AVAudioPlayer alloc] initWithContentsOfURL:(__bridge NSURL*)url error:nil];
            [cd.player play];
            sleep(1.0f);
            NSLog(@"wake up voice button");
            cd.isVoiceProcessing = YES;
            [cd.voiceButton startMonitoring:cd.voiceButton];
        }
    }

    // Mute Audio
    for (UInt32 i=0; i<ioData->mNumberBuffers; ++i)
        memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);

    // Deletes Float32 data.
    delete[] float32_data;

    return err;
}


- (void)setupAudioSession
{
    try {
        // Configure the audio session
        AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];

        // we are going to play and record so we pick that category
        NSError *error = nil;
        [sessionInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        XThrowIfError((OSStatus)error.code, "couldn't set session's audio category");

        // set the buffer duration to 100 ms
        NSTimeInterval bufferDuration = .1;
        [sessionInstance setPreferredIOBufferDuration:bufferDuration error:&error];
        XThrowIfError((OSStatus)error.code, "couldn't set session's I/O buffer duration");

        // set the session's sample rate
        [sessionInstance setPreferredSampleRate:16000 error:&error];
        XThrowIfError((OSStatus)error.code, "couldn't set session's preferred sample rate");

        // add interruption handler
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:sessionInstance];

        // we don't do anything special in the route change notification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:sessionInstance];

        // if media services are reset, we need to rebuild our audio chain
        [[NSNotificationCenter defaultCenter]	addObserver:	self
                                                 selector:	@selector(handleMediaServerReset:)
                                                     name:	AVAudioSessionMediaServicesWereResetNotification
                                                   object:	sessionInstance];

        // activate the audio session
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        XThrowIfError((OSStatus)error.code, "couldn't set session active");
    }

    catch (CAXException &e) {
        NSLog(@"Error returned from setupAudioSession: %d: %s", (int)e.mError, e.mOperation);
    }
    catch (...) {
        NSLog(@"Unknown error returned from setupAudioSession");
    }

    return;
}

- (void)handleInterruption:(NSNotification *)notification
{
    NSLog(@"interrupt");
}


- (void)handleRouteChange:(NSNotification *)notification
{
    NSLog(@"route change");
}

- (void)handleMediaServerReset:(NSNotification *)notification
{
    NSLog(@"media server reset");
}


- (void)setupIOUnit
{
    try {
        // Create a new instance of AURemoteIO

        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_RemoteIO;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        XThrowIfError(AudioComponentInstanceNew(comp, &_rioUnit), "couldn't create a new instance of AURemoteIO");

        //  Enable input and output on AURemoteIO
        //  Input is enabled on the input scope of the input element
        //  Output is enabled on the output scope of the output element

        UInt32 one = 1;
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one)), "could not enable input on AURemoteIO");
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof(one)), "could not enable output on AURemoteIO");

        // Explicitly set the input and output client formats
        // sample rate = 16000, num channels = 1, format = 16 bit signed-integer

        CAStreamBasicDescription ioFormat = CAStreamBasicDescription(16000, 1, CAStreamBasicDescription::kPCMFormatInt16, false);
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &ioFormat, sizeof(ioFormat)), "couldn't set the input client format on AURemoteIO");
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioFormat, sizeof(ioFormat)), "couldn't set the output client format on AURemoteIO");

        // Set the MaximumFramesPerSlice property. This property is used to describe to an audio unit the maximum number
        // of samples it will be asked to produce on any single given call to AudioUnitRender
        UInt32 maxFramesPerSlice = 4096;
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, sizeof(UInt32)), "couldn't set max frames per slice on AURemoteIO");

        // Get the property value back from AURemoteIO. We are going to use this value to allocate buffers accordingly
        UInt32 propSize = sizeof(UInt32);
        XThrowIfError(AudioUnitGetProperty(_rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, &propSize), "couldn't get max frames per slice on AURemoteIO");

        _snowboyDetect = new snowboy::SnowboyDetect(std::string([[[NSBundle mainBundle]pathForResource:@"common" ofType:@"res"] UTF8String]),
                                                    std::string([[[NSBundle mainBundle]pathForResource:@"クックパッド" ofType:@"pmdl"] UTF8String]));
        _snowboyDetect->SetSensitivity("0.6");        // Sensitivity for each hotword
        _snowboyDetect->SetAudioGain(5.0);             // Audio gain for detection

        // We need references to certain data in the render callback
        // This simple struct is used to hold that information

        cd.rioUnit = _rioUnit;
        cd.snowboyDetect = _snowboyDetect;

        // Set the render callback on AURemoteIO
        AURenderCallbackStruct renderCallback;
        renderCallback.inputProc = performRender;
        renderCallback.inputProcRefCon = NULL;
        XThrowIfError(AudioUnitSetProperty(_rioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, sizeof(renderCallback)), "couldn't set render callback on AURemoteIO");

        // Initialize the AURemoteIO instance
        XThrowIfError(AudioUnitInitialize(_rioUnit), "couldn't initialize AURemoteIO instance");
    }

    catch (CAXException &e) {
        NSLog(@"Error returned from setupIOUnit: %d: %s", (int)e.mError, e.mOperation);
    }
    catch (...) {
        NSLog(@"Unknown error returned from setupIOUnit");
    }
    
    return;
}

- (OSStatus)startIOUnit
{
    OSStatus err = AudioOutputUnitStart(_rioUnit);
    if (err) NSLog(@"couldn't start AURemoteIO: %d", (int)err);
    return err;
}


@end
