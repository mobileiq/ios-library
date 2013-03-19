/*
Copyright 2009-2012 Urban Airship Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binaryform must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided withthe distribution.

THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "UAInboxMessageList.h"

#import "UAirship.h"
#import "UAInboxMessage.h"
#import "UAInboxDBManager.h"
#import "UAUtils.h"
#import "UAUser.h"

#import "UA_SBJSON.h"

#import "UAHTTPConnection.h"

NSString *const UAInboxMessageRequestTypeKey = @"UAInboxMessageRequestTypeKey";

typedef enum {
    UAInboxMessageSingleMessage,
    UAInboxMessageBatchUpdate
} UAInboxMessageRequestType;

/*
 * Private methods
 */
@interface UAInboxMessageList() <UAHTTPConnectionDelegate>
@property (nonatomic, retain) UAHTTPConnection *connection;

- (void)loadSavedMessages;

@property(assign) int nRetrieving;

@end

@implementation UAInboxMessageList

@synthesize messages;
@synthesize unreadCount;
@synthesize nRetrieving;
@synthesize isBatchUpdating;

#pragma mark Create Inbox

static UAInboxMessageList *_messageList = nil;

- (void)dealloc {
    _connection.delegate = nil;
    RELEASE_SAFELY(_connection);
    RELEASE_SAFELY(messages);
    [super dealloc];
}

+ (void)land {
    if (_messageList) {
        if (_messageList.isRetrieving || _messageList.isBatchUpdating) {
            UALOG(@"Force quit now may cause crash if UA_ASIRequest is alive.");
        }
        RELEASE_SAFELY(_messageList);
    }
}

+ (UAInboxMessageList *)shared {
    
    @synchronized(self) {
        if(_messageList == nil) {
            _messageList = [[UAInboxMessageList alloc] init];
            _messageList.unreadCount = -1;
            _messageList.nRetrieving = 0;
            _messageList.isBatchUpdating = NO;
        }
    }
    
    return _messageList;
}

- (BOOL)isRetrieving {
    return nRetrieving > 0;
}

#pragma mark Update/Delete/Mark Messages

- (void)loadSavedMessages {
    
    UALOG(@"before retrieve saved messages: %@", messages);
    NSMutableArray *savedMessages = [[UAInboxDBManager shared] getMessagesForUser:[UAUser defaultUser].username app:[[UAirship shared] appId]];
    for (UAInboxMessage *msg in savedMessages) {
        msg.inbox = self;
    }
    self.messages = [[[NSMutableArray alloc] initWithArray:savedMessages] autorelease];
    UALOG(@"after retrieve saved messages: %@", messages);
    
}

- (void)retrieveMessageList {
    
	if(![[UAUser defaultUser] defaultUserCreated]) {
		UALOG("Waiting for User Update message to retrieveMessageList");
		[[UAUser defaultUser] addObserver:self];
		return;
	}

    [self notifyObservers: @selector(messageListWillLoad)];

    [self loadSavedMessages];
    
    NSString *urlString = [NSString stringWithFormat: @"%@%@%@%@",
                                                  [[UAirship shared] server], @"/api/user/", [UAUser defaultUser].username ,@"/messages/"];

    
    UALOG(@"%@",urlString);

    UAHTTPRequest *request = [UAUtils userHTTPRequestWithURLString:urlString method:@"GET"];
    request.userInfo = @{ UAInboxMessageRequestTypeKey : @(UAInboxMessageSingleMessage) };
    self.connection = [UAHTTPConnection connectionWithRequest:request];
    self.connection.cachePolicy = self.inboxCachePolicy;
    self.connection.delegate = self;
    
    self.nRetrieving++;
    [self.connection start];
}

- (void)requestDidSucceed:(UAHTTPRequest *)request
                 response:(NSHTTPURLResponse *)response
             responseData:(NSData *)responseData {
    if ([request.userInfo[UAInboxMessageRequestTypeKey] isEqual:@(UAInboxMessageSingleMessage)]) {
        [self messageListReady:request withResponse:response responseData:responseData];
    }
    else {
        [self batchUpdateFinished:request withResponse:response];
    }
}

