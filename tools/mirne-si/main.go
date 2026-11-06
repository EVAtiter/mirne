// mirne-si: TS から番組情報（EIT の番組名・概要、TOT の時刻）を読み、1 行 1 つの JSON で出す。
//
// mirne の Swift の解析（mirne-probe si・jis-table・captions --pes）と出力を突き合わせるための道具。coax の pkg/mpegts と pkg/isdb を使う。
//
//	mirne-si < input.ts
//	mirne-si input.ts
//	mirne-si -captions corpus.txt   字幕 PES を coax で読んで置く（captions.go）
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/Till0196/coax/pkg/isdb"
	"github.com/Till0196/coax/pkg/mpegts"
)

// 1 回に読むパケット数
const readPackets = 1024

// eventLine は 1 番組の出力
type eventLine struct {
	Kind      string `json:"kind"`
	TableID   byte   `json:"table_id"`
	ServiceID uint16 `json:"service_id"`
	EventID   uint16 `json:"event_id"`
	Start     string `json:"start,omitempty"`
	Duration  int    `json:"duration_s,omitempty"`
	Title     string `json:"title"`
	Text      string `json:"text"`
	// TitleRaw は記号を [字] などに置き換える前の文字列（Swift 版との突き合わせ用）
	TitleRaw string `json:"title_raw"`
	TextRaw  string `json:"text_raw"`
	Lossless bool   `json:"lossless"`
}

type timeLine struct {
	Kind string `json:"kind"`
	Time string `json:"time"`
}

type handler struct {
	mpegts.IgnoreHandler
	out  *json.Encoder
	seen map[string]bool
}

func (h *handler) OnSection(section mpegts.Section) {
	switch {
	case section.TableID >= isdb.TableIDEITActual && section.TableID <= isdb.TableIDEITScheduleHigh:
		table := isdb.ParseEventTable(section.Data)
		if table == nil {
			return
		}
		// 同じ版の同じセクションは繰り返し届くので、1 度だけ出す
		key := fmt.Sprintf("%x/%d/%d/%d", table.TableID, table.ServiceID, table.Version, table.SectionNumber)
		if h.seen[key] {
			return
		}
		h.seen[key] = true
		for _, event := range table.Events {
			for _, descriptor := range event.Descriptors {
				if descriptor.Tag != isdb.DescriptorTagShortEvent {
					continue
				}
				short, ok := isdb.ParseShortEvent(descriptor.Body)
				if !ok {
					continue
				}
				titleRaw, textRaw, lossless := rawTexts(descriptor.Body)
				line := eventLine{
					Kind: "event", TableID: table.TableID, ServiceID: table.ServiceID, EventID: event.EventID,
					Title: short.Title, Text: short.Text, TitleRaw: titleRaw, TextRaw: textRaw, Lossless: lossless,
				}
				if event.StartKnown {
					line.Start = event.Start.Format(time.RFC3339)
				}
				if event.DurationKnown {
					line.Duration = int(event.Duration / time.Second)
				}
				_ = h.out.Encode(line)
			}
		}
	case section.TableID == isdb.TableIDTOT || section.TableID == isdb.TableIDTDT:
		if table := isdb.ParseTimeTable(section.Data); table != nil {
			_ = h.out.Encode(timeLine{Kind: "time", Time: table.Time.Format(time.RFC3339)})
		}
	}
}

// rawTexts は短形式イベント記述子の番組名と概要を、記号の置き換えをせずに復号する
func rawTexts(body []byte) (string, string, bool) {
	title := int(body[3])
	from := 4 + title
	detail := int(body[from])
	titleResult := isdb.DecodeString(body[4 : 4+title])
	textResult := isdb.DecodeString(body[from+1 : from+1+detail])
	return titleResult.Text, textResult.Text, titleResult.Lossless() && textResult.Lossless()
}

// printJISTable は 2 バイトの全区点（追加記号の 0x75〜0x7E 区を含む）を漢字の集合として復号し、「区点 文字」で出す（Swift 版との突き合わせ用）
func printJISTable() {
	writer := bufio.NewWriter(os.Stdout)
	defer writer.Flush()
	for row := 0x21; row <= 0x7e; row++ {
		for cell := 0x21; cell <= 0x7e; cell++ {
			result := isdb.DecodeString([]byte{0x1b, 0x24, 0x42, byte(row), byte(cell)})
			if result.Lossless() && result.Text != "" {
				fmt.Fprintf(writer, "%02X%02X %s\n", row, cell, result.Text)
			}
		}
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "-jis-table" {
		printJISTable()
		return
	}
	if len(os.Args) > 2 && os.Args[1] == "-captions" {
		if err := printCaptions(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	var input io.Reader = os.Stdin
	if len(os.Args) > 1 {
		file, err := os.Open(os.Args[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer file.Close()
		input = file
	}
	writer := bufio.NewWriter(os.Stdout)
	defer writer.Flush()
	h := &handler{out: json.NewEncoder(writer), seen: map[string]bool{}}
	h.out.SetEscapeHTML(false)
	var demuxer mpegts.Demuxer
	// 地上波の L-EIT・M-EIT（0x27・0x26）は固定の PID なので、何もしなくても読まれる
	buffer := make([]byte, mpegts.PacketSize*readPackets)
	reader := bufio.NewReaderSize(input, len(buffer))
	for {
		n, err := io.ReadFull(reader, buffer)
		for at := 0; at+mpegts.PacketSize <= n; at += mpegts.PacketSize {
			demuxer.Push(buffer[at:at+mpegts.PacketSize], h)
		}
		if err != nil {
			break
		}
	}
	demuxer.Flush(h)
}
