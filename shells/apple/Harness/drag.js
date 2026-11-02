// A left-button drag from x y to x2 y2 (points from the main display's top left) on studio's screen, whatever lies
// there: `osascript -l JavaScript drag.js <x> <y> <x2> <y2>`, run by smoke.sh from its ssh session's shell, which may
// post mouse events (System Settings > Privacy & Security > Accessibility: /usr/libexec/sshd-keygen-wrapper) where
// the sandboxed UI test runner may not. As a hand drags: the pointer rests on x y, presses, moves to x2 y2 in steps of
// at most 2 points with the button down, rests there for the drop target to take the drag in, and lets go.
ObjC.import('CoreGraphics');

function run(argv) {
  const [x, y, x2, y2] = argv.map(Number);
  const post = (type, px, py) => {
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent($(), type, $.CGPointMake(px, py), $.kCGMouseButtonLeft));
  };
  post($.kCGEventMouseMoved, x, y);
  delay(1);
  post($.kCGEventLeftMouseDown, x, y);
  delay(0.2);
  const steps = Math.max(1, Math.ceil(Math.max(Math.abs(x2 - x), Math.abs(y2 - y)) / 2));
  for (let i = 1; i <= steps; i++) {
    post($.kCGEventLeftMouseDragged, Math.round(x + ((x2 - x) * i) / steps), Math.round(y + ((y2 - y) * i) / steps));
    delay(0.01);
  }
  delay(0.5);
  post($.kCGEventLeftMouseDragged, x2, y2);
  delay(0.5);
  post($.kCGEventLeftMouseUp, x2, y2);
  return `dragged from ${x} ${y} to ${x2} ${y2}`;
}
