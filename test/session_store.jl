function dummy_model()
    return Agentif.Model(; id="dummy", name="Dummy", api="openai-completions", provider="dummy", baseUrl="http://localhost", reasoning=false, input=["text"], cost=Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0), contextWindow=4096, maxTokens=256, headers=nothing, kw=(;))
end

function fake_evaluator(agent::Agentif.Agent, prompt::String, on_event::Function; append_input::Bool=true)
    on_event(Agentif.AgentEvaluateStartEvent())
    user = Agentif.UserMessage(prompt)
    assistant = Agentif.AssistantMessage(; text="Echo: $(prompt)")
    on_event(Agentif.MessageStartEvent(:assistant, assistant))
    on_event(Agentif.MessageUpdateEvent(:assistant, assistant, :text, assistant.text, nothing))
    on_event(Agentif.MessageEndEvent(:assistant, assistant))
    push!(agent.state.messages, user)
    push!(agent.state.messages, assistant)
    result = Agentif.AgentResult(; message=assistant, usage=Agentif.Usage(), pending_tool_calls=Agentif.PendingToolCall[], stop_reason=:stop)
    on_event(Agentif.AgentEvaluateEndEvent(result))
    return result
end

@testset "session store" begin
    mktempdir() do dir
        session = Vo.new_session(dir; title="First")
        @test session.id != ""
        @test session.title == "First"
        loaded = Vo.get_session(dir, session.id)
        @test loaded !== nothing
        @test loaded.title == "First"
        sessions = Vo.list_sessions(dir)
        @test length(sessions) == 1
        @test sessions[1].id == session.id
        @test Vo.delete_session(dir, session.id)
        @test Vo.get_session(dir, session.id) === nothing
    end
end

@testset "session list ordering" begin
    mktempdir() do dir
        session_one = Vo.new_session(dir; title="One")
        session_two = Vo.new_session(dir; title="Two")
        session_one = Vo.StoredSession(; id=session_one.id, title=session_one.title, created_at=session_one.created_at, updated_at="2024-01-01T00:00:00.000Z", state=session_one.state)
        session_two = Vo.StoredSession(; id=session_two.id, title=session_two.title, created_at=session_two.created_at, updated_at="2024-02-01T00:00:00.000Z", state=session_two.state)
        Vo.save_session!(dir, session_one)
        Vo.save_session!(dir, session_two)
        sessions = Vo.list_sessions(dir)
        @test sessions[1].id == session_two.id
    end
end

@testset "update session title" begin
    mktempdir() do dir
        session = Vo.new_session(dir; title=nothing)
        updated = Vo.update_session_title!(dir, session.id, "Renamed")
        @test updated !== nothing
        @test updated.title == "Renamed"
        updated = Vo.update_session_title!(dir, session.id, "")
        @test updated.title == "New Session"
    end
end

@testset "evaluate session updates state" begin
    mktempdir() do dir
        session = Vo.new_session(dir; title=nothing)
        agent = Agentif.Agent(; prompt="test", model=dummy_model(), apikey="x", tools=Agentif.AgentTool[], state=session.state)
        session, result, error_text = Vo.evaluate_session!(session, agent, "Hello"; evaluator=fake_evaluator)
        @test error_text === nothing
        @test result !== nothing
        @test length(session.state.messages) == 2
        @test session.state.messages[1] isa Agentif.UserMessage
        @test session.state.messages[2] isa Agentif.AssistantMessage
        @test session.title == "Hello"
    end
end

@testset "begin session response persists pending state" begin
    mktempdir() do dir
        session = Vo.new_session(dir; title=nothing)
        started = Vo.begin_session_response!(dir, session.id, "Hello there")
        @test started !== nothing
        @test started.responding
        @test started.pending_user == "Hello there"
        @test started.pending_eval_id !== nothing
        @test started.pending_eval_started_at === nothing
        @test started.state.messages[end] isa Agentif.UserMessage
        @test started.state.messages[end].text == "Hello there"
    end
end

@testset "tool events do not override session preview" begin
    mktempdir() do dir
        session = Vo.new_session(dir; title=nothing)
        session = Vo.begin_session_response!(dir, session.id, "Ping")
        session === nothing && error("session should be available")
        entry = Vo.ToolCallEntry(; call_id="demo", name="demo", arguments="{}", requested_at=1)
        Vo.upsert_tool_call_entry!(dir, session, entry)
        loaded = Vo.get_session(dir, session.id)
        @test Vo.session_preview(loaded) == "Ping"
    end
end

@testset "render assistant messages" begin
    empty_html = Vo.render_messages_html(Agentif.AgentMessage[Agentif.AssistantMessage()])
    @test isempty(empty_html)
    no_thinking_html = Vo.render_messages_html(Agentif.AgentMessage[Agentif.AssistantMessage(; text="Hello")])
    @test !occursin("<details class=\"msg-thinking\"", no_thinking_html)
    reasoning_html = Vo.render_messages_html(Agentif.AgentMessage[Agentif.AssistantMessage(; reasoning="Why")])
    @test occursin("<details class=\"msg-thinking\"", reasoning_html)
end
