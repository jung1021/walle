import Foundation
import Network

/// Finds the camera by scanning the phone's current local subnet(s) for any
/// host with TCP port 554 (RTSP) open. Works on home WiFi (/24) and on the
/// iPhone Personal Hotspot (172.20.10.0/28).
enum CameraDiscovery {

    static func scanForRTSP(port: UInt16 = 554, completion: @escaping ([String]) -> Void) {
        var subnets = localSubnets()
        // Always include the iPhone Personal Hotspot subnet (172.20.10.0/28).
        // When the phone HOSTS the hotspot its interface isn't always readable,
        // so enumeration can miss it — this guarantees we probe 172.20.10.x,
        // where the camera usually lands.
        subnets.append(([172, 20, 10, 1], [255, 255, 255, 240]))
        guard !subnets.isEmpty else { completion([]); return }

        // Build the full host list across every candidate subnet, de-duplicated.
        var seen = Set<String>()
        var hosts: [String] = []
        for (ip, mask) in subnets {
            for h in hostAddresses(ip: ip, mask: mask) where !seen.contains(h) {
                seen.insert(h)
                hosts.append(h)
            }
        }
        guard !hosts.isEmpty else { completion([]); return }

        let found = NSMutableArray()
        let lock = NSLock()
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 32)        // cap concurrent probes
        let queue = DispatchQueue(label: "walle.scan", attributes: .concurrent)

        for host in hosts {
            group.enter()
            sem.wait()
            queue.async {
                checkPort(host: host, port: port, timeout: 1.2) { isOpen in
                    if isOpen { lock.lock(); found.add(host); lock.unlock() }
                    sem.signal()
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let ips = (found as? [String]) ?? []
            completion(ips.sorted { sortKey($0) < sortKey($1) })
        }
    }

    // MARK: - Port probe

    private static func checkPort(host: String, port: UInt16, timeout: TimeInterval,
                                  done: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        var finished = false
        func finish(_ ok: Bool) {
            if finished { return }
            finished = true
            conn.cancel()
            done(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:            finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    // MARK: - Interface enumeration

    /// Returns (ip, netmask) byte-tuples for every usable IPv4 WiFi/hotspot interface.
    private static func localSubnets() -> [([UInt8], [UInt8])] {
        var result: [([UInt8], [UInt8])] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next

            guard let addrPtr = ifa.ifa_addr,
                  addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            // en0 = WiFi client; bridge* = Personal Hotspot host; en1 = fallback.
            guard name == "en0" || name == "en1" || name.hasPrefix("bridge") else { continue }

            guard let ipStr = addressString(addrPtr),
                  let maskPtr = ifa.ifa_netmask,
                  let maskStr = addressString(maskPtr),
                  let ip = parseIPv4(ipStr),
                  let mask = parseIPv4(maskStr) else { continue }

            if ip[0] == 169 && ip[1] == 254 { continue }   // skip link-local
            result.append((ip, mask))
        }
        return result
    }

    private static func addressString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                            &host, socklen_t(host.count),
                            nil, 0, NI_NUMERICHOST)
        return r == 0 ? String(cString: host) : nil
    }

    // MARK: - Subnet math

    private static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    private static func hostAddresses(ip: [UInt8], mask: [UInt8]) -> [String] {
        guard ip.count == 4, mask.count == 4 else { return [] }
        let ipInt = toUInt32(ip)
        let maskInt = toUInt32(mask)
        let network = ipInt & maskInt
        let broadcast = network | ~maskInt
        guard broadcast > network else { return [] }

        var hosts: [String] = []
        var count = 0
        var h = network &+ 1
        while h < broadcast && count < 1024 {   // cap so a /16 can't hang us
            hosts.append(fromUInt32(h))
            h &+= 1
            count += 1
        }
        return hosts
    }

    private static func toUInt32(_ b: [UInt8]) -> UInt32 {
        (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
    private static func fromUInt32(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
    private static func sortKey(_ ip: String) -> UInt32 {
        parseIPv4(ip).map(toUInt32) ?? 0
    }
}
