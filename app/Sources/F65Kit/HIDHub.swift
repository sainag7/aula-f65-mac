import Foundation
import IOKit.hid

// Callbacks run independently of the serial transaction worker. The condition wait releases
// its lock, so a receiver ACK can always arrive while a settings transaction is blocked.
private final class HIDInbox: PacketChannel {
    let device: IOHIDDevice
    let condition=NSCondition()
    var packets:[[UInt8]]=[]
    var statusChanged=false
    init(_ device:IOHIDDevice) { self.device=device }
    func accept(_ bytes:[UInt8]) {
        condition.lock();defer { condition.unlock() }
        guard bytes.count==20,bytes[0]==0x13,ReceiverProtocol.checksum(bytes)==bytes[19] else { return }
        if bytes[1]==0x0a {statusChanged=true} else {packets.append(bytes);if packets.count>256 {packets.removeFirst()}}
        condition.signal()
    }
    func send(_ p:[UInt8]) throws {
        let r=p.withUnsafeBufferPointer {IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,0x13,$0.baseAddress!,p.count)}
        try HIDHub.check(r)
    }
    func receive(timeout:TimeInterval)->[UInt8]? {
        condition.lock();defer{condition.unlock()};let end=Date().addingTimeInterval(timeout)
        while packets.isEmpty {if !condition.wait(until:end) {return nil}}
        return packets.removeFirst()
    }
    func drain() {condition.lock();packets=[];condition.unlock()}
    func takeStatus()->Bool {condition.lock();defer{condition.unlock()};let v=statusChanged;statusChanged=false;return v}
}
public final class HIDHub {
    private let callbacks=DispatchQueue(label:"local.f65.lighting.callbacks")
    private let lock=NSLock()
    private var devices=Set<IOHIDDevice>()
    private var manager:IOHIDManager?
    private var current:IOHIDDevice?
    private var transport:Transport?
    // Keep callback contexts alive until shutdown; hot-plug may have queued callbacks.
    private var inboxes:[IOHIDDevice:HIDInbox]=[:]
    private let cancelled=DispatchSemaphore(value:0)
    private var inbox:HIDInbox?
    public init() {}
    public func start() {
        let m=IOHIDManagerCreate(kCFAllocatorDefault,0)
        IOHIDManagerSetDeviceMatchingMultiple(m,[[kIOHIDVendorIDKey:0x258a,kIOHIDProductIDKey:0x010c],[kIOHIDVendorIDKey:0x3554,kIOHIDProductIDKey:0xfa09,kIOHIDPrimaryUsagePageKey:0xff02]] as CFArray)
        let ctx=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m,{ctx,_,_,d in let h=Unmanaged<HIDHub>.fromOpaque(ctx!).takeUnretainedValue();h.lock.lock();h.devices.insert(d);h.lock.unlock()},ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m,{ctx,_,_,d in let h=Unmanaged<HIDHub>.fromOpaque(ctx!).takeUnretainedValue();h.lock.lock();h.devices.remove(d);h.lock.unlock()},ctx)
        // Register before activation, as required by IOHIDManager's dispatch API.
        IOHIDManagerRegisterInputReportCallback(m,{ctx,_,sender,_,id,p,n in
            guard let ctx,let sender else{return}
            let h=Unmanaged<HIDHub>.fromOpaque(ctx).takeUnretainedValue()
            let d=Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            h.lock.lock();let inbox=h.inboxes[d];h.lock.unlock()
            var bytes=Array(UnsafeBufferPointer(start:p,count:n));if bytes.first != UInt8(id){bytes.insert(UInt8(id),at:0)}
            inbox?.accept(bytes)
        },ctx)
        IOHIDManagerSetDispatchQueue(m,callbacks)
        IOHIDManagerSetCancelHandler(m,{[cancelled] in cancelled.signal()})
        IOHIDManagerActivate(m);manager=m
    }
    private func kind(_ d:IOHIDDevice)->LinkKind? {
        func p(_ k:String)->Int {IOHIDDeviceGetProperty(d,k as CFString) as? Int ?? 0}
        if p(kIOHIDVendorIDKey)==0x258a && p(kIOHIDMaxFeatureReportSizeKey)>=520 {return .cable}
        if p(kIOHIDVendorIDKey)==0x3554 && p(kIOHIDPrimaryUsagePageKey)==0xff02 {return .receiver};return nil
    }
    public func connection(preference:String) throws -> Transport {
        lock.lock();let available=devices;lock.unlock()
        let candidates=available.filter {d in guard let k=kind(d) else{return false};return preference=="auto" || preference==k.rawValue}.sorted {kind($0) == .cable && kind($1) != .cable}
        guard let d=candidates.first else {disconnect();throw F65Error.notFound}
        if current==d,let transport {return transport}
        disconnect();try Self.check(IOHIDDeviceOpen(d,0));current=d
        let t:Transport
        if kind(d) == .cable {
            t=CableTransport(send:{p in try Self.check(p.withUnsafeBufferPointer {IOHIDDeviceSetReport(d,kIOHIDReportTypeFeature,6,$0.baseAddress!,p.count)})},receive:{
                var p=[UInt8](repeating:0,count:520);var n=520
                try Self.check(p.withUnsafeMutableBufferPointer {IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,6,$0.baseAddress!,&n)})
                return Array(p.prefix(n))
            })
        } else {let box=HIDInbox(d);lock.lock();inboxes[d]=box;lock.unlock();inbox=box;t=ReceiverTransport(box)}
        transport=t;return t
    }
    public func statusChanged()->Bool {inbox?.takeStatus() ?? false}
    public func disconnect() {
        if let d=current {IOHIDDeviceClose(d,0)}
        current=nil;transport=nil;inbox=nil
    }
    public static func check(_ r:IOReturn) throws {
        guard r != kIOReturnSuccess else {return}
        if r==kIOReturnNotPermitted {throw F65Error.notPermitted}
        throw F65Error.invalid(String(format:"HID I/O failed (0x%08x).",UInt32(bitPattern:r)))
    }
    // Owned for the app lifetime. Stop after the worker is quiescent.
    public func stop() {disconnect();if let m=manager {IOHIDManagerCancel(m);cancelled.wait();manager=nil;lock.lock();inboxes=[:];lock.unlock()}}
}
