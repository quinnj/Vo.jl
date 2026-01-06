@kwarg mutable struct StoredSession
    id::String
    title::Union{Nothing,String} = nothing
    created_at::String
    updated_at::String
    state::Agentif.AgentState = Agentif.AgentState()
    responding::Bool = false
    pending_user::Union{Nothing,String} = nothing
    pending_assistant::Union{Nothing,String} = nothing
    pending_reasoning::Union{Nothing,String} = nothing
    pending_eval_id::Union{Nothing,String} = nothing
    pending_eval_started_at::Union{Nothing,String} = nothing
end

@kwarg mutable struct ScheduledSession
    id::String
    title::Union{Nothing,String} = nothing
    prompt::Union{Nothing,String} = nothing
    schedule::Union{Nothing,String} = nothing
    is_valid::Bool = false
    created_at::String
    updated_at::String
    session_ids::Vector{String} = String[]
end

@kwarg mutable struct ToolCallEntry
    call_id::String
    name::String
    arguments::String
    requested_at::Int64
    started_at::Union{Nothing,Int64} = nothing
    finished_at::Union{Nothing,Int64} = nothing
    duration_ms::Union{Nothing,Int64} = nothing
    output::Union{Nothing,String} = nothing
    is_error::Union{Nothing,Bool} = nothing
end

@kwarg struct NewSessionRequest
    title::Union{Nothing,String} = nothing
end

@kwarg struct UpdateSessionRequest
    title::Union{Nothing,String} = nothing
end

@kwarg struct NewScheduledSessionRequest
    title::Union{Nothing,String} = nothing
    prompt::Union{Nothing,String} = nothing
    schedule::Union{Nothing,String} = nothing
end

@kwarg struct UpdateScheduledSessionRequest
    title::Union{Nothing,String} = nothing
    prompt::Union{Nothing,String} = nothing
    schedule::Union{Nothing,String} = nothing
end

struct HttpState
    sessions_dir::String
    scheduled_dir::String
    scheduler::Tempus.Scheduler
    agent_config::AgentConfig
    tools::Vector{Agentif.AgentTool}
    base_dir::String
end

const SESSION_LOCKS = Dict{String,ReentrantLock}()
const SESSION_LOCKS_GUARD = ReentrantLock()
const SCHEDULED_LOCKS = Dict{String,ReentrantLock}()
const SCHEDULED_LOCKS_GUARD = ReentrantLock()

function session_lock(session_id::String)
    lock(SESSION_LOCKS_GUARD)
    try
        lock_obj = get!(SESSION_LOCKS, session_id) do
            ReentrantLock()
        end
        return lock_obj
    finally
        unlock(SESSION_LOCKS_GUARD)
    end
end

function with_session_lock(f::Function, session_id::String)
    lock_obj = session_lock(session_id)
    lock(lock_obj)
    try
        return f()
    finally
        unlock(lock_obj)
    end
end

function scheduled_lock(scheduled_id::String)
    lock(SCHEDULED_LOCKS_GUARD)
    try
        lock_obj = get!(SCHEDULED_LOCKS, scheduled_id) do
            ReentrantLock()
        end
        return lock_obj
    finally
        unlock(SCHEDULED_LOCKS_GUARD)
    end
end

function with_scheduled_lock(f::Function, scheduled_id::String)
    lock_obj = scheduled_lock(scheduled_id)
    lock(lock_obj)
    try
        return f()
    finally
        unlock(lock_obj)
    end
end

function http_host(default::String="0.0.0.0")
    value = optional_env(ENV_HTTP_HOST)
    return value === nothing ? default : value
end

function http_port(default::Int=8080)
    value = optional_env(ENV_HTTP_PORT)
    return value === nothing ? default : parse(Int, value)
end

function build_http_prompt(base_dir::String)
    return """You are Vo, an assistant. Be concise. No emojis.

## Context
- For current date/time, use: date
- You have access to prior conversation history for this session.

## Workspace
Base directory: $(base_dir)
- Use relative paths only; absolute paths are not allowed.

## Tools
- read, write, edit, grep, find, ls, bash
- codex: run Codex CLI on a directory
"""
end

function build_http_tools(base_dir::String)
    tools = Agentif.coding_tools(base_dir)
    append!(tools, Agentif.AgentTool[
        Agentif.create_grep_tool(base_dir),
        Agentif.create_find_tool(base_dir),
        Agentif.create_ls_tool(base_dir),
    ])
    push!(tools, Agentif.create_codex_tool())
    return tools
end

function build_http_state(; data_dir::Union{Nothing,String}=nothing, base_dir::Union{Nothing,String}=nothing)
    data_dir_value = data_dir === nothing ? require_env(ENV_DATA_DIR) : data_dir
    base_dir_value = base_dir === nothing ? pwd() : base_dir
    sessions_dir = joinpath(data_dir_value, HTTP_SESSION_DIR)
    isdir(sessions_dir) || mkpath(sessions_dir)
    scheduled_dir = joinpath(data_dir_value, HTTP_SCHEDULED_DIR)
    isdir(scheduled_dir) || mkpath(scheduled_dir)
    provider = require_env(ENV_AGENT_PROVIDER)
    model_id = require_env(ENV_AGENT_MODEL)
    api_key = require_env(ENV_AGENT_API_KEY)
    model = Agentif.getModel(provider, model_id)
    model === nothing && error("Unknown model provider=$(provider) model_id=$(model_id)")
    prompt = build_http_prompt(abspath(base_dir_value))
    agent_config = AgentConfig(provider, model_id, api_key, prompt, model)
    tools = build_http_tools(abspath(base_dir_value))
    scheduler_store = Tempus.FileStore(joinpath(data_dir_value, HTTP_SCHEDULED_STORE_FILENAME))
    scheduler = Tempus.Scheduler(scheduler_store)
    return HttpState(sessions_dir, scheduled_dir, scheduler, agent_config, tools, abspath(base_dir_value))
end

function ensure_http_session_id(session_id::String)
    isempty(session_id) && throw(ArgumentError("session_id is required"))
    occursin(r"[\\/]", session_id) && throw(ArgumentError("session_id must not contain path separators: $(session_id)"))
    return session_id
end

function session_file_path(sessions_dir::String, session_id::String)
    sid = ensure_http_session_id(session_id)
    return joinpath(sessions_dir, "$(sid).json")
end

function ensure_http_scheduled_id(scheduled_id::String)
    isempty(scheduled_id) && throw(ArgumentError("scheduled_id is required"))
    occursin(r"[\\/]", scheduled_id) && throw(ArgumentError("scheduled_id must not contain path separators: $(scheduled_id)"))
    return scheduled_id
end

function scheduled_session_file_path(scheduled_dir::String, scheduled_id::String)
    sid = ensure_http_scheduled_id(scheduled_id)
    return joinpath(scheduled_dir, "$(sid).json")
end

function save_session!(sessions_dir::String, session::StoredSession)
    return with_session_lock(session.id) do
        isdir(sessions_dir) || mkpath(sessions_dir)
        path = session_file_path(sessions_dir, session.id)
        tmp_path = path * "." * string(UUIDs.uuid4()) * ".tmp"
        open(tmp_path, "w") do io
            write(io, JSON.json(session))
        end
        mv(tmp_path, path; force=true)
        return nothing
    end
end

function save_scheduled_session!(scheduled_dir::String, session::ScheduledSession)
    return with_scheduled_lock(session.id) do
        isdir(scheduled_dir) || mkpath(scheduled_dir)
        path = scheduled_session_file_path(scheduled_dir, session.id)
        tmp_path = path * "." * string(UUIDs.uuid4()) * ".tmp"
        open(tmp_path, "w") do io
            write(io, JSON.json(session))
        end
        mv(tmp_path, path; force=true)
        return nothing
    end
end

function load_session_file(path::String)
    try
        return JSON.parsefile(path, StoredSession)
    catch err
        @warn "Failed to parse session file" path exception=(err, catch_backtrace())
        return nothing
    end
end

function load_scheduled_session_file(path::String)
    try
        return JSON.parsefile(path, ScheduledSession)
    catch err
        @warn "Failed to parse scheduled session file" path exception=(err, catch_backtrace())
        return nothing
    end
end

function get_session(sessions_dir::String, session_id::String)
    path = session_file_path(sessions_dir, session_id)
    isfile(path) || return nothing
    return load_session_file(path)
end

function get_scheduled_session(scheduled_dir::String, scheduled_id::String)
    path = scheduled_session_file_path(scheduled_dir, scheduled_id)
    isfile(path) || return nothing
    return load_scheduled_session_file(path)
end

function list_sessions(sessions_dir::String)
    isdir(sessions_dir) || return StoredSession[]
    sessions = StoredSession[]
    for path in readdir(sessions_dir; join=true)
        endswith(path, ".json") || continue
        session = load_session_file(path)
        session === nothing && continue
        push!(sessions, session)
    end
    sort!(sessions; by=session -> session.updated_at, rev=true)
    return sessions
end

function scheduled_run_ids(scheduled_dir::String)
    ids = Set{String}()
    for scheduled in list_scheduled_sessions(scheduled_dir)
        for session_id in scheduled.session_ids
            push!(ids, session_id)
        end
    end
    return ids
end

function list_user_sessions(state::HttpState)
    sessions = list_sessions(state.sessions_dir)
    scheduled_ids = scheduled_run_ids(state.scheduled_dir)
    isempty(scheduled_ids) && return sessions
    filter!(session -> !(session.id in scheduled_ids), sessions)
    return sessions
end

function list_scheduled_sessions(scheduled_dir::String)
    isdir(scheduled_dir) || return ScheduledSession[]
    sessions = ScheduledSession[]
    for path in readdir(scheduled_dir; join=true)
        endswith(path, ".json") || continue
        session = load_scheduled_session_file(path)
        session === nothing && continue
        push!(sessions, session)
    end
    sort!(sessions; by=session -> session.updated_at, rev=true)
    return sessions
end

function new_session(sessions_dir::String; title::Union{Nothing,String}=nothing)
    session_id = string(UUIDs.uuid4())
    now = iso_now()
    clean_title = normalize_title(title)
    session = StoredSession(; id=session_id, title=clean_title, created_at=now, updated_at=now, state=Agentif.AgentState())
    save_session!(sessions_dir, session)
    return session
end

function delete_session(sessions_dir::String, session_id::String)
    path = session_file_path(sessions_dir, session_id)
    isfile(path) || return false
    rm(path)
    return true
end

function utc_offset_minutes()
    local_now = Dates.now()
    utc_now = Dates.now(UTC)
    diff = local_now - utc_now
    return Int(div(Dates.value(diff), 60000))
end

function default_schedule_utc()
    offset_minutes = utc_offset_minutes()
    local_now = Dates.now()
    local_target = DateTime(Dates.year(local_now), Dates.month(local_now), Dates.day(local_now), 4, 0, 0)
    utc_target = local_target - Dates.Minute(offset_minutes)
    return "$(Dates.minute(utc_target)) $(Dates.hour(utc_target)) * * *"
end

function normalize_prompt(prompt::Union{Nothing,String})
    prompt === nothing && return nothing
    cleaned = strip(prompt)
    isempty(cleaned) && return nothing
    return String(cleaned)
end

function normalize_schedule_input(schedule::Union{Nothing,String})
    schedule === nothing && return nothing
    cleaned = strip(schedule)
    isempty(cleaned) && return nothing
    return String(cleaned)
end

function scheduled_session_valid(prompt::Union{Nothing,String}, schedule::Union{Nothing,String})
    prompt_value = normalize_prompt(prompt)
    prompt_value === nothing && return false
    schedule_value = normalize_schedule_input(schedule)
    schedule_value === nothing && return false
    try
        Tempus.parseCron(schedule_value)
    catch
        return false
    end
    return true
end

function scheduled_job_name(scheduled_id::String)
    return "$(HTTP_SCHEDULED_JOB_PREFIX)-$(scheduled_id)"
end

function scheduled_id_from_job(job_name::String)
    prefix = "$(HTTP_SCHEDULED_JOB_PREFIX)-"
    startswith(job_name, prefix) || return nothing
    return job_name[(lastindex(prefix) + 1):end]
end

function scheduled_jobs_by_name(store::Tempus.Store, job_name::String)
    jobs = Tempus.Job[]
    for entry in Tempus.getJobs(store)
        entry.name == job_name && push!(jobs, entry)
    end
    return jobs
end

