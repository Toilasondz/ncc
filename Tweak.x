#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// MARK: - Forward Declarations cho PhotosUI / PHPicker (Tranh loi thieu C++ cmath)
// ============================================================================
@class PHPickerViewController, PHPickerConfiguration, PHPickerFilter, PHPickerResult;

@protocol PHPickerViewControllerDelegate <NSObject>
@optional
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results;
@end

@interface PHPickerFilter : NSObject <NSCopying>
+ (PHPickerFilter *)imagesFilter;
+ (PHPickerFilter *)videosFilter;
+ (PHPickerFilter *)anyFilterMatchingSubfilters:(NSArray<PHPickerFilter *> *)subfilters;
@end

@interface PHPickerConfiguration : NSObject <NSCopying>
@property (nonatomic, assign) NSInteger selectionLimit;
@property (nonatomic, copy) PHPickerFilter *filter;
@end

@interface PHPickerResult : NSObject
@property (nonatomic, readonly) NSItemProvider *itemProvider;
@end

@interface PHPickerViewController : UIViewController
@property (nonatomic, weak) id<PHPickerViewControllerDelegate> delegate;
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
@end

#define VSLOG(fmt, ...) NSLog(@"[VideoStarTool] " fmt, ##__VA_ARGS__)

// ============================================================================
// MARK: - Helper Functions (Tim KeyWindow & Top ViewController)
// ============================================================================

static UIWindow *VSGetActiveKeyWindow(void) {
    if (![NSThread isMainThread]) {
        VSLOG(@"Warning: VSGetActiveKeyWindow called outside main thread!");
    }
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *connectedScenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *win in windowScene.windows) {
                    if (win.isKeyWindow) {
                        keyWindow = win;
                        break;
                    }
                }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    return keyWindow;
}

static UIViewController *VSGetTopViewController(UIViewController *root) {
    if (!root) {
        root = VSGetActiveKeyWindow().rootViewController;
    }
    if (!root) return nil;

    if ([root isKindOfClass:[UINavigationController class]]) {
        return VSGetTopViewController([(UINavigationController *)root visibleViewController]);
    } else if ([root isKindOfClass:[UITabBarController class]]) {
        return VSGetTopViewController([(UITabBarController *)root selectedViewController]);
    } else if (root.presentedViewController) {
        return VSGetTopViewController(root.presentedViewController);
    }
    return root;
}

// ============================================================================
// MARK: - 1. CO CHE LOC LOP THONG MINH (SMART LAYER FILTER)
// ============================================================================
/*
 * Quy tac kiem tra lop nghiem ngat:
 * - DONG Y: Lop Hinh Anh (Image Layer), Lop Video (Video Layer).
 * - TUYET DOI BO QUA: Lop Rong (Empty), Zaps!, Vat 3D (3D Objects),
 *                    Lop Phu (Overlay), Lop Mau (Color Layer), Chu / Text.
 */
static BOOL VSIsEligibleMediaLayer(id layerObj) {
    if (!layerObj) return NO;

    @try {
        NSString *className = NSStringFromClass([layerObj class]);
        NSString *lowerName = [className lowercaseString];

        // 1. Kiem tra Danh sach den (Blacklist) qua ten lop
        NSArray<NSString *> *blacklistedKeywords = @[
            @"empty",     // Lop rong
            @"zap",       // Zaps!
            @"3d",        // Vat the 3D
            @"threed",    // 3D alternate
            @"overlay",   // Lop phu
            @"color",     // Lop mau don sac
            @"text",      // Van ban / Chu
            @"title",     // Tieu de chu
            @"shape",     // Hinh ve / Shape
            @"audioonly"  // Audio thuan
        ];

        for (NSString *keyword in blacklistedKeywords) {
            if ([lowerName containsString:keyword]) {
                VSLOG(@"-> Bo qua lop khong hop le (Khop Blacklist): %@", className);
                return NO;
            }
        }

        // 2. Kiem tra thuoc tinh layerType neu engine co ho tro
        if ([layerObj respondsToSelector:@selector(layerType)]) {
            NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(layerObj, @selector(layerType));
            // Quy uoc chuan: 0: Empty, 1: Video, 2: Photo, 3: Color, 4: Text, 5: 3D/Zaps
            if (type == 0 || type >= 3) {
                VSLOG(@"-> Bo qua layerType = %ld", (long)type);
                return NO;
            }
        }

        // 3. Kiem tra cac ham co phu dinh
        if ([layerObj respondsToSelector:@selector(isTextLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isTextLayer))) {
            return NO;
        }
        if ([layerObj respondsToSelector:@selector(isColorLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isColorLayer))) {
            return NO;
        }
        if ([layerObj respondsToSelector:@selector(isEmptyLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isEmptyLayer))) {
            return NO;
        }

        // 4. Kiem tra cac selector nhan Media (Whitelist)
        if ([layerObj respondsToSelector:@selector(setMediaURL:)] ||
            [layerObj respondsToSelector:@selector(setImage:)] ||
            [layerObj respondsToSelector:@selector(setSourceImage:)] ||
            [layerObj respondsToSelector:@selector(replaceContent:)] ||
            [lowerName containsString:@"video"] ||
            [lowerName containsString:@"photo"] ||
            [lowerName containsString:@"image"] ||
            [lowerName containsString:@"clip"]) {
            return YES;
        }

        return NO;
    } @catch (NSException *exception) {
        VSLOG(@"Loi khi kiem tra lop: %@", exception);
        return NO;
    }
}