- (void)request:(UAHTTPRequest *)request didFailWithError:(NSError *)error {
    if ([request.userInfo[UAInboxMessageRequestTypeKey] isEqual:@(UAInboxMessageSingleMessage)]) {
        [self messageListFailed:request withResponse:nil error:error];
    }
    else {
        [self batchUpdateFailed:request error:error];
    }
}

- (void)messageListReady:(UAHTTPRequest *)request
            withResponse:(NSHTTPURLResponse *)response
            responseData:(NSData *)responseData {
    
    if (response.statusCode != 200) {
        [self messageListFailed:request withResponse:response error:nil];
        return;
    }
    
    self.nRetrieving--;
	NSString *responseString = [[[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] autorelease];
    UA_SBJsonParser *parser = [[UA_SBJsonParser alloc] init];
    NSDictionary *jsonResponse = [parser objectWithString:responseString];
    UALOG(@"Retrieved Messages: %@", responseString);
    [parser release];
    
    // Convert dictionary to objects for convenience
    NSMutableArray *newMessages = [NSMutableArray array];
    for (NSDictionary *message in [jsonResponse objectForKey:@"messages"]) {
        UAInboxMessage *tmp = [[UAInboxMessage alloc] initWithDict:message inbox:self];
        [newMessages addObject:tmp];
        [tmp release];
    }
    
    
    if (newMessages.count > 0) {
        NSSortDescriptor* dateDescriptor = [[[NSSortDescriptor alloc] initWithKey:@"messageSent"
                                                                        ascending:NO] autorelease];
        
        //TODO: this flow seems terribly backwards
        NSArray *sortDescriptors = [NSArray arrayWithObject:dateDescriptor];
        [newMessages sortUsingDescriptors:sortDescriptors];
    }
    
    [[UAInboxDBManager shared] deleteMessages:messages];
    [[UAInboxDBManager shared] addMessages:newMessages forUser:[UAUser defaultUser].username app:[[UAirship shared] appId]];
    self.messages = newMessages;
        
    unreadCount = [[jsonResponse objectForKey: @"badge"] intValue];

    UALOG(@"after retrieveMessageList, messages: %@", messages);
    if (self.nRetrieving == 0) {
        [self notifyObservers:@selector(messageListLoaded)];
    }
}

- (void)messageListFailed:(UAHTTPRequest *)request withResponse:(NSHTTPURLResponse *)response error:(NSError *)error {
    self.nRetrieving--;
    [self requestWentWrong:request response:response error:error];
    if (self.nRetrieving == 0) {
        [self notifyObservers:@selector(inboxLoadFailed)];
    }
}

- (void)performBatchUpdateCommand:(UABatchUpdateCommand)command withMessageIndexSet:(NSIndexSet *)messageIndexSet {

    NSURL *requestUrl = nil;
    NSDictionary *data = nil;
    NSArray *updateMessageArray = [messages objectsAtIndexes:messageIndexSet];
    NSArray *updateMessageURLs = [updateMessageArray valueForKeyPath:@"messageURL.absoluteString"];
    UALOG(@"%@", updateMessageURLs);

    if (command == UABatchDeleteMessages) {
        NSString *urlString = [NSString stringWithFormat:@"%@%@%@%@",
                               [UAirship shared].server,
                               @"/api/user/",
                               [UAUser defaultUser].username,
                               @"/messages/delete/"];
        requestUrl = [NSURL URLWithString:urlString];
        UALOG(@"batch delete url: %@", requestUrl);

        data = [NSDictionary dictionaryWithObject:updateMessageURLs forKey:@"delete"];

    } else if (command == UABatchReadMessages) {
        NSString *urlString = [NSString stringWithFormat:@"%@%@%@%@",
                               [UAirship shared].server,
                               @"/api/user/",
                               [UAUser defaultUser].username,
                               @"/messages/unread/"];
        requestUrl = [NSURL URLWithString:urlString];
        UALOG(@"batch mark as read url: %@", requestUrl);

        data = [NSDictionary dictionaryWithObject:updateMessageURLs forKey:@"mark_as_read"];
    } else {
        UALOG("command=%d is invalid.", command);
        return;
    }
    self.isBatchUpdating = YES;
    [self notifyObservers: @selector(messageListWillLoad)];

    UA_SBJsonWriter *writer = [UA_SBJsonWriter new];
    NSString* body = [writer stringWithObject:data];
    [writer release];

    UAHTTPRequest *request = [UAUtils userHTTPRequestWithURLString:[requestUrl absoluteString] method:@"POST"];
    
    request.userInfo = @{
        @"command" : @(command),
        @"messages" : updateMessageArray,
        UAInboxMessageRequestTypeKey : @(UAInboxMessageBatchUpdate)
    };
    
    [request addRequestHeader:@"Content-Type" value:@"application/json"];
    request.body = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    self.connection = [UAHTTPConnection connectionWithRequest:request];
    self.connection.delegate = self;
    [self.connection start];
}

- (void)batchUpdateFinished:(UAHTTPRequest *)request withResponse:(NSHTTPURLResponse *)response {
    
    self.isBatchUpdating = NO;

    id option = [request.userInfo objectForKey:@"command"];
    
    NSArray *updateMessageArray = [request.userInfo objectForKey:@"messages"];

    if (response.statusCode != 200) {
        UALOG(@"Server error during batch update messages");
        if ([option intValue] == UABatchDeleteMessages) {
            [self notifyObservers:@selector(batchDeleteFailed)];
        } else if ([option intValue] == UABatchReadMessages) {
            [self notifyObservers:@selector(batchMarkAsReadFailed)];
        }
        
        return;
    }
    
    for (UAInboxMessage *msg in updateMessageArray) {
        if (msg.unread) {
            msg.unread = NO;
            self.unreadCount -= 1;
        }
    }

    if ([option intValue] == UABatchDeleteMessages) {
        [messages removeObjectsInArray:updateMessageArray];
        // TODO: add delete to sync
        [[UAInboxDBManager shared] deleteMessages:updateMessageArray];
        [self notifyObservers:@selector(batchDeleteFinished)];
    } else if ([option intValue] == UABatchReadMessages) {
        [[UAInboxDBManager shared] updateMessagesAsRead:updateMessageArray];
        [self notifyObservers:@selector(batchMarkAsReadFinished)];
    }
}

- (void)batchUpdateFailed:(UAHTTPRequest*)request error:(NSError *)error {
    self.isBatchUpdating = NO;

    [self requestWentWrong:request response:nil error:error];
    
    id option = [request.userInfo objectForKey:@"command"];
    if ([option intValue] == UABatchDeleteMessages) {
        [self notifyObservers:@selector(batchDeleteFailed)];
    } else if ([option intValue] == UABatchReadMessages) {
        [self notifyObservers:@selector(batchMarkAsReadFailed)];
    }
}

- (void)requestWentWrong:(UAHTTPRequest *)request response:(NSHTTPURLResponse *)response error:(NSError *)error {
    UALOG(@"Inbox Message List Request Failed: %@", [error localizedDescription]);
}

#pragma mark -
#pragma mark Get messages

- (int)messageCount {
    return [messages count];
}

- (UAInboxMessage *)messageForID:(NSString *)mid {
    for (UAInboxMessage *msg in messages) {
        if ([msg.messageID isEqualToString:mid]) {
            return msg;
        }
    }
    return nil;
}

- (UAInboxMessage *)messageAtIndex:(int)index {
    if (index < 0 || index >= [messages count]) {
        UALOG("Load message(index=%d, count=%d) error.", index, [messages count]);
        return nil;
    }
    return [messages objectAtIndex:index];
}

- (int)indexOfMessage:(UAInboxMessage *)message {
    return [messages indexOfObject:message];
}

#pragma mark -
#pragma mark UAUserObserver

- (void)userUpdated {
    UALOG(@"UAInboxMessageList notified: userUpdated");
	if([[UAUser defaultUser] defaultUserCreated]) {
		[[UAUser defaultUser] removeObserver:self];
		[self retrieveMessageList];
	}
}

@end
