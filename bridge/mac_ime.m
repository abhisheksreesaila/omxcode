// The Mac's input methods for a mojoui canvas (goal 79 M5, D-7979): NSTextInputClient on the AppKit host's canvas view
// class. Several of the protocol's methods take or return structs by value (NSRange, NSRect), which Mojo's FFI rule
// keeps out of Mojo; this shim implements every method in Objective-C and calls back into the host through functions
// that take and return scalars only (or write through pointers). The host installs it at start (looked up by name:
// a build without the shim has no input methods, nothing else changes) and drives the real methods on the real view
// from its test steps through mojoui_ime_drive.
//   Built only by a native Mac build: clang -c -fno-objc-arc bridge/mac_ime.m (scripts/build.sh), linked in.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

typedef void (*ime_text_fn)(void *view, const char *utf8, long n, long sel_loc, long sel_len);
typedef void (*ime_void_fn)(void *view);
typedef long (*ime_range_fn)(void *view, long *loc, long *len);  // 1: there is one (written), 0: none
typedef void (*ime_rect_fn)(void *view, long loc, long len, double *xywh);  // the caret, view points from the top left
typedef void (*ime_cmd_fn)(void *view, const char *selector);

static ime_text_fn g_marked = 0, g_insert = 0;
static ime_void_fn g_unmark = 0;
static ime_range_fn g_marked_range = 0, g_selected_range = 0;
static ime_rect_fn g_rect = 0;
static ime_cmd_fn g_command = 0;

static NSString *plain(id text) {
    return [text isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)text string] : (NSString *)text;
}

static BOOL imp_hasMarkedText(id self, SEL _cmd) {
    long a = 0, b = 0;
    return g_marked_range && g_marked_range((void *)self, &a, &b) && b > 0;
}

static NSRange imp_markedRange(id self, SEL _cmd) {
    long a = 0, b = 0;
    if (g_marked_range && g_marked_range((void *)self, &a, &b) && b > 0) return NSMakeRange((NSUInteger)a, (NSUInteger)b);
    return NSMakeRange(NSNotFound, 0);
}

static NSRange imp_selectedRange(id self, SEL _cmd) {
    long a = 0, b = 0;
    if (g_selected_range && g_selected_range((void *)self, &a, &b)) return NSMakeRange((NSUInteger)a, (NSUInteger)b);
    return NSMakeRange(0, 0);
}

static void imp_setMarkedText(id self, SEL _cmd, id text, NSRange selected, NSRange replacement) {
    NSString *s = plain(text);
    const char *u = [s UTF8String];
    if (g_marked) g_marked((void *)self, u, (long)strlen(u), (long)selected.location, (long)selected.length);
}

static void imp_unmarkText(id self, SEL _cmd) {
    if (g_unmark) g_unmark((void *)self);
}

static NSArray *imp_validAttributes(id self, SEL _cmd) {
    return @[];
}

static NSAttributedString *imp_attributedSubstring(id self, SEL _cmd, NSRange range, NSRangePointer actual) {
    return nil;  // (the composition is drawn by the app; no text is handed back)
}

static void imp_insertText(id self, SEL _cmd, id text, NSRange replacement) {
    NSString *s = plain(text);
    const char *u = [s UTF8String];
    if (g_insert) g_insert((void *)self, u, (long)strlen(u), 0, 0);
}

static NSUInteger imp_characterIndexForPoint(id self, SEL _cmd, NSPoint p) {
    return NSNotFound;
}

static NSRect imp_firstRect(id self, SEL _cmd, NSRange range, NSRangePointer actual) {
    double r[4] = {0, 0, 0, 0};
    if (g_rect) g_rect((void *)self, (long)range.location, (long)range.length, r);
    if (actual) *actual = range;
    NSView *v = (NSView *)self;
    // (the caret in view points from the top left → the view's own coordinates → the window's → the screen's)
    NSRect local = [v isFlipped] ? NSMakeRect(r[0], r[1], r[2], r[3]) : NSMakeRect(r[0], v.bounds.size.height - r[1] - r[3], r[2], r[3]);
    NSRect inWindow = [v convertRect:local toView:nil];
    return v.window ? [v.window convertRectToScreen:inWindow] : inWindow;
}

