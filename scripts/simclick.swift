import CoreGraphics
import Foundation

// Usage: simclick <x> <y>   — posts a real mouse move + left click at screen coords.
let args = CommandLine.arguments
guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
    fputs("usage: simclick <x> <y>\n", stderr); exit(1)
}
let pt = CGPoint(x: x, y: y)

func post(_ type: CGEventType, _ button: CGMouseButton = .left) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt,
            mouseButton: button)?.post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(400_000)            // let the sim register hover/gaze at the point
post(.leftMouseDown)
usleep(80_000)
post(.leftMouseUp)
usleep(100_000)
