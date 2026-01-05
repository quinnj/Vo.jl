module Vo

using Agentif
using Dates
using Harbor
using HTTP
using JSON
using Logging
using Servo
using Slack
using StructUtils
using Tempus
using UUIDs

const ENV_SLACK_APP_TOKEN = "VO_SLACK_APP_TOKEN"
const ENV_SLACK_BOT_TOKEN = "VO_SLACK_BOT_TOKEN"
const ENV_AGENT_PROVIDER = "VO_AGENT_PROVIDER"
const ENV_AGENT_MODEL = "VO_AGENT_MODEL"
const ENV_AGENT_API_KEY = "VO_AGENT_API_KEY"
const ENV_DATA_DIR = "VO_DATA_DIR"
const ENV_DOCKER_NAME = "VO_DOCKER_NAME"
const ENV_HTTP_HOST = "VO_HTTP_HOST"
const ENV_HTTP_PORT = "VO_HTTP_PORT"
const CONTAINER_CALLBACK_PORT = 1455
const CONTAINER_ROOT = "/data"
const DM_DIR = "dms"
const HTTP_SESSION_DIR = "http-sessions"
const HTTP_SCHEDULED_DIR = "http-scheduled-sessions"
const STREAM_FLUSH_SECONDS = 0.3
const THINKING_PREFIX = "> "
const THINKING_SEPARATOR = "\n\n"
const TEMPUS_STORE_FILENAME = "tempus-store.bin"
const HTTP_SCHEDULED_STORE_FILENAME = "http-scheduled-store.bin"
const SCHEDULED_JOB_PREFIX = "scheduled"
const HTTP_SCHEDULED_JOB_PREFIX = "http-scheduled"
const SCHEDULED_USER = "scheduled"
const SCHEDULED_DISPATCH = Ref{Union{Nothing,Function}}(nothing)
const HTTP_SCHEDULED_DISPATCH = Ref{Union{Nothing,Function}}(nothing)
const CODEX_DEFAULT_TIMEOUT = 600

struct SlackEvent
    channel::String
    user::String
    text::String
    ts::String
    thread_ts::Union{Nothing,String}
    is_dm::Bool
    is_mention::Bool
    team_id::Union{Nothing,String}
    is_scheduled::Bool
end

struct CodexResult
    directory::String
    template_name::String
    session_id::Union{Nothing,String}
    summary::String
    branch::Union{Nothing,String}
    success::Bool
    errors::Vector{String}
end

struct PromptTemplate
    name::String
    prompt::String
    description::String
end

struct ScheduledCodexConfig
    templates::Vector{PromptTemplate}
    directories::Vector{String}
end

struct AgentConfig
    provider::String
    model_id::String
    api_key::String
    prompt::String
    model::Agentif.Model
end

struct AppState
    container_id::String
    container::Union{Nothing,Harbor.Container}
    web_client::Slack.WebClient
    bot_user_id::String
    bot_token::String
    agent_config::AgentConfig
    scheduler::Tempus.Scheduler
    team_id::Union{Nothing,String}
end

mutable struct StreamState
    stream::Union{Nothing,Slack.ChatStream}
    last_flush::Float64
    thinking_started::Bool  # whether we've output the thinking prefix
    has_output::Bool
end

const CHANNEL_LOCK = ReentrantLock()
const CHANNEL_QUEUES = Dict{String,Channel{SlackEvent}}()
const CHANNEL_TASKS = Dict{String,Task}()

function require_env(name::String)
    value = get(() -> nothing, ENV, name)
    (value === nothing || isempty(value)) && error("Missing ENV[$(name)]")
    return String(value)
end

function optional_env(name::String)
    value = get(() -> nothing, ENV, name)
    value === nothing && return nothing
    return String(value)
end

function add_if!(dict::AbstractDict, key::String, value)
    value === nothing && return dict
    dict[key] = value
    return dict
end

function find_container_by_name(name::String)
    ids = Harbor.docker_ps(; all=true)
    for id in ids
        info = Harbor.docker_inspect_container(id)
        inspect_name = get(() -> nothing, info, "Name")
        inspect_name == "/$(name)" && return id
    end
    return nothing
end

function container_running(container_id::String)
    info = Harbor.docker_inspect_container(container_id)
    state = get(() -> nothing, info, "State")
    state isa AbstractDict || return false
    running = get(() -> false, state, "Running")
    return running == true
end

function ensure_container(data_dir::String, name::Union{Nothing,String})
    isdir(data_dir) || mkpath(data_dir)
    Harbor.pull("alpine"; tag="latest")
    if name !== nothing
        existing = find_container_by_name(name)
        if existing !== nothing
            container_running(existing) || Harbor.docker_start(existing)
            return existing, nothing, false
        end
    end
    image = Harbor.Image("alpine", "latest")
    container = Harbor.run!(image; name=name, ports=Dict(CONTAINER_CALLBACK_PORT => CONTAINER_CALLBACK_PORT), volumes=Dict("/data" => data_dir), command=["sh", "-c", "tail -f /dev/null"], detach=true)
    return container.id, container, true
end