// ============================================================================
// MARK: - 2. TRINH QUAN LY AUTO NHAP ANH / VIDEO (LAYER AUTO-FILLER)
// ============================================================================
@interface VSLayerAutoFiller : NSObject <PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, weak) id currentEditorController;
@property (nonatomic, strong) NSMutableArray *cachedEligibleLayers;
+ (instancetype)sharedInstance;
- (void)startAutoFillProcessFromController:(UIViewController *)controller;
- (void)applyPickedMedia:(NSArray *)mediaItems toLayers:(NSArray *)layers;
@end

@implementation VSLayerAutoFiller

+ (instancetype)sharedInstance {
    static VSLayerAutoFiller *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VSLayerAutoFiller alloc] init];
        instance.cachedEligibleLayers = [NSMutableArray array];
    });
    return instance;
}

- (void)startAutoFillProcessFromController:(UIViewController *)controller {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentEditorController = controller;
        [self.cachedEligibleLayers removeAllObjects];

        // Lay danh sach cac lop hien co trong Editor
        NSArray *rawLayers = nil;
        if ([controller respondsToSelector:@selector(layers)]) {
            rawLayers = [controller valueForKey:@"layers"];
        } else if ([controller respondsToSelector:@selector(clipLayers)]) {
            rawLayers = [controller valueForKey:@"clipLayers"];
        } else if ([controller respondsToSelector:@selector(allLayers)]) {
            rawLayers = [controller valueForKey:@"allLayers"];
        }

        if (rawLayers && [rawLayers isKindOfClass:[NSArray class]]) {
            for (id layer in rawLayers) {
                if (VSIsEligibleMediaLayer(layer)) {
                    [self.cachedEligibleLayers addObject:layer];
                }
            }
        }

        VSLOG(@"Tim thay %lu lop hop le (Image/Video) de nap du lieu.", (unsigned long)self.cachedEligibleLayers.count);

        if (@available(iOS 14.0, *)) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.selectionLimit = 0; // Khong gioi han so luong chon
            config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
                [PHPickerFilter imagesFilter],
                [PHPickerFilter videosFilter]
            ]];

            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
            picker.delegate = self;
            [controller presentViewController:picker animated:YES completion:nil];
        } else {
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.delegate = self;
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            [controller presentViewController:picker animated:YES completion:nil];
        }
    });
}

// PHPickerViewController Delegate (iOS 14+)
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) return;

    NSMutableArray *loadedMedia = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();

    for (PHPickerResult *result in results) {
        NSItemProvider *provider = result.itemProvider;

        // Xu ly Video
        if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
            dispatch_group_enter(group);
            [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
                if (url && !error) {
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
                    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
                    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
                    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
                    @synchronized (loadedMedia) {
                        [loadedMedia addObject:tempURL];
                    }
                }
                dispatch_group_leave(group);
            }];
        }
        // Xu ly Anh
        else if ([provider canLoadObjectOfClass:[UIImage class]]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
                if ([object isKindOfClass:[UIImage class]] && !error) {
                    @synchronized (loadedMedia) {
                        [loadedMedia addObject:(UIImage *)object];
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        VSLOG(@"Tai hoan tat %lu media, tien hanh gan vao lop hop le...", (unsigned long)loadedMedia.count);
        [self applyPickedMedia:loadedMedia toLayers:self.cachedEligibleLayers];
    });
}

