// Copyright (c) 2018 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "atom/browser/ui/cocoa/atom_ns_window.h"

#include "atom/browser/native_window_mac.h"
#include "atom/browser/ui/cocoa/atom_preview_item.h"
#include "atom/browser/ui/cocoa/atom_touch_bar.h"

namespace atom {

bool ScopedDisableResize::disable_resize_ = false;

}  // namespace atom

@implementation AtomNSWindow

@synthesize acceptsFirstMouse;
@synthesize enableLargerThanScreen;
@synthesize disableAutoHideCursor;
@synthesize disableKeyOrMainWindow;
@synthesize windowButtonsOffset;
@synthesize vibrantView;

- (void)setShell:(atom::NativeWindowMac*)shell {
  shell_ = shell;
}

- (NSTouchBar*)makeTouchBar API_AVAILABLE(macosx(10.12.2)) {
  if (shell_->touch_bar())
    return [shell_->touch_bar() makeTouchBar];
  else
    return nil;
}

// NSWindow overrides.

- (void)swipeWithEvent:(NSEvent *)event {
  if (event.deltaY == 1.0) {
    shell_->NotifyWindowSwipe("up");
  } else if (event.deltaX == -1.0) {
    shell_->NotifyWindowSwipe("right");
  } else if (event.deltaY == -1.0) {
    shell_->NotifyWindowSwipe("down");
  } else if (event.deltaX == 1.0) {
    shell_->NotifyWindowSwipe("left");
  }
}

- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen*)screen {
  // Resizing is disabled.
  if (atom::ScopedDisableResize::IsResizeDisabled())
    return [self frame];

  // Enable the window to be larger than screen.
  if ([self enableLargerThanScreen])
    return frameRect;
  else
    return [super constrainFrameRect:frameRect toScreen:screen];
}

- (void)setFrame:(NSRect)windowFrame display:(BOOL)displayViews {
  // constrainFrameRect is not called on hidden windows so disable adjusting
  // the frame directly when resize is disabled
  if (!atom::ScopedDisableResize::IsResizeDisabled())
    [super setFrame:windowFrame display:displayViews];
}

- (id)accessibilityAttributeValue:(NSString*)attribute {
  if (![attribute isEqualToString:@"AXChildren"])
    return [super accessibilityAttributeValue:attribute];

  // Filter out objects that aren't the title bar buttons. This has the effect
  // of removing the window title, which VoiceOver already sees.
  // * when VoiceOver is disabled, this causes Cmd+C to be used for TTS but
  //   still leaves the buttons available in the accessibility tree.
  // * when VoiceOver is enabled, the full accessibility tree is used.
  // Without removing the title and with VO disabled, the TTS would always read
  // the window title instead of using Cmd+C to get the selected text.
  NSPredicate *predicate = [NSPredicate predicateWithFormat:
      @"(self isKindOfClass: %@) OR (self.className == %@)",
      [NSButtonCell class],
      @"RenderWidgetHostViewCocoa"];

  NSArray *children = [super accessibilityAttributeValue:attribute];
  return [children filteredArrayUsingPredicate:predicate];
}

- (BOOL)canBecomeMainWindow {
  return !self.disableKeyOrMainWindow;
}

- (BOOL)canBecomeKeyWindow {
  return !self.disableKeyOrMainWindow;
}

- (void)enableWindowButtonsOffset {
  auto closeButton = [self standardWindowButton:NSWindowCloseButton];
  auto miniaturizeButton = [self standardWindowButton:NSWindowMiniaturizeButton];
  auto zoomButton = [self standardWindowButton:NSWindowZoomButton];

  [closeButton setPostsFrameChangedNotifications:YES];
  [miniaturizeButton setPostsFrameChangedNotifications:YES];
  [zoomButton setPostsFrameChangedNotifications:YES];

  windowButtonsInterButtonSpacing_ =
    NSMinX([miniaturizeButton frame]) - NSMaxX([closeButton frame]);

  auto center = [NSNotificationCenter defaultCenter];

  [center addObserver:self
             selector:@selector(adjustCloseButton:)
                 name:NSViewFrameDidChangeNotification
               object:closeButton];

  [center addObserver:self
             selector:@selector(adjustMiniaturizeButton:)
                 name:NSViewFrameDidChangeNotification
               object:miniaturizeButton];

  [center addObserver:self
             selector:@selector(adjustZoomButton:)
                 name:NSViewFrameDidChangeNotification
               object:zoomButton];
}

- (void)adjustCloseButton:(NSNotification*)notification {
  [self adjustButton:[notification object]
              ofKind:NSWindowCloseButton];
}

- (void)adjustMiniaturizeButton:(NSNotification*)notification {
  [self adjustButton:[notification object]
              ofKind:NSWindowMiniaturizeButton];
}

- (void)adjustZoomButton:(NSNotification*)notification {
  [self adjustButton:[notification object]
              ofKind:NSWindowZoomButton];
}

- (void)adjustButton:(NSButton*)button
              ofKind:(NSWindowButton)kind {
  NSRect buttonFrame = [button frame];
  NSRect frameViewBounds = [[self frameView] bounds];
  NSPoint offset = self.windowButtonsOffset;

  buttonFrame.origin = NSMakePoint(
    offset.x,
    (NSHeight(frameViewBounds) - NSHeight(buttonFrame) - offset.y));

  switch (kind) {
    case NSWindowZoomButton:
      buttonFrame.origin.x += NSWidth(
        [[self standardWindowButton:NSWindowMiniaturizeButton] frame]);
      buttonFrame.origin.x += windowButtonsInterButtonSpacing_;
      // fallthrough
    case NSWindowMiniaturizeButton:
      buttonFrame.origin.x += NSWidth(
        [[self standardWindowButton:NSWindowCloseButton] frame]);
      buttonFrame.origin.x += windowButtonsInterButtonSpacing_;
      // fallthrough
    default:
      break;
  }

  BOOL didPost = [button postsBoundsChangedNotifications];
  [button setPostsFrameChangedNotifications:NO];
  [button setFrame:buttonFrame];
  [button setPostsFrameChangedNotifications:didPost];
}

- (NSView*)frameView {
  return [[self contentView] superview];
}

// Quicklook methods

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel {
  return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel {
  panel.delegate = [self delegate];
  panel.dataSource = static_cast<id<QLPreviewPanelDataSource>>([self delegate]);
}

- (void)endPreviewPanelControl:(QLPreviewPanel*)panel {
  panel.delegate = nil;
  panel.dataSource = nil;
}

// Custom window button methods

- (void)performClose:(id)sender {
  if (shell_->title_bar_style() == atom::NativeWindowMac::CUSTOM_BUTTONS_ON_HOVER)
    [[self delegate] windowShouldClose:self];
  else
    [super performClose:sender];
}

- (void)toggleFullScreenMode:(id)sender {
  if (shell_->simple_fullscreen())
    shell_->SetSimpleFullScreen(!shell_->IsSimpleFullScreen());
  else
   [super toggleFullScreen:sender];
}

- (void)performMiniaturize:(id)sender {
  if (shell_->title_bar_style() == atom::NativeWindowMac::CUSTOM_BUTTONS_ON_HOVER)
    [self miniaturize:self];
  else
    [super performMiniaturize:sender];
}

@end
