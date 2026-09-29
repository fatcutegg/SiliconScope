//go:build linux

//
//  File:      workloads_linux_test.go
//  Created:   2026-09-29
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for recognising a ComfyUI server and reading a container id from a cgroup.
//  Notes:     argv shapes follow kennt-Ubuntu: a host ComfyUI (`venv/bin/python main.py --listen
//             0.0.0.0`) beside a ComfyUI worker container. Run on Linux (`GOOS=linux go test -c`).
//
package main

import "testing"

func TestComfyUIIsRecognisedWithItsPort(t *testing.T) {
	cases := []struct {
		name string
		args []string
		cwd  string
		port int
		ok   bool
	}{
		{"host, default port", []string{"/home/kennt/ComfyUI/venv/bin/python", "main.py", "--listen", "0.0.0.0"}, "/home/kennt/ComfyUI", 8188, true},
		{"explicit port", []string{"python", "main.py", "--port", "8190"}, "/srv/comfyui", 8190, true},
		{"port=form", []string{"python", "/opt/ComfyUI/main.py", "--port=9000"}, "/", 9000, true},
		{"some other main.py", []string{"python", "main.py"}, "/home/kennt/flask-app", 0, false},
		{"ComfyUI path but not the server", []string{"python", "/home/kennt/ComfyUI/tools/convert.py"}, "/home/kennt/ComfyUI", 0, false},
	}
	for _, c := range cases {
		port, ok := comfyUIPort(c.args, c.cwd)
		if ok != c.ok || port != c.port {
			t.Errorf("%s: got (%d, %v), want (%d, %v)", c.name, port, ok, c.port, c.ok)
		}
	}
}

func TestContainerIDFromCgroup(t *testing.T) {
	v2 := "0::/system.slice/docker-c5b2dcd5328a0f1e2d3c4b5a69788776655443322110fedcba9876543210abcd.scope\n"
	v1 := "12:memory:/docker/c5b2dcd5328a0f1e2d3c4b5a69788776655443322110fedcba9876543210abcd\n"
	host := "0::/user.slice/user-1000.slice/session-2.scope\n"
	want := "c5b2dcd5328a0f1e2d3c4b5a69788776655443322110fedcba9876543210abcd"
	if got := containerIDInCgroup.FindString(v2); got != want {
		t.Errorf("cgroup v2: %q", got)
	}
	if got := containerIDInCgroup.FindString(v1); got != want {
		t.Errorf("cgroup v1: %q", got)
	}
	if got := containerIDInCgroup.FindString(host); got != "" {
		t.Errorf("host process read as a container: %q", got)
	}
}

func TestScriptOfNamesThePythonScript(t *testing.T) {
	cases := map[string][]string{
		"halluc_bench.py": {"bin/python", "halluc_bench.py"},
		"server.py":       {"/home/kennt/whisper-bench/bin/python", "-u", "/home/kennt/whisper-bench/server.py", "--port", "9000"},
		"main.py":         {"/home/kennt/ComfyUI/venv/bin/python", "main.py", "--listen", "0.0.0.0"},
		"":                {"python3", "-m", "vllm.entrypoints.openai.api_server"},
	}
	for want, args := range cases {
		if got := scriptOf(args); got != want {
			t.Errorf("%v: got %q, want %q", args, got, want)
		}
	}
	if got := scriptOf([]string{"/usr/local/lib/ollama/llama-server", "--model", "x.py"}); got != "" {
		t.Errorf("not Python, yet named a script: %q", got)
	}
}
