package main

import (
	"flag"
	"log"
	"net/http"
	"os"
)

func main() {

	static := flag.String("static", "../frontend/dist", "built frontend directory")
	port := flag.String("port", "8050", "TCP port")

	flag.Parse()

	if p := os.Getenv("PORT"); p != "" {

		*port = p

	}

	mux := http.NewServeMux()

	mux.Handle("/", http.FileServer(http.Dir(*static)))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {

		w.Write([]byte("ok\n"))

	})

	log.Printf("GraniteOS web  →  http://localhost:%s", *port)
	log.Fatal(http.ListenAndServe(":"+*port, coopHeaders(mux)))

}

// coopHeaders sets the headers required for SharedArrayBuffer (needed for QEMU-WASM SMP).
func coopHeaders(next http.Handler) http.Handler {

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {

		w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")

		next.ServeHTTP(w, r)

	})

}
