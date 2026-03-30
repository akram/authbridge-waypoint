// demo-agent is a minimal HTTP service that acts as the "agent" in the
// user→agent→tool flow. It receives a user token and forwards it to
// downstream tools. The waypoint's ext_authz intercepts each request,
// validates the JWT, and exchanges it for a tool-scoped token before
// the request reaches the tool.
//
// Routes:
//
//	GET /call/{tool-name}  → forwards to http://{tool-name}.{TOOL_NS}.svc.cluster.local:8080/
//	GET /healthz           → health check
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var (
	toolNS     string
	httpClient = &http.Client{Timeout: 10 * time.Second}
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	toolNS = os.Getenv("TOOL_NS")
	if toolNS == "" {
		toolNS = "tool-ns"
	}

	http.HandleFunc("/call/", handleCall)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("demo-agent listening on :%s, tool namespace: %s", port, toolNS)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// handleCall forwards the request to any tool by name.
// GET /call/echo-tool  → http://echo-tool.tool-ns.svc.cluster.local:8080/
// GET /call/time-tool  → http://time-tool.tool-ns.svc.cluster.local:8080/
func handleCall(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/call/")
	if name == "" {
		http.Error(w, `{"error":"usage: /call/{tool-name}"}`, http.StatusBadRequest)
		return
	}

	token := r.Header.Get("Authorization")
	if token == "" {
		http.Error(w, `{"error":"no token provided: set Authorization header"}`, http.StatusBadRequest)
		return
	}

	toolURL := fmt.Sprintf("http://%s.%s.svc.cluster.local:8080/", name, toolNS)

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, toolURL, nil)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"creating request: %v"}`, err), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Authorization", token)

	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"calling %s: %v"}`, name, err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"reading %s response: %v"}`, name, err), http.StatusInternalServerError)
		return
	}

	// tool_response_raw must be valid JSON for encoding. Envoy/plain-text errors are not JSON;
	// wrapping avoids Encode failure and empty responses to clients.
	var toolRaw json.RawMessage
	if json.Valid(body) {
		toolRaw = json.RawMessage(body)
	} else {
		wrapped, err := json.Marshal(map[string]string{"non_json_body": string(body)})
		if err != nil {
			toolRaw = json.RawMessage(`{"non_json_body":""}`)
		} else {
			toolRaw = wrapped
		}
	}

	result := map[string]any{
		"agent_action":      "called " + name,
		"tool_url":          toolURL,
		"tool_status":       resp.StatusCode,
		"tool_response_raw": toolRaw,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(result); err != nil {
		log.Printf("encode /call/%s response: %v", name, err)
		http.Error(w, `{"error":"internal encoding error"}`, http.StatusInternalServerError)
	}
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