function stop_container(container_id::String)
    try
        Harbor.docker_stop(container_id)
    catch err
        @warn "Failed to stop container" container_id exception=(err, catch_backtrace())
    end
end

function container_path(parts::AbstractString...)
    return joinpath(CONTAINER_ROOT, parts...)
end

function exec_container(container_id::String, args::Vector{String})
    return Harbor.docker_exec(container_id, args)
end

function ensure_dir(container_id::String, path::String)
    exec_container(container_id, ["sh", "-c", "mkdir -p \"\$1\"", "sh", path])
    return path
end

function file_exists(container_id::String, path::String)
    output = exec_container(container_id, ["sh", "-c", "if [ -f \"\$1\" ]; then printf yes; fi", "sh", path])
    return strip(output) == "yes"
end

function read_file(container_id::String, path::String)
    return exec_container(container_id, ["sh", "-c", "cat \"\$1\"", "sh", path])
end

function append_line(container_id::String, path::String, line::String)
    dir = dirname(path)
    content = line * "\n"
    exec_container(container_id, ["sh", "-c", "mkdir -p \"\$1\" && printf '%s' \"\$2\" >> \"\$3\"", "sh", dir, content, path])
    return nothing
end

function iso_now()
    return Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
end

function build_agent_prompt()
    return """You are Vo, a Slack bot assistant. Be concise. No emojis.

## Context
- For current date/time, use: date
- You have access to prior conversation history for this thread (user and assistant messages).
- Message logs are stored as JSONL under $(CONTAINER_ROOT), per channel and thread.

## Slack Formatting (mrkdwn, NOT Markdown)
Bold: *text*, Italic: _text_, Code: `code`, Block: ```code```, Links: <url|text>
Do NOT use **double asterisks** or [markdown](links).

## Environment
You operate via tools inside a Docker container (Alpine Linux).
- Bash working directory: $(CONTAINER_ROOT)
- Use relative paths only; absolute paths are not allowed
- Install tools with: apk add <package>
- Your changes persist across sessions

## Workspace Layout
$(CONTAINER_ROOT)/
|-- dms/
|   |-- messages/
|-- <channel-id>/
|   |-- messages/

Each message log is a JSONL file: <message-id>-logs.jsonl
Fields include: created_at, role, content, is_thinking, user, slack_ts, thread_ts.

## Scheduled Prompts
Use the schedule_prompt tool to schedule or cancel prompts.
- action="add": provide prompt and either at (one-time) or schedule (cron)
- action="remove": provide name returned by add
- action="list": list scheduled prompts

One-time (at) format:
- ISO 8601, treated as UTC unless an offset is provided
- Examples: 2025-12-14T09:00:00Z, 2025-12-14T09:00:00+01:00

Repeating (schedule) format:
- Cron: minute hour day-of-month month day-of-week
- Optional seconds field at the start (6 fields total)
- Examples:
  - 0 9 * * * (daily at 09:00 UTC)
  - 0 9 * * 1-5 (weekdays at 09:00 UTC)
  - 30 14 * * 1 (Mondays at 14:30 UTC)

Scheduled prompts post in the channel root.

## Tools
- bash: Run shell commands in $(CONTAINER_ROOT) (relative paths only)
- read: Read files in $(CONTAINER_ROOT)
- write: Create/overwrite files in $(CONTAINER_ROOT)
- edit: Surgical file edits in $(CONTAINER_ROOT)
- ls/find/grep: Inspect files in $(CONTAINER_ROOT)
- schedule_prompt: Schedule or cancel prompts
"""
end

function build_log_entry(role::String, content::String; user=nothing, slack_ts=nothing, thread_ts=nothing, is_thinking=false)
    entry = Dict{String, Any}("created_at" => iso_now(), "role" => role, "content" => content, "is_thinking" => is_thinking)
    add_if!(entry, "user", user)
    add_if!(entry, "slack_ts", slack_ts)
    add_if!(entry, "thread_ts", thread_ts)
    return JSON.json(entry)
end

function message_id(event::SlackEvent)
    return event.thread_ts === nothing ? event.ts : event.thread_ts
end

function storage_channel_id(event::SlackEvent)
    event.is_dm && return DM_DIR
    return event.channel
end

function stream_thread_ts(event::SlackEvent)
    event.is_dm && return nothing
    return message_id(event)
end

function message_log_path(container_id::String, event::SlackEvent)
    channel_dir = storage_channel_id(event)
    messages_dir = container_path(channel_dir, "messages")
    ensure_dir(container_id, messages_dir)
    msg_id = message_id(event)
    return joinpath(messages_dir, string(msg_id, "-logs.jsonl"))
end

function load_log_entries(container_id::String, path::String)
    file_exists(container_id, path) || return JSON.Object[]
    content = read_file(container_id, path)
    isempty(content) && return JSON.Object[]
    lines = split(content, "\n"; keepempty=false)
    entries = JSON.Object[]
    for line in lines
        try
            parsed = JSON.parse(line)
            parsed isa AbstractDict || continue
            push!(entries, parsed)
        catch
        end
    end
    return entries
end