function remove_scheduled_job!(scheduler::Tempus.Scheduler, job_name::String)
    jobs = scheduled_jobs_by_name(scheduler.store, job_name)
    isempty(jobs) && return nothing
    for job in jobs
        Tempus.purgeJob!(scheduler.store, job)
    end
    @lock scheduler.lock begin
        filter!(job_exec -> job_exec.job.name != job_name, scheduler.jobExecutions)
    end
    return nothing
end

function new_scheduled_session(scheduled_dir::String; title::Union{Nothing,String}=nothing, prompt::Union{Nothing,String}=nothing, schedule::Union{Nothing,String}=nothing)
    scheduled_id = string(UUIDs.uuid4())
    now = iso_now()
    clean_title = normalize_title(title)
    prompt_value = normalize_prompt(prompt)
    schedule_value = normalize_schedule_input(schedule)
    schedule_value === nothing && (schedule_value = default_schedule_utc())
    is_valid = scheduled_session_valid(prompt_value, schedule_value)
    session = ScheduledSession(; id=scheduled_id, title=clean_title, prompt=prompt_value, schedule=schedule_value, is_valid=is_valid, created_at=now, updated_at=now, session_ids=String[])
    if session.title === nothing && session.prompt !== nothing
        session.title = derive_title(session.prompt)
    end
    save_scheduled_session!(scheduled_dir, session)
    return session
end

function delete_scheduled_session(state::HttpState, scheduled_id::String)
    path = scheduled_session_file_path(state.scheduled_dir, scheduled_id)
    isfile(path) || return false
    rm(path)
    job_name = scheduled_job_name(scheduled_id)
    job_exists(state.scheduler.store, job_name) && remove_scheduled_job!(state.scheduler, job_name)
    return true
end

function add_scheduled_session_run!(scheduled_dir::String, scheduled::ScheduledSession, session_id::String)
    return with_scheduled_lock(scheduled.id) do
        latest = get_scheduled_session(scheduled_dir, scheduled.id)
        latest === nothing && (latest = scheduled)
        pushfirst!(latest.session_ids, session_id)
        latest.updated_at = iso_now()
        save_scheduled_session!(scheduled_dir, latest)
        return latest
    end
end

function scheduled_session_in_progress(sessions_dir::String, scheduled::ScheduledSession)
    for session_id in scheduled.session_ids
        session = get_session(sessions_dir, session_id)
        session === nothing && continue
        session.responding && return true
    end
    return false
end

function sync_scheduled_job!(state::HttpState, scheduled::ScheduledSession)
    job_name = scheduled_job_name(scheduled.id)
    jobs = scheduled_jobs_by_name(state.scheduler.store, job_name)
    if !scheduled.is_valid
        isempty(jobs) || remove_scheduled_job!(state.scheduler, job_name)
        return nothing
    end
    schedule_value = normalize_schedule_input(scheduled.schedule)
    if schedule_value === nothing
        scheduled.is_valid = false
        scheduled.updated_at = iso_now()
        save_scheduled_session!(state.scheduled_dir, scheduled)
        isempty(jobs) || remove_scheduled_job!(state.scheduler, job_name)
        return nothing
    end
    cron = try
        Tempus.parseCron(schedule_value)
    catch
        scheduled.is_valid = false
        scheduled.updated_at = iso_now()
        save_scheduled_session!(state.scheduled_dir, scheduled)
        isempty(jobs) || remove_scheduled_job!(state.scheduler, job_name)
        return nothing
    end
    if length(jobs) == 1
        existing = jobs[1]
        if existing.schedule == cron && !Tempus.isdisabled(existing)
            return nothing
        end
    end
    isempty(jobs) || remove_scheduled_job!(state.scheduler, job_name)
    job = Tempus.Job(() -> dispatch_http_scheduled_session(scheduled.id), job_name, cron)
    push!(state.scheduler, job)
    return nothing
end

function sync_http_scheduler!(state::HttpState)
    sessions = list_scheduled_sessions(state.scheduled_dir)
    valid_ids = Set{String}()
    for scheduled in sessions
        computed_valid = scheduled_session_valid(scheduled.prompt, scheduled.schedule)
        if computed_valid != scheduled.is_valid
            scheduled.is_valid = computed_valid
            scheduled.updated_at = iso_now()
            save_scheduled_session!(state.scheduled_dir, scheduled)
        end
        scheduled.is_valid && push!(valid_ids, scheduled.id)
        sync_scheduled_job!(state, scheduled)
    end
    for job in Tempus.getJobs(state.scheduler.store)
        scheduled_id = scheduled_id_from_job(job.name)
        scheduled_id === nothing && continue
        scheduled_id in valid_ids && continue
        remove_scheduled_job!(state.scheduler, job.name)
    end
    return nothing
end

function update_scheduled_session!(state::HttpState, scheduled_id::String; title::Union{Nothing,String}=nothing, prompt::Union{Nothing,String}=nothing, schedule::Union{Nothing,String}=nothing)
    return with_scheduled_lock(scheduled_id) do
        scheduled = get_scheduled_session(state.scheduled_dir, scheduled_id)
        scheduled === nothing && return nothing
        if title !== nothing
            scheduled.title = normalize_title(title)
        end
        if prompt !== nothing
            scheduled.prompt = normalize_prompt(prompt)
            if scheduled.title === nothing && scheduled.prompt !== nothing
                scheduled.title = derive_title(scheduled.prompt)
            end
        end
        if schedule !== nothing
            scheduled.schedule = normalize_schedule_input(schedule)
        end
        scheduled.is_valid = scheduled_session_valid(scheduled.prompt, scheduled.schedule)
        scheduled.updated_at = iso_now()
        save_scheduled_session!(state.scheduled_dir, scheduled)
        sync_scheduled_job!(state, scheduled)
        return scheduled
    end
end

function begin_session_response!(sessions_dir::String, session_id::String, prompt::AbstractString)
    return with_session_lock(session_id) do
        session = get_session(sessions_dir, session_id)
        session === nothing && return nothing
        session.responding && return nothing
        session.responding = true
        session.pending_user = String(prompt)
        session.pending_assistant = nothing
        session.pending_reasoning = nothing
        session.pending_eval_id = string(UUIDs.uuid4())
        session.pending_eval_started_at = nothing
        last_msg = isempty(session.state.messages) ? nothing : session.state.messages[end]
        if !(last_msg isa Agentif.UserMessage && last_msg.text == session.pending_user)
            push!(session.state.messages, Agentif.UserMessage(session.pending_user))
        end
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function finalize_session_response!(sessions_dir::String, session::StoredSession)
    return with_session_lock(session.id) do
        session.responding = false
        session.pending_user = nothing
        session.pending_assistant = nothing
        session.pending_reasoning = nothing
        session.pending_eval_id = nothing
        session.pending_eval_started_at = nothing
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function mark_session_eval_started!(sessions_dir::String, session::StoredSession)
    return with_session_lock(session.id) do
        session.pending_eval_started_at === nothing || return nothing
        session.pending_eval_started_at = iso_now()
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function append_pending_assistant!(sessions_dir::String, session::StoredSession, delta::String)
    return with_session_lock(session.id) do
        if session.pending_assistant === nothing
            session.pending_assistant = delta
        else
            session.pending_assistant *= delta
        end
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function append_pending_reasoning!(sessions_dir::String, session::StoredSession, delta::String)
    return with_session_lock(session.id) do
        if session.pending_reasoning === nothing
            session.pending_reasoning = delta
        else
            session.pending_reasoning *= delta
        end
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function commit_pending_output!(sessions_dir::String, session::StoredSession)
    return with_session_lock(session.id) do
        text_value = session.pending_assistant === nothing ? "" : session.pending_assistant
        reasoning_value = session.pending_reasoning === nothing ? "" : session.pending_reasoning
        isempty(text_value) && isempty(reasoning_value) && return session
        message = Agentif.AssistantMessage(; text=text_value, reasoning=reasoning_value, kind="text")
        append_session_message!(sessions_dir, session, message)
        return session
    end
end

function update_session_title!(sessions_dir::String, session_id::String, title::Union{Nothing,String})
    return with_session_lock(session_id) do
        session = get_session(sessions_dir, session_id)
        session === nothing && return nothing
        cleaned = normalize_title(title)
        if cleaned === nothing
            fallback = ""
            if !isempty(session.state.messages)
                fallback = latest_message_text(session.state.messages)
            end
            session.title = derive_title(fallback)
        else
            session.title = cleaned
        end
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function normalize_title(title::Union{Nothing,String})
    title === nothing && return nothing
    cleaned = strip(title)
    isempty(cleaned) && return nothing
    return cleaned
end

function truncate_text(text::AbstractString, max_len::Int)
    cleaned = strip(text)
    isempty(cleaned) && return ""
    if length(cleaned) <= max_len
        return cleaned
    end
    return rstrip(first(cleaned, max_len)) * "..."
end

function compact_text(text::AbstractString)
    cleaned = strip(text)
    isempty(cleaned) && return ""
    return replace(cleaned, r"\s+" => " ")
end

const TOOL_CALL_SNIPPET_MAX_LEN = 140
const TOOL_RESULT_SNIPPET_MAX_LEN = 160
const STREAM_FINAL_ORDER_OFFSET = 10000000000000

function tool_call_request_snippet(entry::ToolCallEntry)
    args = compact_text(entry.arguments)
    isempty(args) && return "(no args)"
    return truncate_text(args, TOOL_CALL_SNIPPET_MAX_LEN)
end

function tool_call_result_snippet(output::AbstractString)
    cleaned = compact_text(output)
    isempty(cleaned) && return "(empty output)"
    return truncate_text(cleaned, TOOL_RESULT_SNIPPET_MAX_LEN)
end

function tool_call_full_request(entry::ToolCallEntry)
    isempty(strip(entry.arguments)) && return entry.name
    return "$(entry.name)\n$(entry.arguments)"
end

function format_duration_seconds(duration_ms::Union{Nothing,Int64})
    duration_ms === nothing && return ""
    seconds = duration_ms / 1000
    return string(round(seconds; digits=2), "s")
end

function split_tool_event_text(text::AbstractString)
    parts = split(String(text), '\n'; limit=2)
    title = parts[1]
    content = length(parts) > 1 ? parts[2] : ""
    return title, content
end

function append_session_message!(sessions_dir::String, session::StoredSession, message::Agentif.AgentMessage)
    return with_session_lock(session.id) do
        push!(session.state.messages, message)
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function tool_call_entry_from_message(message::Agentif.AssistantMessage)
    message.kind == "tool" || return nothing
    try
        return JSON.parse(message.text, ToolCallEntry)
    catch
        return nothing
    end
end

function tool_call_message(entry::ToolCallEntry)
    return Agentif.AssistantMessage(; text=JSON.json(entry), kind="tool")
end

function find_tool_call_message_index(messages::Vector{Agentif.AgentMessage}, call_id::String)
    for (idx, msg) in pairs(messages)
        msg isa Agentif.AssistantMessage || continue
        entry = tool_call_entry_from_message(msg)
        entry === nothing && continue
        entry.call_id == call_id && return idx
    end
    return nothing
end

function find_tool_call_entry(messages::Vector{Agentif.AgentMessage}, call_id::String)
    idx = find_tool_call_message_index(messages, call_id)
    idx === nothing && return nothing
    message = messages[idx]::Agentif.AssistantMessage
    return tool_call_entry_from_message(message)
end

function upsert_tool_call_entry!(sessions_dir::String, session::StoredSession, entry::ToolCallEntry)
    return with_session_lock(session.id) do
        messages = session.state.messages
        idx = find_tool_call_message_index(messages, entry.call_id)
        if idx === nothing
            push!(messages, tool_call_message(entry))
        else
            msg = messages[idx]::Agentif.AssistantMessage
            msg.text = JSON.json(entry)
        end
        session.updated_at = iso_now()
        save_session!(sessions_dir, session)
        return session
    end
end

function tool_call_entry_from_request(event::Agentif.ToolCallRequestEvent, existing::Union{Nothing,ToolCallEntry})
    if existing === nothing
        return ToolCallEntry(; call_id=event.tool_call.call_id, name=event.tool_call.name, arguments=event.tool_call.arguments, requested_at=event.timestamp)
    end
    existing.name = event.tool_call.name
    existing.arguments = event.tool_call.arguments
    existing.requested_at = min(existing.requested_at, event.timestamp)
    return existing
end

function tool_call_entry_from_start(event::Agentif.ToolExecutionStartEvent, existing::Union{Nothing,ToolCallEntry})
    entry = existing === nothing ? ToolCallEntry(; call_id=event.tool_call.call_id, name=event.tool_call.name, arguments=event.tool_call.arguments, requested_at=event.timestamp) : existing
    entry.started_at = event.timestamp
    return entry
