//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSInvalidIdentityKeyReceivingErrorMessage.h"
#import "OWSFingerprint.h"
#import "OWSIdentityManager.h"
#import "OWSMessageManager.h"
#import "OWSMessageReceiver.h"
#import "OWSPrimaryStorage+SessionStore.h"
#import "OWSPrimaryStorage.h"
#import "TSContactThread.h"
#import "TSDatabaseView.h"
#import "TSErrorMessage_privateConstructor.h"
#import <AxolotlKit/NSData+keyVersionByte.h>
#import <AxolotlKit/PreKeyWhisperMessage.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

/// TODO we can eventually deprecate this, since incoming messages are now always decrypted.
@interface TSInvalidIdentityKeyReceivingErrorMessage ()

@property (nonatomic, readonly, copy) NSString *authorId;

@end

@implementation TSInvalidIdentityKeyReceivingErrorMessage {
    // Not using a property declaration in order to exclude from DB serialization
    SSKEnvelope *_Nullable _envelope;
}

@synthesize envelopeData = _envelopeData;

- (nullable SSKEnvelope *)envelope
{
    if (!_envelope) {
        NSError *error;
        SSKEnvelope *_Nullable envelope = [[SSKEnvelope alloc] initWithSerializedData:self.envelopeData error:&error];
        if (error || envelope == nil) {
            OWSProdLogAndFail(@"%@ Could not parse proto: %@", self.logTag, error);
        } else {
            _envelope = envelope;
        }
    }
    return _envelope;
}

- (void)acceptNewIdentityKey
{
    OWSAssertIsOnMainThread();

    if (self.errorType != TSErrorMessageWrongTrustedIdentityKey) {
        DDLogError(@"Refusing to accept identity key for anything but a Key error.");
        return;
    }

    NSData *_Nullable newKey = [self newIdentityKey];
    if (!newKey) {
        OWSFail(@"Couldn't extract identity key to accept");
        return;
    }

    [[OWSIdentityManager sharedManager] saveRemoteIdentity:newKey recipientId:self.envelope.source];

    // Decrypt this and any old messages for the newly accepted key
    NSArray<TSInvalidIdentityKeyReceivingErrorMessage *> *messagesToDecrypt =
        [self.thread receivedMessagesForInvalidKey:newKey];

    for (TSInvalidIdentityKeyReceivingErrorMessage *errorMessage in messagesToDecrypt) {
        [[OWSMessageReceiver sharedInstance] handleReceivedEnvelopeData:errorMessage.envelopeData];

        // Here we remove the existing error message because handleReceivedEnvelope will either
        //  1.) succeed and create a new successful message in the thread or...
        //  2.) fail and create a new identical error message in the thread.
        [errorMessage remove];
    }
}

- (nullable NSData *)newIdentityKey
{
    if (!self.envelope) {
        DDLogError(@"Error message had no envelope data to extract key from");
        return nil;
    }

    if (self.envelope.type != SSKEnvelopeTypePrekeyBundle) {
        DDLogError(@"Refusing to attempt key extraction from an envelope which isn't a prekey bundle");
        return nil;
    }

    NSData *pkwmData = self.envelope.content;
    if (!pkwmData) {
        DDLogError(@"Ignoring acceptNewIdentityKey for empty message");
        return nil;
    }

    PreKeyWhisperMessage *message = [[PreKeyWhisperMessage alloc] initWithData:pkwmData];
    return [message.identityKey removeKeyType];
}

- (NSString *)theirSignalId
{
    if (self.authorId) {
        return self.authorId;
    } else {
        // for existing messages before we were storing author id.
        return self.envelope.source;
    }
}

@end

NS_ASSUME_NONNULL_END