function build_context(entries)
    lines = String[]
    for entry in entries
        role = get(() -> nothing, entry, "role")
        content = get(() -> "", entry, "content")
        is_thinking = get(() -> false, entry, "is_thinking")
        user = get(() -> nothing, entry, "user")
        if role == "user"
            label = user === nothing ? "user" : "user $(user)"
            push!(lines, "[$(label)]: $(content)")
        elseif role == "assistant"
            if is_thinking == true
                push!(lines, "[assistant thinking]: $(content)")
            else
                push!(lines, "[assistant]: $(content)")
            end
        end
    end
    return join(lines, "\n")
end

function build_agent_input(context::String, user_text::String)
    isempty(context) && return user_text
    return "Conversation context:\n" * context * "\n\nCurrent user message:\n" * user_text
end

function normalize_text(text::String)
    cleaned = replace(text, r"<@[^>]+>" => "")
    return strip(cleaned)
end

function slack_ts_leq(a::AbstractString, b::AbstractString)
    a_num = tryparse(Float64, a)
    b_num = tryparse(Float64, b)
    if a_num === nothing || b_num === nothing
        return a <= b
    end
    return a_num <= b_num
end

function parse_app_mention(event::Slack.SlackAppMentionEvent, team_id::Union{Nothing,String})
    event.channel === nothing && return nothing
    event.user === nothing && return nothing
    event.ts === nothing && return nothing
    event.text === nothing && return nothing
    return SlackEvent(
        event.channel,
        event.user,
        normalize_text(event.text),
        event.ts,
        event.thread_ts,
        false,
        true,
        team_id,
        false,
    )
end

function parse_message_event(event::Slack.SlackMessageEvent, bot_user_id::Union{Nothing,String}, team_id::Union{Nothing,String})
    event.channel_type === nothing && return nothing
    event.subtype === nothing || event.subtype == "file_share" || return nothing
    event.bot_id === nothing || return nothing
    event.user === nothing && return nothing
    bot_user_id !== nothing && event.user == bot_user_id && return nothing
    event.channel === nothing && return nothing
    event.ts === nothing && return nothing
    is_dm = event.channel_type == "im" || event.channel_type == "mpim"
    if !is_dm
        event.thread_ts === nothing && return nothing
    end
    return SlackEvent(
        event.channel,
        event.user,
        normalize_text(something(event.text, "")),
        event.ts,
        event.thread_ts,
        is_dm,
        false,
        team_id,
        false,
    )
end

function parse_event(envelope::Slack.SlackEventsApiPayload, bot_user_id::Union{Nothing,String}, default_team_id::Union{Nothing,String})
    envelope.event === nothing && return nothing
    team_id = envelope.team_id === nothing ? default_team_id : envelope.team_id
    event = envelope.event
    if event isa Slack.SlackAppMentionEvent
        return parse_app_mention(event, team_id)
    elseif event isa Slack.SlackMessageEvent
        return parse_message_event(event, bot_user_id, team_id)
    else
        @warn "Unhandled event type: $(typeof(event))"
    end
    return nothing
end

function should_handle_event(state::AppState, event::SlackEvent)
    event.is_dm && return true
    event.is_mention && return true
    event.thread_ts === nothing && return true
    log_path = message_log_path(state.container_id, event)
    return file_exists(state.container_id, log_path)
end

function fetch_thread_messages(client::Slack.WebClient, channel::String, thread_ts::String)
    messages = []
    cursor = nothing
    while true
        resp = if cursor === nothing
            Slack.api_call(client, "conversations.replies"; http_verb="POST", channel=channel, ts=thread_ts, limit=200)
        else
            Slack.api_call(client, "conversations.replies"; http_verb="POST", channel=channel, ts=thread_ts, limit=200, cursor=cursor)
        end
        Slack.validate(resp)
        chunk = get(() -> nothing, resp, "messages")
        chunk isa AbstractVector || break
        append!(messages, chunk)
        has_more = get(() -> false, resp, "has_more")
        has_more == true || break
        metadata = get(() -> nothing, resp, "response_metadata")
        next_cursor = metadata isa AbstractDict ? get(() -> nothing, metadata, "next_cursor") : nothing
        next_cursor === nothing && break
        cursor = String(next_cursor)
        isempty(cursor) && break
    end
    return messages
end

function append_thread_history!(state::AppState, event::SlackEvent, log_path::String)
    event.thread_ts === nothing && return nothing
    messages = fetch_thread_messages(state.web_client, event.channel, event.thread_ts)
    isempty(messages) && return nothing
    for msg in messages
        msg isa AbstractDict || continue
        msg_ts = get(() -> nothing, msg, "ts")
        msg_ts === nothing && continue
        msg_ts = String(msg_ts)
        slack_ts_leq(msg_ts, event.ts) || continue
        msg_ts == event.ts && continue
        bot_id = get(() -> nothing, msg, "bot_id")
        bot_id === nothing || continue
        subtype = get(() -> nothing, msg, "subtype")
        subtype === nothing || subtype == "file_share" || continue
        user = get(() -> nothing, msg, "user")
        user === nothing && continue
        text = get(() -> "", msg, "text")
        content = normalize_text(String(text))
        entry = build_log_entry("user", content; user=String(user), slack_ts=msg_ts, thread_ts=event.thread_ts)
        append_line(state.container_id, log_path, entry)
    end
    return nothing
