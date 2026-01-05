# Vo

Vo is a lightweight Julia package that runs Agentif-powered sessions via a CLI and an HTTP server.

## HTTP Server

```julia
julia> using Vo
julia> Vo.run_http()
```

Set `ENV["VO_DATA_DIR"] = "/path/to/data"` before starting, then visit http://localhost:8080/.

**Endpoints:**
- `GET /v1/sessions` — List sessions
- `GET /v1/sessions/{id}` — Session details
- `POST /v1/sessions/{id}/evaluate` — Evaluate prompt (`{"prompt": "..."}`)
