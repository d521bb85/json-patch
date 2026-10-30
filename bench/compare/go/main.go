package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	jsonpatch "github.com/evanphx/json-patch/v5"
)

func main() {
	dir := os.Args[1]
	millis, _ := strconv.Atoi(os.Args[2])
	min := time.Duration(millis) * time.Millisecond
	for _, name := range os.Args[3:] {
		doc, _ := os.ReadFile(dir + "/" + name + ".doc.json")
		patchText, _ := os.ReadFile(dir + "/" + name + ".patch.json")
		var times []int64
		var result []byte
		failed := false
		started := time.Now()
		for len(times) < 5 || time.Since(started) < min {
			start := time.Now()
			patch, err := jsonpatch.DecodePatch(patchText)
			if err != nil {
				panic(err)
			}
			result, err = patch.Apply(doc)
			if err != nil {
				fmt.Fprintln(os.Stderr, name, err)
				failed = true
				break
			}
			times = append(times, time.Since(start).Nanoseconds())
		}
		if failed {
			fmt.Println(name, "FAILED")
			continue
		}
		sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
		os.WriteFile(dir+"/out/go."+name+".json", result, 0o644)
		fmt.Println(name, times[len(times)/2])
	}
}
