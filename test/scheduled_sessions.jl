using Tempus

function dummy_http_state(dir::String)
    sessions_dir = joinpath(dir, "sessions")
    scheduled_dir = joinpath(dir, "scheduled")
    mkpath(sessions_dir)
    mkpath(scheduled_dir)
    model = dummy_model()
    config = Vo.AgentConfig("dummy", "dummy", "x", "prompt", model)
    scheduler_store = Tempus.FileStore(joinpath(dir, "scheduler.bin"))
    scheduler = Tempus.Scheduler(scheduler_store)
    return Vo.HttpState(sessions_dir, scheduled_dir, scheduler, config, Agentif.AgentTool[], dir)
end

function find_job(store::Tempus.Store, job_name::String)
    for job in Tempus.getJobs(store)
        job.name == job_name && return job
    end
    return nothing
end

@testset "scheduled sessions" begin
    mktempdir() do dir
        state = dummy_http_state(dir)
        scheduled = Vo.new_scheduled_session(state.scheduled_dir; title=nothing)
        @test scheduled.id != ""
        @test scheduled.schedule !== nothing
        @test scheduled.is_valid == false
        loaded = Vo.get_scheduled_session(state.scheduled_dir, scheduled.id)
        @test loaded !== nothing
        updated = Vo.update_scheduled_session!(state, scheduled.id; prompt="Daily check-in", schedule="0 4 * * *")
        @test updated !== nothing
        @test updated.is_valid
        @test updated.title == Vo.derive_title("Daily check-in")
        job_name = Vo.scheduled_job_name(scheduled.id)
        job = find_job(state.scheduler.store, job_name)
        @test job !== nothing
        @test job.schedule == Tempus.parseCron("0 4 * * *")
        updated = Vo.update_scheduled_session!(state, scheduled.id; prompt="Daily check-in v2")
        @test updated.prompt == "Daily check-in v2"
        job_after_prompt = find_job(state.scheduler.store, job_name)
        @test job_after_prompt === job
        updated = Vo.update_scheduled_session!(state, scheduled.id; schedule="0 5 * * *")
        @test updated.is_valid
        job_after_schedule = find_job(state.scheduler.store, job_name)
        @test job_after_schedule !== nothing
        @test job_after_schedule !== job
        @test job_after_schedule.schedule == Tempus.parseCron("0 5 * * *")
        updated = Vo.update_scheduled_session!(state, scheduled.id; schedule="not a cron")
        @test updated.is_valid == false
        @test find_job(state.scheduler.store, job_name) === nothing
        updated = Vo.add_scheduled_session_run!(state.scheduled_dir, updated, "session-1")
        @test updated.session_ids[1] == "session-1"
        @test Vo.delete_scheduled_session(state, scheduled.id)
    end
end

@testset "scheduled runs filtered from session list" begin
    mktempdir() do dir
        state = dummy_http_state(dir)
        manual = Vo.new_session(state.sessions_dir; title="Manual")
        scheduled = Vo.new_scheduled_session(state.scheduled_dir; title="Scheduled", prompt="Hello", schedule="0 4 * * *")
        run = Vo.new_session(state.sessions_dir; title="Run")
        Vo.add_scheduled_session_run!(state.scheduled_dir, scheduled, run.id)
        sessions = Vo.list_user_sessions(state)
        @test any(session -> session.id == manual.id, sessions)
        @test all(session -> session.id != run.id, sessions)
    end
end
