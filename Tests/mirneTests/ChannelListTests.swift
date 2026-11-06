import Foundation
import Testing

/// 架空の局で作った `coax scan` の結果（実在の局名・TSID は使わない）
private let scanJSON = """
{
  "backend": "cech-zd1j",
  "device": "cech-zd1j:test:0",
  "started_at": "2026-11-03T21:13:07.893537+09:00",
  "results": [
    {"channel": "13", "properties": {"DELIVERY_SYSTEM": "ISDBT", "FREQUENCY": "473142857"}, "status": "no_lock", "elapsed_ms": 5000},
    {"channel": "20", "properties": {"DELIVERY_SYSTEM": "ISDBT", "FREQUENCY": "515142857"}, "status": "found", "elapsed_ms": 2000,
     "analysis": {"transport": {"transport_stream_id": 101, "original_network_id": 101,
       "services": [
         {"service_id": 2001, "service_type": 1, "name": "テスト三局"},
         {"service_id": 2400, "service_type": 192, "name": "テスト三局ワンセグ", "partial_reception": true}
       ],
       "networks": [{"actual": true, "transports": [{"transport_stream_id": 101, "remote_control_key_id": 3, "ts_name": "テスト三局"}]}]}}},
    {"channel": "22", "properties": {"DELIVERY_SYSTEM": "ISDBT", "FREQUENCY": "527142857"}, "status": "found", "elapsed_ms": 2000,
     "analysis": {"transport": {"transport_stream_id": 100, "original_network_id": 100,
       "services": [
         {"service_id": 1025, "service_type": 1, "name": "テスト一局２"},
         {"service_id": 1024, "service_type": 1, "name": "テスト一局１"},
         {"service_id": 1100, "service_type": 161, "name": "テスト一局臨時"},
         {"service_id": 65520, "service_type": 164}
       ],
       "networks": [{"actual": true, "transports": [
         {"transport_stream_id": 100, "remote_control_key_id": 1, "ts_name": "テスト一局", "partial_reception_service_ids": [1100]}
       ]}]}}},
    {"channel": "30", "properties": {"DELIVERY_SYSTEM": "ISDBT", "FREQUENCY": "575142857"}, "status": "found", "elapsed_ms": 2000,
     "analysis": {"transport": {"transport_stream_id": 100, "original_network_id": 100, "services": []}}},
    {"channel": "40", "properties": {"DELIVERY_SYSTEM": "ISDBT", "FREQUENCY": "635142857"}, "status": "found", "elapsed_ms": 2000,
     "analysis": {"transport": {"transport_stream_id": 200, "original_network_id": 200,
       "services": [{"service_id": 3000, "service_type": 1, "name": "キー無し局"}]}}}
  ]
}
"""

@Suite("チャンネル一覧")
struct ChannelListTests {
    @Test("受信できたチャンネルだけを取り込み、同じ TS は最初の周波数を使う")
    func importsFoundChannels() throws {
        let list = try ChannelList.importing(scanResult: Data(scanJSON.utf8))
        #expect(list.channels.map(\.name) == ["20", "22", "40"])
        let first = try #require(list.channels.first { $0.transportStreamID == 100 })
        #expect(first.frequency == 527_142_857)
        #expect(first.remoteControlKey == 1)
        #expect(first.tsName == "テスト一局")
        #expect(list.channels.first { $0.name == "40" }?.remoteControlKey == nil)
    }

    @Test("一覧はリモコンキー順に主のサービスだけ。キーの無い局は最後")
    func ordersByRemoteControlKey() throws {
        let list = try ChannelList.importing(scanResult: Data(scanJSON.utf8))
        #expect(list.lineup.map(\.service.serviceID) == [1024, 2001, 3000])
        #expect(list.lineup.map(\.remoteControlKey) == [1, 3, nil])
        #expect(list.allServices.map(\.service.serviceID) == [1024, 1025, 2001, 3000])
        #expect(list.allServices.map(\.branch) == [1, 2, 1, 1])
    }