end

function tool_call_entry_from_end(event::Agentif.ToolExecutionEndEvent, existing::Union{Nothing,ToolCallEntry})
    entry = existing === nothing ? ToolCallEntry(; call_id=event.tool_call.call_id, name=event.tool_call.name, arguments=event.tool_call.arguments, requested_at=event.timestamp) : existing
    entry.finished_at = event.timestamp
    entry.duration_ms = event.duration_ms
    entry.output = event.result.output
    entry.is_error = event.result.is_error
    if entry.started_at === nothing && entry.duration_ms !== nothing
        entry.started_at = max(0, event.timestamp - entry.duration_ms)
    end
    return entry
end

function append_error_message!(sessions_dir::String, session::StoredSession, message::AbstractString)
    error_text = isempty(message) ? "Error" : String(message)
    entry = Agentif.AssistantMessage(; text=error_text, kind="error")
    return append_session_message!(sessions_dir, session, entry)
end

function derive_title(prompt::String)
    cleaned = strip(prompt)
    isempty(cleaned) && return "New Session"
    first_line = split(cleaned, '\n'; limit=2)[1]
    return truncate_text(first_line, 60)
end

function session_id_label(session_id::String)
    short = length(session_id) > 8 ? first(session_id, 8) : session_id
    return "id: $(short)"
end

function message_text(msg::Agentif.AgentMessage)
    if msg isa Agentif.UserMessage
        return msg.text
    elseif msg isa Agentif.AssistantMessage
        msg.kind == "tool" && return ""
        return isempty(msg.text) ? msg.refusal : msg.text
    end
    return ""
end

function string_delta(new_text::String, old_text::String)
    isempty(old_text) && return new_text
    new_text == old_text && return ""
    startswith(new_text, old_text) || return new_text
    start_idx = nextind(new_text, lastindex(old_text))
    start_idx > lastindex(new_text) && return ""
    return new_text[start_idx:end]
end

function latest_message_text(messages::Vector{Agentif.AgentMessage})
    for msg in Iterators.reverse(messages)
        text = message_text(msg)
        isempty(text) && continue
        return text
    end
    return ""
end

function session_title(session::StoredSession)
    title = normalize_title(session.title)
    return title === nothing ? "New Session" : title
end

function session_preview(session::StoredSession)
    messages = session.state.messages
    isempty(messages) && return "No messages yet"
    text = latest_message_text(messages)
    isempty(text) && return "No messages yet"
    return truncate_text(text, 96)
end

function scheduled_session_title(session::ScheduledSession)
    title = normalize_title(session.title)
    title !== nothing && return title
    prompt_value = normalize_prompt(session.prompt)
    prompt_value === nothing && return "Scheduled Session"
    return derive_title(prompt_value)
end

function scheduled_session_prompt_preview(session::ScheduledSession)
    prompt_value = normalize_prompt(session.prompt)
    prompt_value === nothing && return "No prompt yet"
    return truncate_text(prompt_value, 96)
end

function scheduled_session_schedule(session::ScheduledSession)
    schedule_value = normalize_schedule_input(session.schedule)
    schedule_value === nothing && return "No schedule yet"
    return schedule_value
end

function session_summary(session::StoredSession)
    return Dict(
        "id" => session.id,
        "title" => session_title(session),
        "preview" => session_preview(session),
        "message_count" => length(session.state.messages),
        "created_at" => session.created_at,
        "updated_at" => session.updated_at,
        "responding" => session.responding,
    )
end

function session_detail(session::StoredSession)
    return Dict(
        "id" => session.id,
        "title" => session_title(session),
        "created_at" => session.created_at,
        "updated_at" => session.updated_at,
        "messages" => session.state.messages,
        "usage" => session.state.usage,
        "pending_tool_calls" => session.state.pending_tool_calls,
        "responding" => session.responding,
        "pending_user" => session.pending_user,
        "pending_assistant" => session.pending_assistant,
        "pending_reasoning" => session.pending_reasoning,
        "pending_eval_id" => session.pending_eval_id,
        "pending_eval_started_at" => session.pending_eval_started_at,
    )
end

function scheduled_session_summary(session::ScheduledSession)
    return Dict(
        "id" => session.id,
        "title" => scheduled_session_title(session),
        "prompt" => session.prompt,
        "schedule" => session.schedule,
        "is_valid" => session.is_valid,
        "created_at" => session.created_at,
        "updated_at" => session.updated_at,
        "session_ids" => session.session_ids,
    )
end

function scheduled_session_detail(session::ScheduledSession)
    return Dict(
        "id" => session.id,
        "title" => scheduled_session_title(session),
        "prompt" => session.prompt,
        "schedule" => session.schedule,
        "is_valid" => session.is_valid,
        "created_at" => session.created_at,
        "updated_at" => session.updated_at,
        "session_ids" => session.session_ids,
    )
end

function default_evaluator(agent::Agentif.Agent, prompt::String, on_event::Function; append_input::Bool=true)
    return Agentif.evaluate(agent, prompt; append_input=append_input) do event
        on_event(event)
    end
end

function build_http_agent(state::HttpState, session_state::Agentif.AgentState)
    return Agentif.Agent(; prompt=state.agent_config.prompt, model=state.agent_config.model, input_guardrail=nothing, tools=state.tools, apikey=state.agent_config.api_key, state=session_state)
end

function evaluate_session!(session::StoredSession, agent::Agentif.Agent, prompt::AbstractString; title::Union{Nothing,String}=nothing, on_event::Function=identity, evaluator::Function=default_evaluator, append_input::Bool=true)
    error_text = nothing
    result = nothing
    prompt_value = String(prompt)
    try
        result = evaluator(agent, prompt_value, on_event; append_input=append_input)
    catch err
        error_text = sprint(showerror, err)
    end
    session.state = agent.state
    session.updated_at = iso_now()
    override_title = normalize_title(title)
    if override_title !== nothing
        session.title = override_title
    elseif normalize_title(session.title) === nothing
        session.title = derive_title(prompt_value)
    end
    return session, result, error_text
end

function evaluate_session!(state::HttpState, session_id::String, prompt::AbstractString; title::Union{Nothing,String}=nothing, on_event::Function=identity, evaluator::Function=default_evaluator, append_input::Bool=true)
    session = get_session(state.sessions_dir, session_id)
    session === nothing && return nothing, nothing, "session not found"
    agent = build_http_agent(state, session.state)
    session, result, error_text = evaluate_session!(session, agent, prompt; title=title, on_event=on_event, evaluator=evaluator, append_input=append_input)
    save_session!(state.sessions_dir, session)
    return session, result, error_text
end

function dispatch_http_scheduled_session(scheduled_id::String)
    handler = HTTP_SCHEDULED_DISPATCH[]
    handler === nothing && return nothing
    handler(scheduled_id)
    return nothing
end

function enqueue_http_scheduled_session!(state::HttpState, scheduled_id::String)
    errormonitor(Threads.@spawn execute_scheduled_session!(state, scheduled_id))
    return nothing
end

function prepare_scheduled_run(state::HttpState, scheduled_id::String)
    scheduled = get_scheduled_session(state.scheduled_dir, scheduled_id)
    scheduled === nothing && return nothing, nothing, "scheduled session not found"
    scheduled.is_valid || return scheduled, nothing, "scheduled session is invalid"
    scheduled_session_in_progress(state.sessions_dir, scheduled) && return scheduled, nothing, "scheduled session already running"
    prompt_value = normalize_prompt(scheduled.prompt)
    prompt_value === nothing && return scheduled, nothing, "scheduled session is invalid"
    return scheduled, prompt_value, nothing
end

function start_scheduled_run!(state::HttpState, scheduled::ScheduledSession, prompt_value::String)
    title_value = scheduled.title
    session = new_session(state.sessions_dir; title=title_value)
    add_scheduled_session_run!(state.scheduled_dir, scheduled, session.id)
    session = begin_session_response!(state.sessions_dir, session.id, prompt_value)
    session === nothing && return nothing
    return session
end

function run_scheduled_session_async!(state::HttpState, session::StoredSession, prompt_value::String; title::Union{Nothing,String}=nothing, scheduled_id::Union{Nothing,String}=nothing)
    errormonitor(Threads.@spawn begin
        agent = build_http_agent(state, session.state)
        logged_error = Ref(false)
        function on_event(event)
            if event isa Agentif.MessageUpdateEvent && event.role == :assistant
                if event.kind == :reasoning
                    isempty(event.delta) || append_pending_reasoning!(state.sessions_dir, session, event.delta)
                elseif event.kind == :text || event.kind == :refusal
                    isempty(event.delta) || append_pending_assistant!(state.sessions_dir, session, event.delta)
                end
            elseif event isa Agentif.ToolCallRequestEvent
                existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
                entry = tool_call_entry_from_request(event, existing)
                upsert_tool_call_entry!(state.sessions_dir, session, entry)
            elseif event isa Agentif.ToolExecutionStartEvent
                existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
                entry = tool_call_entry_from_start(event, existing)
                upsert_tool_call_entry!(state.sessions_dir, session, entry)
            elseif event isa Agentif.ToolExecutionEndEvent
                existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
                entry = tool_call_entry_from_end(event, existing)
                upsert_tool_call_entry!(state.sessions_dir, session, entry)
            elseif event isa Agentif.AgentErrorEvent
                logged_error[] = true
                append_error_message!(state.sessions_dir, session, "Error: " * sprint(showerror, event.error))
            end
            return nothing
        end
        mark_session_eval_started!(state.sessions_dir, session)
        updated, _, error_text = evaluate_session!(session, agent, prompt_value; title=title, on_event=on_event, append_input=false)
        if error_text !== nothing
            commit_pending_output!(state.sessions_dir, updated)
            if !logged_error[]
                append_error_message!(state.sessions_dir, updated, "Error: " * error_text)
            end
        end
        save_session!(state.sessions_dir, updated)
        finalize_session_response!(state.sessions_dir, updated)
        if error_text !== nothing && scheduled_id !== nothing
            @warn "Scheduled session evaluation failed" scheduled_id=scheduled_id error=error_text
        elseif error_text !== nothing
            @warn "Scheduled session evaluation failed" error=error_text
        end
    end)
    return nothing
end

function run_scheduled_session_sync!(state::HttpState, session::StoredSession, prompt_value::String; title::Union{Nothing,String}=nothing, scheduled_id::Union{Nothing,String}=nothing)
    agent = build_http_agent(state, session.state)
    logged_error = Ref(false)
    function on_event(event)
        if event isa Agentif.MessageUpdateEvent && event.role == :assistant
            if event.kind == :reasoning
                isempty(event.delta) || append_pending_reasoning!(state.sessions_dir, session, event.delta)
            elseif event.kind == :text || event.kind == :refusal
                isempty(event.delta) || append_pending_assistant!(state.sessions_dir, session, event.delta)
            end
        elseif event isa Agentif.ToolCallRequestEvent
            existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
            entry = tool_call_entry_from_request(event, existing)
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
        elseif event isa Agentif.ToolExecutionStartEvent
            existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
            entry = tool_call_entry_from_start(event, existing)
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
        elseif event isa Agentif.ToolExecutionEndEvent
            existing = find_tool_call_entry(session.state.messages, event.tool_call.call_id)
            entry = tool_call_entry_from_end(event, existing)
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
        elseif event isa Agentif.AgentErrorEvent
            logged_error[] = true
            append_error_message!(state.sessions_dir, session, "Error: " * sprint(showerror, event.error))
        end
        return nothing
    end
    mark_session_eval_started!(state.sessions_dir, session)
    updated, _, error_text = evaluate_session!(session, agent, prompt_value; title=title, on_event=on_event, append_input=false)
    if error_text !== nothing
        commit_pending_output!(state.sessions_dir, updated)
        if !logged_error[]
            append_error_message!(state.sessions_dir, updated, "Error: " * error_text)
        end
    end
    save_session!(state.sessions_dir, updated)
    finalize_session_response!(state.sessions_dir, updated)
    if error_text !== nothing && scheduled_id !== nothing
        @warn "Scheduled session evaluation failed" scheduled_id=scheduled_id error=error_text
    elseif error_text !== nothing
        @warn "Scheduled session evaluation failed" error=error_text
    end
    return updated
end

function execute_scheduled_session!(state::HttpState, scheduled_id::String)
    scheduled, prompt_value, error_text = prepare_scheduled_run(state, scheduled_id)
    error_text !== nothing && return nothing
    session = start_scheduled_run!(state, scheduled, prompt_value)
    session === nothing && return nothing
    run_scheduled_session_sync!(state, session, prompt_value; title=scheduled.title, scheduled_id=scheduled_id)
    return nothing
