//
//  FullyLoaded.m
//  FullyLoaded
//
//  Created by Anoop Ranganath on 1/1/11.
//  Copyright 2011 Anoop Ranganath. All rights reserved.
//
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.


#import "FullyLoaded.h"


// users can define their own concurrency rules
#ifndef kFullyLoadedMaxConnections
#define kFullyLoadedMaxConnections 2
#endif


#if FullyLoadedErrorLog
#define FLError(...) NSLog(@"FullyLoaded error: " __VA_ARGS__)
#else
#define FLError(...) ((void)0)
#endif

#if FullyLoadedVerboseLog
#define FLLog(...) NSLog(@"FullyLoaded: " __VA_ARGS__)
#else
#define FLLog(...) ((void)0)
#endif

// by default FullyLoaded will dispatch all loads to flQueue, even if the file exists on disk.
// this will make FL do a check on disk and return it synchronously.
#define FL_USE_MAIN_QUEUE_FOR_LOADS 1

static NSString * const FLIdleRunloopNotification = @"FLIdleRunloopNotification";

static dispatch_queue_t flQueue = nil;

// encapsulates the result created in the urlQueue thread to pass to main thread.
@interface FLResponse : NSObject

@property (nonatomic) NSURL *url;
@property (nonatomic) UIImage *image;

@end


@implementation FLResponse

@synthesize
url     = _url,
image   = _image;



@end


@interface FullyLoaded()

@property (nonatomic) NSString *imageCachePath;
@property (nonatomic) NSCache *imageCache;  // maps urls to images
@property (nonatomic) NSMutableArray *urlQueue;         // urls that have not yet been requested
@property (nonatomic) NSMutableSet *pendingURLSet;      // urls in the queue, plus requested urls
@property (nonatomic) NSOperationQueue *responseQueue;  // operation queue for NSURLConnection

@property (nonatomic) int connectionCount; // number of connected urls
@property (nonatomic) BOOL suspended;

- (void)dequeueNextURL;

- (void)handleResponse:(FLResponse *)response;

@end


@implementation FullyLoaded

@synthesize
imageCachePath  = _imageCachePath,
imageCache      = _imageCache,
urlQueue        = _urlQueue,
pendingURLSet   = _pendingURLSet,
responseQueue   = _responseQueue,
connectionCount = _connectionCount,
suspended       = _suspended;


// clear cache on launch for debugging
#ifdef DEBUG
+ (void)initialize {
    [[self sharedFullyLoaded] clearCache];
}
#endif


+ (id)sharedFullyLoaded {
    static FullyLoaded *shared = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [self new];
    });
    
    return shared;
}