end

function fetch_auth_info(client::Slack.WebClient)
    resp = Slack.api_call(client, "auth.test"; http_verb="POST")
    Slack.validate(resp)
    user_id = get(() -> nothing, resp, "user_id")
    user_id === nothing && error("Slack auth.test missing user_id")
    team_id = get(() -> nothing, resp, "team_id")
    return String(user_id), team_id === nothing ? nothing : String(team_id)
end

function get_or_create_queue(channel_id::String, worker_fn::Function)
    lock(CHANNEL_LOCK)
    try
        ch = get!(CHANNEL_QUEUES, channel_id) do
            Channel{SlackEvent}(Inf)
        end
        if !haskey(CHANNEL_TASKS, channel_id)
            task = errormonitor(Threads.@spawn worker_fn(channel_id, ch))
            CHANNEL_TASKS[channel_id] = task
        end
        return ch
    finally
        unlock(CHANNEL_LOCK)
    end
end

function shutdown_channel_workers()
    lock(CHANNEL_LOCK)
    try
        for (_, ch) in CHANNEL_QUEUES
            close(ch)
        end
        for (_, task) in CHANNEL_TASKS
            try
                wait(task)
            catch
            end
        end
        empty!(CHANNEL_QUEUES)
        empty!(CHANNEL_TASKS)
    finally
        unlock(CHANNEL_LOCK)
    end
end

function stream_append!(state::StreamState, delta::String; thinking::Bool)
    stream = state.stream
    stream === nothing && return ""
    isempty(delta) && return ""
    text_to_append = if thinking
        if !state.thinking_started
            # Add blockquote prefix only at the very start of thinking content
            state.thinking_started = true
            THINKING_PREFIX * delta
        elseif contains(delta, "\n\n")
            replace(delta, "\n\n" => "\n")
        else
            delta
        end
    else
        if state.thinking_started
            # Transition from thinking to regular output
            state.thinking_started = false
            THINKING_SEPARATOR * delta
        else
            delta
        end
    end
    Slack.append!(stream; markdown_text=text_to_append)
    state.has_output = true
    now = time()
    # if now - state.last_flush >= STREAM_FLUSH_SECONDS
        Slack.flush_buffer!(stream)
        state.last_flush = now
    # end
    return delta
end

function finalize_stream!(state::StreamState)
    stream = state.stream
    stream === nothing && return nothing
    state.has_output || return nothing
    isempty(stream.buffer) || Slack.flush_buffer!(stream)
    Slack.stop!(stream)
    return nothing
end

function scheduler_store_path(data_dir::String)
    return joinpath(data_dir, TEMPUS_STORE_FILENAME)
end

function dispatch_scheduled_prompt(channel_id::String, prompt::String, job_name::String)
    handler = SCHEDULED_DISPATCH[]
    handler === nothing && return nothing
    handler(channel_id, prompt, job_name)
    return nothing
end

function generate_job_name()
    return string(SCHEDULED_JOB_PREFIX, "-", uuid4())
end

function normalize_job_name(name::String)
    cleaned = replace(strip(name), r"[^A-Za-z0-9_-]" => "-")
    isempty(cleaned) && throw(ArgumentError("name is required"))
    return cleaned
end

function job_exists(store::Tempus.Store, name::String)
    jobs = Tempus.getJobs(store)
    for job in jobs
        job.name == name && return true
    end
    return false
end

function parse_at_datetime(value::String)
    cleaned = strip(value)
    isempty(cleaned) && throw(ArgumentError("at is required"))
    match_result = match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?$", cleaned)
    match_result === nothing && throw(ArgumentError("invalid at timestamp: $(value)"))
    date_part = match_result.captures[1]
    time_part = match_result.captures[2]
    seconds_part = match_result.captures[3]
    tz_part = match_result.captures[4]
    seconds = seconds_part === nothing ? "00" : seconds_part
    dt = DateTime("$(date_part)T$(time_part):$(seconds)", dateformat"yyyy-mm-ddTHH:MM:SS")
    offset_minutes = 0
    if tz_part !== nothing
        if tz_part == "Z"
            offset_minutes = 0
        else
            sign = tz_part[1]
            hours = parse(Int, tz_part[2:3])
            minutes = parse(Int, tz_part[5:6])
            offset_minutes = hours * 60 + minutes
            sign == '-' && (offset_minutes = -offset_minutes)
        end
    end
    return dt - Dates.Minute(offset_minutes)
end

function cron_from_datetime(dt::DateTime)
    return "$(Dates.second(dt)) $(Dates.minute(dt)) $(Dates.hour(dt)) $(Dates.day(dt)) $(Dates.month(dt)) *"
end