end

function html_escape(text::AbstractString)
    escaped = replace(String(text), "&" => "&amp;")
    escaped = replace(escaped, "<" => "&lt;")
    escaped = replace(escaped, ">" => "&gt;")
    escaped = replace(escaped, "\"" => "&quot;")
    escaped = replace(escaped, "'" => "&#39;")
    return escaped
end

function html_id_safe(text::AbstractString)
    return replace(String(text), r"[^A-Za-z0-9_-]" => "-")
end

function msg_order_attrs(order::Union{Nothing,Int}, timestamp::Union{Nothing,Int})
    attrs = ""
    order !== nothing && (attrs *= " style=\"order: $(order)\"")
    timestamp !== nothing && (attrs *= " data-ts=\"$(timestamp)\"")
    return attrs
end

function render_stream_group_html(group_id::String)
    return """<div class=\"stream-group\" id=\"$(group_id)\"></div>"""
end

function render_stream_group_oob_html(group_id::String)
    return """<div hx-swap-oob=\"beforeend:#messages\">$(render_stream_group_html(group_id))</div>"""
end

function render_user_message_html(content::String, message_id::String)
    text = html_escape(content)
    return """<div class=\"msg msg-user\" id=\"msg-$(message_id)\"><div class=\"msg-bubble\"><div class=\"msg-meta\">You</div><div class=\"msg-text\">$(text)</div></div></div>"""
end

function render_user_message_oob_html(content::String, message_id::String)
    return """<div hx-swap-oob=\"beforeend:#messages\">$(render_user_message_html(content, message_id))</div>"""
end

function render_assistant_message_html(message_id::String; thinking_html::String="", order::Union{Nothing,Int}=nothing, timestamp::Union{Nothing,Int}=nothing)
    attrs = msg_order_attrs(order, timestamp)
    return """<div class=\"msg msg-assistant\" id=\"msg-$(message_id)\"$(attrs)><div class=\"msg-bubble\"><div class=\"msg-meta\">Vo</div><div class=\"msg-text\" id=\"assistant-text-$(message_id)\"></div><div class=\"msg-thinking-slot\" id=\"assistant-thinking-slot-$(message_id)\">$(thinking_html)</div><div class=\"msg-status\" id=\"assistant-status-$(message_id)\">Streaming...</div></div></div>"""
end

function render_assistant_message_oob_html(message_id::String; thinking_html::String="", order::Union{Nothing,Int}=nothing, timestamp::Union{Nothing,Int}=nothing, target_id::String="messages")
    return """<div hx-swap-oob=\"beforeend:#$(target_id)\">$(render_assistant_message_html(message_id; thinking_html=thinking_html, order=order, timestamp=timestamp))</div>"""
end

function render_assistant_thinking_block_html(message_id::String, content::AbstractString="")
    safe_content = html_escape(content)
    return """<details class=\"msg-thinking\" open id=\"assistant-thinking-$(message_id)\"><summary>Thinking</summary><pre id=\"assistant-thinking-text-$(message_id)\">$(safe_content)</pre></details>"""
end

function render_assistant_thinking_block_oob_html(message_id::String, content::AbstractString="")
    return """<div hx-swap-oob=\"innerHTML:#assistant-thinking-slot-$(message_id)\">$(render_assistant_thinking_block_html(message_id, content))</div>"""
end

function render_thinking_message_html(message_id::String, content::AbstractString=""; order::Union{Nothing,Int}=nothing, timestamp::Union{Nothing,Int}=nothing)
    attrs = msg_order_attrs(order, timestamp)
    safe_content = html_escape(content)
    return """<div class=\"msg msg-thinking-block\" id=\"msg-$(message_id)\"$(attrs)><div class=\"msg-bubble\"><details class=\"thinking-details\" open><summary>Thinking</summary><pre id=\"thinking-text-$(message_id)\">$(safe_content)</pre></details></div></div>"""
end

function render_thinking_message_oob_html(message_id::String, content::AbstractString=""; order::Union{Nothing,Int}=nothing, timestamp::Union{Nothing,Int}=nothing, target_id::String="messages")
    return """<div hx-swap-oob=\"beforeend:#$(target_id)\">$(render_thinking_message_html(message_id, content; order=order, timestamp=timestamp))</div>"""
end

function render_thinking_delta_html(message_id::String, delta::AbstractString)
    text = html_escape(delta)
    return """<span hx-swap-oob=\"beforeend:#thinking-text-$(message_id)\">$(text)</span>"""
end

function render_assistant_message_content_html(message_id::String, text::AbstractString, reasoning::AbstractString; status_done::Bool=true)
    thinking_html = isempty(reasoning) ? "" : render_assistant_thinking_block_html(message_id, reasoning)
    message_html = render_assistant_message_html(message_id; thinking_html=thinking_html)
    isempty(text) || (message_html = replace(message_html, "<div class=\"msg-text\" id=\"assistant-text-$(message_id)\"></div>" => "<div class=\"msg-text\" id=\"assistant-text-$(message_id)\">$(html_escape(text))</div>"))
    if status_done
        message_html = replace(message_html, "<div class=\"msg-status\" id=\"assistant-status-$(message_id)\">Streaming...</div>" => "<div class=\"msg-status done\" id=\"assistant-status-$(message_id)\">Complete</div>")
    end
    return message_html
end

function render_assistant_delta_html(message_id::String, delta::AbstractString)
    text = html_escape(delta)
    return """<span hx-swap-oob=\"beforeend:#assistant-text-$(message_id)\">$(text)</span>"""
end

function render_assistant_thinking_delta_html(message_id::String, delta::AbstractString)
    text = html_escape(delta)
    return """<span hx-swap-oob=\"beforeend:#assistant-thinking-text-$(message_id)\">$(text)</span>"""
end

function render_assistant_done_html(message_id::String)
    return """<div class=\"msg-status done\" hx-swap-oob=\"outerHTML:#assistant-status-$(message_id)\">Complete</div>"""
end

function tool_calls_list_id(block_id::String)
    return "$(block_id)-list"
end

function tool_call_row_id(block_id::String, call_id::String)
    safe_id = html_id_safe(call_id)
    return "$(block_id)-call-$(safe_id)"
end

function render_tool_call_row_html(block_id::String, entry::ToolCallEntry)
    row_id = tool_call_row_id(block_id, entry.call_id)
    executing = entry.started_at !== nothing && entry.finished_at === nothing
    request_snippet = html_escape(tool_call_request_snippet(entry))
    request_full = html_escape(tool_call_full_request(entry))
    result_ready = entry.finished_at !== nothing
    output_value = entry.output === nothing ? "" : entry.output
    output_display = isempty(compact_text(output_value)) ? "(empty output)" : output_value
    output_snippet = html_escape(tool_call_result_snippet(output_display))
    output_full = html_escape(output_display)
    duration_text = html_escape(format_duration_seconds(entry.duration_ms))
    error_class = entry.is_error === true ? " tool-call-error" : ""
    executing_attr = executing ? "true" : "false"
    buf = IOBuffer()
    print(buf, "<div class=\"tool-call-row\" id=\"", row_id, "\" data-executing=\"", executing_attr, "\">")
    print(buf, "<details class=\"tool-call-bubble tool-call-request\"><summary><span class=\"tool-call-label\">", html_escape(entry.name), "</span><span class=\"tool-call-snippet\">", request_snippet, "</span><span class=\"tool-call-spinner\"></span></summary><pre class=\"tool-call-full\">", request_full, "</pre></details>")
    if result_ready
        print(buf, "<details class=\"tool-call-bubble tool-call-result", error_class, "\">")
        print(buf, "<summary><span class=\"tool-call-label\">Result</span><span class=\"tool-call-snippet\">", output_snippet, "</span>")
        isempty(duration_text) || print(buf, "<span class=\"tool-call-duration\">", duration_text, "</span>")
        print(buf, "</summary><pre class=\"tool-call-full\">", output_full, "</pre></details>")
    else
        print(buf, "<div class=\"tool-call-slot tool-call-empty\"></div>")
    end
    print(buf, "</div>")
    return String(take!(buf))
end

function render_tool_calls_list_html(block_id::String, entries::Vector{ToolCallEntry})
    isempty(entries) && return ""
    sort!(entries; by=entry -> entry.requested_at)
    buf = IOBuffer()
    for entry in entries
        print(buf, render_tool_call_row_html(block_id, entry))
    end
    return String(take!(buf))
end

function render_tool_calls_list_oob_html(block_id::String, entries::Vector{ToolCallEntry})
    list_html = render_tool_calls_list_html(block_id, entries)
    return """<div hx-swap-oob=\"innerHTML:#$(tool_calls_list_id(block_id))\">$(list_html)</div>"""
end

function render_tool_calls_block_html(block_id::String, entries::Vector{ToolCallEntry}; order::Union{Nothing,Int}=nothing, timestamp::Union{Nothing,Int}=nothing)
    attrs = msg_order_attrs(order, timestamp)
    list_html = render_tool_calls_list_html(block_id, entries)
    return """<div class=\"msg msg-toolcalls\" id=\"$(block_id)\"$(attrs)><div class=\"msg-bubble\"><div class=\"msg-meta\">Tool calls</div><div class=\"tool-call-list\" id=\"$(tool_calls_list_id(block_id))\">$(list_html)</div></div></div>"""
end

function render_tool_message_html(title::AbstractString, content::AbstractString)
    safe_title = html_escape(title)
    safe_content = html_escape(content)
    return """<div class=\"msg msg-tool\"><div class=\"msg-bubble\"><div class=\"msg-meta\">$(safe_title)</div><pre class=\"msg-code\">$(safe_content)</pre></div></div>"""
end

function render_tool_event_html(title::AbstractString, content::AbstractString)
    return """<div hx-swap-oob=\"beforeend:#messages\">$(render_tool_message_html(title, content))</div>"""
end

function render_error_message_html(message::AbstractString)
    safe_message = html_escape(message)
    return """<div class=\"msg msg-error\"><div class=\"msg-bubble\"><div class=\"msg-meta\">Error</div><div class=\"msg-text\">$(safe_message)</div></div></div>"""
end

function render_error_html(message::AbstractString)
    return """<div hx-swap-oob=\"beforeend:#messages\">$(render_error_message_html(message))</div>"""
end

function render_agent_status_html(active::Bool=false)
    class_name = active ? "agent-status active" : "agent-status"
    return """<div id=\"agent-status\" class=\"$(class_name)\"><div class=\"agent-spinner\"></div><div class=\"agent-status-text\">Vo is working...</div></div>"""
end

function render_agent_status_oob_html(active::Bool=false)
    return """<div hx-swap-oob=\"outerHTML:#agent-status\">$(render_agent_status_html(active))</div>"""
end

function render_session_item_html(session::StoredSession; active_id::Union{Nothing,String}=nothing, show_delete::Bool=true, item_class::String="session-item", link_class::String="session-link")
    title = html_escape(session_title(session))
    preview = html_escape(session_preview(session))
    active_class = active_id === session.id ? " active" : ""
    buf = IOBuffer()
    print(buf, "<div class=\"", item_class, active_class, "\" id=\"session-", session.id, "\">")
    print(buf, "<button type=\"button\" class=\"", link_class, "\" hx-get=\"/ui/sessions/", session.id, "\" hx-target=\"#session-view\" hx-swap=\"innerHTML\">")
    print(buf, "<div class=\"session-title\">", title, "</div>")
    print(buf, "<div class=\"session-preview\">", preview, "</div>")
    print(buf, "</button>")
    if session.responding && session.id != active_id
        print(buf, "<div class=\"session-status\" title=\"Responding\"><span class=\"agent-spinner\"></span></div>")
    end
    if show_delete
        print(buf, "<button type=\"button\" class=\"session-delete\" title=\"Delete session\" hx-delete=\"/ui/sessions/", session.id, "\" hx-target=\"#session-list\" hx-swap=\"innerHTML\">")
        print(buf, "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M9 3h6l1 2h4v2H4V5h4l1-2zm1 6h2v9h-2V9zm4 0h2v9h-2V9zM7 9h2v9H7V9z\"/></svg>")
        print(buf, "</button>")
    end
    print(buf, "</div>")
    return String(take!(buf))
end

function render_session_list_html(sessions::Vector{StoredSession}; active_id::Union{Nothing,String}=nothing)
    isempty(sessions) && return "<div class=\"session-empty\">No sessions yet</div>"
    buf = IOBuffer()
    for session in sessions
        print(buf, render_session_item_html(session; active_id=active_id))
    end
    return String(take!(buf))
