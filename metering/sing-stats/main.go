// sing-stats: tiny gRPC client for sing-box's v2ray_api StatsService.
//
// Nodes have no grpcurl, and the service name is easy to get wrong by hand,
// so this imports the generated stub from the sing-box module itself and
// lets the module own the names.
//
// Caveat that cost a live test: the generated client constants say
// "/experimental.v2rayapi.StatsService/QueryStats" (stats.proto package), but
// experimental/v2rayapi/stats.go has an init() that rewrites
// StatsService_ServiceDesc.ServiceName to "v2ray.core.app.stats.command.
// StatsService" for V2Ray tooling compatibility, and that is what the server
// registers. Calling the generated NewStatsServiceClient therefore returns
// Unimplemented ("unknown service experimental.v2rayapi.StatsService") against
// a real sing-box. So the method path is derived at runtime from the
// ServiceDesc the package init() has already patched, and the request/response
// messages still come from the generated stub. Whatever upstream renames it to
// next, this follows.
//
// Usage:
//
//	sing-stats [-listen 127.0.0.1:10085] [-reset] [-timeout 5s]
//
// -listen is the value of experimental.v2ray_api.listen in the node config;
// the sing-monitor.sh template (hydra utils/server.rs) passes it through as
// `sing-stats -listen "$LISTEN" -reset`. -addr is accepted as an alias.
//
// Prints one JSON object on stdout mapping every user counter with a non-zero
// value to its byte counts since the last reset:
//
//	{"<user>":{"up":123,"down":456},...}
//
// "up" is what the client sent (inbound uplink), "down" what it received.
// With -reset the counters are swapped to zero atomically as they are read,
// which is what the harvest path in sing-monitor.sh relies on. Users with
// zero on both directions are omitted so the heartbeat body stays small.
//
// Exit status is non-zero (and stdout empty) on any error so a shell caller
// can treat failure as "nothing harvested" and leave its pending file alone.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/sagernet/sing-box/experimental/v2rayapi"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	userPrefix   = "user>>>"
	trafficInfix = ">>>traffic>>>"
)

type counters struct {
	Up   int64 `json:"up"`
	Down int64 `json:"down"`
}

func main() {
	addr := flag.String("listen", "127.0.0.1:10085", "v2ray_api gRPC listen address (experimental.v2ray_api.listen)")
	flag.StringVar(addr, "addr", "127.0.0.1:10085", "alias of -listen")
	reset := flag.Bool("reset", false, "zero each counter as it is read")
	timeout := flag.Duration("timeout", 5*time.Second, "overall RPC timeout")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	// sing-box serves the API in plaintext on a loopback listener.
	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fail("dial: %v", err)
	}
	defer conn.Close()

	// "/<service>/QueryStats", with <service> read from the (init-patched)
	// ServiceDesc rather than the stale generated FullMethodName constant.
	method := "/" + v2rayapi.StatsService_ServiceDesc.ServiceName + "/QueryStats"
	req := &v2rayapi.QueryStatsRequest{
		Patterns: []string{userPrefix},
		Reset_:   *reset,
	}
	resp := &v2rayapi.QueryStatsResponse{}
	if err := conn.Invoke(ctx, method, req, resp); err != nil {
		fail("QueryStats (%s): %v", method, err)
	}

	users := make(map[string]*counters)
	for _, stat := range resp.GetStat() {
		name := stat.GetName()
		if !strings.HasPrefix(name, userPrefix) {
			continue
		}
		rest := strings.TrimPrefix(name, userPrefix)
		idx := strings.LastIndex(rest, trafficInfix)
		if idx < 0 {
			continue
		}
		user := rest[:idx]
		direction := rest[idx+len(trafficInfix):]
		c, ok := users[user]
		if !ok {
			c = &counters{}
			users[user] = c
		}
		switch direction {
		case "uplink":
			c.Up += stat.GetValue()
		case "downlink":
			c.Down += stat.GetValue()
		}
	}
	for user, c := range users {
		if c.Up == 0 && c.Down == 0 {
			delete(users, user)
		}
	}

	out, err := json.Marshal(users)
	if err != nil {
		fail("encode: %v", err)
	}
	fmt.Println(string(out))
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "sing-stats: "+format+"\n", args...)
	os.Exit(1)
}