static void imp_doCommand(id self, SEL _cmd, SEL command) {
    if (g_command) g_command((void *)self, sel_getName(command));
}

static void add(Class c, SEL s, IMP imp) {
    struct objc_method_description d = protocol_getMethodDescription(@protocol(NSTextInputClient), s, YES, YES);
    if (!d.types) d = protocol_getMethodDescription(@protocol(NSTextInputClient), s, NO, YES);
    class_addMethod(c, s, imp, d.types);
}

// The canvas class (not registered yet) becomes an NSTextInputClient calling these functions.
void mojoui_ime_install(void *cls, void *marked, void *insert, void *unmark, void *marked_range, void *selected_range,
                        void *rect, void *command) {
    Class c = (Class)cls;
    g_marked = (ime_text_fn)marked;
    g_insert = (ime_text_fn)insert;
    g_unmark = (ime_void_fn)unmark;
    g_marked_range = (ime_range_fn)marked_range;
    g_selected_range = (ime_range_fn)selected_range;
    g_rect = (ime_rect_fn)rect;
    g_command = (ime_cmd_fn)command;
    class_addProtocol(c, @protocol(NSTextInputClient));
    add(c, @selector(hasMarkedText), (IMP)imp_hasMarkedText);
    add(c, @selector(markedRange), (IMP)imp_markedRange);
    add(c, @selector(selectedRange), (IMP)imp_selectedRange);
    add(c, @selector(setMarkedText:selectedRange:replacementRange:), (IMP)imp_setMarkedText);
    add(c, @selector(unmarkText), (IMP)imp_unmarkText);
    add(c, @selector(validAttributesForMarkedText), (IMP)imp_validAttributes);
    add(c, @selector(attributedSubstringForProposedRange:actualRange:), (IMP)imp_attributedSubstring);
    add(c, @selector(insertText:replacementRange:), (IMP)imp_insertText);
    add(c, @selector(characterIndexForPoint:), (IMP)imp_characterIndexForPoint);
    add(c, @selector(firstRectForCharacterRange:actualRange:), (IMP)imp_firstRect);
    add(c, @selector(doCommandBySelector:), (IMP)imp_doCommand);
}

// A keyDown: offered to the view's input context first (an input method composes, or inserts text): 1 when it took it.
long mojoui_ime_key(void *view, void *event) {
    NSTextInputContext *ctx = [(NSView *)view inputContext];
    return ctx && [ctx handleEvent:(NSEvent *)event] ? 1 : 0;
}

// The test steps: the real methods called on the real view, as an input method calls them.
//   kind 0: setMarkedText:utf8 selectedRange:(end, 0) replacementRange:(NotFound, 0)
//   kind 1: firstRectForCharacterRange:(0, 0) → xywh (screen points), and markedRange/selectedRange/hasMarkedText
//   kind 2: insertText:utf8 replacementRange:(NotFound, 0)
//   kind 3: unmarkText
void mojoui_ime_drive(void *view, long kind, const char *utf8, double *out) {
    id v = (id)view;
    NSString *s = utf8 ? [NSString stringWithUTF8String:utf8] : @"";
    if (kind == 0) {
        [v setMarkedText:s selectedRange:NSMakeRange(s.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    } else if (kind == 1) {
        NSRange actual;
        NSRect r = [v firstRectForCharacterRange:NSMakeRange(0, 0) actualRange:&actual];
        NSRange m = [v markedRange];
        NSRange sel = [v selectedRange];
        if (out) {
            out[0] = r.origin.x; out[1] = r.origin.y; out[2] = r.size.width; out[3] = r.size.height;
            out[4] = m.location == NSNotFound ? -1 : (double)m.location; out[5] = (double)m.length;
            out[6] = (double)sel.location; out[7] = [v hasMarkedText] ? 1 : 0;
        }
    } else if (kind == 2) {
        [v insertText:s replacementRange:NSMakeRange(NSNotFound, 0)];
    } else if (kind == 3) {
        [v unmarkText];
    }
}