end

function scheduled_child_sessions(scheduled::ScheduledSession, sessions_dir::String)
    sessions = StoredSession[]
    for session_id in scheduled.session_ids
        session = get_session(sessions_dir, session_id)
        session === nothing && continue
        push!(sessions, session)
    end
    sort!(sessions; by=session -> session.updated_at, rev=true)
    return sessions
end

function render_scheduled_children_html(scheduled::ScheduledSession, sessions_dir::String; active_session_id::Union{Nothing,String}=nothing)
    sessions = scheduled_child_sessions(scheduled, sessions_dir)
    isempty(sessions) && return "<div class=\"scheduled-empty\">No runs yet</div>"
    buf = IOBuffer()
    for session in sessions
        print(buf, render_session_item_html(session; active_id=active_session_id, show_delete=false, item_class="session-item session-child", link_class="session-link session-child-link"))
    end
    return String(take!(buf))
end

function render_scheduled_list_html(scheduled_sessions::Vector{ScheduledSession}, sessions_dir::String; active_scheduled_id::Union{Nothing,String}=nothing, active_session_id::Union{Nothing,String}=nothing)
    isempty(scheduled_sessions) && return "<div class=\"session-empty\">No scheduled sessions yet</div>"
    buf = IOBuffer()
    for scheduled in scheduled_sessions
        title = html_escape(scheduled_session_title(scheduled))
        schedule_value = html_escape(scheduled_session_schedule(scheduled))
        preview = html_escape(scheduled_session_prompt_preview(scheduled))
        active_class = active_scheduled_id === scheduled.id ? " active" : ""
        print(buf, "<div class=\"scheduled-item", active_class, "\" id=\"scheduled-", scheduled.id, "\" data-scheduled-id=\"", scheduled.id, "\">")
        print(buf, "<div class=\"scheduled-row\">")
        print(buf, "<button type=\"button\" class=\"scheduled-toggle\" data-scheduled-toggle=\"", scheduled.id, "\" aria-label=\"Toggle scheduled session\">")
        print(buf, "<svg viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M4.5 6l3.5 4 3.5-4z\"/></svg>")
        print(buf, "</button>")
        print(buf, "<button type=\"button\" class=\"scheduled-link\" hx-get=\"/ui/scheduled/", scheduled.id, "\" hx-target=\"#session-view\" hx-swap=\"innerHTML\">", title, "</button>")
        print(buf, "<button type=\"button\" class=\"scheduled-delete\" title=\"Delete scheduled session\" hx-delete=\"/ui/scheduled/", scheduled.id, "\" hx-target=\"#scheduled-list\" hx-swap=\"innerHTML\">")
        print(buf, "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M9 3h6l1 2h4v2H4V5h4l1-2zm1 6h2v9h-2V9zm4 0h2v9h-2V9zM7 9h2v9H7V9z\"/></svg>")
        print(buf, "</button>")
        print(buf, "</div>")
        print(buf, "<div class=\"scheduled-meta\"><span class=\"scheduled-cron\">UTC <code>", schedule_value, "</code></span>")
        scheduled.is_valid || print(buf, "<span class=\"scheduled-invalid\">Invalid</span>")
        print(buf, "</div>")
        print(buf, "<div class=\"scheduled-preview\">", preview, "</div>")
        print(buf, "<div class=\"scheduled-children\">", render_scheduled_children_html(scheduled, sessions_dir; active_session_id=active_session_id), "</div>")
        print(buf, "</div>")
    end
    return String(take!(buf))
end

function render_prompt_input_html(value::String="")
    return """<textarea id=\"prompt-input\" name=\"prompt\" class=\"prompt-input\" rows=\"4\" placeholder=\"Type your next prompt...\" required>$(html_escape(value))</textarea>"""
end

function render_session_header_html(session::StoredSession)
    title = html_escape(session_title(session))
    updated = html_escape(session.updated_at)
    id_label = html_escape(session_id_label(session.id))
    return """<div id=\"session-header\" class=\"session-header\"><button type=\"button\" class=\"session-title-main editable\" hx-get=\"/ui/sessions/$(session.id)/title/edit\" hx-target=\"#session-header\" hx-swap=\"outerHTML\">$(title)</button><div class=\"session-meta\"><span class=\"session-id\" title=\"$(session.id)\">$(id_label)</span><span class=\"session-updated\">Updated $(updated)</span></div></div>"""
end

function render_session_title_edit_html(session::StoredSession)
    title = html_escape(session_title(session))
    updated = html_escape(session.updated_at)
    id_label = html_escape(session_id_label(session.id))
    return """<div id=\"session-header\" class=\"session-header\"><input type=\"text\" name=\"title\" class=\"session-title-input\" value=\"$(title)\" autocomplete=\"off\" hx-put=\"/ui/sessions/$(session.id)/title\" hx-target=\"#session-header\" hx-swap=\"outerHTML\" hx-trigger=\"keyup[key=='Enter'], blur\"><div class=\"session-meta\"><span class=\"session-id\" title=\"$(session.id)\">$(id_label)</span><span class=\"session-updated\">Updated $(updated) (press Enter to save)</span></div></div>"""
end

function render_scheduled_run_button_html(session::ScheduledSession, sessions_dir::String)
    running = scheduled_session_in_progress(sessions_dir, session)
    disabled = !session.is_valid || running
    label = running ? "Running..." : "Run now"
    title_text = if !session.is_valid
        "Add a prompt and valid cron schedule to enable."
    elseif running
        "A run is already in progress."
    else
        "Run now"
    end
    disabled_attr = disabled ? " disabled" : ""
    running_class = running ? " running" : ""
    return """<button type=\"button\" class=\"run-now-button$(running_class)\" hx-post=\"/ui/scheduled/$(session.id)/run\" hx-target=\"#session-view\" hx-swap=\"innerHTML\" title=\"$(html_escape(title_text))\"$(disabled_attr)>$(label)</button>"""
end

function render_scheduled_session_header_html(session::ScheduledSession, sessions_dir::String)
    title = html_escape(scheduled_session_title(session))
    updated = html_escape(session.updated_at)
    id_label = html_escape(session_id_label(session.id))
    run_button = render_scheduled_run_button_html(session, sessions_dir)
    return """<div id=\"scheduled-header\" class=\"session-header\"><div class=\"session-header-row\"><button type=\"button\" class=\"session-title-main editable\" hx-get=\"/ui/scheduled/$(session.id)/title/edit\" hx-target=\"#scheduled-header\" hx-swap=\"outerHTML\">$(title)</button>$(run_button)</div><div class=\"session-meta\"><span class=\"session-id\" title=\"$(session.id)\">$(id_label)</span><span class=\"session-updated\">Updated $(updated)</span></div></div>"""
end

function render_scheduled_session_title_edit_html(session::ScheduledSession, sessions_dir::String)
    title = html_escape(scheduled_session_title(session))
    updated = html_escape(session.updated_at)
    id_label = html_escape(session_id_label(session.id))
    run_button = render_scheduled_run_button_html(session, sessions_dir)
    return """<div id=\"scheduled-header\" class=\"session-header\"><div class=\"session-header-row\"><input type=\"text\" name=\"title\" class=\"session-title-input\" value=\"$(title)\" autocomplete=\"off\" hx-put=\"/ui/scheduled/$(session.id)/title\" hx-target=\"#scheduled-header\" hx-swap=\"outerHTML\" hx-trigger=\"keyup[key=='Enter'], blur\">$(run_button)</div><div class=\"session-meta\"><span class=\"session-id\" title=\"$(session.id)\">$(id_label)</span><span class=\"session-updated\">Updated $(updated) (press Enter to save)</span></div></div>"""
end

function render_messages_html(messages::Vector{Agentif.AgentMessage}; start_index::Int=1)
    buf = IOBuffer()
    message_index = start_index - 1
    tool_block_entries = ToolCallEntry[]
    tool_block_index = 0
    for msg in messages
        message_index += 1
        message_id = "history-$(message_index)"
        if msg isa Agentif.UserMessage
            if !isempty(tool_block_entries)
                tool_block_index += 1
                print(buf, render_tool_calls_block_html("tool-calls-history-$(tool_block_index)", tool_block_entries))
                empty!(tool_block_entries)
            end
            print(buf, render_user_message_html(msg.text, message_id))
        elseif msg isa Agentif.AssistantMessage
            if msg.kind == "tool"
                entry = tool_call_entry_from_message(msg)
                if entry === nothing
                    if !isempty(tool_block_entries)
                        tool_block_index += 1
                        print(buf, render_tool_calls_block_html("tool-calls-history-$(tool_block_index)", tool_block_entries))
                        empty!(tool_block_entries)
                    end
                    title, content = split_tool_event_text(msg.text)
                    print(buf, render_tool_message_html(title, content))
                else
                    push!(tool_block_entries, entry)
                end
            elseif msg.kind == "error"
                if !isempty(tool_block_entries)
                    tool_block_index += 1
                    print(buf, render_tool_calls_block_html("tool-calls-history-$(tool_block_index)", tool_block_entries))
                    empty!(tool_block_entries)
                end
                print(buf, render_error_message_html(msg.text))
            else
                if !isempty(tool_block_entries)
                    tool_block_index += 1
                    print(buf, render_tool_calls_block_html("tool-calls-history-$(tool_block_index)", tool_block_entries))
                    empty!(tool_block_entries)
                end
                text_value = message_text(msg)
                reasoning_value = msg.reasoning
                isempty(text_value) && isempty(reasoning_value) && continue
                print(buf, render_assistant_message_content_html(message_id, text_value, reasoning_value; status_done=true))
            end
        end
    end
    if !isempty(tool_block_entries)
        tool_block_index += 1
        print(buf, render_tool_calls_block_html("tool-calls-history-$(tool_block_index)", tool_block_entries))
        empty!(tool_block_entries)
    end
    return String(take!(buf))
end

function render_pending_messages_html(session::StoredSession)
    session.responding || return ""
    buf = IOBuffer()
    if session.pending_user !== nothing
        last_msg = nothing
        for msg in Iterators.reverse(session.state.messages)
            msg isa Agentif.AssistantMessage && msg.kind == "tool" && continue
            last_msg = msg
            break
        end
        if !(last_msg isa Agentif.UserMessage && last_msg.text == session.pending_user)
            print(buf, render_user_message_html(session.pending_user, "pending-user"))
        end
    end
    assistant_text = session.pending_assistant === nothing ? "" : session.pending_assistant
    reasoning_text = session.pending_reasoning === nothing ? "" : session.pending_reasoning
    if !isempty(assistant_text) || !isempty(reasoning_text)
        print(buf, render_assistant_message_content_html("pending-assistant", assistant_text, reasoning_text; status_done=false))
    end
    return String(take!(buf))
end

function render_session_view_html(session::StoredSession; run_eval_id::Union{Nothing,String}=nothing)
    header = render_session_header_html(session)
    messages = render_messages_html(session.state.messages) * render_pending_messages_html(session)
    input = render_prompt_input_html()
    active_eval_id = run_eval_id
    active_eval_id === nothing && session.responding && (active_eval_id = session.pending_eval_id)
    status = render_agent_status_html(session.responding || active_eval_id !== nothing)
    stream_root = active_eval_id === nothing ? "<div id=\"stream-root\" class=\"stream-root\"></div>" : render_sse_shell_html(session.id; eval_id=active_eval_id)
    return """<div class=\"session-view\" data-session-id=\"$(session.id)\">$(header)<div id=\"messages\" class=\"messages\">$(messages)</div><div class=\"composer\">$(status)<form class=\"prompt-form\" hx-post=\"/ui/sessions/$(session.id)/evaluate\" hx-target=\"#stream-root\" hx-swap=\"outerHTML\">$(input)<div class=\"composer-actions\"><button type=\"submit\" class=\"send-button\">Send</button></div></form></div>$(stream_root)</div>"""
end

function render_session_run_html(session::StoredSession)
    title = html_escape(session_title(session))
    preview = html_escape(session_preview(session))
    return """<div class=\"session-item session-run\" id=\"run-$(session.id)\"><button type=\"button\" class=\"session-link session-run-link\" hx-get=\"/ui/sessions/$(session.id)\" hx-target=\"#session-view\" hx-swap=\"innerHTML\"><div class=\"session-title\">$(title)</div><div class=\"session-preview\">$(preview)</div></button></div>"""
end