// Phan bo phuong tien vao cac lop hop le
- (void)applyPickedMedia:(NSArray *)mediaItems toLayers:(NSArray *)layers {
    if (mediaItems.count == 0 || layers.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thong bao"
                                                                           message:@"Khong tim thay lop Hinh anh hoac Video hop le nao de nap!"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Da hieu" style:UIAlertActionStyleDefault handler:nil]];
            [VSGetTopViewController(nil) presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    NSUInteger assignCount = MIN(mediaItems.count, layers.count);

    for (NSUInteger i = 0; i < assignCount; i++) {
        id media = mediaItems[i];
        id layer = layers[i];

        @try {
            if ([media isKindOfClass:[UIImage class]]) {
                UIImage *img = (UIImage *)media;
                if ([layer respondsToSelector:@selector(replaceContentWithImage:)]) {
                    [layer performSelector:@selector(replaceContentWithImage:) withObject:img];
                } else if ([layer respondsToSelector:@selector(setImage:)]) {
                    [layer performSelector:@selector(setImage:) withObject:img];
                } else if ([layer respondsToSelector:@selector(setSourceImage:)]) {
                    [layer performSelector:@selector(setSourceImage:) withObject:img];
                }
            } else if ([media isKindOfClass:[NSURL class]]) {
                NSURL *videoURL = (NSURL *)media;
                if ([layer respondsToSelector:@selector(replaceContentWithVideoURL:)]) {
                    [layer performSelector:@selector(replaceContentWithVideoURL:) withObject:videoURL];
                } else if ([layer respondsToSelector:@selector(setMediaURL:)]) {
                    [layer performSelector:@selector(setMediaURL:) withObject:videoURL];
                } else if ([layer respondsToSelector:@selector(setVideoURL:)]) {
                    [layer performSelector:@selector(setVideoURL:) withObject:videoURL];
                }
            }

            if ([layer respondsToSelector:@selector(setNeedsDisplay)]) {
                [layer performSelector:@selector(setNeedsDisplay)];
            }
        } @catch (NSException *ex) {
            VSLOG(@"Loi gan media vao lop thu %lu: %@", (unsigned long)i, ex);
        }
    }

    // Lam moi timeline editor
    if ([self.currentEditorController respondsToSelector:@selector(reloadLayers)]) {
        [self.currentEditorController performSelector:@selector(reloadLayers)];
    } else if ([self.currentEditorController respondsToSelector:@selector(refreshTimeline)]) {
        [self.currentEditorController performSelector:@selector(refreshTimeline)];
    }

    UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"Auto Nhap Thanh Cong"
                                                                       message:[NSString stringWithFormat:@"Da tu dong nap %lu tap tin vao %lu lop hop le!\n(Da bo qua toan bo lop chu, 3D, zaps, mau, overlay).", (unsigned long)assignCount, (unsigned long)layers.count]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [doneAlert addAction:[UIAlertAction actionWithTitle:@"Dong Y" style:UIAlertActionStyleCancel handler:nil]];
    [VSGetTopViewController(nil) presentViewController:doneAlert animated:YES completion:nil];
}

@end

// ============================================================================
// MARK: - 3. THANH CONG CU CHIA BEAT (BEAT MAPPING TOOLBAR VIEW)
// ============================================================================
@interface VSBeatToolbarView : UIView
@property (nonatomic, strong) UIButton *btnPrevBeat;
@property (nonatomic, strong) UIButton *btnNextBeat;
@property (nonatomic, strong) UIButton *btnSettings;
@property (nonatomic, strong) UIButton *btnSpeed;
@property (nonatomic, strong) UIButton *btnSplit;
@property (nonatomic, assign) CGFloat beatInterval;
@property (nonatomic, assign) CGFloat currentSpeed;
@property (nonatomic, weak) id activeTimelineController;
+ (instancetype)sharedToolbar;
- (void)toggleVisibility;
@end

@implementation VSBeatToolbarView

+ (instancetype)sharedToolbar {
    static VSBeatToolbarView *toolbar = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        toolbar = [[VSBeatToolbarView alloc] initWithFrame:CGRectZero];
    });
    return toolbar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _beatInterval = 0.5; // Mac dinh 120 BPM (~0.5s/beat)
        _currentSpeed = 1.0;
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    self.layer.cornerRadius = 16.0;
    self.layer.borderColor = [[UIColor systemPurpleColor] colorWithAlphaComponent:0.8].CGColor;
    self.layer.borderWidth = 1.2;
    self.clipsToBounds = YES;
    self.hidden = YES;

    // Hieu ung mo nen Blur
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:blurView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
    ]];

    // 1. Nut Lui Beat (<)
    self.btnPrevBeat = [self createButtonWithTitle:@"◀" action:@selector(onPrevBeatClicked)];
    [stack addArrangedSubview:self.btnPrevBeat];

    // 2. Nut Tien Beat (>)
    self.btnNextBeat = [self createButtonWithTitle:@"▶" action:@selector(onNextBeatClicked)];
    [stack addArrangedSubview:self.btnNextBeat];

    // 3. Nut 1x Toc do
    self.btnSpeed = [self createButtonWithTitle:@"1.0x" action:@selector(onSpeedClicked)];
    [stack addArrangedSubview:self.btnSpeed];

    // 4. Nut Cat / Chia Beat
    self.btnSplit = [self createButtonWithTitle:@"✂ Chia" action:@selector(onSplitClicked)];
    self.btnSplit.backgroundColor = [UIColor systemRedColor];
    [stack addArrangedSubview:self.btnSplit];

    // 5. Nut Cai dat Beat
    self.btnSettings = [self createButtonWithTitle:@"⚙ Cai dat" action:@selector(onSettingsClicked)];
    [stack addArrangedSubview:self.btnSettings];
}