- (id)init {
    self = [super init];
    if (self) {
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *baseDir = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        NSAssert(baseDir, @"Caches directory doesn't exist!");
        
        self.imageCachePath     = [baseDir stringByAppendingPathComponent:@"images"];
        self.imageCache         = [[NSCache alloc] init];
        self.urlQueue           = [NSMutableArray array];
        self.pendingURLSet      = [NSMutableSet set];
        self.responseQueue      = [NSOperationQueue new];
        
        NSNotificationCenter *c = [NSNotificationCenter defaultCenter];
        
        // listen for the idle notification to resume downloads
        [c addObserver:self selector:@selector(resume) name:FLIdleRunloopNotification object:nil];
        
        // note (itsbonczek): iOS sometimes removes old files from /tmp while the app is suspended. When a UIImage loses
        // it's file data, it will try to attempt to restore it from disk. However, if the image happens to have been
        // deleted, UIImage can't restore itself and UIImageView will end up showing a black image. To combat this
        // we delete the in-memory cache whenever the app is backgrounded.
        [c addObserver:self selector:@selector(clearMemoryCache) name:UIApplicationDidEnterBackgroundNotification object:nil];
        
            //clear memory cache in low-memory conditions
        [c addObserver:self selector:@selector(clearMemoryCache) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        
        flQueue = dispatch_queue_create("flQueue", NULL);
        
        self.respectScreenScale = YES;
    }
    return self;
}


#pragma mark - FullyLoaded


- (BOOL)connectionsAvailable {
    return self.connectionCount < kFullyLoadedMaxConnections;
}


- (NSString *)pathForURL:(NSURL*)url {
    NSString *hostPath = [self.imageCachePath stringByAppendingPathComponent:url.host];
    return [hostPath stringByAppendingPathComponent:url.path];
}


// returns path to image file
- (NSString *)writeImageData:(NSData*)data url:(NSURL *)url {
        
    NSString *path = [self pathForURL:url];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
        
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    
    if (error) {
        FLError(@"creating directory: %@\n%@", dir, error);
        return nil;
    }
    
    [data writeToFile:path options:NSDataWritingAtomic error:&error];
    
    if (error) {
        FLError(@"writing to file: %@\n%@", path, error);
        return nil;
    }
    
    return path;
}


- (void)fetchURL:(NSURL *)url {
    
    NSAssert(url, @"nil url");
    
    NSURLRequest *request = [[NSURLRequest alloc] initWithURL:url];
    
    // preflight check
    if (![NSURLConnection canHandleRequest:request]) {
        // handle error now so that the caller is in the same stack (helps debugging with breakpoints)
        FLError(@"preflight:        %@", url);
        return;
    }
    
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:self.responseQueue
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                               
                               // TODO: catch exceptions and convert to errors?
                               @autoreleasepool {
                                   
                                   FLResponse *r = [FLResponse new];
                                   // save the original url; response.URL might be a redirect, or nil on error
                                   r.url = url;
                                   
                                   if (error) {
                                       FLError(@"connection: %@\n%@", url, error);
                                   }
                                   else {
                                       NSString *path = [self writeImageData:data url:url];
                                       
                                       if (path) {
                                           // because UIImage may unload images that are backed on disk,
                                           // we write and then read back the image here.
                                           // this way all images behave consistently.
                                           // manually cached images are the exception; see note below.
                                           
                                           NSData *imageData = [NSData dataWithContentsOfFile:path];
                                           float scale = [UIScreen mainScreen].scale;
                                           if ((self.respectScreenScale) && (scale > 1.0)) {
                                                r.image = [UIImage imageWithData:imageData scale:scale];
                                           } else {
                                               r.image = [UIImage imageWithData:imageData];
                                           }
                                           
//                                           r.image = [UIImage imageWithContentsOfFile:path];
                                           
                                           if (!r.image) {
                                               // although the download completed, the image read failed
                                               // perhaps bad/damaged image on server, or file system error
                                               FLError(@"nil image: %@\n  path: %@", url, path);
                                           }
                                       } // else no path; error already logged
                                   }
                                   
                                   [self performSelectorOnMainThread:@selector(handleResponse:)
                                                          withObject:r
                                                       waitUntilDone:NO];
                               }
                           }];
    
    self.connectionCount = self.connectionCount + 1;
}


- (void)fetchOrEnqueueURL:(NSURL *)url {
    
    NSAssert(![self.pendingURLSet containsObject:url], @"pendingURLSet already contains url: %@", url);
    
    [self.pendingURLSet addObject:url];
    
    FLLog(@"pending url set:   %@", self.pendingURLSet);
    
    if (self.connectionsAvailable) {
        [self fetchURL:url];
    }
    else {
        [self.urlQueue addObject:url];
    }
}


- (void)dequeueNextURL {
    
    NSAssert(self.connectionsAvailable, @"exceeded max connection count: %d", self.connectionCount);
    
    if (!self.urlQueue.count) return;
    
    NSURL *url = [self.urlQueue lastObject]; // FILO: last request is most likely to be still relevant
    [self.urlQueue removeLastObject];
    [self fetchURL:url];
}


- (void)handleResponse:(FLResponse *)response {
    
    NSAssert(response.url, @"nil url"); // matches assertion in fetchURL
    
    if (response.image) {
        [self.imageCache setObject:response.image forKey:response.url];
        FLLog(@"cached:          %@", response.url);
        [[NSNotificationCenter defaultCenter] postNotificationName:FLImageLoadedNotification object:response.url];
    }
    
    [self.pendingURLSet removeObject:response.url];
    
    FLLog(@"pending url set:   %@", self.pendingURLSet);
    
    self.connectionCount = self.connectionCount - 1;
    
    [self dequeueNextURL];
}


- (void)clearMemoryCache {
    FLLog(@"clearing memory cache");
    [self.imageCache removeAllObjects];
}


- (void)clearCache {
    [self clearMemoryCache];
    
    FLLog(@"clearing disk cache");
    
    NSFileManager *m = [NSFileManager defaultManager];
    
    if (![m fileExistsAtPath:self.imageCachePath]) {
        FLLog(@"no existing disk cache");
        return;
    }
    
    NSError *error = nil;
    [m removeItemAtPath:self.imageCachePath error:&error];
    
    if (error) {
        FLError(@"could not clear disk cache: %@", error);
    }
}


- (void)suspend {
    FLLog(@"suspend");
    
    self.suspended = YES;
    self.responseQueue.suspended = YES;
    
    // whenever the run loop becomes idle, this notification will get posted, and the queue will resume downloading
    NSNotification *n = [NSNotification notificationWithName:FLIdleRunloopNotification object:self];
    [[NSNotificationQueue defaultQueue] enqueueNotification:n postingStyle:NSPostWhenIdle];
}


