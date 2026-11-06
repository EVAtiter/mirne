import Foundation

/// 1 サービスを視聴・録画するのに要る PID（Mirakurun の TSFilter と同じ規則）。
///
/// mirne の再生は TSDemuxer が対象の PMT の PID だけを拾うので、この集合で TS を切り出すことはしない。
/// 録画（1.0 の後）で 1 サービスだけの TS を作るときと、受信している TS の中身を確かめるときに使う。
///
/// Mirakurun（src/Mirakurun/TSFilter.ts）の規則:
/// - 固定で通す: PAT（対象の 1 番組と NIT だけに書き換える）・CAT・NIT・SDT・EIT（0x12）・RST・TDT/TOT・
///   SDTT（0x23・0x28）・BIT・CDT
/// - PMT から: PMT 自身・PCR・すべての ES・番組全体の最初の記述子の CA_PID（ECM）
/// - PMT の版が変わっても、通す PID は足すだけで外さない
///
/// mirne はこれに加えて、ES ごとの限定受信方式記述子の ECM も含める。版が変わったら集合を作り直す
/// （古い ES を通し続けない）。
public enum ServicePIDs {
    /// PAT
    public static let pat: UInt16 = 0x0000
    /// 固定で通す SI の PID（Mirakurun の PROVIDE_PIDS から PAT を除いたもの）
    public static let fixedSI: [UInt16: String] = [
        0x0001: "CAT", 0x0010: "NIT", 0x0011: "SDT", 0x0012: "EIT", 0x0013: "RST",
        0x0014: "TDT/TOT", 0x0023: "SDTT", 0x0024: "BIT", 0x0028: "SDTT", 0x0029: "CDT",
    ]

    /// 対象サービスの PMT から決まる PID（PMT 自身を含む）
    public static func pids(for map: ProgramMap, pmtPID: UInt16) -> Set<UInt16> {
        var pids: Set<UInt16> = [pat, pmtPID, map.pcrPID]
        pids.formUnion(fixedSI.keys)
        pids.formUnion(map.ecmPIDs)
        for stream in map.streams {
            pids.insert(stream.pid)
            if let ecm = stream.ecmPID { pids.insert(ecm) }
        }
        return pids
    }
}

/// 受信した TS に含まれるサービスを調べる（PAT とすべての PMT を読む）。
public final class ServiceSurvey {
    /// 番組番号 → PMT の PID
    public private(set) var programs: [UInt16: UInt16] = [:]
    /// 番組番号 → PMT（届いたもの）
    public private(set) var maps: [UInt16: ProgramMap] = [:]
    /// PID ごとのパケット数（中身を確かめる用）
    public private(set) var packetsPerPID: [UInt16: Int] = [:]

    private var residue = [UInt8]()
    private var sections: [UInt16: SectionAssembler] = [:]

    public init() {}

    /// PAT のすべての番組の PMT が揃ったか
    public var isComplete: Bool {
        !programs.isEmpty && programs.keys.allSatisfy { maps[$0] != nil }
    }

    public func feed(_ data: Data) {
        residue.append(contentsOf: data)
        var offset = 0
        while residue.count - offset >= TSPacket.size {
            guard residue[offset] == TSPacket.syncByte else {
                offset += 1
                continue
            }
            let packet = Array(residue[offset..<offset + TSPacket.size])
            offset += TSPacket.size
            let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
            packetsPerPID[pid, default: 0] += 1
            let isPMT = programs.values.contains(pid)
            guard pid == ServicePIDs.pat || isPMT, packet[3] & 0x10 != 0 else { continue }
            let start = 4 + (packet[3] & 0x20 != 0 ? 1 + Int(packet[4]) : 0)
            guard start < TSPacket.size else { continue }
            let assembler = sections[pid] ?? SectionAssembler()
            sections[pid] = assembler
            let sectionsFound = packet.withUnsafeBufferPointer {
                assembler.feed(UnsafeBufferPointer(rebasing: $0[start...]), unitStart: packet[1] & 0x40 != 0, lost: false)
            }
            for section in sectionsFound where PSI.crcIsValid(section) {
                if let table = PSI.parsePAT(section) {
                    programs = table
                } else if let map = PSI.parsePMT(section) {
                    maps[map.programNumber] = map
                }
            }
        }
        residue.removeFirst(offset)
    }
}