function get_default_prompt_templates()
    return PromptTemplate[
        PromptTemplate(
            "fix_issue",
            "Review the codebase and identify any issues or bugs. Fix any problems you find. Use the GitHub CLI to create a feature branch, commit your changes with descriptive messages, and push the branch to the remote (but do NOT open a PR).",
            "Find and fix bugs in the codebase"
        ),
        PromptTemplate(
            "look_for_bugs",
            "Audit the code for potential issues, edge cases, security vulnerabilities, or areas that could be improved. Report your findings and, if possible, fix any issues. Use the GitHub CLI to create a feature branch, commit your changes with descriptive messages, and push the branch to the remote (but do NOT open a PR).",
            "Audit code for potential issues"
        ),
        PromptTemplate(
            "implement_feature",
            "Review the codebase and suggest a useful feature that could be added. Implement the feature with tests and documentation. Use the GitHub CLI to create a feature branch, commit your changes with descriptive messages, and push the branch to the remote (but do NOT open a PR).",
            "Add new functionality"
        ),
        PromptTemplate(
            "improve_tests",
            "Review the test coverage and add comprehensive tests for untested functionality. Use the GitHub CLI to create a feature branch, commit your changes with descriptive messages, and push the branch to the remote (but do NOT open a PR).",
            "Improve test coverage"
        ),
        PromptTemplate(
            "refactor",
            "Review the code and refactor it for better readability, performance, or maintainability. Ensure all tests still pass. Use the GitHub CLI to create a feature branch, commit your changes with descriptive messages, and push the branch to the remote (but do NOT open a PR).",
            "Improve code quality"
        ),
    ]
end

function get_default_directories()
    return filter(isdir, [
        "/Users/jacob.quinn/.julia/dev/Vo",
        "/Users/jacob.quinn/.julia/dev/Agentif",
        "/Users/jacob.quinn/.julia/dev/Slack",
    ])
end

function run_codex_on_directory(template::PromptTemplate, directory::String; timeout::Int=CODEX_DEFAULT_TIMEOUT)
    codex_tool = Agentif.create_codex_tool()
    try
        result = codex_tool.func(template.prompt, directory, timeout)
        return CodexResult(
            directory,
            template.name,
            get(() -> nothing, result, "session_id"),
            get(() -> "", result, "summary"),
            get(() -> nothing, result, "branch"),
            get(() -> false, result, "success"),
            get(() -> String[], result, "errors"),
        )
    catch err
        return CodexResult(
            directory,
            template.name,
            nothing,
            "",
            nothing,
            false,
            [sprint(showerror, err)],
        )
    end
end

function run_codex_batch(config::ScheduledCodexConfig; timeout::Int=CODEX_DEFAULT_TIMEOUT)
    tasks = Task[]
    results_channel = Channel{CodexResult}(length(config.templates) * length(config.directories))
    total_tasks = length(config.templates) * length(config.directories)

    for template in config.templates
        for directory in config.directories
            task = errormonitor(Threads.@spawn begin
                result = run_codex_on_directory(template, directory; timeout)
                put!(results_channel, result)
            end)
            push!(tasks, task)
        end
    end

    results = CodexResult[]
    for i in 1:total_tasks
        push!(results, take!(results_channel))
    end

    for task in tasks
        try
            wait(task)
        catch
        end
    end

    return results
end

function generate_codex_report(results::Vector{CodexResult})::String
    lines = String[]
    push!(lines, "=" ^ 80)
    push!(lines, "CODEX BATCH EXECUTION REPORT")
    push!(lines, "=" ^ 80)
    push!(lines, "")

    total = length(results)
    successes = count(r -> r.success, results)
    failures = total - successes

    push!(lines, "Summary:")
    push!(lines, "  Total runs: $(total)")
    push!(lines, "  Successful: $(successes)")
    push!(lines, "  Failed: $(failures)")
    push!(lines, "")

    if total > 0
        push!(lines, "Results by Template:")
        template_groups = Dict{String,Vector{CodexResult}}()
        for result in results
            group = get!(template_groups, result.template_name) do
                CodexResult[]
            end
            push!(group, result)
        end

        for (template_name, template_results) in sort(collect(template_groups))
            push!(lines, "")
            push!(lines, "  Template: $(template_name)")
            for result in template_results
                status = result.success ? "✓ SUCCESS" : "✗ FAILED"
                push!(lines, "    $(status) - $(result.directory)")
                if result.session_id !== nothing
                    push!(lines, "      Session ID: $(result.session_id)")
                end
                if result.branch !== nothing
                    push!(lines, "      Branch: $(result.branch)")
                end
                if !isempty(result.summary)
                    summary_lines = split(result.summary, "\n")
                    for (idx, line) in enumerate(summary_lines[1:min(3, length(summary_lines))])
                        push!(lines, "      Summary: $(strip(line))")
                    end
                    if length(summary_lines) > 3
                        push!(lines, "      ...")
                    end
                end
                if !isempty(result.errors)
                    for err in result.errors
                        err_lines = split(err, "\n")
                        for (idx, line) in enumerate(err_lines[1:min(2, length(err_lines))])
                            push!(lines, "      Error: $(strip(line))")
                        end
                    end
                end
            end
        end
    end

    push!(lines, "")
    push!(lines, "=" ^ 80)

    return join(lines, "\n")
end

