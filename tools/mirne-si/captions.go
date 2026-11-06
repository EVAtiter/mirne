// 字幕の突き合わせ：字幕 PES の中身を 1 行 1 つ（16 進）で書いたファイルを、coax の
// pkg/isdb/caption で読んで置き、mirne-probe captions --pes と同じ書式で出す。
//
//	mirne-si -captions corpus.txt
//
// 管理データはその種類（字幕・文字スーパー）の Presenter で画面を整え、本文データはそれで置く。
// 文字は Unicode のスカラー値の 16 進で出す（文字列の正規化の違いを比べないため）。言語コードの不正なバイトは
// Swift 版と同じく 1 バイトずつ置換文字（U+FFFD）にする。
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/Till0196/coax/pkg/isdb/caption"
)

func colorText(c caption.Color) string {
	return fmt.Sprintf("%d,%d,%d,%d", c.R, c.G, c.B, c.A)
}

func printCaptions(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	presenters := map[caption.Kind]*caption.Presenter{
		caption.KindCaption:     caption.NewPresenter(caption.KindCaption),
		caption.KindSuperimpose: caption.NewPresenter(caption.KindSuperimpose),
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 1<<24)
	index := 0
	for scanner.Scan() {
		payload, err := hex.DecodeString(strings.TrimSpace(scanner.Text()))
		if err != nil {
			return err
		}
		group, ok := caption.ParsePES(payload)
		if !ok {
			fmt.Fprintf(out, "G %d -\n", index)
			index++
			continue
		}
		p := presenters[group.Kind]
		if group.Management != nil {
			m := group.Management
			var languages []string
			for _, l := range m.Languages {
				languages = append(languages, fmt.Sprintf("%d:%d:%s:%d:%d:%d", l.Tag, l.DMF, string([]rune(string(l.ISO[:]))), l.Format, l.TCS, l.Rollup))
			}
			fmt.Fprintf(out, "G %d M kind=%d id=%d tmd=%d langs=%s units=%d\n", index, group.Kind, group.ID, m.TMD, strings.Join(languages, ","), len(m.Units))
			p.Manage(m)
			index++
			continue
		}
		s := group.Statement
		stm := "-"
		if s.HasSTM {
			stm = fmt.Sprint(s.STM)
		}
		fmt.Fprintf(out, "G %d S kind=%d id=%d tmd=%d stm=%s units=%d\n", index, group.Kind, group.ID, s.TMD, stm, len(s.Units))
		layout := p.Present(s)
		after := "-"
		if layout.HasClearAfterMS {
			after = fmt.Sprint(layout.ClearAfterMS)
		}
		motion := "-"
		if layout.Motion != nil {
			m := layout.Motion
			motion = fmt.Sprintf("%d,%d,%d,%d,%d,%d", m.FromX, m.FromY, m.ToX, m.ToY, m.DelayMS, m.DurationMS)
		}
		clear := 0
		if layout.Clear {
			clear = 1
		}
		fmt.Fprintf(out, "L screen=%dx%d area=%d,%d,%d,%d clear=%d after=%s raster=%s sound=%d motion=%s\n",
			layout.ScreenW, layout.ScreenH, layout.AreaX, layout.AreaY, layout.AreaW, layout.AreaH, clear, after,
			colorText(layout.Raster), layout.Sound, motion)
		for _, t := range layout.Texts {
			outline := "-"
			if t.HasOutline {
				outline = colorText(t.Outline)
			}
			until := "-"
			if t.HasUntilMS {
				until = fmt.Sprint(t.UntilMS)
			}
			var scalars []string
			for _, r := range t.Text {
				scalars = append(scalars, fmt.Sprintf("%X", r))
			}
			fmt.Fprintf(out, "T %d,%d %d,%d %d,%d fg=%s bg=%s ol=%s flash=%d enc=%d delay=%d until=%s %s\n",
				t.X, t.Y, t.CellW, t.CellH, t.SizeW, t.SizeH, colorText(t.Fg), colorText(t.Bg), outline,
				t.Flash, t.Enclosure, t.DelayMS, until, strings.Join(scalars, " "))
		}
		runes := make([]rune, 0, len(layout.DRCS))
		for r := range layout.DRCS {
			runes = append(runes, r)
		}
		sort.Slice(runes, func(i, j int) bool { return runes[i] < runes[j] })
		for _, r := range runes {
			var glyphs []string
			for _, g := range layout.DRCS[r] {
				var bitmap strings.Builder
				for _, level := range g.Bitmap {
					fmt.Fprintf(&bitmap, "%x", level)
				}
				glyphs = append(glyphs, fmt.Sprintf("%dx%d/%d/%s", g.Width, g.Height, g.Levels, bitmap.String()))
			}
			fmt.Fprintf(out, "D %X %s\n", r, strings.Join(glyphs, " "))
		}
		index++
	}
	return scanner.Err()
}
