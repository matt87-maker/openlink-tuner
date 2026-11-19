import Foundation
import IOKit
import IOKit.usb

/// Notices when a Link cable (FTDI 0403:7068–706F) is plugged in or removed.
final class UsbWatcher {
    var onChange: ((Bool) -> Void)?
    private var port: IONotificationPortRef?
    private var addIter: io_iterator_t = 0
    private var rmIter: io_iterator_t = 0
    private(set) var present = false

    static let vendor = 0x0403
    static let products = 0x7068...0x706F

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            Unmanaged<UsbWatcher>.fromOpaque(refcon).takeUnretainedValue().drain(iter)
        }
        // match every USB device and filter by vendor/product ourselves — IOKit ignores a plain
        // "idVendor" key in this kind of query (it matched nothing on a real Link cable)
        func matching() -> CFDictionary { IOServiceMatching("IOUSBHostDevice") }
        // draining arms each notification and also catches a cable that's already plugged in
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, matching(), cb, me, &addIter)
        drain(addIter)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, matching(), cb, me, &rmIter)
        drain(rmIter)
    }

    private func drain(_ iter: io_iterator_t) {
        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
        let now = Self.scan()
        if now != present { present = now; onChange?(now) }
    }

    /// Is a Link cable connected right now?
    static func scan() -> Bool {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        func num(_ s: io_object_t, _ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        var found = false
        while case let s = IOIteratorNext(it), s != 0 {
            if num(s, "idVendor") == vendor, let p = num(s, "idProduct"), products.contains(p) { found = true }
            IOObjectRelease(s)
        }
        return found
    }
}
