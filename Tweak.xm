// DateSpeedBar — fecha (dd/mm/aaaa) encima del reloj y velocímetro de red debajo.
// Barra de estado · roothide arm64e · iOS 15–17.
//
// Estrategia: se engancha la vista de texto del reloj de la barra de estado
// (_UIStatusBarStringView / UIStatusBarStringView). Se detecta cuál es el reloj
// por el patrón de hora (H:MM), se le reduce el tamaño con una escala y se le
// añaden dos UILabel hermanos: la fecha arriba y la velocidad abajo.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <notify.h>

// Se declaran como subclases de UILabel solo para poder tratar 'self' como
// etiqueta en tiempo de compilación; el enganche es por nombre en tiempo de ejecución.
@interface _UIStatusBarStringView : UILabel
@end
@interface UIStatusBarStringView : UILabel
@end

// ===== Identificadores =====
static NSString *const kPrefsID   = @"com.juana.datespeedbar";
static NSString *const kNotifyStr = @"com.juana.datespeedbar/prefs";

#define DSB_DATE_TAG   918201
#define DSB_SPEED_TAG  918202

// ===== Preferencias (con valores por defecto) =====
static BOOL    gEnabled    = YES;
static BOOL    gShowDate   = YES;
static BOOL    gShowSpeed  = YES;
static BOOL    gShowUpload = YES;
static CGFloat gClockScale = 0.78;   // 1.0 = tamaño original del reloj
static CGFloat gDateSize   = 8.0;    // pt
static CGFloat gSpeedSize  = 8.0;    // pt
static CGFloat gGap        = 1.0;    // separación vertical entre líneas
static CGFloat gYOffset    = 0.0;    // desplazamiento vertical del conjunto

// ===== Estado del velocímetro =====
static uint64_t gPrevIn  = 0;
static uint64_t gPrevOut = 0;
static NSTimeInterval gPrevTS = 0;
static NSString *gSpeedText = @"";

// ===== Caché de la fecha =====
static NSString *gDateText = @"";
static NSInteger gCachedDay = -1;

// ===== Referencias débiles a lo que inyectamos =====
static __weak UILabel *gDateLabel  = nil;
static __weak UILabel *gSpeedLabel = nil;
static __weak UILabel *gTimeView   = nil;
static NSTimer *gTimer = nil;

// ---------------------------------------------------------------------------

static void DSBLoadPrefs(void) {
    CFStringRef app = (__bridge CFStringRef)kPrefsID;
    CFPreferencesAppSynchronize(app);

    Boolean ok = false;
    Boolean b;
    b = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"),    app, &ok); gEnabled    = ok ? (BOOL)b : YES;
    b = CFPreferencesGetAppBooleanValue(CFSTR("ShowDate"),   app, &ok); gShowDate   = ok ? (BOOL)b : YES;
    b = CFPreferencesGetAppBooleanValue(CFSTR("ShowSpeed"),  app, &ok); gShowSpeed  = ok ? (BOOL)b : YES;
    b = CFPreferencesGetAppBooleanValue(CFSTR("ShowUpload"), app, &ok); gShowUpload = ok ? (BOOL)b : YES;

    #define RD_NUM(k, def, var) do { \
        CFPropertyListRef r = CFPreferencesCopyAppValue(CFSTR(k), app); \
        var = (def); \
        if (r) { var = (CGFloat)[(__bridge id)r doubleValue]; CFRelease(r); } \
    } while (0)

    RD_NUM("ClockScale", 0.78, gClockScale);
    RD_NUM("DateSize",   8.0,  gDateSize);
    RD_NUM("SpeedSize",  8.0,  gSpeedSize);
    RD_NUM("Gap",        1.0,  gGap);
    RD_NUM("YOffset",    0.0,  gYOffset);
    #undef RD_NUM

    if (gClockScale < 0.30) gClockScale = 0.30;
    if (gClockScale > 1.00) gClockScale = 1.00;
}

// ---- Velocímetro: suma de bytes de wifi (en*) y celular (pdp_ip*) ----------

static NSString *DSBFmtRate(double bps) {
    if (bps < 1024.0)        return [NSString stringWithFormat:@"%.0fB", bps];
    double kb = bps / 1024.0;
    if (kb < 1024.0)         return [NSString stringWithFormat:@"%.0fK", kb];
    double mb = kb / 1024.0;
    if (mb < 100.0)          return [NSString stringWithFormat:@"%.1fM", mb];
    return [NSString stringWithFormat:@"%.0fM", mb];
}

static NSString *DSBFormatSpeed(double down, double up) {
    if (gShowUpload)
        return [NSString stringWithFormat:@"↓%@ ↑%@", DSBFmtRate(down), DSBFmtRate(up)];
    return [NSString stringWithFormat:@"↓%@", DSBFmtRate(down)];
}

static void DSBSampleSpeed(void) {
    struct ifaddrs *list = NULL, *ifa;
    uint64_t totIn = 0, totOut = 0;
    if (getifaddrs(&list) == 0) {
        for (ifa = list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
            const char *n = ifa->ifa_name;
            if (!n) continue;
            BOOL isWifi = (strncmp(n, "en", 2) == 0);
            BOOL isCell = (strncmp(n, "pdp_ip", 6) == 0);
            if (!isWifi && !isCell) continue;
            struct if_data *d = (struct if_data *)ifa->ifa_data;
            if (!d) continue;
            totIn  += d->ifi_ibytes;
            totOut += d->ifi_obytes;
        }
        freeifaddrs(list);
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gPrevTS > 0 && now > gPrevTS) {
        double dt = now - gPrevTS;
        uint64_t dIn  = (totIn  >= gPrevIn)  ? (totIn  - gPrevIn)  : 0;  // protege reinicios del contador
        uint64_t dOut = (totOut >= gPrevOut) ? (totOut - gPrevOut) : 0;
        gSpeedText = DSBFormatSpeed(dIn / dt, dOut / dt);
    }
    gPrevIn = totIn; gPrevOut = totOut; gPrevTS = now;
}