- (UIButton *)createButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    btn.layer.cornerRadius = 8.0;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)toggleVisibility {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = VSGetActiveKeyWindow();
        if (!window) return;

        if (!self.superview) {
            CGFloat width = window.bounds.size.width - 32;
            CGFloat height = 50.0;
            CGFloat yPos = window.bounds.size.height - height - 90.0;
            self.frame = CGRectMake(16, yPos, width, height);
            [window addSubview:self];
        }

        self.hidden = !self.hidden;
        if (!self.hidden) {
            [self.superview bringSubviewToFront:self];
            self.transform = CGAffineTransformMakeScale(0.9, 0.9);
            [UIView animateWithDuration:0.25 animations:^{
                self.transform = CGAffineTransformIdentity;
                self.alpha = 1.0;
            }];
        }
    });
}

- (void)onPrevBeatClicked {
    [self stepPlayheadBySeconds:-(self.beatInterval * (1.0 / self.currentSpeed))];
}

- (void)onNextBeatClicked {
    [self stepPlayheadBySeconds:(self.beatInterval * (1.0 / self.currentSpeed))];
}

- (void)stepPlayheadBySeconds:(CGFloat)delta {
    @try {
        UIViewController *topVC = VSGetTopViewController(nil);
        id timeline = nil;
        if ([topVC respondsToSelector:@selector(timelineView)]) {
            timeline = [topVC valueForKey:@"timelineView"];
        } else if ([topVC respondsToSelector:@selector(audioEngine)]) {
            timeline = [topVC valueForKey:@"audioEngine"];
        }

        if (timeline && [timeline respondsToSelector:@selector(currentTime)]) {
            CMTime cur = [((NSValue *)[timeline valueForKey:@"currentTime"]) CMTimeValue];
            Float64 currentSec = CMTimeGetSeconds(cur);
            Float64 newSec = MAX(0.0, currentSec + delta);
            CMTime newTime = CMTimeMakeWithSeconds(newSec, 600);

            if ([timeline respondsToSelector:@selector(seekToTime:)]) {
                ((void (*)(id, SEL, CMTime))objc_msgSend)(timeline, @selector(seekToTime:), newTime);
            }
            VSLOG(@"Da dich Playhead toi: %.2f giay", newSec);
        }
    } @catch (NSException *ex) {
        VSLOG(@"Loi nhay Beat: %@", ex);
    }
}

- (void)onSpeedClicked {
    if (self.currentSpeed == 0.5) {
        self.currentSpeed = 1.0;
    } else if (self.currentSpeed == 1.0) {
        self.currentSpeed = 1.5;
    } else if (self.currentSpeed == 1.5) {
        self.currentSpeed = 2.0;
    } else {
        self.currentSpeed = 0.5;
    }
    [self.btnSpeed setTitle:[NSString stringWithFormat:@"%.1fx", self.currentSpeed] forState:UIControlStateNormal];
}

- (void)onSplitClicked {
    @try {
        UIViewController *topVC = VSGetTopViewController(nil);
        if ([topVC respondsToSelector:@selector(splitCurrentClip)]) {
            [topVC performSelector:@selector(splitCurrentClip)];
            VSLOG(@"Da goi splitCurrentClip");
        } else if ([topVC respondsToSelector:@selector(addMarkerAtCurrentTime)]) {
            [topVC performSelector:@selector(addMarkerAtCurrentTime)];
            VSLOG(@"Da goi addMarkerAtCurrentTime");
        } else {
            VSLOG(@"Khong tim thay ham Split tuong thich.");
        }
    } @catch (NSException *e) {
        VSLOG(@"Loi thuc thi cat phan canh: %@", e);
    }
}