function render_scheduled_runs_html(session::ScheduledSession, sessions_dir::String)
    runs = scheduled_child_sessions(session, sessions_dir)
    buf = IOBuffer()
    print(buf, "<div class=\"scheduled-runs\"><div class=\"scheduled-runs-title\">Runs</div>")
    if isempty(runs)
        print(buf, "<div class=\"scheduled-runs-empty\">No runs yet</div>")
    else
        print(buf, "<div class=\"scheduled-runs-list\">")
        for run in runs
            print(buf, render_session_run_html(run))
        end
        print(buf, "</div>")
    end
    print(buf, "</div>")
    return String(take!(buf))
end

function render_scheduled_status_html(session::ScheduledSession)
    validity_label = session.is_valid ? "<span class=\"scheduled-valid\">Valid</span>" : "<span class=\"scheduled-invalid\">Invalid</span>"
    return """<div id=\"scheduled-status\" class=\"scheduled-status\">$(validity_label)</div>"""
end

function render_scheduled_status_oob_html(session::ScheduledSession)
    validity_label = session.is_valid ? "<span class=\"scheduled-valid\">Valid</span>" : "<span class=\"scheduled-invalid\">Invalid</span>"
    return """<div id=\"scheduled-status\" class=\"scheduled-status\" hx-swap-oob=\"outerHTML:#scheduled-status\">$(validity_label)</div>"""
end

function render_scheduled_cron_input_html(session::ScheduledSession; oob::Bool=false)
    schedule_value = session.schedule === nothing ? "" : html_escape(session.schedule)
    schedule_class = session.is_valid ? "scheduled-input" : "scheduled-input invalid"
    oob_attr = oob ? " hx-swap-oob=\"outerHTML:#scheduled-cron\"" : ""
    return """<input id=\"scheduled-cron\" type=\"text\" name=\"schedule\" class=\"$(schedule_class)\" value=\"$(schedule_value)\" placeholder=\"0 4 * * *\" hx-put=\"/ui/scheduled/$(session.id)\" hx-trigger=\"change\" hx-target=\"#session-view\" hx-swap=\"none\"$(oob_attr)>"""
end

function render_scheduled_cron_oob_html(session::ScheduledSession)
    return render_scheduled_cron_input_html(session; oob=true)
end

function render_scheduled_session_view_html(session::ScheduledSession, sessions_dir::String)
    header = render_scheduled_session_header_html(session, sessions_dir)
    prompt_value = session.prompt === nothing ? "" : html_escape(session.prompt)
    runs_html = render_scheduled_runs_html(session, sessions_dir)
    status_html = render_scheduled_status_html(session)
    cron_input = render_scheduled_cron_input_html(session)
    return """<div class=\"schedule-view\" data-scheduled-id=\"$(session.id)\">$(header)<div class=\"schedule-body\"><div class=\"scheduled-field\"><label for=\"scheduled-prompt\">Prompt</label><textarea id=\"scheduled-prompt\" name=\"prompt\" class=\"scheduled-textarea\" rows=\"6\" placeholder=\"Add the prompt to run on schedule...\" hx-put=\"/ui/scheduled/$(session.id)\" hx-trigger=\"change\" hx-target=\"#session-view\" hx-swap=\"none\">$(prompt_value)</textarea></div><div class=\"scheduled-field\"><label for=\"scheduled-cron\">Cron schedule (UTC)</label><div class=\"cron-helper\">Cron runs in UTC. Local offset: <span data-utc-offset>...</span>. 4:00 local is <span data-utc-example>...</span>.</div>$(cron_input)$(status_html)</div>$(runs_html)</div></div>"""
end

function render_zero_state_html()
    return """<div class=\"zero-state\"><div class=\"zero-card\"><h2>Start a session</h2><p>Create a new thread or pick an existing one to review its history.</p></div></div>"""
end

function render_sse_shell_html(session_id::String; eval_id::Union{Nothing,String}=nothing)
    eval_id === nothing && throw(ArgumentError("eval_id is required"))
    encoded_eval_id = HTTP.URIs.escapeuri(String(eval_id))
    sse_url = "/v1/sessions/$(session_id)/evaluate?eval_id=$(encoded_eval_id)"
    buf = IOBuffer()
    print(buf, "<div id=\"stream-root\" class=\"stream-root\" hx-ext=\"sse\" sse-connect=\"", sse_url, "\">")
    for event_name in (
        "AgentEvaluateStartEvent",
        "MessageStartEvent",
        "MessageUpdateEvent",
        "MessageEndEvent",
        "ToolCallRequestEvent",
        "ToolExecutionStartEvent",
        "ToolExecutionEndEvent",
        "AgentErrorEvent",
        "AgentEvaluateEndEvent",
    )
        print(buf, "<div class=\"sse-sink\" sse-swap=\"", event_name, "\" hx-swap=\"beforeend\"></div>")
    end
    print(buf, "</div>")
    shell = String(take!(buf))
    clear_input = """<textarea id=\"prompt-input\" name=\"prompt\" class=\"prompt-input\" rows=\"4\" placeholder=\"Type your next prompt...\" required hx-swap-oob=\"outerHTML:#prompt-input\"></textarea>"""
    return shell * clear_input
end

function html_response(body::String; status::Int=200)
    return HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8"]; body=body)
end

function js_response(body::String; status::Int=200)
    return HTTP.Response(status, ["Content-Type" => "application/javascript; charset=utf-8"]; body=body)
end

function parse_query_param(req::HTTP.Request, key::String)
    for (k, v) in HTTP.URIs.queryparampairs(HTTP.URI(req.target))
        k == key && return v
    end
    return nothing
end

function parse_form_param(req::HTTP.Request, key::String)
    body = String(req.body)
    isempty(body) && return nothing
    for (k, v) in HTTP.URIs.queryparampairs(HTTP.URI("?" * body))
        k == key && return v
    end
    return nothing
end

function parse_form_params(req::HTTP.Request)
    body = String(req.body)
    isempty(body) && return Dict{String,String}()
    params = Dict{String,String}()
    for (k, v) in HTTP.URIs.queryparampairs(HTTP.URI("?" * body))
        params[String(k)] = String(v)
    end
    return params
end

function sse_safe_write!(stream::HTTP.SSEStream, stream_closed::Base.RefValue{Bool}, event_name::String, data::String)
    stream_closed[] && return nothing
    isempty(data) && return nothing
    try
        write(stream, HTTP.SSEEvent(data; event=event_name))
    catch
        stream_closed[] = true
    end
    return nothing
end

function sse_abort!(stream::HTTP.SSEStream, stream_closed::Base.RefValue{Bool}, message::String)
    sse_safe_write!(stream, stream_closed, "AgentErrorEvent", render_error_html(message) * render_agent_status_oob_html(false))
    return nothing
end

function follow_eval_sse!(state::HttpState, session_id::String, eval_id::String, stream::HTTP.SSEStream, stream_closed::Base.RefValue{Bool})
    session = get_session(state.sessions_dir, session_id)
    session === nothing && return sse_abort!(stream, stream_closed, "session not found")
    session.pending_eval_id == eval_id || return sse_abort!(stream, stream_closed, "evaluation not found")
    messages_html = render_messages_html(session.state.messages) * render_pending_messages_html(session)
    sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", "<div hx-swap-oob=\"innerHTML:#messages\">$(messages_html)</div>" * render_agent_status_oob_html(session.responding))
    if !session.responding
        list_html = render_session_list_html(list_user_sessions(state); active_id=session.id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        header_html = render_session_header_html(session)
        update_html = """<div hx-swap-oob=\"innerHTML:#session-list\">$(list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"outerHTML:#session-header\">$(header_html)</div>""" * render_agent_status_oob_html(false)
        sse_safe_write!(stream, stream_closed, "AgentEvaluateEndEvent", update_html)
        return nothing
    end
    last_message_count = length(session.state.messages)
    last_pending_assistant = session.pending_assistant === nothing ? "" : session.pending_assistant
    last_pending_reasoning = session.pending_reasoning === nothing ? "" : session.pending_reasoning
    pending_visible = !isempty(last_pending_assistant) || !isempty(last_pending_reasoning)
    thinking_started = !isempty(last_pending_reasoning)
    while true
        stream_closed[] && return nothing
        sleep(0.4)
        updated = get_session(state.sessions_dir, session_id)
        updated === nothing && return sse_abort!(stream, stream_closed, "session not found")
        if length(updated.state.messages) > last_message_count
            new_messages = updated.state.messages[(last_message_count + 1):end]
            new_html = render_messages_html(new_messages; start_index=last_message_count + 1)
            isempty(new_html) || sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", "<div hx-swap-oob=\"beforeend:#messages\">$(new_html)</div>")
            last_message_count = length(updated.state.messages)
        end
        pending_assistant = updated.pending_assistant === nothing ? "" : updated.pending_assistant
        pending_reasoning = updated.pending_reasoning === nothing ? "" : updated.pending_reasoning
        pending_present = !isempty(pending_assistant) || !isempty(pending_reasoning)
        if pending_present && !pending_visible
            pending_html = render_assistant_message_content_html("pending-assistant", pending_assistant, pending_reasoning; status_done=false)
            sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", "<div hx-swap-oob=\"beforeend:#messages\">$(pending_html)</div>")
            pending_visible = true
            thinking_started = !isempty(pending_reasoning)
            last_pending_assistant = pending_assistant
            last_pending_reasoning = pending_reasoning
        end
        if pending_present
            if pending_assistant != last_pending_assistant
                delta = string_delta(pending_assistant, last_pending_assistant)
                isempty(delta) || sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", render_assistant_delta_html("pending-assistant", delta))
                last_pending_assistant = pending_assistant
            end
            if pending_reasoning != last_pending_reasoning
                delta = string_delta(pending_reasoning, last_pending_reasoning)
                if !isempty(delta)
                    if !thinking_started
                        thinking_started = true
                        sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", render_assistant_thinking_block_oob_html("pending-assistant", delta))
                    else
                        sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", render_assistant_thinking_delta_html("pending-assistant", delta))
                    end
                end
                last_pending_reasoning = pending_reasoning
            end
        elseif pending_visible
            sse_safe_write!(stream, stream_closed, "MessageUpdateEvent", "<div hx-swap-oob=\"outerHTML:#msg-pending-assistant\"></div>")
            pending_visible = false
            thinking_started = false
            last_pending_assistant = ""
            last_pending_reasoning = ""
        end
        if !updated.responding
            list_html = render_session_list_html(list_user_sessions(state); active_id=updated.id)
            scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=updated.id)
            header_html = render_session_header_html(updated)
            update_html = """<div hx-swap-oob=\"innerHTML:#session-list\">$(list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"outerHTML:#session-header\">$(header_html)</div>""" * render_agent_status_oob_html(false)
            sse_safe_write!(stream, stream_closed, "AgentEvaluateEndEvent", update_html)
            return nothing
        end
    end
    return nothing
end