function run_scheduled_codex(templates::Union{Nothing,Vector{PromptTemplate}}=nothing, directories::Union{Nothing,Vector{String}}=nothing; timeout::Int=CODEX_DEFAULT_TIMEOUT)
    templates_value = templates === nothing ? get_default_prompt_templates() : templates
    directories_value = directories === nothing ? get_default_directories() : directories

    println("Starting scheduled Codex batch execution...")
    println("Templates: $(join([t.name for t in templates_value], ", "))")
    println("Directories: $(join(directories_value, ", "))")
    println("")

    config = ScheduledCodexConfig(templates_value, directories_value)
    results = run_codex_batch(config; timeout)

    report = generate_codex_report(results)
    println(report)

    return results
end

function normalize_schedule(schedule::Union{Nothing,String})
    schedule === nothing && throw(ArgumentError("schedule is required"))
    cleaned = strip(schedule)
    isempty(cleaned) && throw(ArgumentError("schedule is required"))
    Tempus.parseCron(cleaned)
    return cleaned
end

function format_scheduled_jobs(store::Tempus.Store)
    jobs = collect(Tempus.getJobs(store))
    isempty(jobs) && return "No scheduled prompts."
    sort!(jobs, by=job -> job.name)
    lines = String[]
    for job in jobs
        schedule = job.schedule === nothing ? "one-shot" : string(job.schedule)
        status = Tempus.isdisabled(job) ? " disabled" : ""
        push!(lines, "$(job.name): $(schedule)$(status)")
    end
    return join(lines, "\n")
end

function add_scheduled_prompt!(state::AppState, channel_id::String, prompt::String; name::Union{Nothing,String}=nothing, schedule::Union{Nothing,String}=nothing, at::Union{Nothing,String}=nothing)
    prompt_value = strip(prompt)
    isempty(prompt_value) && throw(ArgumentError("prompt is required"))
    job_name = name === nothing ? generate_job_name() : normalize_job_name(name)
    job_exists(state.scheduler.store, job_name) && throw(ArgumentError("job already exists: $(job_name)"))
    schedule === nothing && at === nothing && throw(ArgumentError("provide schedule or at"))
    schedule !== nothing && at !== nothing && throw(ArgumentError("provide only one of schedule or at"))
    if at !== nothing
        dt = parse_at_datetime(at)
        dt <= Dates.now(Dates.UTC) && throw(ArgumentError("at must be in the future (UTC)"))
        cron = cron_from_datetime(dt)
        Tempus.parseCron(cron)
        job = Tempus.Job(() -> dispatch_scheduled_prompt(channel_id, prompt_value, job_name), job_name, cron; max_executions=1)
    else
        schedule_value = normalize_schedule(schedule)
        job = Tempus.Job(() -> dispatch_scheduled_prompt(channel_id, prompt_value, job_name), job_name, schedule_value)
    end
    push!(state.scheduler, job)
    return job_name
end

function remove_scheduled_prompt!(scheduler::Tempus.Scheduler, name::String)
    job_name = normalize_job_name(name)
    Tempus.purgeJob!(scheduler.store, job_name)
    @lock scheduler.lock begin
        filter!(job_exec -> job_exec.job.name != job_name, scheduler.jobExecutions)
    end
    return job_name
end

function enqueue_scheduled_prompt!(state::AppState, channel_id::String, prompt::String, job_name::String)
    event = SlackEvent(channel_id, SCHEDULED_USER, prompt, job_name, nothing, false, false, state.team_id, true)
    ch = get_or_create_queue(channel_id, (channel, queue) -> channel_worker(channel, queue, state))
    put!(ch, event)
    return nothing
end

function schedule_prompt_tool(state::AppState, event::SlackEvent)
    channel_id = event.channel
    return @tool(
        "Schedule or cancel a prompt. Use action=\"add\" with prompt and either at (one-time) or schedule (cron). Use action=\"remove\" with name. Use action=\"list\" to list jobs.",
        schedule_prompt(action::String, name::Union{Nothing,String}, prompt::Union{Nothing,String}, schedule::Union{Nothing,String}, at::Union{Nothing,String}) = begin
            action_value = lowercase(strip(action))
            if action_value == "add"
                prompt === nothing && throw(ArgumentError("prompt is required"))
                job_name = add_scheduled_prompt!(state, channel_id, prompt; name=name, schedule=schedule, at=at)
                return "Scheduled prompt with name: $(job_name)"
            elseif action_value == "remove"
                name === nothing && throw(ArgumentError("name is required"))
                job_name = normalize_job_name(name)
                job_exists(state.scheduler.store, job_name) || return "No scheduled prompt found with name: $(job_name)"
                job_name = remove_scheduled_prompt!(state.scheduler, job_name)
                return "Removed scheduled prompt: $(job_name)"
            elseif action_value == "list"
                return format_scheduled_jobs(state.scheduler.store)
            end
            throw(ArgumentError("Unknown action: $(action). Use add, remove, or list."))
        end,
    )
end

function build_sandboxed_tools(container_id::String)
    return Agentif.AgentTool[
        Agentif.create_sandboxed_read_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_bash_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_edit_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_write_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_grep_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_find_tool(container_id, CONTAINER_ROOT),
        Agentif.create_sandboxed_ls_tool(container_id, CONTAINER_ROOT),
    ]
end