- (void)onSettingsClicked {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cai Dat Nhip Beat"
                                                                   message:@"Nhap khoang cach nhip beat (giay) hoac BPM:"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Khoang cach giay (VD: 0.5 = 120 BPM)";
        textField.text = [NSString stringWithFormat:@"%.2f", self.beatInterval];
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Luu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *field = alert.textFields.firstObject;
        CGFloat val = [field.text floatValue];
        if (val > 0.05) {
            self.beatInterval = val;
            VSLOG(@"Khoang cach Beat moi: %.3f s", self.beatInterval);
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [VSGetTopViewController(nil) presentViewController:alert animated:YES completion:nil];
}

@end

// ============================================================================
// MARK: - 4. NUT NOI (DRAGGABLE FLOATING BUTTON & ACTION SHEET)
// ============================================================================
@interface VSFloatingMenuButton : UIButton
+ (instancetype)sharedButton;
- (void)attachToKeyWindow;
@end

@implementation VSFloatingMenuButton

+ (instancetype)sharedButton {
    static VSFloatingMenuButton *btn = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        btn = [VSFloatingMenuButton buttonWithType:UIButtonTypeCustom];
        [btn setupDesign];
    });
    return btn;
}

- (void)setupDesign {
    self.frame = CGRectMake(20, 150, 52, 52);
    self.layer.cornerRadius = 26;
    self.layer.masksToBounds = NO;
    self.backgroundColor = [UIColor colorWithRed:0.55 green:0.15 blue:0.95 alpha:0.9];
    self.layer.borderColor = [UIColor whiteColor].CGColor;
    self.layer.borderWidth = 2.0;

    // Do bong noi bat
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowOpacity = 0.4;
    self.layer.shadowRadius = 6.0;

    [self setTitle:@"★" forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    // Cu chi keo tha Pan Gesture
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    [self addTarget:self action:@selector(onMenuTapped) forControlEvents:UIControlEventTouchUpInside];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIWindow *window = self.superview ? (UIWindow *)self.superview : VSGetActiveKeyWindow();
    if (!window) return;

    CGPoint translation = [pan translationInView:window];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW, MIN(window.bounds.size.width - halfW, newCenter.x));
    newCenter.y = MAX(halfH + 40, MIN(window.bounds.size.height - halfH - 40, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:window];

    if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat snapX = (self.center.x < window.bounds.size.width / 2.0) ? (halfW + 8) : (window.bounds.size.width - halfW - 8);
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.center = CGPointMake(snapX, self.center.y);
        } completion:nil];
    }
}

- (void)onMenuTapped {
    UIViewController *top = VSGetTopViewController(nil);
    if (!top) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"⭐ VIDEO STAR TOOL PRO ⭐"
                                                                   message:@"Chon chuc nang ban muon su dung:"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Chuc nang 1: Auto Nhap Media
    [sheet addAction:[UIAlertAction actionWithTitle:@"📥 Auto Nhap Anh / Video (Da Loc Lop)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [[VSLayerAutoFiller sharedInstance] startAutoFillProcessFromController:top];
    }]];

    // Chuc nang 2: Bat/Tat Thanh Chia Beat
    [sheet addAction:[UIAlertAction actionWithTitle:@"🎵 Bat / Tat Thanh Chia Beat"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [[VSBeatToolbarView sharedToolbar] toggleVisibility];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Dong Menu" style:UIAlertActionStyleCancel handler:nil]];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self;
        sheet.popoverPresentationController.sourceRect = self.bounds;
    }

    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)attachToKeyWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = VSGetActiveKeyWindow();
        if (window && !self.superview) {
            [window addSubview:self];
            [window bringSubviewToFront:self];
            VSLOG(@"Floating Menu Button da duoc gan vao KeyWindow.");
        }
    });
}

@end

// ============================================================================
// MARK: - 5. LOGOS HOOKS & KHOI TAO AN TOAN
// ============================================================================

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[VSFloatingMenuButton sharedButton] attachToKeyWindow];
    });
}

%end

// Ham khoi tao Constructor
%ctor {
    @autoreleasepool {
        VSLOG(@"VideoStarTool dylib duoc nap vao bo nho tien trinh!");

        // Tri hoan 2.5 giay sau UIApplicationDidFinishLaunchingNotification
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[VSFloatingMenuButton sharedButton] attachToKeyWindow];
                VSLOG(@"Khoi dong giao dien floating button thanh cong.");
            });
        }];
    }
}
