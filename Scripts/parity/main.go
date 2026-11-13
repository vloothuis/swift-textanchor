// Command parity runs the Go textanchor library on a fixed corpus and writes
// the results as JSON fixtures for the Swift tests.
//
//	cd Scripts/parity && go run .
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/vloothuis/textanchor"
	"github.com/vloothuis/textanchor/quotefind"
)

type span struct {
	Doc   string `json:"doc"`
	Start int    `json:"start"`
	End   int    `json:"end"`
}

type anchorCase struct {
	span
	Anchor textanchor.Anchor `json:"anchor"`
}

type resolution struct {
	Anchor       int     `json:"anchor"`
	Target       string  `json:"target"`
	Range        []int   `json:"range"`
	Confidence   float64 `json:"confidence"`
	OrphanReason string  `json:"orphan_reason"`
}

type rendered struct {
	Source string `json:"source"`
	Text   string `json:"text"`
	Map    []int  `json:"map"`
}

type findCase struct {
	Doc    string `json:"doc"`
	Quote  string `json:"quote"`
	Prefix string `json:"prefix"`
	Suffix string `json:"suffix"`
	Range  []int  `json:"range"`
}

type segmentCase struct {
	span
	Segments [][]int `json:"segments"`
}

// rng is a small deterministic generator, so fixtures are stable.
type rng uint64

func (r *rng) next(n int) int {
	*r = *r*6364136223846793005 + 1442695040888963407
	return int(uint64(*r>>33) % uint64(n))
}

func snap(s string, i int) int {
	for i > 0 && i < len(s) && !utf8.RuneStart(s[i]) {
		i--
	}
	return i
}

// spans picks ranges of several lengths across the document.
func spans(doc string, seed rng, n int) [][2]int {
	lengths := []int{4, 12, 40, 120, 400}
	var out [][2]int
	for k := 0; k < n; k++ {
		l := lengths[seed.next(len(lengths))]
		if l >= len(doc) {
			l = len(doc) / 2
		}
		s := snap(doc, seed.next(len(doc)-l))
		e := snap(doc, s+l)
		if strings.TrimSpace(doc[s:e]) == "" {
			continue
		}
		out = append(out, [2]int{s, e})
	}
	return out
}

var edits = []struct {
	name string
	f    func(string) string
}{
	{"unchanged", func(s string) string { return s }},
	{"paragraph inserted", func(s string) string { return "A new opening paragraph.\n\n" + s }},
	{"words changed", func(s string) string {
		r := strings.NewReplacer("the ", "a ", "and ", "or ", "is ", "was ")
		return r.Replace(s)
	}},
	{"rewrapped", func(s string) string { return strings.ReplaceAll(s, ". ", ".\n") }},
	{"first half deleted", func(s string) string {
		i := strings.Index(s[len(s)/2:], "\n\n")
		if i < 0 {
			return s
		}
		return s[len(s)/2+i+2:]
	}},
	{"sections swapped", func(s string) string {
		parts := strings.Split(s, "\n## ")
		if len(parts) < 3 {
			return s
		}
		parts[1], parts[2] = parts[2], parts[1]
		return strings.Join(parts, "\n## ")
	}},
}

var snippets = []string{
	"foo \nbar", "foo   \nbar", "**bold**\nnext", "hard\\\nbreak", "see www.example.com now",
	"a `x\ny` b", "a ``  x  `` b", "- item\n\n      code in list\n", "> ```\n> q code\n> ```\n",
	"Setext\n======\n\nbody", "![alt *t*](img.png) end", "a\r\nb", "x <span>html</span> y",
	"<div>\nblock\n</div>\n\nafter", "* a\n* b\n\n  continued", "1) one\n2) two", "# H #\n",
	"Text &copy; &#169; \\_x\\_", "~~gone~~ kept", "- [ ] todo\n- [x] done", "",
}

func main() {
	names, _ := filepath.Glob("docs/*.md")
	sort.Strings(names)
	docs := map[string]string{}
	var order []string
	for _, n := range names {
		b, err := os.ReadFile(n)
		if err != nil {
			panic(err)
		}
		name := strings.TrimSuffix(filepath.Base(n), ".md")
		docs[name] = string(b)
		order = append(order, name)
	}

	targets := map[string]string{}
	var anchors []anchorCase
	var resolutions []resolution
	var segs []segmentCase
	var finds []findCase
	var renders []rendered

	for di, name := range order {
		doc := docs[name]
		for _, sp := range spans(doc, rng(di+1), 40) {
			a, err := textanchor.New(doc, sp[0], sp[1], nil)
			if err != nil {
				continue
			}
			idx := len(anchors)
			anchors = append(anchors, anchorCase{span{name, sp[0], sp[1]}, a})
			for _, e := range edits {
				key := name + "/" + e.name
				target := e.f(doc)
				targets[key] = target
				res := textanchor.Resolve(target, a, nil)
				r := resolution{Anchor: idx, Target: key, Confidence: res.Confidence, OrphanReason: res.OrphanReason}
				if res.Range != nil {
					r.Range = []int{res.Range.Start, res.Range.End}
				}
				resolutions = append(resolutions, r)
			}
			sc := segmentCase{span: span{name, sp[0], sp[1]}, Segments: [][]int{}}
			for _, r := range quotefind.Segments(doc, sp[0], sp[1]) {
				sc.Segments = append(sc.Segments, []int{r.Start, r.End})
			}
			segs = append(segs, sc)
		}

		// Selections in the rendered text, as a browser reports them.
		text, _ := quotefind.RenderedTextWithMapping(doc)
		for _, sp := range spans(text, rng(100+di), 40) {
			quote := strings.TrimSpace(text[sp[0]:sp[1]])
			if quote == "" {
				continue
			}
			p := snap(text, max(0, sp[0]-50))
			e := snap(text, min(len(text), sp[1]+50))
			for _, ctx := range [][2]string{{"", ""}, {text[p:sp[0]], text[sp[1]:e]}} {
				fc := findCase{Doc: name, Quote: quote, Prefix: ctx[0], Suffix: ctx[1]}
				if s, e, ok := quotefind.FindWithContext(doc, quote, ctx[0], ctx[1]); ok {
					fc.Range = []int{s, e}
				}
				finds = append(finds, fc)
			}
		}
	}

	for _, s := range append(snippets, order...) {
		src := s
		if d, ok := docs[s]; ok {
			src = d
		}
		text, m := quotefind.RenderedTextWithMapping(src)
		renders = append(renders, rendered{src, text, m})
	}

	write("../../Tests/TextAnchorTests/Fixtures/parity.json", map[string]any{
		"docs": docs, "targets": targets, "anchors": anchors, "resolutions": resolutions,
	})
	write("../../Tests/QuoteFindTests/Fixtures/parity.json", map[string]any{
		"rendered": renders, "find": finds, "segments": segs, "docs": docs,
	})
}

func write(path string, v any) {
	b, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
		panic(err)
	}
}