function build_tools(state::AppState, event::SlackEvent)
    tools = build_sandboxed_tools(state.container_id)
    push!(tools, schedule_prompt_tool(state, event))
    return tools
end

function evaluate_with_stream(agent::Agentif.Agent, input::String, stream_state::StreamState, assistant_text::IOBuffer, assistant_thinking::IOBuffer)
    agent_error = Ref{Union{Nothing,String}}(nothing)
    try
        Agentif.evaluate(agent, input) do agent_event
            if agent_event isa Agentif.AgentErrorEvent
                agent_error[] = sprint(showerror, agent_event.error)
            elseif agent_event isa Agentif.MessageUpdateEvent && agent_event.role == :assistant
                if agent_event.kind == :reasoning
                    appended = stream_append!(stream_state, agent_event.delta; thinking=true)
                    isempty(appended) || write(assistant_thinking, appended)
                elseif agent_event.kind == :text || agent_event.kind == :refusal
                    appended = stream_append!(stream_state, agent_event.delta; thinking=false)
                    isempty(appended) || write(assistant_text, appended)
                end
            end
        end
    catch err
        agent_error[] = sprint(showerror, err)
    end
    return agent_error[]
end

function evaluate_buffered(agent::Agentif.Agent, input::String, assistant_text::IOBuffer, assistant_thinking::IOBuffer)
    agent_error = Ref{Union{Nothing,String}}(nothing)
    try
        Agentif.evaluate(agent, input) do agent_event
            if agent_event isa Agentif.AgentErrorEvent
                agent_error[] = sprint(showerror, agent_event.error)
            elseif agent_event isa Agentif.MessageUpdateEvent && agent_event.role == :assistant
                if agent_event.kind == :reasoning
                    isempty(agent_event.delta) || write(assistant_thinking, agent_event.delta)
                elseif agent_event.kind == :text || agent_event.kind == :refusal
                    isempty(agent_event.delta) || write(assistant_text, agent_event.delta)
                end
            end
        end
    catch err
        agent_error[] = sprint(showerror, err)
    end
    return agent_error[]
end

function format_scheduled_message(thinking_text::String, assistant_text::String, error_text::Union{Nothing,String})
    output = ""
    if !isempty(thinking_text)
        output = THINKING_PREFIX * replace(thinking_text, "\n\n" => "\n")
    end
    text_value = assistant_text
    if error_text !== nothing && isempty(text_value)
        text_value = error_text
        error_text = nothing
    end
    if !isempty(text_value)
        if isempty(output)
            output = text_value
        else
            output *= THINKING_SEPARATOR * text_value
        end
    end
    if error_text !== nothing
        output = isempty(output) ? error_text : output * "\n" * error_text
    end
    return output
end

function handle_scheduled_event(event::SlackEvent, state::AppState)
    log_path = message_log_path(state.container_id, event)
    entries = load_log_entries(state.container_id, log_path)
    context = build_context(entries)
    input = build_agent_input(context, event.text)
    user_entry = build_log_entry("user", event.text; user=event.user, slack_ts=nothing, thread_ts=message_id(event))
    append_line(state.container_id, log_path, user_entry)
    assistant_text = IOBuffer()
    assistant_thinking = IOBuffer()
    tools = build_tools(state, event)
    agent = Agentif.Agent(; prompt=state.agent_config.prompt, model=state.agent_config.model, input_guardrail=nothing, tools, apikey=state.agent_config.api_key)
    agent_error = evaluate_buffered(agent, input, assistant_text, assistant_thinking)
    thinking_text = String(take!(assistant_thinking))
    assistant_text_value = String(take!(assistant_text))
    error_text = agent_error === nothing ? nothing : "Error: " * agent_error
    output = format_scheduled_message(thinking_text, assistant_text_value, error_text)
    assistant_ts = Ref{Union{Nothing,String}}(nothing)
    if !isempty(output)
        resp = Slack.chat_post_message(state.web_client; channel=event.channel, text=output)
        Slack.validate(resp)
        ts = get(() -> nothing, resp, "ts")
        assistant_ts[] = ts === nothing ? nothing : String(ts)
    end
    if !isempty(thinking_text)
        entry = build_log_entry("assistant", thinking_text; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=true)
        append_line(state.container_id, log_path, entry)
    end
    if !isempty(assistant_text_value)
        entry = build_log_entry("assistant", assistant_text_value; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=false)
        append_line(state.container_id, log_path, entry)
    end
    if error_text !== nothing && isempty(assistant_text_value)
        entry = build_log_entry("assistant", error_text; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=false)
        append_line(state.container_id, log_path, entry)
    end
    return nothing
end