static void DSBRefreshDate(void) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger day = [cal component:NSCalendarUnitDay fromDate:[NSDate date]];
    if (day != gCachedDay || gDateText.length == 0) {
        static NSDateFormatter *fmt = nil;
        if (!fmt) { fmt = [NSDateFormatter new]; fmt.dateFormat = @"dd/MM/yyyy"; }
        gDateText = [fmt stringFromDate:[NSDate date]];
        gCachedDay = day;
    }
}

static void DSBTick(void) {
    if (!gEnabled) return;
    DSBSampleSpeed();
    DSBRefreshDate();
    UILabel *s = gSpeedLabel;
    if (s) s.text = gShowSpeed ? gSpeedText : @"";
    UILabel *d = gDateLabel;
    if (d) d.text = gShowDate ? gDateText : @"";
}

static void DSBStartTimerIfNeeded(void) {
    if (gTimer) return;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        DSBTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes]; // sigue durante el scroll
    DSBTick();
}

// ---- Decoración del reloj ---------------------------------------------------

static BOOL DSBLooksLikeTime(NSString *t) {
    if (t.length == 0) return NO;
    static NSRegularExpression *re = nil;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"\\d{1,2}:\\d{2}" options:0 error:nil];
    return [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] != nil;
}

static UILabel *DSBEnsureLabel(UIView *host, NSInteger tag) {
    UILabel *l = [host viewWithTag:tag];
    if (!l) {
        l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.tag = tag;
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor clearColor];
        l.userInteractionEnabled = NO;   // no robar toques a la barra de estado
        [host addSubview:l];
    }
    return l;
}

static void DSBDecorateTimeLabel(UILabel *clock) {
    gTimeView = clock;

    UIColor *color = clock.textColor ?: [UIColor whiteColor];

    // Se lee centro y bounds ANTES de aplicar la escala (la transform altera el frame).
    CGPoint c  = clock.center;
    CGSize  bs = clock.bounds.size;
    clock.transform = CGAffineTransformMakeScale(gClockScale, gClockScale);

    UIView *host = clock.superview;
    if (!host) return;
    host.clipsToBounds = NO;
    if (host.superview) host.superview.clipsToBounds = NO;

    CGFloat cx   = c.x;
    CGFloat topY = c.y - bs.height / 2.0;
    CGFloat botY = c.y + bs.height / 2.0;

    // --- Fecha (encima) ---
    UILabel *date = DSBEnsureLabel(host, DSB_DATE_TAG);
    date.hidden    = !gShowDate;
    date.textColor = color;
    date.font      = [UIFont systemFontOfSize:gDateSize weight:UIFontWeightMedium];
    if (date.text.length == 0) date.text = gDateText;
    [date sizeToFit];
    date.center = CGPointMake(cx, topY - gGap - date.bounds.size.height / 2.0 + gYOffset);
    gDateLabel = date;

    // --- Velocímetro (debajo) ---
    UILabel *spd = DSBEnsureLabel(host, DSB_SPEED_TAG);
    spd.hidden    = !gShowSpeed;
    spd.textColor = color;
    spd.font      = [UIFont systemFontOfSize:gSpeedSize weight:UIFontWeightMedium];
    if (spd.text.length == 0) spd.text = gSpeedText;
    [spd sizeToFit];
    spd.center = CGPointMake(cx, botY + gGap + spd.bounds.size.height / 2.0 + gYOffset);
    gSpeedLabel = spd;

    DSBStartTimerIfNeeded();
}

static void DSBMaybeDecorate(UILabel *self) {
    NSString *txt = nil;
    @try { txt = [self valueForKey:@"text"]; } @catch (__unused id e) {}
    if (![txt isKindOfClass:[NSString class]] || !DSBLooksLikeTime(txt)) return;
    DSBDecorateTimeLabel(self);
}

// ---- Enganches (dos nombres posibles de la clase del reloj) ----------------

%group G_Modern
%hook _UIStatusBarStringView
- (void)layoutSubviews {
    %orig;
    if (gEnabled) DSBMaybeDecorate((UILabel *)self);
}
%end
%end

%group G_Legacy
%hook UIStatusBarStringView
- (void)layoutSubviews {
    %orig;
    if (gEnabled) DSBMaybeDecorate((UILabel *)self);
}
%end
%end

// ---- Recarga en caliente al cambiar ajustes --------------------------------

static void DSBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    DSBLoadPrefs();
    UILabel *t = gTimeView;
    if (t) [t setNeedsLayout];   // reaplica escala/posición al instante
    DSBTick();                   // refresca textos al instante
}

%ctor {
    @autoreleasepool {
        DSBLoadPrefs();
        DSBRefreshDate();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, DSBPrefsChanged,
                                        (__bridge CFStringRef)kNotifyStr, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        if (objc_getClass("_UIStatusBarStringView")) %init(G_Modern);
        if (objc_getClass("UIStatusBarStringView"))  %init(G_Legacy);
    }
}