function evaluate_sse!(state::HttpState, session_id::String; prompt::Union{Nothing,String}=nothing, eval_id::Union{Nothing,String}=nothing, title::Union{Nothing,String}=nothing, stream::HTTP.SSEStream)
    assistant_id = string("assistant-", UUIDs.uuid4())
    user_id = string("user-", UUIDs.uuid4())
    assistant_started = Ref(false)
    assistant_text_started = Ref(false)
    thinking_started = Ref(false)
    tool_calls_started = Ref(false)
    tool_calls = Dict{String,ToolCallEntry}()
    tool_calls_order = Ref{Union{Nothing,Int}}(nothing)
    stream_closed = Ref(false)
    saw_error = Ref(false)
    logged_error = Ref(false)
    prompt_value = ""
    session = nothing
    eval_id_value = eval_id
    function safe_write(event_name::String, data::String)
        sse_safe_write!(stream, stream_closed, event_name, data)
        return nothing
    end
    function abort_with_error(message::String)
        sse_abort!(stream, stream_closed, message)
        return nothing
    end
    if eval_id !== nothing
        session = get_session(state.sessions_dir, session_id)
        session === nothing && return abort_with_error("session not found")
        session.pending_eval_id == eval_id || return abort_with_error("evaluation not found")
        if session.pending_eval_started_at !== nothing || !session.responding
            return follow_eval_sse!(state, session_id, eval_id, stream, stream_closed)
        end
        prompt_value = session.pending_user === nothing ? "" : session.pending_user
        isempty(prompt_value) && return abort_with_error("pending prompt missing")
        mark_session_eval_started!(state.sessions_dir, session) === nothing && return abort_with_error("evaluation already started")
    else
        prompt_value = prompt === nothing ? "" : strip(String(prompt))
        isempty(prompt_value) && return abort_with_error("prompt is required")
        session = get_session(state.sessions_dir, session_id)
        session === nothing && return abort_with_error("session not found")
        session.responding && return abort_with_error("session is already responding")
        session = begin_session_response!(state.sessions_dir, session_id, prompt_value)
        session === nothing && return abort_with_error("session is already responding")
        mark_session_eval_started!(state.sessions_dir, session)
    end
    eval_id_value === nothing && (eval_id_value = session.pending_eval_id)
    group_token = html_id_safe(String(eval_id_value))
    stream_group_id = "stream-group-$(group_token)"
    tool_calls_block_id = "tool-calls-$(group_token)"
    thinking_id = "thinking-$(group_token)"
    function ensure_tool_calls_block(timestamp::Int, event_name::String)
        if tool_calls_order[] === nothing || timestamp < tool_calls_order[]
            tool_calls_order[] = timestamp
        end
        if !tool_calls_started[]
            tool_calls_started[] = true
            order_value = tool_calls_order[]
            block_html = render_tool_calls_block_html(tool_calls_block_id, collect(values(tool_calls)); order=order_value, timestamp=order_value)
            safe_write(event_name, "<div hx-swap-oob=\"beforeend:#$(stream_group_id)\">$(block_html)</div>")
        end
        return nothing
    end
    function update_tool_calls_list(event_name::String)
        tool_calls_started[] || return nothing
        safe_write(event_name, render_tool_calls_list_oob_html(tool_calls_block_id, collect(values(tool_calls))))
        return nothing
    end
    function on_event(event)
        if event isa Agentif.AgentEvaluateStartEvent
            start_html = render_user_message_oob_html(prompt_value, user_id) * render_stream_group_oob_html(stream_group_id) * render_agent_status_oob_html(true)
            safe_write("AgentEvaluateStartEvent", start_html)
        elseif event isa Agentif.MessageStartEvent && event.role == :assistant
            return nothing
        elseif event isa Agentif.MessageUpdateEvent && event.role == :assistant
            if event.kind == :reasoning
                isempty(event.delta) && return nothing
                append_pending_reasoning!(state.sessions_dir, session, event.delta)
                if !thinking_started[]
                    thinking_started[] = true
                    safe_write("MessageUpdateEvent", render_thinking_message_oob_html(thinking_id, event.delta; order=event.timestamp, timestamp=event.timestamp, target_id=stream_group_id))
                else
                    safe_write("MessageUpdateEvent", render_thinking_delta_html(thinking_id, event.delta))
                end
            elseif event.kind == :text || event.kind == :refusal
                if !assistant_started[]
                    order_value = event.timestamp + STREAM_FINAL_ORDER_OFFSET
                    safe_write("MessageStartEvent", render_assistant_message_oob_html(assistant_id; order=order_value, timestamp=event.timestamp, target_id=stream_group_id))
                    assistant_started[] = true
                end
                isempty(event.delta) && return nothing
                append_pending_assistant!(state.sessions_dir, session, event.delta)
                safe_write("MessageUpdateEvent", render_assistant_delta_html(assistant_id, event.delta))
                assistant_text_started[] = true
            end
        elseif event isa Agentif.MessageEndEvent && event.role == :assistant
            final_text = message_text(event.message)
            final_reasoning = event.message.reasoning
            if !thinking_started[] && !isempty(final_reasoning)
                append_pending_reasoning!(state.sessions_dir, session, final_reasoning)
                thinking_started[] = true
                safe_write("MessageUpdateEvent", render_thinking_message_oob_html(thinking_id, final_reasoning; order=event.timestamp, timestamp=event.timestamp, target_id=stream_group_id))
            end
            if !assistant_started[] && (!isempty(final_text) || !isempty(final_reasoning))
                order_value = event.timestamp + STREAM_FINAL_ORDER_OFFSET
                safe_write("MessageStartEvent", render_assistant_message_oob_html(assistant_id; order=order_value, timestamp=event.timestamp, target_id=stream_group_id))
                assistant_started[] = true
            end
            if assistant_started[]
                if !assistant_text_started[] && !isempty(final_text)
                    append_pending_assistant!(state.sessions_dir, session, final_text)
                    safe_write("MessageUpdateEvent", render_assistant_delta_html(assistant_id, final_text))
                    assistant_text_started[] = true
                end
                safe_write("MessageEndEvent", render_assistant_done_html(assistant_id))
            end
        elseif event isa Agentif.ToolCallRequestEvent
            existing = get(() -> nothing, tool_calls, event.tool_call.call_id)
            entry = tool_call_entry_from_request(event, existing)
            tool_calls[event.tool_call.call_id] = entry
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
            ensure_tool_calls_block(event.timestamp, "ToolCallRequestEvent")
            update_tool_calls_list("ToolCallRequestEvent")
        elseif event isa Agentif.ToolExecutionStartEvent
            existing = get(() -> nothing, tool_calls, event.tool_call.call_id)
            entry = tool_call_entry_from_start(event, existing)
            tool_calls[event.tool_call.call_id] = entry
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
            ensure_tool_calls_block(event.timestamp, "ToolExecutionStartEvent")
            update_tool_calls_list("ToolExecutionStartEvent")
        elseif event isa Agentif.ToolExecutionEndEvent
            existing = get(() -> nothing, tool_calls, event.tool_call.call_id)
            entry = tool_call_entry_from_end(event, existing)
            tool_calls[event.tool_call.call_id] = entry
            upsert_tool_call_entry!(state.sessions_dir, session, entry)
            ensure_tool_calls_block(event.timestamp, "ToolExecutionEndEvent")
            update_tool_calls_list("ToolExecutionEndEvent")
        elseif event isa Agentif.AgentErrorEvent
            saw_error[] = true
            error_text = sprint(showerror, event.error)
            append_error_message!(state.sessions_dir, session, "Error: " * error_text)
            logged_error[] = true
            safe_write("AgentErrorEvent", render_error_html(error_text) * render_agent_status_oob_html(false))
        end
        return nothing
    end
    agent = build_http_agent(state, session.state)
    session, result, error_text = evaluate_session!(session, agent, prompt_value; title=title, on_event=on_event, append_input=false)
    if error_text !== nothing
        commit_pending_output!(state.sessions_dir, session)
        if !logged_error[]
            append_error_message!(state.sessions_dir, session, "Error: " * error_text)
            logged_error[] = true
        end
    end
    finalize_session_response!(state.sessions_dir, session)
    if error_text !== nothing && !saw_error[]
        safe_write("AgentErrorEvent", render_error_html(error_text) * render_agent_status_oob_html(false))
    end
    if session !== nothing
        list_html = render_session_list_html(list_user_sessions(state); active_id=session.id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        header_html = render_session_header_html(session)
        update_html = """<div hx-swap-oob=\"innerHTML:#session-list\">$(list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"outerHTML:#session-header\">$(header_html)</div>""" * render_agent_status_oob_html(false)
        safe_write("AgentEvaluateEndEvent", update_html)
    end
    return result
end

function api_list_sessions(state::HttpState)
    sessions = list_sessions(state.sessions_dir)
    summaries = [session_summary(session) for session in sessions]
    return Dict("ok" => true, "sessions" => summaries)
end

function api_list_scheduled_sessions(state::HttpState)
    sessions = list_scheduled_sessions(state.scheduled_dir)
    summaries = [scheduled_session_summary(session) for session in sessions]
    return Dict("ok" => true, "scheduled_sessions" => summaries)
end

function api_get_session(state::HttpState, session_id::String)
    session = get_session(state.sessions_dir, session_id)
    session === nothing && return Dict("ok" => false, "error" => "session not found")
    return Dict("ok" => true, "session" => session_detail(session))
end

function api_get_scheduled_session(state::HttpState, scheduled_id::String)
    session = get_scheduled_session(state.scheduled_dir, scheduled_id)
    session === nothing && return Dict("ok" => false, "error" => "scheduled session not found")
    return Dict("ok" => true, "scheduled_session" => scheduled_session_detail(session))
end

function api_new_session(state::HttpState, request::NewSessionRequest)
    session = new_session(state.sessions_dir; title=request.title)
    return Dict("ok" => true, "session" => session_detail(session))
end

function api_new_scheduled_session(state::HttpState, request::NewScheduledSessionRequest)
    session = new_scheduled_session(state.scheduled_dir; title=request.title, prompt=request.prompt, schedule=request.schedule)
    sync_scheduled_job!(state, session)
    return Dict("ok" => true, "scheduled_session" => scheduled_session_detail(session))
end

function api_update_session(state::HttpState, session_id::String, request::UpdateSessionRequest)
    session = update_session_title!(state.sessions_dir, session_id, request.title)
    session === nothing && return Dict("ok" => false, "error" => "session not found")
    return Dict("ok" => true, "session" => session_detail(session))
end

function api_update_scheduled_session(state::HttpState, scheduled_id::String, request::UpdateScheduledSessionRequest)
    session = update_scheduled_session!(state, scheduled_id; title=request.title, prompt=request.prompt, schedule=request.schedule)
    session === nothing && return Dict("ok" => false, "error" => "scheduled session not found")
    return Dict("ok" => true, "scheduled_session" => scheduled_session_detail(session))
end

function api_delete_session(state::HttpState, session_id::String)
    deleted = delete_session(state.sessions_dir, session_id)
    return Dict("ok" => deleted, "deleted" => deleted)
end

function api_delete_scheduled_session(state::HttpState, scheduled_id::String)
    deleted = delete_scheduled_session(state, scheduled_id)
    return Dict("ok" => deleted, "deleted" => deleted)
end

function api_run_scheduled_session(state::HttpState, scheduled_id::String)
    scheduled, prompt_value, error_text = prepare_scheduled_run(state, scheduled_id)
    error_text !== nothing && return Dict("ok" => false, "error" => error_text)
    session = start_scheduled_run!(state, scheduled, prompt_value)
    session === nothing && return Dict("ok" => false, "error" => "failed to start scheduled run")
    run_scheduled_session_async!(state, session, prompt_value; title=scheduled.title, scheduled_id=scheduled_id)
    return Dict("ok" => true, "session" => session_detail(session))
end

function register_options!(router::HTTP.Router, path::String)
    HTTP.register!(router, "OPTIONS", path, _ -> HTTP.Response(200))
    return nothing
end

function build_http_router(state::HttpState)
    router = HTTP.Router(HTTP.Handlers.default404, HTTP.Handlers.default405, Servo.cors_middleware)
    HTTP.register!(router, "GET", "/", _ -> html_response(read(joinpath(@__DIR__, "..", "web", "index.html"), String)))
    HTTP.register!(router, "GET", "/htmx-sse.js", _ -> js_response(read(joinpath(@__DIR__, "..", "web", "htmx-sse.js"), String)))
    HTTP.register!(router, "GET", "/ui/zero", _ -> html_response(render_zero_state_html()))
    HTTP.register!(router, "GET", "/ui/sessions", function (req)
        active_id = parse_query_param(req, "active_session_id")
        return html_response(render_session_list_html(list_user_sessions(state); active_id=active_id))
    end)
    HTTP.register!(router, "GET", "/ui/scheduled", function (req)
        active_session_id = parse_query_param(req, "active_session_id")
        active_scheduled_id = parse_query_param(req, "active_scheduled_id")
        list_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_scheduled_id=active_scheduled_id, active_session_id=active_session_id)
        return html_response(list_html)
    end)
    HTTP.register!(router, "POST", "/ui/sessions", function (_)
        session = new_session(state.sessions_dir; title=nothing)
        list_html = render_session_list_html(list_user_sessions(state); active_id=session.id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        view_html = render_session_view_html(session)
        body = list_html * "<div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"innerHTML:#session-view\">$(view_html)</div>"
        return html_response(body)
    end)
    HTTP.register!(router, "POST", "/ui/scheduled", function (_)
        scheduled = new_scheduled_session(state.scheduled_dir; title=nothing)
        sync_scheduled_job!(state, scheduled)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_scheduled_id=scheduled.id)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        view_html = render_scheduled_session_view_html(scheduled, state.sessions_dir)
        body = scheduled_html * "<div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div><div hx-swap-oob=\"innerHTML:#session-view\">$(view_html)</div>"
        return html_response(body)
    end)
    HTTP.register!(router, "GET", "/ui/sessions/{session_id}", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        session = get_session(state.sessions_dir, session_id)
        session === nothing && return html_response(render_zero_state_html(); status=404)
        list_html = render_session_list_html(list_user_sessions(state); active_id=session.id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        view_html = render_session_view_html(session)
        body = """$(view_html)<div hx-swap-oob=\"innerHTML:#session-list\">$(list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div>"""
        return html_response(body)
    end)
    HTTP.register!(router, "GET", "/ui/scheduled/{scheduled_id}", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        scheduled = get_scheduled_session(state.scheduled_dir, scheduled_id)
        scheduled === nothing && return html_response(render_zero_state_html(); status=404)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_scheduled_id=scheduled.id)
        view_html = render_scheduled_session_view_html(scheduled, state.sessions_dir)
        body = """$(view_html)<div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div>"""
        return html_response(body)
    end)
    HTTP.register!(router, "POST", "/ui/scheduled/{scheduled_id}/run", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        scheduled, prompt_value, error_text = prepare_scheduled_run(state, scheduled_id)
        error_text !== nothing && return html_response("", status=409)
        session = new_session(state.sessions_dir; title=scheduled.title)
        add_scheduled_session_run!(state.scheduled_dir, scheduled, session.id)
        session = begin_session_response!(state.sessions_dir, session.id, prompt_value)
        session === nothing && return html_response("", status=409)
        view_html = render_session_view_html(session; run_eval_id=session.pending_eval_id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        body = """$(view_html)<div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div>"""
        return html_response(body)
    end)
    HTTP.register!(router, "GET", "/ui/sessions/{session_id}/title/edit", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        session = get_session(state.sessions_dir, session_id)
        session === nothing && return html_response("", status=404)
        return html_response(render_session_title_edit_html(session))
    end)
    HTTP.register!(router, "PUT", "/ui/sessions/{session_id}/title", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        title_value = parse_form_param(req, "title")
        session = update_session_title!(state.sessions_dir, session_id, title_value)
        session === nothing && return html_response("", status=404)
        header_html = render_session_header_html(session)
        list_html = render_session_list_html(list_user_sessions(state); active_id=session.id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_session_id=session.id)
        body = header_html * "<div hx-swap-oob=\"innerHTML:#session-list\">$(list_html)</div><div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div>"
        return html_response(body)
    end)
    HTTP.register!(router, "GET", "/ui/scheduled/{scheduled_id}/title/edit", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        scheduled = get_scheduled_session(state.scheduled_dir, scheduled_id)
        scheduled === nothing && return html_response("", status=404)
        return html_response(render_scheduled_session_title_edit_html(scheduled, state.sessions_dir))
    end)
    HTTP.register!(router, "PUT", "/ui/scheduled/{scheduled_id}/title", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        title_value = parse_form_param(req, "title")
        scheduled = update_scheduled_session!(state, scheduled_id; title=title_value)
        scheduled === nothing && return html_response("", status=404)
        header_html = render_scheduled_session_header_html(scheduled, state.sessions_dir)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_scheduled_id=scheduled.id)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        body = header_html * "<div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div>"
        return html_response(body)
    end)
    HTTP.register!(router, "DELETE", "/ui/sessions/{session_id}", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        delete_session(state.sessions_dir, session_id)
        list_html = render_session_list_html(list_user_sessions(state))
        zero_html = render_zero_state_html()
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir)
        body = list_html * "<div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"innerHTML:#session-view\">$(zero_html)</div>"
        return html_response(body)
    end)
    HTTP.register!(router, "PUT", "/ui/scheduled/{scheduled_id}", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        params = parse_form_params(req)
        prompt_value = get(() -> nothing, params, "prompt")
        schedule_value = get(() -> nothing, params, "schedule")
        scheduled = update_scheduled_session!(state, scheduled_id; prompt=prompt_value, schedule=schedule_value)
        scheduled === nothing && return html_response("", status=404)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir; active_scheduled_id=scheduled.id)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        status_html = render_scheduled_status_oob_html(scheduled)
        cron_html = render_scheduled_cron_oob_html(scheduled)
        header_needed = prompt_value !== nothing || schedule_value !== nothing
        header_html = header_needed ? "<div hx-swap-oob=\"outerHTML:#scheduled-header\">$(render_scheduled_session_header_html(scheduled, state.sessions_dir))</div>" : ""
        body = """$(status_html)$(cron_html)$(header_html)<div hx-swap-oob=\"innerHTML:#scheduled-list\">$(scheduled_html)</div><div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div>"""
        return html_response(body)
    end)
    HTTP.register!(router, "DELETE", "/ui/scheduled/{scheduled_id}", function (req)
        scheduled_id = HTTP.getparams(req)["scheduled_id"]
        delete_scheduled_session(state, scheduled_id)
        scheduled_html = render_scheduled_list_html(list_scheduled_sessions(state.scheduled_dir), state.sessions_dir)
        session_list_html = render_session_list_html(list_user_sessions(state); active_id=nothing)
        zero_html = render_zero_state_html()
        body = """$(scheduled_html)<div hx-swap-oob=\"innerHTML:#session-list\">$(session_list_html)</div><div hx-swap-oob=\"innerHTML:#session-view\">$(zero_html)</div>"""
        return html_response(body)
    end)
    HTTP.register!(router, "POST", "/ui/sessions/{session_id}/evaluate", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        session = get_session(state.sessions_dir, session_id)
        session === nothing && return html_response("", status=404)
        prompt = parse_form_param(req, "prompt")
        prompt_value = prompt === nothing ? "" : strip(prompt)
        isempty(prompt_value) && return html_response("", status=400)
        session.responding && return html_response(render_error_html("Session is already responding.") * render_agent_status_oob_html(false))
        session = begin_session_response!(state.sessions_dir, session_id, prompt_value)
        session === nothing && return html_response(render_error_html("Session is already responding.") * render_agent_status_oob_html(false))
        return html_response(render_sse_shell_html(session_id; eval_id=session.pending_eval_id))
    end)
    Servo.@GET(router, "/v1/sessions", function list_sessions_route()
        return api_list_sessions(state)
    end)
    Servo.@POST(router, "/v1/sessions", function new_session_route(request::NewSessionRequest)
        return api_new_session(state, request)
    end)
    Servo.@GET(router, "/v1/sessions/{session_id}", function get_session_route(session_id::String)
        return api_get_session(state, session_id)
    end)
    Servo.@PUT(router, "/v1/sessions/{session_id}", function update_session_route(session_id::String, request::UpdateSessionRequest)
        return api_update_session(state, session_id, request)
    end)
    Servo.@DELETE(router, "/v1/sessions/{session_id}", function delete_session_route(session_id::String)
        return api_delete_session(state, session_id)
    end)
    Servo.@GET(router, "/v1/scheduled-sessions", function list_scheduled_route()
        return api_list_scheduled_sessions(state)
    end)
    Servo.@POST(router, "/v1/scheduled-sessions", function new_scheduled_route(request::NewScheduledSessionRequest)
        return api_new_scheduled_session(state, request)
    end)
    Servo.@GET(router, "/v1/scheduled-sessions/{scheduled_id}", function get_scheduled_route(scheduled_id::String)
        return api_get_scheduled_session(state, scheduled_id)
    end)
    Servo.@PUT(router, "/v1/scheduled-sessions/{scheduled_id}", function update_scheduled_route(scheduled_id::String, request::UpdateScheduledSessionRequest)
        return api_update_scheduled_session(state, scheduled_id, request)
    end)
    Servo.@DELETE(router, "/v1/scheduled-sessions/{scheduled_id}", function delete_scheduled_route(scheduled_id::String)
        return api_delete_scheduled_session(state, scheduled_id)
    end)
    Servo.@POST(router, "/v1/scheduled-sessions/{scheduled_id}/run", function run_scheduled_route(scheduled_id::String)
        return api_run_scheduled_session(state, scheduled_id)
    end)
    HTTP.register!(router, "GET", "/v1/sessions/{session_id}/evaluate", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        eval_id = parse_query_param(req, "eval_id")
        prompt = parse_query_param(req, "prompt")
        title = normalize_title(parse_query_param(req, "title"))
        prompt_value = prompt === nothing ? "" : strip(prompt)
        if eval_id === nothing
            isempty(prompt_value) && return HTTP.Response(400, "prompt is required")
        end
        response = HTTP.Response(200)
        stream = HTTP.sse_stream(response)
        errormonitor(Threads.@spawn begin
            try
                evaluate_sse!(state, session_id; prompt=prompt_value, eval_id=eval_id, title=title, stream=stream)
            finally
                close(stream)
            end
        end)
        return response
    end)
    HTTP.register!(router, "POST", "/v1/sessions/{session_id}/evaluate", function (req)
        session_id = HTTP.getparams(req)["session_id"]
        body = try
            JSON.parse(req.body)
        catch
            return HTTP.Response(400, "invalid JSON body")
        end
        prompt_raw = get(() -> nothing, body, "prompt")
        title_raw = get(() -> nothing, body, "title")
        prompt_value = prompt_raw isa AbstractString ? strip(String(prompt_raw)) : ""
        isempty(prompt_value) && return HTTP.Response(400, "prompt is required")
        title = title_raw isa AbstractString ? normalize_title(String(title_raw)) : nothing
        response = HTTP.Response(200)
        stream = HTTP.sse_stream(response)
        errormonitor(Threads.@spawn begin
            try
                evaluate_sse!(state, session_id; prompt=prompt_value, title=title, stream=stream)
            finally
                close(stream)
            end
        end)
        return response
    end)
    register_options!(router, "/")
    register_options!(router, "/htmx-sse.js")
    register_options!(router, "/ui/zero")
    register_options!(router, "/ui/sessions")
    register_options!(router, "/ui/scheduled")
    register_options!(router, "/ui/sessions/{session_id}")
    register_options!(router, "/ui/scheduled/{scheduled_id}")
    register_options!(router, "/ui/scheduled/{scheduled_id}/run")
    register_options!(router, "/ui/sessions/{session_id}/title/edit")
    register_options!(router, "/ui/sessions/{session_id}/title")
    register_options!(router, "/ui/scheduled/{scheduled_id}/title/edit")
    register_options!(router, "/ui/scheduled/{scheduled_id}/title")
    register_options!(router, "/ui/sessions/{session_id}/evaluate")
    register_options!(router, "/v1/scheduled-sessions")
    register_options!(router, "/v1/scheduled-sessions/{scheduled_id}")
    register_options!(router, "/v1/scheduled-sessions/{scheduled_id}/run")
    register_options!(router, "/v1/sessions/{session_id}/evaluate")
    return router
