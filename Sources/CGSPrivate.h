// Private CoreGraphics (WindowServer) cursor calls. Undocumented, but stable for
// over a decade: Mousecape has shipped on them since 10.9 and still does on Tahoe.
// Signatures from Mousecape's CGSInternal/CGSCursor.h.
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef int CGSConnectionID;

extern CGSConnectionID CGSMainConnectionID(void);

// Registers (replaces) the named system cursor for every app in the session.
// images: one CGImage per scale; animated frames are stacked vertically.
extern CGError CGSRegisterCursorWithImages(CGSConnectionID cid, const char *cursorName,
                                           bool setGlobally, bool instantly,
                                           CGSize cursorSize, CGPoint hotspot,
                                           unsigned long frameCount, CGFloat frameDuration,
                                           CFArrayRef imageArray, int *seed);
extern CGError CGSCopyRegisteredCursorImages(CGSConnectionID cid, const char *cursorName,
                                             CGSize *imageSize, CGPoint *hotSpot,
                                             unsigned long *frameCount, CGFloat *frameDuration,
                                             CFArrayRef *imageArray);
extern CGError CGSGetRegisteredCursorDataSize(CGSConnectionID cid, const char *cursorName, size_t *size);
extern CGError CGSRemoveRegisteredCursor(CGSConnectionID cid, const char *cursorName, bool unknownFlag);

extern CGError CoreCursorUnregisterAll(CGSConnectionID cid);
extern CGError CoreCursorSet(CGSConnectionID cid, int cursorID);

extern CGError CGSGetCursorScale(CGSConnectionID cid, float *scale);
extern CGError CGSSetCursorScale(CGSConnectionID cid, float scale);

extern char *CGSCursorNameForSystemCursor(int cursorID);
