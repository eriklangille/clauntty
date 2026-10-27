#import <Foundation/Foundation.h>

// A file in a review
@interface ReviewFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSInteger added;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation ReviewFile
- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _added = 0;
    }
    return self;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"%@ (+%ld)", self.path, (long)self.added];
}
@end
