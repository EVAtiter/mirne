import Testing

// MPEG-2 のピクチャを復号に回すかの判断（VideoToolbox と FFmpeg で共通）
@Suite("MPEG-2 のピクチャを回すかの判断")
struct MPEG2PictureGateTests {
    private func picture(_ type: MPEG2PictureInfo.CodingType) -> MPEG2PictureInfo {
        MPEG2PictureInfo(codingType: type, temporalReference: 0)
    }

    @Test("シーケンスヘッダ付きの I まで捨てる")
    func waitsForIntraWithSequenceHeader() {
        var gate = MPEG2PictureGate()
        let admitted1 = gate.admit(picture(.predicted), hasSequenceHeader: false, damaged: false)
        #expect(!admitted1)
        let admitted2 = gate.admit(picture(.bidirectional), hasSequenceHeader: false, damaged: false)
        #expect(!admitted2)
        // シーケンスヘッダの無い I でも始めない
        let admitted3 = gate.admit(picture(.intra), hasSequenceHeader: false, damaged: false)
        #expect(!admitted3)
        let admitted4 = gate.admit(picture(.intra), hasSequenceHeader: true, damaged: false)
        #expect(admitted4)
        #expect(gate.skippedBeforeIntra == 3)
    }

    @Test("I の直後の B は、最初の P を回すまで捨てる")
    func skipsLeadingBidirectionalUntilPredicted() {
        var gate = MPEG2PictureGate()
        let admitted5 = gate.admit(picture(.intra), hasSequenceHeader: true, damaged: false)
        #expect(admitted5)
        let admitted6 = gate.admit(picture(.bidirectional), hasSequenceHeader: false, damaged: false)
        #expect(!admitted6)
        let admitted7 = gate.admit(picture(.bidirectional), hasSequenceHeader: false, damaged: false)
        #expect(!admitted7)
        let admitted8 = gate.admit(picture(.predicted), hasSequenceHeader: false, damaged: false)
        #expect(admitted8)
        let admitted9 = gate.admit(picture(.bidirectional), hasSequenceHeader: false, damaged: false)
        #expect(admitted9)
        #expect(gate.skippedLeadingB == 2)
    }

    @Test("欠けたピクチャも回し、数だけ数える")
    func admitsDamagedPictures() {
        var gate = MPEG2PictureGate()
        let admitted10 = gate.admit(picture(.intra), hasSequenceHeader: true, damaged: true)
        #expect(admitted10)
        let admitted11 = gate.admit(picture(.predicted), hasSequenceHeader: false, damaged: true)
        #expect(admitted11)
        #expect(gate.damagedPictures == 2)
    }

    @Test("始め直すと、また I まで捨てる")
    func restartWaitsForIntraAgain() {
        var gate = MPEG2PictureGate()
        let admitted12 = gate.admit(picture(.intra), hasSequenceHeader: true, damaged: false)
        #expect(admitted12)
        let admitted13 = gate.admit(picture(.predicted), hasSequenceHeader: false, damaged: false)
        #expect(admitted13)
        gate.restart()
        let admitted14 = gate.admit(picture(.predicted), hasSequenceHeader: false, damaged: false)
        #expect(!admitted14)
        let admitted15 = gate.admit(picture(.intra), hasSequenceHeader: true, damaged: false)
        #expect(admitted15)
        let admitted16 = gate.admit(picture(.bidirectional), hasSequenceHeader: false, damaged: false)
        #expect(!admitted16)
    }
}