end

const HTTP_SCHEDULER_STATE = Ref{Union{Nothing,HttpState}}(nothing)
const HTTP_SCHEDULER_TASK = Ref{Union{Nothing,Task}}(nothing)

function start_http_scheduler!(state::HttpState)
    sync_http_scheduler!(state)
    HTTP_SCHEDULED_DISPATCH[] = scheduled_id -> enqueue_http_scheduled_session!(state, scheduled_id)
    task = errormonitor(Threads.@spawn Tempus.run!(state.scheduler))
    HTTP_SCHEDULER_STATE[] = state
    HTTP_SCHEDULER_TASK[] = task
    return task
end

function stop_http_scheduler!()
    state = HTTP_SCHEDULER_STATE[]
    task = HTTP_SCHEDULER_TASK[]
    HTTP_SCHEDULED_DISPATCH[] = nothing
    HTTP_SCHEDULER_STATE[] = nothing
    HTTP_SCHEDULER_TASK[] = nothing
    state === nothing && return nothing
    try
        Tempus.close(state.scheduler)
    catch err
        @warn "Failed to close HTTP scheduler" exception=(err, catch_backtrace())
    end
    task !== nothing && (try
        wait(task)
    catch
    end)
    return nothing
end

function run_http!(; host::Union{Nothing,String}=nothing, port::Union{Nothing,Int}=nothing, data_dir::Union{Nothing,String}=nothing, base_dir::Union{Nothing,String}=nothing)
    state = build_http_state(; data_dir=data_dir, base_dir=base_dir)
    start_http_scheduler!(state)
    host_value = host === nothing ? http_host() : host
    port_value = port === nothing ? http_port() : port
    router = build_http_router(state)
    @info "Vo HTTP server starting" host=host_value port=port_value sessions_dir=state.sessions_dir base_dir=state.base_dir
    return HTTP.serve!(router, host_value, port_value)
end

function run_http(; host::Union{Nothing,String}=nothing, port::Union{Nothing,Int}=nothing, data_dir::Union{Nothing,String}=nothing, base_dir::Union{Nothing,String}=nothing)
    Base.exit_on_sigint(false)
    server = run_http!(; host=host, port=port, data_dir=data_dir, base_dir=base_dir)
    try
        while isopen(server)
            sleep(0.2)
        end
    catch err
        if err isa InterruptException
            HTTP.forceclose(server)
            return nothing
        end
        rethrow()
    finally
        stop_http_scheduler!()
        isopen(server) && close(server)
    end
    return nothing
end