// called manually or in response to the idle run loop notification
- (void)resume {
    FLLog(@"resume");
    
    self.suspended = NO;
    self.responseQueue.suspended = NO;
    
    if (self.connectionsAvailable) {
        [self dequeueNextURL];
    }
}

- (void)cancelURL:(NSURL *)url {

    if(url){
        [self.pendingURLSet removeObject:url];
        [self.urlQueue removeObject:url];
        
        FLLog(@"cancelURL: %@", url);
        FLLog(@"pending url set:   %@", self.pendingURLSet);
    }
}


- (void)cachedImageForURL:(NSURL *)url completion:(void(^)(UIImage *image))completionBlock {
        
    if (!url) {
        FLLog(@"nil url");
        completionBlock(nil);
        return;
    }
    
    UIImage *image = [self.imageCache objectForKey:url];

    if (image) {
        FLLog(@"from memory:     %@", url);
        completionBlock(image);
        return;
    }
    
#if FL_USE_MAIN_QUEUE_FOR_LOADS

    BOOL usingMainQueue = [[NSFileManager defaultManager] fileExistsAtPath:[self pathForURL:url]] && [NSThread isMainThread];
    
    dispatch_block_t loadBlock = ^{
        UIImage *image = [UIImage imageWithContentsOfFile:[self pathForURL:url]];
        
        if (image) {
            FLLog(@"from disk:       %@", url);
            [self.imageCache setObject:image forKey:url];
        }
        
        if (usingMainQueue) {
            completionBlock(image);
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(image);
            });
        }
    };
    
    if (!usingMainQueue) {
        dispatch_async(flQueue, loadBlock);
    }
    else {
        loadBlock();
    }
    
#else
    dispatch_async(flQueue, ^{
        UIImage *imageFromDisk = nil;
        NSData *imageData = [NSData dataWithContentsOfFile:[self pathForURL:url]];
        float scale = [UIScreen mainScreen].scale;
        if ((self.respectScreenScale) && (scale > 1.0)) {
            imageFromDisk = [UIImage imageWithData:imageData scale:scale];
        } else {
            imageFromDisk = [UIImage imageWithData:imageData];
        }
        
//        UIImage *image = [UIImage imageWithContentsOfFile:[self pathForURL:url]];
        
        if (imageFromDisk) {
            FLLog(@"from disk:       %@", url);
            [self.imageCache setObject:imageFromDisk forKey:url];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(imageFromDisk);
        });
    });
#endif
    

}

- (void)imageForURL:(NSURL *)url completion:(void(^)(UIImage *image))completionBlock{
        
    if (!url) {
        FLLog(@"nil url");
        completionBlock(nil);
        return;
    }
    
   [self cachedImageForURL:url completion:^(UIImage *image) {

      if (!image && url && ![self.pendingURLSet containsObject:url]) {
           [self fetchOrEnqueueURL:url];
      }
       
      completionBlock(image);
       
   }];
}


// MARK: cache insertion


- (void)cacheImage:(UIImage *)image forURL:(NSURL *)url {
    // note: unlike downloaded images, manually cached images might not have been initialized with a file path,
    // and therefore might not be unloaded in low memory situations.
    [self.imageCache setObject:image forKey:url];
    [self writeImageData:UIImageJPEGRepresentation(image, 0.8f) url:url];
}


// MARK: url string wrappers


- (void)imageForURLString:(NSString *)urlString completion:(void(^)(UIImage *image))completionBlock {
    return [self imageForURL:[NSURL URLWithString:urlString] completion:completionBlock];
}


- (void)cachedImageForURLString:(NSString *)urlString completion:(void(^)(UIImage *image))completionBlock{
    return [self cachedImageForURL:[NSURL URLWithString:urlString] completion:completionBlock];
}

- (void)cacheImage:(UIImage *)image forURLString:(NSString *)urlString {
    if (image) {
        [self cacheImage:image forURL:[NSURL URLWithString:urlString]];
    }
}

- (BOOL)warmUpCacheForURL:(NSURL *)url {
    NSString *path = [self pathForURL:url];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (fileExists && ![self.imageCache objectForKey:path]) {
        dispatch_async(flQueue, ^{
            UIImage *image = [UIImage imageWithContentsOfFile:[self pathForURL:url]];
            if (image) {
                FLLog(@"from disk:       %@", url);
                [self.imageCache setObject:image forKey:url];
            }
        });
    }
    return fileExists;
}


@end
