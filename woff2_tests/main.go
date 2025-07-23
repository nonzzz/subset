package main

import (
	"bytes"
	"io/ioutil"
	"log"

	"dmitri.shuralyov.com/font/woff2"
)

func main() {
	fd, err := ioutil.ReadFile("./test.woff2")
	if err != nil {
		log.Fatal(err)
	}
	println(len(fd))
	r := bytes.NewReader(fd)
	woff2Data, err := woff2.Parse(r)
	if err != nil {
		log.Fatal(err)
	}
	println("Parsed WOFF2 data successfully")
	println(&woff2Data.Header)
}