    @Test("サブチャンネルは同じ物理チャンネルの出すサービスを枝番の順に")
    func listsSubServices() throws {
        let list = try ChannelList.importing(scanResult: Data(scanJSON.utf8))
        let first = try #require(list.lineup.first)
        #expect(list.subServices(of: first.channel).map(\.service.serviceID) == [1024, 1025])
        #expect(list.subServices(of: first.channel).map(\.branch) == [1, 2])
    }

    @Test("ワンセグ・臨時・データなどは既定で隠す")
    func hidesNonTelevisionServices() throws {
        let list = try ChannelList.importing(scanResult: Data(scanJSON.utf8))
        let services = list.channels.flatMap(\.services)
        let hidden = services.filter { !$0.isVisible }.map(\.serviceID).sorted()
        #expect(hidden == [1100, 2400, 65520])
        #expect(services.first { $0.serviceID == 2400 }?.isPartialReception == true)
        #expect(services.first { $0.serviceID == 65520 }?.name == "サービス 65520")
    }

    @Test("受信できたチャンネルが無ければ失敗にする")
    func failsWhenNothingFound() {
        let empty = #"{"backend": "x", "device": "x", "started_at": "2026-11-03T21:13:07+09:00", "results": []}"#
        #expect(throws: ChannelImportError.nothingFound) {
            try ChannelList.importing(scanResult: Data(empty.utf8))
        }
    }

    @Test("保存して読み戻すと同じ一覧になる")
    func savesAndLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mirne-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChannelStore(fileURL: directory.appendingPathComponent("channels.json"))
        #expect(try store.load() == nil)
        let list = try ChannelList.importing(scanResult: Data(scanJSON.utf8))
        try store.save(list)
        #expect(try store.load() == list)
    }

    @Test("coax scan の進み具合の行を読む")
    func parsesProgressLine() throws {
        let parsed = try #require(ScanProgress.parse(line: "[3/40] ISDBT/40 ... found (ts, 4427588 bytes) 17.27 Mbps CNR 25.7dB -50dBm"))
        #expect(parsed.completed == 3)
        #expect(parsed.total == 40)
        #expect(parsed.channel == "40")
        #expect(parsed.status == "found")
        #expect(ScanProgress.parse(line: "[1/113] ISDBT/13 ... no lock")?.status == "no lock")
        #expect(ScanProgress.parse(line: "          テスト一局  TSID=100  ONID=100") == nil)
    }
}

@Suite("チャンネルの編集")
struct ChannelEditsTests {
    private func list() throws -> ChannelList {
        try ChannelList.importing(scanResult: Data(scanJSON.utf8))
    }

    @Test("並べた順が先、編集に無い局は後ろに既定の順。隠した局は一覧から除くが、設定の表には残る")
    func ordersAndHides() throws {
        let list = try list()
        // 既定は 1024（キー 1）・2001（キー 3）・3000（キー無し）
        let edits = ChannelEdits(order: ["200-200", "101-101"], hidden: ["100-100"])
        #expect(list.stations(with: edits).map(\.service.serviceID) == [3000, 2001, 1024])
        #expect(list.lineup(with: edits).map(\.service.serviceID) == [3000, 2001])
        #expect(list.lineup(with: ChannelEdits()).map(\.service.serviceID) == list.lineup.map(\.service.serviceID))
    }

    @Test("名前の上書きは主のサービスだけに当て、マルチ編成のサブはそのまま")
    func renamesMainService() throws {
        let list = try list()
        let edits = ChannelEdits(names: ["100-100": "わたしの一局", "101-101": ""])
        #expect(list.lineup(with: edits).map(\.service.name) == ["わたしの一局", "テスト三局", "キー無し局"])
        let main = try #require(list.lineup.first)
        #expect(list.subServices(of: main.channel, with: edits).map(\.service.name) == ["わたしの一局", "テスト一局２"])
        #expect(list.allServices(with: edits).first { $0.service.serviceID == 1024 }?.service.name == "わたしの一局")
    }
}