function handle_event(event::SlackEvent, state::AppState)
    event.is_scheduled && return handle_scheduled_event(event, state)
    log_path = message_log_path(state.container_id, event)
    if event.is_mention && event.thread_ts !== nothing && !file_exists(state.container_id, log_path)
        try
            append_thread_history!(state, event, log_path)
        catch err
            @warn "Failed to backfill thread history" channel=event.channel thread_ts=event.thread_ts exception=(err, catch_backtrace())
        end
    end
    entries = load_log_entries(state.container_id, log_path)
    context = build_context(entries)
    input = build_agent_input(context, event.text)
    user_entry = build_log_entry("user", event.text; user=event.user, slack_ts=event.ts, thread_ts=message_id(event))
    append_line(state.container_id, log_path, user_entry)
    assistant_text = IOBuffer()
    assistant_thinking = IOBuffer()
    agent_error = Ref{Union{Nothing,String}}(nothing)
    assistant_ts = Ref{Union{Nothing,String}}(nothing)
    recipient_team_id = event.team_id === nothing ? state.team_id : event.team_id
    recipient_user_id = event.user
    tools = build_tools(state, event)
    Slack.ChatStream(
        state.web_client;
        channel=event.channel,
        thread_ts=stream_thread_ts(event),
        token=state.bot_token,
        recipient_team_id=recipient_team_id,
        recipient_user_id=recipient_user_id,
        buffer_size=256,
    ) do stream
        stream_state = StreamState(stream, time(), false, false)
        agent = Agentif.Agent(; prompt=state.agent_config.prompt, model=state.agent_config.model, input_guardrail=nothing, tools, apikey=state.agent_config.api_key)
        agent_error[] = evaluate_with_stream(agent, input, stream_state, assistant_text, assistant_thinking)
        error_text = agent_error[] === nothing ? nothing : "Error: " * agent_error[]
        error_text !== nothing && stream_append!(stream_state, "\n" * error_text; thinking=false)
        finalize_stream!(stream_state)
        assistant_ts[] = stream.stream_ts
    end
    thinking_text = String(take!(assistant_thinking))
    assistant_text_value = String(take!(assistant_text))
    error_text = agent_error[] === nothing ? nothing : "Error: " * agent_error[]
    if !isempty(thinking_text)
        entry = build_log_entry("assistant", thinking_text; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=true)
        append_line(state.container_id, log_path, entry)
    end
    if !isempty(assistant_text_value)
        entry = build_log_entry("assistant", assistant_text_value; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=false)
        append_line(state.container_id, log_path, entry)
    end
    if error_text !== nothing && isempty(assistant_text_value)
        entry = build_log_entry("assistant", error_text; slack_ts=assistant_ts[], thread_ts=message_id(event), is_thinking=false)
        append_line(state.container_id, log_path, entry)
    end
    return nothing
end

function channel_worker(channel_id::String, ch::Channel{SlackEvent}, state::AppState)
    for event in ch
        try
            should_handle_event(state, event) || continue
            handle_event(event, state)
        catch err
            @error "Channel worker error" channel=channel_id exception=(err, catch_backtrace())
        end
    end
    return nothing
end

function socket_request_handler(state::AppState, socket_client::Slack.SocketModeClient, request::Slack.SocketModeRequest)
    request.envelope_id === nothing && return nothing
    Slack.ack!(socket_client, request)
    request.type == "events_api" || return nothing
    request.payload === nothing && return nothing
    event = parse_event(request.payload, state.bot_user_id, state.team_id)
    event === nothing && return nothing
    ch = get_or_create_queue(event.channel, (channel_id, channel) -> channel_worker(channel_id, channel, state))
    put!(ch, event)
    return nothing
end

function main()
    app_token = require_env(ENV_SLACK_APP_TOKEN)
    bot_token = require_env(ENV_SLACK_BOT_TOKEN)
    provider = require_env(ENV_AGENT_PROVIDER)
    model_id = require_env(ENV_AGENT_MODEL)
    api_key = require_env(ENV_AGENT_API_KEY)
    data_dir = require_env(ENV_DATA_DIR)
    docker_name = optional_env(ENV_DOCKER_NAME)
    prompt = build_agent_prompt()
    model = Agentif.getModel(provider, model_id)
    model === nothing && error("Unknown model provider=$(provider) model_id=$(model_id)")
    container_id, container, created = ensure_container(data_dir, docker_name)
    scheduler = Tempus.Scheduler(Tempus.FileStore(scheduler_store_path(data_dir)))
    scheduler_task = nothing
    try
        web_client = Slack.WebClient(token=bot_token)
        bot_user_id, team_id = fetch_auth_info(web_client)
        agent_config = AgentConfig(provider, model_id, api_key, prompt, model)
        state = AppState(container_id, container, web_client, bot_user_id, bot_token, agent_config, scheduler, team_id)
        SCHEDULED_DISPATCH[] = (channel_id, prompt_text, job_name) -> enqueue_scheduled_prompt!(state, channel_id, prompt_text, job_name)
        scheduler_task = errormonitor(Threads.@spawn Tempus.run!(scheduler))
        Slack.run!(app_token; web_client=web_client, auto_reconnect=true) do client, request
            socket_request_handler(state, client, request)
        end
    finally
        SCHEDULED_DISPATCH[] = nothing
        try
            Tempus.close(scheduler)
        catch err
            @warn "Failed to close scheduler" exception=(err, catch_backtrace())
        end
        scheduler_task !== nothing && (try
            wait(scheduler_task)
        catch
        end)
        shutdown_channel_workers()
        created && stop_container(container_id)
    end
    return nothing
end

include("http_server.jl")

end
