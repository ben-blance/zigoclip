package main

import (
	"flag"
	"log"

	"zigoclip/internal/agent"	
)

func main() {
	name := flag.String("name", "client", "device name")
	flag.Parse()

	a, err := agent.New(*name)
	if err != nil {
		log.Fatal(err)
	}

	a.Run()
}