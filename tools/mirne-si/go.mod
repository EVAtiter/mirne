module mirne/tools/mirne-si

go 1.26.0

require github.com/Till0196/coax v0.0.0

require golang.org/x/text v0.43.0 // indirect

// coax は scripts/fetch-coax.sh が build/coax-src に取り出したもの（scripts/coax.lock のコミット）を使う
replace github.com/Till0196/coax => ../../build/coax-src
